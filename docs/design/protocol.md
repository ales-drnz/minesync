# MineSync: protocol and storage

This document describes the hub API, the hub data layout and the client
state, including the hub web UI, the Admin area and the hub extras. It is
the contract between `ms_core` (client engine), `apps/hub`, `apps/hub_web`,
`apps/desktop` and `apps/cli`; the Dart models live in
`packages/ms_protocol`. The behaviour rules are listed in
`docs/spec/behaviour.md`.

## Concepts

- **Hub**: the always-on server (usually a NAS container). It owns every
  file, the history and the lock. Clients only speak HTTP to it.
- **Space**: one synced folder, usually a Minecraft server. Has a `profile`
  (`minecraft` or `generic`) that decides default exclusions and client
  behaviour.
- **Generation**: an immutable snapshot of a space. History is linear:
  generation `n` has parent `n-1`. A restore creates a new generation equal
  to an old one; nothing is ever rewritten.
- **Blob**: content addressed by SHA-256 (lower-case hex). Stored once per
  hub, shared by every space.
- **Lock**: at most one member hosts a space at a time. Pushing needs the
  lock.
- **Member**: a ZeroTier network member. The network is the authentication;
  there are no passwords. Roles: `member`, `admin`.

## Manifest

A generation's file map. Keys are paths, values are entries:

```json
{
  "world/region/r.0.0.mca": {
    "size": 9437184,
    "h": "<sha256 of the whole file>",
    "chunks": [{"h": "<sha256>", "size": 524288}, "..."],
    "x": false
  }
}
```

- `h` is always the hash of the whole file, so a reassembled file is always
  verified end to end.
- `chunks` is present only for files of at least 2 MiB. Chunk boundaries are
  content-defined (FastCDC, gear hash, min 256 KiB, average 512 KiB, max
  2 MiB, normalised masks). The gear table is generated with splitmix64 from
  a fixed seed; changing any parameter breaks deduplication, so they are
  constants of the protocol (`ms_protocol/chunking`).
- For files without `chunks`, the blob is `h`. For chunked files the blobs
  are the chunks; `h` is not stored as a blob.
- `x` marks the executable bit (start scripts on Linux/macOS).

### Paths

A path is valid only if all of these hold (checked by client and hub on
everything they send or receive):

- relative, `/`-separated, UTF-8, Unicode NFC, at most 1024 bytes;
- no empty, `.` or `..` segment, no leading or trailing `/`, no `\`;
- no control characters (U+0000–U+001F, U+007F);
- portable to Windows: no `< > : " | ? *`, no segment ending in a dot or a
  space, no reserved device names (`CON`, `PRN`, `AUX`, `NUL`, `COM1`–`COM9`,
  `LPT1`–`LPT9`, with or without an extension, any case);
- no two paths in one manifest equal under case folding (they would collide
  on Windows and macOS).

Paths starting with `.minesync` are reserved and never synced.

### Digest

`digest` = SHA-256 of the canonical encoding of the manifest: entries sorted
by path (byte order of the UTF-8), each encoded as JSON with keys in the
fixed order `size, h, chunks, x`, no whitespace, joined into one JSON object.
`ms_protocol` owns the encoder; client and hub must produce identical bytes.

## Hub API (v1)

Base path `/api/v1`. Bodies are JSON (`application/json`), except blob
transfers (`application/octet-stream`).

### Rules for every request

- Identity is the caller's ZeroTier address, resolved to a member through
  ZTNET. Forwarded headers are never trusted.
- State-changing requests (`POST`, `PUT`, `PATCH`, `DELETE`) must carry
  `X-MineSync: 1` and must not be `Sec-Fetch-Site: cross-site`.
- `Host` must be an IP literal, a name in the hub's DNS zone or a name in
  the configured allow-list (DNS rebinding).
- Errors are `{"error": {"code": "...", "message": "...", "details": {}}}`.
  `message` is English for logs; clients translate from `code`.

### Error codes

| HTTP | code | meaning |
|---|---|---|
| 400 | `bad_request` | malformed body or parameter |
| 400 | `bad_path` | a path failed validation (`details.path`) |
| 401 | `unauthenticated` | caller is not a known network member |
| 403 | `forbidden` | admin only, or cross-site request |
| 404 | `not_found` | no such space, generation, push or blob |
| 404 | `space_gone` | the space was deleted (heartbeat, push) |
| 409 | `stale_base` | parent generation or digest is not HEAD |
| 409 | `mass_delete` | push removes too many files; retry with `confirmMassDelete` (admin) |
| 409 | `locked` | someone else holds a live lock (`details.lock`) |
| 409 | `lock_lost` | the lock token is no longer the holder |
| 409 | `push_incomplete` | commit with blobs still missing (`details.missing`) |
| 409 | `is_head` | the operation is not allowed on HEAD (delete generation) |
| 409 | `blobs_missing` | a generation references blobs the hub lost (`details.missing`, ZIP export) |
| 409 | `not_locked` | needs a live `play` lock (port test) |
| 409 | `feature_off` | the feature is switched off in the Admin area or by env |
| 409 | `from_config` | a `MINESYNC_ADMINS` admin cannot be demoted from the UI |
| 409 | `last_admin` | the change would leave the hub without any admin |
| 410 | `push_expired` | the push session timed out |
| 413 | `too_large` | body above the limit for that call |
| 422 | `bad_hash` | uploaded bytes do not match the hash or size |
| 429 | `rate_limited` | called again too soon (`details.retryMs`) |
| 500 | `internal` | unexpected error, or an unreadable generation blocks the operation |
| 502 | `upstream` | Telegram or ZTNET answered with an error (`details.error`, never a secret) |
| 507 | `disk_full` | free space below the configured minimum |

