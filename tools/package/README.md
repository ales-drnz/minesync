# Desktop packages

Scripts that turn the desktop app into the files users download: an AppImage
on Linux, a per-user installer on Windows, a dmg on macOS, plus the signed
self-update payload served by the hub under `/dl/update/<platform>/`. The
install layout they produce is the one of the launcher, see
[`apps/launcher/README.md`](../../apps/launcher/README.md).

| Script | What it does |
|---|---|
| `desktop.sh <platform> <outdir>` | builds app, guard, CLI and launcher and writes the package |
| `sign.sh <outdir>` | signs `update/*/manifest.json` and writes `SHA256SUMS` + `.sig` |
| `verify.sh <platform> <outdir>` | checks a package without opening windows (CI) |
| `verify_release.dart` | signature, checksum and manifest checks used by `verify.sh` |

`<platform>` is `linux-x64`, `linux-arm64`, `windows-x64`, `macos-arm64` or
`macos-x64`. Each one is built on that OS and CPU (no cross-compilation); on
Windows the scripts run in Git Bash. The version comes from `VERSION` at the
repository root.

## Building locally

Requirements: the Flutter SDK of `.github/workflows/ci.yml` on `PATH`, plus

- Linux: Docker (for the glibc 2.31 build; the container brings its own
  Flutter and toolchain), or the Flutter Linux toolchain
  (`clang cmake ninja-build pkg-config libgtk-3-dev
  libayatana-appindicator3-dev libnotify-dev`) and `binutils` for a native
  build;
- Windows: Visual Studio with the C++ desktop workload and Inno Setup 6.3+
  (installed with `choco` if missing);
- macOS: Xcode and CocoaPods.

```sh
# public key embedded in the app (without it the app does not self-update)
export MINESYNC_UPDATE_PUBKEY=<base64>

tools/package/desktop.sh linux-x64 dist      # Linux, see below for the container
tools/package/desktop.sh windows-x64 dist    # Git Bash
tools/package/desktop.sh macos-arm64 dist

MINESYNC_UPDATE_KEY=<base64 seed> tools/package/sign.sh dist
MINESYNC_VERIFY_PUBKEY=<base64> tools/package/verify.sh linux-x64 dist
```

Linux builds must run on glibc 2.31 or newer. The Flutter engine and the Dart
executables only need glibc 2.18, but the GTK runner compiled on the build
machine takes the build machine's glibc. `desktop.sh` checks every ELF file
with `objdump -T` and fails above `GLIBC_2.31`. On a newer distribution with
Docker, `desktop.sh` therefore builds inside an Ubuntu 20.04 container
(`tools/package/linux/Dockerfile`, same repository path, your user id) by
default; this is what CI does. `MINESYNC_PKG_CONTAINER=none` forces a native
build, `MINESYNC_PKG_CONTAINER=ubuntu:20.04` forces the container.

Other variables: `MINESYNC_GLIBC_CHECK=warn` (native test build on a new
distribution), `MINESYNC_SKIP_FLUTTER_BUILD=1` (reuse the Flutter build),
`MINESYNC_NO_DOWNLOAD=1` (stop at the AppDir, do not fetch appimagetool),
`MINESYNC_APPIMAGETOOL=<path>` (use a local appimagetool). appimagetool
1.9.1 and the type 2 runtime 20251108 are downloaded from GitHub and checked
against pinned SHA-256 values. Intermediate files go to `build/package/`.

## Outputs

```
<outdir>/
  MineSync-<v>-linux-x64.AppImage         (or -linux-arm64)
  MineSync-<v>-windows-x64-setup.exe
  MineSync-<v>-macos-arm64.dmg            (or -macos-x64)
  MineSync-<v>-<platform>-cli.tar.gz      CLI + guard (.zip on Windows)
  update/<platform>/manifest.json         self-update payload
  update/<platform>/manifest.json.sig     written by sign.sh
  update/<platform>/minesync-<v>-<platform>.tar.gz
  SHA256SUMS, SHA256SUMS.sig              written by sign.sh, downloads only
```

`desktop.sh` leaves the payload unsigned; `sign.sh` signs the exact manifest
bytes with `MINESYNC_UPDATE_KEY` (the format of `minesync_release keygen`)
and lists only the user downloads in `SHA256SUMS` (`<hex>  <name>`). In CI
the `package` job signs with a throwaway key generated in the job; only the
tag release uses the real key.

What each package contains:

- **AppImage**: `AppRun` is the launcher; `bootstrap/` is a complete version
  folder (Flutter bundle, `minesync-guard` and `minesync` next to the app
  binary, `.manifest.json`). On first start the launcher copies it into
  `~/.local/share/MineSync/versions/<v>/`. The AppImage uses the static type 2
  runtime, so `libfuse2` is not needed.
- **Windows installer** (Inno Setup, per user, no admin prompt): installs to
  `%LOCALAPPDATA%\MineSync` with `MineSync.exe` (launcher, GUI subsystem) at
  the root and the app in `versions\<v>\`, writes `state.json`, and creates
  the Start menu shortcut `MineSync.lnk` with the AppUserModelID `MineSync`
  used by the app's notifications. English and Italian. The uninstaller
  removes the install folder and the autostart entry, and asks before removing
  the settings in `%APPDATA%\MineSync` (kept on silent uninstall).
- **dmg**: `MineSync.app` (the launcher, `io.github.alesdrnz.minesync`, no
  Dock icon of its own) with the app bundle in
  `Contents/Resources/bootstrap/MineSync.app`
  (`io.github.alesdrnz.minesyncDesktop`, thinned to one architecture, guard
  and CLI in `Contents/MacOS`), and a link to `/Applications`. Versions are
  installed to `~/Library/Application Support/MineSync/versions/`.

## Minimum OS versions

| OS | Minimum |
|---|---|
| Linux | glibc 2.31 (Ubuntu 20.04, Debian 11, Fedora 32 or newer), x64 or arm64 |
| Windows | Windows 10 22H2 (build 19045), x64 |
| macOS | macOS 13 Ventura, Apple Silicon or Intel |

## Unsigned apps

The packages have no code signing certificate yet, so the first start shows a
warning:

- **Windows SmartScreen** ("Windows protected your PC"): click *More info*,
  then *Run anyway*. The installer never asks for administrator rights.
- **macOS Gatekeeper** ("cannot be opened because the developer cannot be
  verified" or "is damaged"): the bundle has an ad-hoc signature only, which
  Apple Silicon requires to run code at all but which Gatekeeper does not
  trust. After copying `MineSync.app` to Applications, right-click it and
  choose *Open* (on macOS 15 and later: *System Settings → Privacy & Security
  → Open Anyway*), or remove the quarantine flag:
  `xattr -dr com.apple.quarantine /Applications/MineSync.app`.
- **Linux**: make the AppImage executable (`chmod +x`) and start it.

Self-updates are not affected: the app verifies the ed25519 signature of
every update against the public key embedded at build time.
