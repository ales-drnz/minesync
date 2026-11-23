# MineSync: architecture

How the pieces fit together. The contracts are in
[protocol.md](protocol.md) (API v1, storage, data layout),
[modpack.md](modpack.md) (pack file, `.mrpack`, resolver) and
[ui.md](ui.md) (design system); the observable rules are in
[behaviour.md](../spec/behaviour.md).

## Components

```
 desktop app ─┐                        ┌─ ZTNET (who is who)
 minesync CLI ┼── HTTP + SSE ──▶ hub ──┼─ Telegram Bot API (optional)
 hub web UI ──┘   (ZeroTier only)  │   └─ DNS :53 (optional, answers clients)
                                   └─ /data (local disk)
 desktop app ──▶ minesync-guard ──▶ Minecraft server (java)
 launcher ──▶ desktop app version N (self-update from <hub>/dl/update)
 friends' Minecraft ──▶ host PC (peer to peer over ZeroTier)
```

| Component | Code | Role |
|---|---|---|
| Hub | `apps/hub` | `dart:io` server: API v1, SSE, store, lock, settings, DNS, Telegram bot, `/dl`, static web UI |
| Hub web UI | `apps/hub_web` | Flutter web (wasm with JS fallback) served by the hub: overview, servers, history, downloads, Admin |
| Desktop app | `apps/desktop` | Flutter app for Windows, macOS, Linux: sync, sessions, history, mods, settings, tray, notifications |
| CLI | `apps/cli` | `minesync`: the same engine without UI |
| Guard | `apps/guard` | AOT supervisor between the app and the server process |
| Launcher | `apps/launcher` | the executable users start; picks, trials and rolls back app versions |
| Packages | `packages/ms_*` | protocol models, sync engine, Minecraft helpers, session, modpacks, UI, strings |

`ms_protocol` and the pure part of `ms_modpack` are web-safe, so the hub,
the apps and the browser share the same models, path rules and pack logic.

## Hub API v1 and events

All calls are under `/api/v1`, JSON except blob bodies. Errors carry a
stable `code` that clients translate; `message` is for logs. The full list of
endpoints, error codes and models is in protocol.md.

Clients learn about changes from the event log: `GET /events?after=SEQ` and
`GET /events/stream` (Server-Sent Events, resumable with `Last-Event-ID`,
keep-alive comments every 15 s). The desktop app and the web UI follow the
stream and reconnect when it drops; events never contain tokens, LAN
addresses or file contents.

## Store, generations, push and pull

- A **space** is one synced folder (usually a server) with a profile
  (`minecraft` or `generic`) that selects the default exclusions.
- Files are stored as **blobs** named by SHA-256, once per hub and shared by
  every space. Files of 2 MiB or more are split into content-defined chunks
  (FastCDC), so a changed region file uploads only its changed chunks.
- A **generation** is an immutable manifest (path → size, hash, chunks,
  executable bit) with a canonical digest. History is linear; a restore
  creates a new generation equal to an old one. Retention and GC remove old
  generations and blobs nobody references; GC refuses to run if any
  generation is unreadable.
- **Push**: begin (manifest, parent and its digest, lock token) → the hub
  returns the missing blobs → upload each (re-hashed by the hub) → atomic
  commit. The hub checks the lock, the base (`stale_base`), the mass-delete
  guard and free space.
- **Pull**: the client compares the hub's manifest, its last synced base
  (`.minesync/base.json`) and a scan of the folder (hash cache keyed by path,
  size, mtime). Unpushed local edits are never overwritten silently: they are
  refused, or backed up into `.minesync/backup/` when the user chooses the
  hub version.
- **Autosave** snapshots changed files into `.minesync/outbox/` while the
  server is in `save-off`, then uploads in the background with a bandwidth
  limit, so the game is paused only for the flush.

Every hub write is temp file + `fsync` + rename + directory `fsync`.

## Lock and sessions

One member hosts a space at a time. The lock has a 90 s TTL renewed by a
heartbeat every 20 s (values sent by the hub); an expired lock is *stale* and
free to take, a live one can be taken only by an admin with `force`. The
heartbeat carries players, port and client version. The hub records the
holder's address as seen on the socket: that address is used by the port test
and the DNS, never an address from the request body. A play lock is a
session: the hub keeps per-space session history and play/hosting time.