Validation errors on settings and bodies use `bad_request` with
`details.field` (`section.field`, or `topics.<spaceId>`).

### Endpoints

| Method and path | Use |
|---|---|
| `GET /hub` | hub name, version, API version, server time, disk, caller (`me`) |
| `GET /spaces` | list with HEAD summary and lock state |
| `POST /spaces` | create (admin): `{name, profile}` |
| `GET /spaces/{id}` | details: HEAD, lock, effective exclusions, settings |
| `PATCH /spaces/{id}` | rename, own exclusions, per-space overrides (admin) |
| `DELETE /spaces/{id}` | delete (admin; refused with a live lock) |
| `GET /spaces/{id}/generations?before=N&limit=M` | history, newest first |
| `GET /spaces/{id}/generations/{n\|head}` | summary plus manifest |
| `POST /spaces/{id}/restore` | `{generation}` → new generation (admin; refused with a live lock held by someone else) |
| `GET /blobs/{hash}` | blob bytes (`Range` supported) |
| `POST /spaces/{id}/pushes` | begin: `{parent, parentDigest, lockToken, message, manifest, confirmMassDelete?}` → `{pushId, missing[]}` |
| `PUT /pushes/{pushId}/blobs/{hash}` | upload one missing blob, re-hashed by the hub |
| `POST /pushes/{pushId}/commit` | atomic commit → generation summary (idempotent) |
| `DELETE /pushes/{pushId}` | abort |
| `POST /spaces/{id}/lock` | acquire: `{info, force?}` → `{token, ttlMs, heartbeatMs}` |
| `POST /spaces/{id}/lock/heartbeat` | `{token, info}` renews |
| `DELETE /spaces/{id}/lock` | `{token}` releases (or admin force) |
| `GET /events?after=SEQ` | recent events |
| `GET /events?before=SEQ&limit=M` | older events, newest first (see "Events") |
| `GET /events/stream` | the same as Server-Sent Events, resumable with `Last-Event-ID` |
| `GET /settings`, `PATCH /settings/{section}` | Admin settings (admin; see "Settings") |

The hub web, Admin and extras endpoints are listed in "Hub web, Admin
area and extras endpoints" below.

### Push

1. **Begin.** The client sends the proposed manifest, the generation it is
   based on (`parent`, `parentDigest`) and its lock token. The hub checks,
   in order: the space exists, paths are valid, the lock token is the
   holder, `parent`/`parentDigest` match HEAD (`stale_base` otherwise), the
   mass-delete guard, free disk space. It answers with the blobs it does
   not have.
2. **Upload.** Each missing blob is `PUT` once (parallel is fine). The hub
   streams it to a temporary file, hashing as it goes, refuses more bytes
   than the manifest declared, and moves it into the store only if the hash
   matches. Uploading a blob the hub already has is a no-op success.
3. **Commit.** The hub re-checks lock and HEAD, checks every blob is
   present, writes the generation file, then moves HEAD (both atomically).
   Committing the same push twice returns the same generation.

A push session expires after 1 hour without activity. Its uploaded blobs are
treated as referenced by GC while it is open.

### Lock

- TTL 90 s; the client heartbeats every 20 s (`ttlMs` and `heartbeatMs` are
  returned so they can change without a client update).
- An expired lock is *stale*: anyone may take it. Taking a live lock held by
  someone else needs `force: true` and admin rights.
- `info` carries what the hub shows: client version, players online, game
  port, address. It is updated by heartbeats.
- The lock lives in memory under the space's mutex; `lock.json` only lets it
  survive a hub restart.

## Hub web, Admin area and extras

Models: `ms_protocol` `admin.dart`, `world.dart`, `history.dart`,
`telegram.dart`, `dl.dart`, `event_types.dart`, plus optional fields in
`models.dart`. Every rule below is hot-applied: no hub restart.

### Hub web, Admin area and extras endpoints

All under `/api/v1`; "admin" = 403 `forbidden` for members. GETs never need
`X-MineSync`; everything else does (the general rules apply).

