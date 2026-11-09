# MineSync — Design

MineSync synchronises the state of one or more **spaces** (today: Minecraft server folders) between the PCs of a group of friends, over HTTP on a private ZeroTier network.

## Principles

1. **No mounts.** Clients only talk HTTP to the hub. The hub owns every file and arbitrates everything.
2. **Git-like, but simple.** Every push is a **generation**: an immutable manifest pointing to content-addressed blobs (SHA-256). History is linear; a restore creates a new generation equal to an old one. Identical blobs are stored once.
3. **One authority.** Lock, history and the truth about files live in the hub. In the worst case a client's push is refused; it can never corrupt another client.
4. **Modular.** The core (spaces, blobs, generations, lock, events) is generic. `minecraft` is a **profile**: default exclusions on the hub plus behaviour in the client (start the server, console, autosave). A `generic` profile syncs any folder with manual pull/push.
5. **Nothing to install for friends.** One Go binary per OS; the TUI is the product.

## Topology

```
┌──────────────────────────────────────────────┐
│ always-on machine (NAS)                      │
│  docker: minesync-hub (network_mode: zerotier)│
│   • /data on a local disk                    │
│   • HTTP :8084 (API, web UI, /dl)            │
│   • DNS  :53/udp (optional)                  │
└────────────────────┬─────────────────────────┘
          HTTP over ZeroTier (identity = member IP)
       ┌─────────────┼──────────────┐
    ┌──▼──┐       ┌──▼──┐        ┌──▼──┐
    │ PC  │       │ PC  │        │ PC  │   ← `minesync` TUI / CLI
    └─────┘       └─────┘        └─────┘
       ▲ game traffic is peer-to-peer, never through the hub
```

## Authentication

The ZeroTier network is the authentication. The hub resolves the caller's source address to a member through the ZTNET API (cached, refreshed in the background) and uses the member's name as identity; `MINESYNC_ADMINS` lists admins by name or node id. Forwarded headers are never trusted.

Because authority is ambient (any page in a member's browser comes from the member's IP), the hub also:
- refuses state-changing API calls without the `X-MineSync` header (a cross-site page cannot add it without a CORS preflight, which the hub never grants);
- refuses `Sec-Fetch-Site: cross-site` requests;
- accepts only `Host` values that are IP addresses, names in its DNS zone or names in `MINESYNC_HOSTS` (DNS rebinding).

## Hub data layout (`/data`)

```
/data/
  events.jsonl                 append-only event log
  spaces/<id>/
    space.json                 {id, name, profile, ignore[], createdAt}
    HEAD                       current generation number
    generations/<n>.json       {n, parent, author, message, ts, files{path→{h|chunks,size,exec}}, stats}
    blobs/<h[0:2]>/<h>[.gz]    content, name = SHA-256
    lock.json                  only while locked: {owner, session, since, ttl, lastBeat, info}
    stats.json                 hosting and play time per member
```

- Every write goes through one helper: temporary file, `fsync`, `rename`, `fsync` of the directory. A power cut leaves either the old or the new file, never an empty one.
- An unreadable `HEAD` is rebuilt from the highest valid generation.
- The garbage collector refuses to delete anything if a generation cannot be read, and treats the blobs of open pushes as referenced.
- The lock is arbitrated in memory under the space mutex; `lock.json` only survives restarts.

## API v1 (JSON)

