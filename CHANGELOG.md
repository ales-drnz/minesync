# Changelog

## 0.1.0 (unreleased)

First release of MineSync: a self-hosted hub keeps the Minecraft servers of
a group of friends on a private ZeroTier network, and whoever wants to play
hosts the server on their own computer with the latest world, synced back
to the hub while they play. Written in Dart and Flutter: hub, hub web UI,
desktop app and CLI.

### Hub

- API v1 with stable error codes, an event log with Server-Sent Events,
  and a content-addressed store shared by all servers, with content-defined
  chunks for large files.
- Linear history of immutable generations; restore of a generation or of one
  file, ZIP export, diff, deletion, automatic retention and cleanup.
- Lock with heartbeat, stale detection and admin takeover; play sessions and
  statistics; port test of the host.
- Identity from the ZeroTier network through ZTNET, bootstrap admins and
  roles; Host, CSRF and security-header checks.
- Settings edited live from the Admin area, with per-server overrides.
- Optional built-in DNS (`zerotier.<server>.<zone>`, A and SRV) and Telegram
  bot (notifications, `/status`, topics per server).
- World metadata, players and mods read from HEAD for the web UI.
- Serves the web UI, the desktop downloads and the signed self-update.
- Distroless multi-arch Docker image (amd64, arm64), Compose example with
  ZeroTier and ZTNET; standalone Linux binaries.

### Hub web UI

- Flutter web app: overview, servers (players, mods, history, admin tab),
  downloads, and an Admin area for general, members, history and disk,
  sessions, protection, exclusions, Telegram, statistics and system.

### Desktop app

- Flutter app for Windows, macOS and Linux with a pixel design system,
  IT/EN, light and dark themes and interface sizes.
- Play and host: lock, pull, start through the guard, autosave without
  stopping the game, background upload with bandwidth limit, crash restarts,
  autostop, final save on close.
- Local-change protection with backup, history and restore, notifications,
  tray, start with the computer.
- Windows installer (per user), macOS dmg, Linux AppImage; signed
  self-update from the hub with automatic rollback. Packages are not
  code-signed yet.

### Modpacks

- `minesync-pack.json` in the server folder; server mods from Modrinth with
  dependencies, updates, sides, pins and version or loader changes.
- New server wizard: from scratch, from a `.mrpack` or Modrinth modpack, or
  from a folder.
- Player pack: `.mrpack` export, Prism Launcher import, official launcher
  profile (vanilla, Fabric, Quilt); `.mrpack` and mods ZIP from the hub.

### CLI

- `minesync` with `login`, `spaces`, `link`, `status`, `pull`, `push`,
  `verify` and `play`.

### Release

- One version in `VERSION` checked by `tools/check_version.sh`; release
  workflow with signed manifests and `SHA256SUMS`, ghcr.io image and draft
  GitHub release.