| Method and path | Who | Use → response model |
|---|---|---|
| `GET /spaces/{id}/world` | all | level.dat + server.properties + chip of HEAD → `WorldInfo` |
| `GET /spaces/{id}/icon` | all | `server-icon.png` of HEAD (`image/png`) |
| `GET /spaces/{id}/players` | all | players of HEAD → `PlayerList` |
| `GET /spaces/{id}/mods` | all | jars in `mods/` of HEAD → `ModList` |
| `GET /spaces/{id}/mods/{file}/icon` | all | icon of one jar (`image/png`) |
| `GET /spaces/{id}/stats` | all | sessions and rankings → `SpaceStats` |
| `GET /spaces/{id}/generations/{n}/diff?limit=120` | all | changes vs parent → `GenerationChanges` |
| `GET /spaces/{id}/generations/{n\|head}/zip` | all | the generation as a streamed ZIP |
| `GET /spaces/{id}/generations/{n}/freed` | admin | `{n, bytes}` freed by deleting it |
| `DELETE /spaces/{id}/generations/{n}` | admin | delete a non-HEAD generation → `{deleted, bytes}` |
| `POST /spaces/{id}/restore-file` | admin | `RestoreFileRequest` → new `GenerationSummary` (201) |
| `POST /spaces/{id}/lock/port-check` | all | re-run the port test → `PortCheck` |
| `POST /spaces/{id}/gc/preview` | admin | `{keep?}` or `{history?}` → `GcPreview` (one row) |
| `POST /spaces/{id}/gc` | admin | `{keep?}` → `GcReport` |
| `POST /gc/preview` | admin | the same for every space → `GcPreview` |
| `POST /gc` | admin | clean every space now → `GcReport` |
| `GET /usage` | all | disk use per space → `HubUsage` |
| `POST /exclusions/test` | admin | `{path, profile?\|spaceId?, patterns?}` → `ExclusionTest` |
| `GET /members` | admin | members and ZTNET status → `MemberList` |
| `PUT /members/{id}/role` | admin | `{role}` → `MemberInfo` |
| `POST /members/refresh` | admin | refresh from ZTNET now ("check now") → `ZtnetStatus` |
| `GET /system` | admin | read-only system info → `SystemInfo` |
| `GET /telegram` | admin | bot settings (no token) and state → `TelegramStatus` |
| `PATCH /telegram` | admin | `TelegramPatch` → `TelegramStatus` |
| `POST /telegram/test` | admin | send a test message → `TelegramTestResult` |
| `POST /telegram/find-chat` | admin | `{token?}` → `{chats: [TelegramChat]}` |
| `GET /dl` | all | desktop downloads → `DlListing` |

Changed: `GET /hub` adds `language` (Admin › General, `auto`/`it`/`en`) and
`dnsZone` (only with the DNS server on). `GET /spaces` / `GET /spaces/{id}`
add `dnsName`, `world` (`WorldChip`), `lastSession` and, on the lock,
`ip` and `portCheck`. `GET /spaces/{id}` adds `profileExclusions`,
`settings` (effective `sessions`/`history`/`protection`), `inherited` (the
hub-wide values of the same sections), `overrides` and `usage`.

### Settings

`GET /settings` (admin) → `HubSettings`:
`{"sections": {...}, "defaults": {...}, "changed": {"by", "byId", "at", "section"}}`.
`defaults` are the factory values (the UI shows "Default: …" and "Reset").
`PATCH /settings/{section}` takes a partial object, validates every field
(`bad_request`, `details.field`; nothing saved on error), applies it at once
and returns the whole `HubSettings`. Unknown section → 404. `telegram` is
not a section of this endpoint (404); it has its own endpoints.

| Section | Field | Type, range | Default |
|---|---|---|---|
| `general` | `name` | text 1–40, no control chars | `MineSync` |
| | `language` | `auto` \| `it` \| `en` (bot and clients without a choice) | `auto` |
| `members` | `trustHours` | 0–8760; known members stay recognised while ZTNET is down; 0 = always | 24 |
| | `refreshSeconds` | 10–3600; ZTNET refresh period | 30 |
| `history` | `keepLast`, `keepHours`, `keepDays` | automatic retention (B-RET) | 30, 24, 7 |
| `disk` | `minFreeGiB` | 0–100000 | 1 |
| | `minFreePercent` | 0–50 | 2 |
| `sessions` | `autosaveMinutes` | 1–1440 | 5 |
| | `autostop`, `autostopMinutes` | bool; 1–1440 minutes without players | true, 30 |
| | `crashRestarts` | 0–10 | 2 |
| | `portTest` | bool | true |
| `protection` | `massDeleteRatio`, `massDeleteMinFiles` | mass-delete guard (B-GUARD); the client asks for confirmation at the same threshold | 0.5, 20 |
| `exclusions` | `minecraft`, `generic` | list ≤ 500 patterns, each 1–256 chars | `minecraftExclusions`, `genericExclusions` |
| `stats` | `sessionsKept` | 1–1000 sessions per space | 40 |

- Free-space threshold = max(`minFreeGiB` GiB, `minFreePercent` % of the
  volume) (`DiskSettings.thresholdFor`). `MINESYNC_MIN_FREE`, when set,
  wins and `SystemInfo.minFreeEnv` shows it. `DiskInfo.minFree` is always the
  effective value.
- Exclusions: spaces inherit their profile list live (a change applies from
  the next push or scan). The system patterns (`systemExclusions`) are not
  part of the list, always apply and are dropped if sent.
- Per-space overrides: `PATCH /spaces/{id}` `overrides` accepts the sections
  `sessions`, `history`, `protection` with partial fields; `{}` or `null` for
  a section (or omitting a field) means "inherit". A section present in the
  PATCH replaces that section's saved override; sections not named stay as
  they are. Errors name `details.field = overrides.<section>[.<field>]`. Own
  exclusions stay `exclusions` on the space.
  In `GET /spaces/{id}` `settings`/`inherited`, a missing section decodes as
  factory defaults; the fields of a present section are required.
- Every successful PATCH (also `/telegram` and space overrides) updates
  `changed` and publishes `settings` (or `space.update`). Space overrides
  record `changed.section = spaces`.