| Method and path | Use |
|---|---|
| `GET /api/v1/status` · `GET /api/v1/whoami` | hub info and version · caller identity |
| `GET/POST /api/v1/spaces` | list / create (admin) |
| `GET/PATCH/DELETE /api/v1/spaces/{id}` | details · edit exclusions/profile (admin) · delete (admin) |
| `GET /api/v1/spaces/{id}/manifest?gen=N` | manifest of a generation (default HEAD) |
| `GET /api/v1/spaces/{id}/generations[/{n}[/zip]]` | history · one generation · ZIP export |
| `DELETE /api/v1/spaces/{id}/generations/{n}` | delete a generation (admin) |
| `POST /api/v1/spaces/{id}/restore` · `/restore-file` | restore a generation or one file (admin) |
| `POST /api/v1/spaces/{id}/gc?keep=N` | prune and collect blobs (admin) |
| `GET /api/v1/spaces/{id}/blobs/{hash}` | download a blob |
| `POST /api/v1/spaces/{id}/push/begin` | proposed manifest + lock session → `{pushId, missing[]}` |
| `PUT /api/v1/spaces/{id}/push/{pushId}/blobs/{hash}` | upload a blob (re-hashed by the hub) |
| `POST /api/v1/spaces/{id}/push/{pushId}/commit` | atomic commit → new generation (idempotent) |
| `POST /api/v1/spaces/{id}/lock` · `/lock/heartbeat` · `DELETE …/lock` | acquire · renew · release |
| `GET /api/v1/spaces/{id}/world` · `/players` · `/mods[/{file}[/icon]]` · `/stats` | world metadata for the web UI |
| `GET /api/v1/events[?stream=1]` | recent events · live SSE |
| `GET /dl`, `GET /dl/{file}` | client downloads, `SHA256SUMS`, `SHA256SUMS.sig` |

Rules:
- **A push needs the lock**, and the lock session it was started with must still be held at commit. `?nolock=1` is admin-only.
- **A push is compare-and-swap**: the client declares its `parent`; if HEAD moved, 409.
- A push that removes more than half of a space's files is refused unless an admin confirms it.
- Uploaded blobs are re-hashed; a wrong hash is never accepted.
- Lock TTL 90 s, heartbeat every 20 s. An expired lock is *stale* and anyone may take it; breaking a live lock is admin-only.
- Automatic retention keeps the last `MINESYNC_KEEP` generations, everything from the last 24 hours and one generation per day for a week.

## Client

One binary `minesync` (Windows, Linux, macOS). Configuration in `~/.minesync/config.json`: hub address and `space → local folder` links.

- **Sync engine**: diff between the remote manifest and a local scan, with a hash cache keyed by `(path, size, mtime)`. Region files are split into chunks so a save only uploads the chunks that changed. 8 parallel workers, SHA-256 verification after every write, retries with backoff, idle watchdog on transfers. Every path and hash received from the hub is validated before touching the disk.
- **Pull** = checkout of HEAD. Before overwriting anything the client compares the local tree with the generation it last synced: unpushed changes are pushed first when nobody else pushed meanwhile, otherwise the user decides and the local copy is backed up.
- **Push** = begin → upload missing blobs → commit (retried safely).
- **Minecraft profile**: detects start scripts and launcher jars, picks Java, starts the server with stdin/stdout embedded, autosaves every 5 minutes, stops cleanly and pushes. The server process is stopped cleanly when the client exits for any reason.
- **Self-update**: only to a newer version, verified against `SHA256SUMS` and, when the client embeds a public key, its ed25519 signature; the previous binary is kept until the new one has started.

## TUI

A router of screens, each an independent Bubble Tea component (home, space, play, history, Java settings, setup); the root only routes and draws the shared header and footer. One theme, every screen handles resizing. Slow work (Java detection, network) runs in commands, never in `Update` or `View`.

## Web UI

Vanilla JS and CSS embedded in the hub (`go:embed`), no build step. Pages: overview, space (history with restore, exclusions, lock), world (seed, version, mods, players), events, client downloads.

## Repository

```
minesync/
  go.work            workspace: server, client, scripts/sign
  VERSION            single release number, injected at build time
  server/            hub (internal/{api,store,events,mcdns,mcmeta,notify,web,ztauth})
  client/            TUI + CLI (internal/{api,syncx,session,mc,tui,config,selfupdate,launch,version})
  deploy/            Dockerfile, docker-compose.example.yml
  scripts/           build.sh / build.ps1, sign (update signing), genicon
```
