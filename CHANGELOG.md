# Changelog

## [3.2.0] - 2026-11-17

Robustness release: slow connections, unusual failures and a few edge cases found by an end-to-end review.

### Changed

- **Autosave no longer pauses world saving during the upload.** The client freezes a consistent snapshot of the changed data (waiting for mods that keep writing to settle), turns saving back on within seconds and uploads in the background without blocking the session. Background uploads are rate-limited (about 70% of the measured upload speed, configurable) and never overlap; the session panel shows how old the copy on the hub is. Stopping cancels an in-flight upload and pushes the final state at full speed.
- Uploads work on very slow links: the client no longer hands a whole blob to the OS buffer and then times out waiting for the reply while the bytes are still leaving.
- Manual and command-line pushes keep the lock alive for their whole duration, and are no longer announced on Telegram as a server opening.
- Lock ownership follows the session, so renaming a member in ZTNET mid-game no longer stops the server.
- The hub keeps serving known members when ZTNET is down (up to `MINESYNC_ZTNET_GRACE`, 24 h by default) instead of locking everyone out after 5 minutes.
- Cleanup of old generations runs outside the space lock, and the DNS answers from a snapshot, so a large history never stalls heartbeats or name lookups.

### Fixed

- A player typing "Saved the game" in chat (`/me`, `/say`, renamed items…) could make the client upload before the server had finished saving. Only the server's own confirmation counts now, and the wait for it extends while the server is still saving (up to 10 minutes).
- Generations are identified by a content digest as well as their number: after restoring the hub from a backup, or recreating a space with the same name, an old local copy can no longer silently overwrite newer work.
- A file that is unreadable (antivirus, a mod's database) no longer aborts the whole push: it is skipped and the hub keeps its previous version.
- A file changed during the upload is no longer retried with the same hash; the next attempt takes a fresh snapshot.
- File names that are invalid on Windows, and names differing only in case, are skipped on upload and refused by the hub, instead of breaking every Windows friend's pull.
- The hub refuses pushes and new sessions when its disk is nearly full (`MINESYNC_MIN_FREE`), with a clear message and a Telegram alert; the client checks free space before a pull.
- Deleting a space while someone is hosting it is refused; a hosting client whose space disappears stops cleanly.
- Telegram honours rate limits, merges a quick close/reopen into nothing, and keeps announcements consistent after a lock goes stale and comes back.
- On Windows the Minecraft server is closed together with the client if the client crashes or is killed.
- Smaller fixes: lock times immune to clock jumps, hash cache safe on FAT/exFAT drives, `chmod` errors ignored on filesystems without permissions, the system proxy is not used for the hub (`MINESYNC_USE_PROXY=1` to opt in), files that changed during an interrupted pull are backed up before the retry.

## [3.1.1] - 2026-11-17

### Fixed

- The client said Java was "missing" when the server folder had never been downloaded yet (first Play on a new PC, typically on Windows), and kept saying it during the session even after the pull had brought the pack's own Java runtime and the server was running. The dashboard now says "after the first pull" for an empty folder, and the session panel shows the Java and start script actually used.

## [3.1.0] - 2026-11-17

### Added

- **Settings** page in the web UI (admins only). Its first section configures the Telegram bot: on/off, token, chat id, message language, and which messages to send (server opened, server closed, warnings, replies to `/status`), with a test message and the bot's last error.
- `GET /api/v1/settings`, `PUT /api/v1/settings/telegram`, `POST /api/v1/settings/telegram/test`. The token is never returned by the API.
- Settings are stored in `/data/settings.json` (atomic write, mode `0600`). Changing them logs an event in the activity feed.
- Telegram forum groups: one topic per server. Each server's open/close/warning messages go to its topic, and `/status` in a server's topic answers for that server only. Topics are set in Settings by pasting the topic link (or its number), with a per-server test button; a deleted topic falls back to the main chat and shows up as the bot's last error.

### Changed

- The Telegram bot is configured from the web UI instead of environment variables, and every change applies immediately without restarting the hub. Open sessions are still tracked while the bot is off, so the closing message keeps the session length.
- Telegram errors now include Telegram's own description (e.g. `chat not found`), and configuration errors (bad token, bad chat) are no longer retried.

### Upgrading from 3.0

- `MINESYNC_TELEGRAM_TOKEN` and `MINESYNC_TELEGRAM_CHAT` are deprecated. On the first start of 3.1 they are imported into the settings (bot enabled) and the hub logs a notice; afterwards they are ignored and can be removed from the compose file.

## [3.0.1] - 2026-11-17

### Fixed

- Pulling into an emptied or recreated folder was refused as "local changes never pushed", and the client suggested a push that would have emptied the hub. Files missing locally no longer block a pull (it downloads them again); only files changed or added locally do.

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