- `members` applies to the ZTNET resolver at once (`ttl`, `grace`; 0 =
  unlimited grace).
- `sessions` reaches the desktop through `GET /spaces/{id}` `settings`; the
  app reads it when a session starts and at each autosave.

`POST /exclusions/test` (admin): `{path, profile?, spaceId?, patterns?}`.
With `patterns` it tests that unsaved list (plus system patterns) and
reports `source: draft`; otherwise it uses the space's (or profile's)
effective list (neither given = the `minecraft` profile). `path` is any
string ≤ 1024 bytes (not path-validated, so
`logs/` works). Response: `{path, excluded, pattern?, source?}`; `pattern` is
the first matching pattern as written (`Exclusions.firstMatch`, also usable
in the browser).

### World metadata, players, mods

Computed by the hub from the blobs of HEAD and cached per `(space, digest)`
under `cache/world/<space>/<digest>.json` plus a small in-memory LRU (a
generation is immutable). Space with no HEAD: 200 with
`n: 0` and empty data. Paths: `server.properties` at the root; the level
folder is `level-name` (default `world`); `<level>/level.dat`,
`<level>/stats/<uuid>.json`, `ops.json`, `whitelist.json`, `usercache.json`.

- `level.dat` (gzip NBT, B-META-01/04): ≤ 16 MiB decompressed, ≤ 300 000
  nodes, list lengths checked against remaining bytes. Spawn from
  `SpawnX/Y/Z` or the newer `Data.spawn.pos` int array; seed falls back to
  `<level>/data/minecraft/world_gen_settings.dat` (26.1+). `seed` is a decimal
  **string** (64-bit, not safe as a JS number). `day = Time / 24000`,
  `timeTicks = Time`.
- `server.properties`: `motd` with `§x` codes removed, `maxPlayers`, `pvp`,
  `whitelist` (`white-list`), `whitelistCount` (entries of whitelist.json),
  `viewDistance`, `simulationDistance`, `port`, `onlineMode`. Missing keys
  are omitted, never invented.
- Chip (`WorldChip`): `mcVersion` from level.dat `Version.Name`; `loader`
  from the files present (`fabric-server-launch.jar`/`.fabric` → fabric,
  `libraries/net/neoforged` → neoforge, `libraries/net/minecraftforge` →
  forge, `quilt-server-launch.jar` → quilt, `paper*.jar` → paper, otherwise
  `vanilla` if a `server.jar`/level exists, else null; quilt is checked
  first because a Quilt server also carries Fabric libraries); `loaderVersion` from
  the library folder name; `mods` = jars in `mods/`.
- Mods (B-META-02/03): only `mods/*.jar` (top level). The hub reads the ZIP
  central directory and at most `fabric.mod.json`, `quilt.mod.json`,
  `META-INF/mods.toml`, `META-INF/neoforge.mods.toml` (each ≤ 1 MiB) and the
  declared icon. `homepage` keeps only `http`/`https` URLs, trimmed
  (B-META-05). `icon` is true only for a PNG ≤ 512 KiB (magic checked).
  `since`/`updated` are computed over retained generations only (may be
  null). `changed` = added or changed in HEAD vs its parent. `{file}` in
  the icon URL is the jar name, percent-encoded; unknown → 404.
- Icons (`/icon`, `/mods/{file}/icon`): `image/png`,
  `Cache-Control: private, max-age=86400`, `ETag` = blob hash; 404 if none.
- Players: union of uuids in `stats/`, ops.json, whitelist.json. `name` from
  usercache.json, ops.json or whitelist.json (null if none has it).
  `online` = name in the live lock's `info.players`. `lastSeen` is only an
  estimate (`usercache.json` `expiresOn` − 1 month). Stats keys:
  `minecraft:custom` `minecraft:play_time` (fallback `play_one_minute`),
  `deaths`, `mob_kills`, and the sum of `walk_one_cm`, `sprint_one_cm`,
  `crouch_one_cm`, `swim_one_cm`, `walk_on_water_one_cm`,
  `walk_under_water_one_cm`. Avatars are generated by the client from the
  uuid; the hub never contacts Mojang or any other service.

The hub cannot know: per-player "online since", unreadable chunks (only the
client reports them, see "Damaged files"), mod changes older than retained
history, anything not in the synced files (excluded files are never on the
hub; `usercache.json` and `usernamecache.json` are not excluded by default,
so player names are known).

### Sessions and statistics

- A session starts when a lock with `info.action = play` is acquired and
  ends at release (`released`), takeover by force (`forced`) or when it goes
  stale and is never renewed (`stale`, `end` = last heartbeat). A stale lock
  renewed by a heartbeat continues the same session. Push-only locks are not
  sessions.
- On each heartbeat the hub adds the elapsed time (capped at 2 × the
  heartbeat interval) to every name in `info.players`. Hosting time = `end −
  start`.
- Stored per space in `spaces/<id>/sessions.json` (newest first, at most
  `stats.sessionsKept`, the ongoing one first; written at most once a minute
  and at the end). On hub restart an ongoing session is adopted.
- `GET /spaces/{id}/stats` → `SpaceStats`: `sessions`, `play` (players by
  in-game time) and `hosting` (members by hosting time), top 10 each, both
  over the kept sessions only. Count, average, longest and last are derived
  by the client from `sessions`.