`ms_session` drives a session on the host: lock, pull, start through the
guard, wait for "Done", autosave on a timer, restart after a crash (up to
`crashRestarts`), stop when empty (`autostop`), and at the end final push and
unlock. The hub's session settings reach the app through
`GET /spaces/{id}` and are re-read at each autosave.

## Guard

The Minecraft server must never outlive MineSync. The app starts
`minesync-guard`, which starts the server's script or `java`, relays the
console over a pipe and stops the whole process tree (console `stop`, then
kill after a grace period) when the app's pipe closes, the parent dies or it
gets `SIGTERM`. Containment: own process group and child subreaper on Linux,
process group on macOS, a kill-on-close Job Object on Windows.

## Launcher and self-update

The launcher is the only executable users start. It keeps complete version
folders under `versions/<v>/` and an atomic `state.json`
(`current`, `previous`, `pending`, `bad`). The app checks
`<hub>/dl/update/<platform>/manifest.json`, verifies its ed25519 signature
(over the exact bytes, before parsing) against the public key built into the
app, downloads and verifies the archive file by file, stages it and asks the
launcher to restart it (exit code 75). The launcher starts the pending
version on trial: it is promoted when it writes `run/healthy-<v>`, rolled back
after two failed starts or 60 s without the marker, and never installed
again. Details: [apps/launcher/README.md](../../apps/launcher/README.md).

## Hub web UI and downloads

The hub serves the `hub_web` build from memory with a build id in the URLs
(immutable caching), a strict CSP and no inline scripts. Pages need no
identity to load; the app shows "not recognised" from the API's 401. `/dl`
lists and serves the desktop packages with `SHA256SUMS(.sig)` and the
self-update payloads. Admin settings are validated by schema and applied
live.

## Extras

- **DNS** (optional): a small authoritative server for
  `zerotier.<space>.<zone>` answering with the current host's address (or the
  host's LAN address when the host itself asks), an SRV record for the port,
  TTL 5 s; it reads the in-memory lock snapshot only.
- **Port test**: for a play lock the hub tries to connect to the host's game
  port for up to 3 minutes and publishes `reachable` or `blocked`.
- **Telegram** (optional): a bot that follows the event stream and the lock
  snapshots to announce opens, closes, forced and stale sessions, disk alerts
  and `/status`, with optional forum topics per server; its token lives only
  in `telegram.json` (0600) and is never returned.
- **World metadata**: the hub reads `level.dat`, `server.properties`, player
  files and mod jars of HEAD (bounded parsers, cached per digest) for the web
  UI; it never contacts Mojang or other services.
- **Modpacks**: `minesync-pack.json` in the server folder is a normal synced
  file. The desktop app talks to Modrinth and the loader sources; the hub only
  builds the player pack (`.mrpack`, mods ZIP) from HEAD.

## Security model

- **Network**: the hub listens only inside the ZeroTier network (it shares
  the ZeroTier container's network namespace). Being an authorised member of
  the network is the authentication.
- **Identity**: the caller's ZeroTier IP on the socket is resolved to a
  member through the ZTNET API; forwarded headers are never trusted.
  Admins come from `MINESYNC_ADMINS` or roles set in the Admin area; the last
  admin cannot be removed. Known members stay recognised for a configurable
  time while ZTNET is down.
- **Browser guards**: the `Host` header must be an IP literal, `localhost`, a
  name in the DNS zone or in `MINESYNC_HOSTS` (DNS rebinding); state-changing
  requests need `X-MineSync: 1` and must not be cross-site (CSRF);
  security headers and CSP on every response.
- **Data safety**: paths are validated on both sides (relative, NFC,
  Windows-portable, no case collisions); uploaded bytes are re-hashed;
  mass deletions and pushes on a stale base are refused; destructive admin
  actions need explicit confirmation.
- **Updates**: release manifests and `SHA256SUMS` are signed with an ed25519
  key kept only as a CI secret; the app accepts only strictly newer versions
  signed by the key built into it, and checks every archive entry (no path
  traversal, links, devices, missing files or hash mismatches). Packages are
  not code-signed yet (see [the app guide](../guide/app.md#install)).
- **Container**: distroless image, non-root user 65532, read-only root file
  system in the Compose example, no shell.

## Data layout

- Hub: `/data`, see [protocol.md, "Hub data layout"](protocol.md#hub-data-layout-data).
- Client: `config.json` in the OS config folder and a `.minesync/` folder
  per linked server, see [protocol.md, "Client state"](protocol.md#client-state).
- Install folders of the desktop app: [apps/launcher/README.md](../../apps/launcher/README.md#install-layout).
