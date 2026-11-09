# Changelog

## [3.0.0] - 2026-11-09

First public release.

### Highlights

- English and Italian everywhere: TUI and CLI (system language, switchable in the TUI and saved), web UI (browser language plus a selector), API errors and the `/dl` page (per request), Telegram bot and hub logs (`MINESYNC_LANG`).

### Upgrading from 2.x

- Clients update themselves the first time they reach a 3.0.0 hub. A 2.x client cannot push to a 3.0.0 hub before updating.
- The image now runs as user `65532:65532`. If you mount a host folder on `/data`, either keep your own `user:` in the compose file (as before) or `chown -R 65532:65532` the folder.
- The default hub address is no longer compiled into the client: pass `MINESYNC_DEFAULT_SERVER` (build arg or environment of `scripts/build.sh`) to prefill it, otherwise the client asks for it on first start.
- `?nolock=1` pushes and breaking a lock that is not stale are now admin-only.
- The Telegram bot and the hub logs speak English unless `MINESYNC_LANG=it` (or an Italian `LANG`) is set on the hub.

### Security

- The hub refuses cross-site requests and unknown `Host` names (CSRF and DNS rebinding through a member's browser).
- A member can no longer erase a world's history: automatic retention never prunes the last 24 hours, keeps one generation per day for a week, and mass deletions are refused.
- Pushes are bound to the lock session, checked again at commit.
- Client self-updates are verified against `SHA256SUMS` and, optionally, an ed25519 signature; downgrades are refused.
- The client validates every path and hash coming from the hub before writing to disk.
- The reachability probe only targets the caller's own address; the Telegram token no longer appears in logs; `MINESYNC_DEV_USER` only applies to loopback requests; security headers on the web UI; DNS server ignores responses and non-query opcodes; bounded memory for icons, manifests, push sessions and NBT parsing.

### Fixed

- Unpushed local changes were overwritten by the next pull after a failed final push.
- The hub could crash when the stats page was open during a heartbeat.
- The garbage collector could delete blobs of a generation it failed to read, or of a push still uploading.
- Writes were atomic but not durable: a power cut could leave empty `HEAD`, generation or blob files; a corrupt `HEAD` is now rebuilt.
- A failed rename on Linux deleted the destination file.
- A lost commit response made every later push fail; commits are now idempotent and retried.
- Network transfers could hang forever on a half-open connection.
- The Java server kept running (holding the lock, without a final push) when the client was closed or killed.
- Exclusion patterns like `world_backup*/**` and `**/logs/**` never matched.
- A ZIP export with a missing blob looked complete.
- Several TUI issues: frozen UI during Java detection, duplicate ping loop, stale "lagging" warning, early-access Java builds ignored, Windows console shared with the parent shell.

### Changed

- Version, default server and update key are injected at build time from `VERSION` (`scripts/build.sh`, Dockerfile, CI); binaries are statically linked for every platform.
- Multi-arch image (`amd64`, `arm64`) on GitHub Container Registry; Linux `arm64` and macOS `amd64` clients.
- Large internal refactors of the sync engine, the play session and the TUI, with new tests.

## [2.3.1] - 2026-07-25

- New version number for an already circulated 2.3.0 build.
- Mod search in the web UI filters again.

## [2.3.0] - 2026-07-24

- Works with any modpack layout, not only the original one.
- Durable save and two format pitfalls fixed; symlinked files are followed.

## [2.1.x] - 2026-07-24

- Pull no longer wipes the folder; TUI can be started with a double click; region file verification no longer flags files not aligned to 4 KiB.