- `SpaceSummary.lastSession` = the newest ended session.

### History extras

- **Damaged files** (B-GEN-11): `PushBegin.damaged` lists manifest paths the
  client found damaged (`{path, bad?, total?}`, e.g. unreadable chunks of a
  region file); unknown paths → `bad_path`. They are stored in the
  generation and returned in `GenerationSummary.damaged`.
- **Diff**: `GET .../generations/{n}/diff?limit=L` (L 1–1000, default 120)
  compares `n` with its parent (or the newest retained generation before
  it; 0 = empty). Each of `added`/`changed`/`removed` has `total` and at most
  L `items` sorted by path. `damaged` lists the damaged files of `n` with
  `lastIntact` (newest earlier generation where the file exists and is not
  flagged).
- **ZIP export** (B-SPACE-03): `GET .../generations/{n|head}/zip` checks
  every blob exists **before sending any byte** (409 `blobs_missing`
  otherwise), then streams `application/zip` (entries stored, UTF-8 names,
  CRC-32 in a data descriptor after each entry since it is computed while
  streaming, sizes also in the local header; ZIP64 records only where needed:
  an entry ≥ 4 GiB, offsets beyond 4 GiB or ≥ 65535 entries; exec bit in the
  Unix external attributes) with `Content-Length` (exact, entries are stored)
  and `Content-Disposition: attachment; filename="<space>-<n>.zip"`. Reads
  follow socket backpressure. No event.
- **Delete generation** (B-GEN-15, admin, irreversible): `DELETE
  .../generations/{n}`; HEAD → 409 `is_head`; missing → 404; any unreadable
  generation → 500 and nothing deleted (B-GC-05). Removes the generation and
  the blobs only it referenced (open pushes are protected, B-GC-04; the
  parent generation of an open push → 409 `locked`).
  `.../freed` gives the same byte count without deleting.
- **Restore one file** (B-GEN-12/14, admin): `POST /spaces/{id}/restore-file`
  `{path, from?, message?}`; `from` 0 or absent = auto (newest generation
  before HEAD that has the file not flagged damaged). Creates a new
  generation = HEAD with that one file replaced, `kind: restore`,
  `restoredFrom`, `restoredPath`; HEAD's damaged list minus that path.
  Refused with any live lock (409 `locked`); no source → 404; source blobs
  lost → 409 `blobs_missing`.
- **GC** (admin): body `{keep: N}` (1–10000, B-GC-08) = manual cleanup
  keeping the newest N generations of each space; no `keep` = apply the
  retention rules now. `POST .../gc/preview` takes `{keep}` or
  `{history: {keepLast, keepHours, keepDays}}` (draft rules, validated like
  the section) and changes nothing; spaces with their own `history`
  override keep their current effective rules (the draft does not apply to
  them) and are flagged `ownRules`; on `POST /spaces/{id}/gc/preview` the
  draft is merged over that space's own history override. `bytes` counts
  blobs of the removed generations that no surviving generation of any
  space, open push or running export references. Open pushes keep their
  parent generation. Manual GC always publishes `gc` (with `actor`, `keep?`
  and `space` for the per-space call).
- **Usage**: `GET /usage` → `HubUsage` (`blobs`, `dl`, per space
  `generations`, `logical` = sum of generation sizes, `referenced` = distinct
  blobs, `exclusive` = not shared with other spaces). Computed in the
  background after maintenance (at most every 10 min), `computedAt` says
  when; "other" in the UI = `disk.total − disk.free − blobs − dl` is not the
  hub's.

### Lock, port test and DNS

- The hub records the lock holder's address as seen on the socket
  (`LockHolder.ip`, canonical form). It is the "direct IP", the DNS answer
  and the only port-test target. `info.address` is informative only.
- `LockInfo.lan` (optional, sent by the client) is the host's LAN address,
  used only for DNS split horizon; the hub never returns it (responses,
  events, Telegram).
- **Port test** (`sessions.portTest`, per-space override allowed): for a
  `play` lock the hub opens a TCP connection to `ip:port` (`info.port`,
  default 25565), timeout 3 s, every 10 s while `pending`, for at most 3 min
  after acquire or after a port change; first success → `reachable`; window
  over → `blocked`. Switched off or push lock → `off`. The target is never
  taken from the request body (no SSRF). `POST .../lock/port-check` (any
  member) restarts the window: 409 `not_locked` without a live play lock,
  409 `feature_off` when off, 429 `rate_limited` within 10 s of the last
  start. Each transition to `reachable`/`blocked` publishes `port`.
- **DNS** (B-DNS-01…07): on when `MINESYNC_DNS_ZONE` is set and the server
  is bound on `MINESYNC_DNS_ADDR` (default `:53`, `off` disables it; the zone
  still counts for allowed hosts). Name per space: `zerotier.<id>.<zone>`
  (space ids are DNS labels). `SpaceSummary.dnsName` and `HubInfo.dnsZone`
  are present only while the DNS server runs. A = `LockHolder.ip` of a live
  `play` lock (the `lan` address if the querier is the host itself); SRV
  `_minecraft._tcp.<name>` = `info.port` with glue; offline → NOERROR empty
  + SOA; unknown space → NXDOMAIN; AAAA → empty; out of zone → REFUSED.
  `SystemInfo.dns` shows zone, address, on/off and a bind error. UDP is
  required (a busy port is a bind error, no `SO_REUSEADDR`); TCP on the same
  port is served when it can be bound. TTL 5 s, answers read the in-memory
  lock snapshot and never wait on the space mutex.

### Members and ZTNET

- `GET /members` (admin): members seen by the hub (`members.json`) merged
  with the ZTNET member list (including unauthorized ones, `authorized:
  false`, which never authenticate; once a ZTNET list is known, a member seen
  earlier but missing from it is also `authorized: false`). `fromConfig` = matched by
  `MINESYNC_ADMINS` (name or node id, case-insensitive). Sorted: admins,
  then most recently seen.
- `PUT /members/{id}/role` `{role: admin|member}`: 404 unknown id, 409
  `from_config` to demote a config admin, 409 `last_admin` if no admin would
  remain. Applies to the next request. Publishes `member.role`.
- `ZtnetStatus`: `state` `ok`/`error`/`off` (not configured), authorized
  `members`, `lastRefresh`, last error and time (kept after recovery),
  `url` in clear, `tokenHint`/`networkHint` = last 4 chars. `POST
  /members/refresh` runs one refresh (coalesced with a running one) and
  returns the status; ZTNET failure is reported in the status, not as an
  HTTP error. Transitions ok↔error publish `ztnet`.

### Telegram

Stored in its own file `telegram.json` (mode 0600, atomic write), token
included; never returned. A missing file means the defaults (disabled, all
notifications on). `TelegramStatus` = `settings` (`enabled`, `tokenSet`,
`tokenHint` (last 4), `chat`, `language` (`hub` = follow
`general.language`, `it`, `en`), `notify {open, close, alerts, status}`,
`coalesceMinutes` 0–60 (default 1), `pushWarnMinutes` 5–1440 (default 30),
`topics {spaceId: thread}`) + `state` (`disabled`, `incomplete`, `active`,
`error`), `chatTitle`, `botUsername`, `lastSentAt`/`lastSent`,
`lastError`/`lastErrorAt`, `missingTopics`.

- `PATCH /telegram` (B-TG-24/28/30): partial; absent keys unchanged; `token`
  empty or absent = unchanged; `removeToken: true` clears it (400 if the bot
  stays enabled, allowed together with `enabled: false`); enabling without
  token and chat → 400. Token `^\d+:[A-Za-z0-9_-]{30,}$`; chat `-100…`,
  digits or `@channel`. `topics`, when present, replaces the whole map:
  values are thread numbers or `t.me` links (B-TG-26); `""`/`"1"` = main
  chat (entry removed); unknown spaces dropped; invalid → 400
  `details.field = topics.<spaceId>`; a link for another chat → 400 naming
  both chats, validated against the chat in the same request. Deleted spaces
  vanish from GET. Publishes `settings` with `section: telegram` and field
  names only (B-EVENTS-04).
- `POST /telegram/test` (B-TG-29): body may carry `token`, `chat`,
  `language` (tested, not saved) and `spaceId` (its saved topic) or `topic`
  (not saved). Nothing configured → 400; unknown space → 404; within 3 s of
  the previous test → 429; Telegram error → 502 `upstream` with the API text
  in `details.error`. Success/error is recorded in the status (B-TG-18) but
  a deleted topic does not mark the status (B-TG-21).
- `POST /telegram/find-chat`: uses `token` from the body or the saved one
  (none → 400). Lists the chats of the most recent updates the bot received:
  the hub's polling buffer when `/status` is on, otherwise one `getUpdates`
  without confirming offsets. Telegram error → 502.
- Behaviour of the bot is B-TG-01…22; the open message uses
  `zerotier.<id>.<zone>` (only while the DNS server runs) and
  `LockHolder.ip`, never `lan`.
- The bot follows the event stream (`lock`, `unlock`, `force`, `stale`,
  `push`, `space.delete`, `disk`) and every 5 s reads the lock snapshots, so a
  client that vanishes without unlocking is still announced closed. Send
  failures publish `telegram.error` (at most one per hour).

### Events

- `GET /events?before=SEQ&limit=M` (M ≤ 500, default 100) returns events
  with `seq < SEQ`, **newest first**, reading the on-disk segments when the
  memory ring is not enough; `{events, last, oldest, more}` (`oldest` = oldest
  seq still on disk). Both `after` and `before` accept `space=<id>` and
  `types=a,b` filters; the `after` form also returns `more` (true when
  `limit` was reached).
- Types (`EventType`); `actor` is the member name when a person caused it:

| type | space | data |
|---|---|---|
| `push` | ✓ | `n`, `kind`, `stats` |
| `lock` | ✓ | `action?`, `tookOver?` |
| `unlock` | ✓ | `durationMs` (play locks) |
| `stale` | ✓ | `holder`, `lastBeat` (published once when a lock passes its TTL) |
| `force` | ✓ | `from`, `released?`, `durationMs?` |
| `port` | ✓ | `state` (`reachable`/`blocked`), `port` |
| `restore` | ✓ | `n`, `restoredFrom` |
| `restore.file` | ✓ | `n`, `restoredFrom`, `path` |
| `generation.delete` | ✓ | `n`, `bytes` |
| `space.create` / `space.update` / `space.delete` | ✓ | `name` / `fields` / — |
| `gc` | opt. | `generations`, `blobs`, `bytes`, `keep?` (manual: `actor` set) |
| `gc.error` | ✓ | `generation` |
| `disk` | — | `free`, `total`, `minFree`, `level` (`warn` below 2 × minFree, at most every 6 h; `full` on refusal, at most hourly) |
| `settings` | — | `section`, `fields`, `values?` (new values; never for `telegram` or `exclusions`) |
| `member.role` | — | `memberId`, `member`, `role` |
| `ztnet` | — | `state`, `error?` |
| `telegram.error` | — | `error` (at most one per hour) |

  No event ever contains a token, a LAN address or file contents.

### Downloads (`/dl`) and self-update

Served from `MINESYNC_DL` (absent → `/dl/*` 404, empty listing). Outside
`/api/v1` but with the same guards: Host check, member identity (401
otherwise), security headers; GET/HEAD only, no `X-MineSync` needed;
`Range` supported.

- `GET /api/v1/dl` → `DlListing`: regular files at the top of `MINESYNC_DL`,
  excluding dotfiles, `SHA256SUMS`, `SHA256SUMS.sig` and `update/`
  (B-DL-01). `os` from the extension (`.exe`/`.msi` → windows,
  `.dmg`/`.pkg` → macos, `.AppImage`/`.deb`/`.rpm`/`.tar.gz` → linux (a `.tar.gz`
  named `-macos-`/`-windows-` → that OS); CLI archives (`-cli.`) and other
  files are not listed), `arch` from `x86_64|x64|amd64` → `x64`,
  `arm64|aarch64` → `arm64`, `universal`; `version` from the name;
  `sha256` from `SHA256SUMS`; `updates` from `update/*/manifest.json`
  (`signed` = the `.sig` exists); `signedSums` = `SHA256SUMS.sig` exists.
- `GET /dl/<file>`: listed files with `Content-Disposition: attachment;
  filename="<file>"`; `SHA256SUMS(.sig)` as `text/plain` without
  attachment.
- Self-update, exactly as `apps/launcher` `UpdateHub` expects (base
  `<hub>/dl/`): `GET /dl/update/<platform>/manifest.json`
  (`application/json`, exact bytes), `.../manifest.json.sig` (`text/plain`,
  base64 ed25519 of those bytes), `.../<archive.name>` (`application/gzip`).
  `<platform>` is `linux-x64`, `windows-x64`, `macos-arm64`, … No
  attachment, `Cache-Control: no-cache` + `ETag`.
- Only names matching `[A-Za-z0-9._+-]+` (one segment, or
  `update/<platform>/<name>`) are served; anything else, symlinks leaving the
  folder and directories → 404.
- `/dl` and `/dl/` (no extension) are the web UI's download page (SPA
  fallback below).

### Static web UI (`apps/hub_web`)

Served from `MINESYNC_WEB` (a `flutter build web` output; absent → `/` is
404 and the API still works). Same Host guard and security headers; **no
identity needed** (the app itself shows "not recognised" from the 401 of
`GET /api/v1/hub`).

- At start the hub loads the build in memory, computes `buildId` = first 12
  hex of SHA-256 over sorted `(path, bytes)`, precomputes gzip and uses a
  `<file>.br` sibling when present (`Vary: Accept-Encoding`).
- `index.html`: the placeholder `__BUILD__` is replaced by `buildId`;
  `Cache-Control: no-cache` + `ETag`. It must not contain inline scripts
  (the bootstrap is `/b/<buildId>/flutter_bootstrap.js`).
- `/b/<buildId>/<path>`: build files, `Cache-Control: public,
  max-age=31536000, immutable`. Another build id (an old tab) → the current
  file with `no-cache`.
- Any other path without an extension that is not `/api/…` or `/dl/<file>`
  → `index.html` (SPA routes: `/`, `/server/<id>`, `/admin`, `/dl`, …). A
  path with an extension that exists at the build root (favicon, manifest)
  → `no-cache` + `ETag`; otherwise 404.
- MIME: `.wasm` `application/wasm`, `.mjs`/`.js` `text/javascript`,
  `.json` `application/json`, `.html` `text/html`, fonts `font/*`,
  `.png`/`.svg`/`.ico` as usual; always `charset=utf-8` on text.
- CSP for these pages (the API keeps `default-src 'none'`):
  `default-src 'self'; script-src 'self' 'wasm-unsafe-eval';
  style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:;
  font-src 'self'; connect-src 'self'; worker-src 'self' blob:;
  object-src 'none'; base-uri 'self'; form-action 'none';
  frame-ancestors 'none'`. `base-uri 'self'` (not `'none'`): Flutter's path
  URL strategy reads the effective `<base href="/">`, and with the base
  blocked every deep link (`/server/<id>`) fails to start.
- The build id is a hash input entry `path\0length\0bytes` per file, in
  path order. Not loaded: dotfiles, `*.symbols`, `*.map`, `*.gz` (`*.br`
  only as siblings); every engine variant stays (the loader picks one per
  browser). Bounded at 256 MiB in total, 64 MiB per file.
- Build: `flutter build web --wasm --release --no-web-resources-cdn
  --no-source-maps --base-href /` (CanvasKit and skwasm
  then live in `canvaskit/` of the build, loaded from
  `/b/<buildId>/canvaskit/`); `web/flutter_bootstrap.js` takes the build id
  from `<meta name="minesync-build">`. Optional: `brotli -k -q 11` on
  `.js/.mjs/.wasm/.json/.ttf/.otf` to ship `.br` siblings.

### Environment variables (hub web and extras)

| Variable | Use | Default |
|---|---|---|
| `MINESYNC_WEB` | folder of the hub_web build | unset (no web UI) |
| `MINESYNC_DL` | folder of desktop downloads and `update/` | unset |
| `MINESYNC_DNS_ADDR` | DNS bind address, or `off` | `:53` when the zone is set |

`MINESYNC_DATA`, `MINESYNC_ADDR`, `MINESYNC_ADMINS`, `MINESYNC_HOSTS`,
`MINESYNC_DNS_ZONE`, `MINESYNC_MIN_FREE`, `ZTNET_*`, `MINESYNC_DEV_USER` and
`TZ` are set when the hub starts and appear read-only in `GET /system` ("set at
start"). The update signing key is a build secret: the hub only reports
whether manifests are signed.

## Player pack

Model: `ms_protocol` `pack.dart` (`ClientPack`, `PackMissingMod`). The pack
file format and its `.mrpack` mapping are in `docs/design/modpack.md`. The
hub builds everything on the fly from `minesync-pack.json` in HEAD and the
files of HEAD; it never contacts Modrinth or any other service (download
URLs come from the pack file). The plan is cached per `(space, digest)` in
memory; the ZIPs are streamed from the blobs (stored entries, exact
`Content-Length`), like the generation ZIP.

| Method and path | Who | Use → response |
|---|---|---|
| `GET /spaces/{id}/pack` | all | summary of the player pack of HEAD → `ClientPack` |
| `GET /spaces/{id}/pack.mrpack` | all | the `.mrpack` (`application/x-modrinth-modpack+zip`) |
| `GET /spaces/{id}/pack-mods.zip` | all | only the player mods as `mods/<file>.jar` (`application/zip`) |

- No HEAD, no `minesync-pack.json`, or an invalid one (logged): `/pack` is
  200 `{"n": N, "available": false}`; the two files are 404 `not_found`.
  `pack-mods.zip` is 404 also when no player mod is in HEAD
  (`modsZipName` null).
- `ClientPack`: `n`, `available`, `name`, `mcVersion`, `loader`,
  `loaderVersion`, counts `mods` (all entries), `required` / `optional`
  (enabled, side `client` or `both`), `serverOnly` (enabled, side `server`),
  `manual` (source `manual`), `disabled`; `missing[]`
  (`{file, source, name?, pageUrl?}`: CurseForge mods whose author forbids
  redistribution, and manual jars not in HEAD: players download them by
  hand); `fileName` (`<name>-<n>.mrpack`, name = pack name or space name with
  unsafe characters replaced by `_`), `size` (exact bytes), `modsZipName`,
  `modsZipSize`.
- `.mrpack` content: `modrinth.index.json` (`versionId` = generation number)
  with the player mods that have a download on an allowed host; jars without
  one are taken from HEAD as `overrides/` (side `both`) or
  `client-overrides/` (side `client`); files matching the pack's `shared`
  patterns → `overrides/`; files under `client-overrides/` → `client-overrides/`.
  Optional mods keep `env.client: optional`. Server-only, disabled and
  non-redistributable mods are never included.
- Both files answer with `Content-Disposition: attachment`, `ETag`
  (digest-based; `If-None-Match` → 304) and `Cache-Control: private, no-cache`.
  A blob missing from the store → 409 `blobs_missing` before any byte is sent.

## Hub data layout (`/data`)

```
/data/
  settings.json            {sections, changed}: sections validated by schema (0600)
  telegram.json            Telegram bot settings, token included (0600)
  members.json             members seen, roles set from the Admin area
  cache/                   world/mods/players metadata per digest, usage (safe to delete)
  events/                  append-only event log, one JSON object per line
  blobs/<h[0:2]>/<h>       content, file name = SHA-256
  tmp/                     uploads in progress (wiped at start)
  pushes/<pushId>.json     open push sessions
  spaces/<id>/
    space.json             {id, name, profile, createdAt, exclusions[], overrides{}}
    head.json              {n, digest}
    generations/<n>.json   {n, parent, digest, author, message, ts, kind, restoredFrom?, restoredPath?, damaged?, manifest, stats}
    lock.json              present only while locked
    sessions.json          kept play sessions, newest first
```

- Every write goes through one helper: write a temporary file, `fsync` it,
  `rename` over the target, `fsync` the directory. A power cut leaves the
  old or the new file, never a partial one.
- An unreadable `head.json` is rebuilt from the highest valid generation.
- GC refuses to delete anything if any generation cannot be read.

## Client state

- App configuration (`config.json` in the OS config directory): hub URL,
  links `spaceId → folder`, local preferences.
- Per linked folder, a `.minesync/` directory (never synced):
  - `base.json`: the generation last synced (`n`, `digest`) and its
    manifest, used to tell local edits from remote ones;
  - `cache.json`: hash cache keyed by `(path, size, mtime)`;
  - `outbox/`: blobs snapshotted for a background push;
  - `backup/`: local copies kept before a pull overwrote unpushed edits.
