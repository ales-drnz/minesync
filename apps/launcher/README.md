# minesync_launcher

Launcher and signed self-update of the MineSync desktop app.

## Pieces

- `bin/minesync_launcher.dart`: the only executable users start. Compiled AOT
  as `minesync-launcher` (Linux), `MineSync.exe` (Windows, patched to the GUI
  subsystem with `minesync_release gui-subsystem`), `MineSync` inside
  `MineSync.app/Contents/MacOS` (macOS).
- `lib/update.dart`: install layout and `state.json`, manifest and ed25519
  verification, `Stager` (download, verify, extract, mark pending). The
  desktop app uses it from `apps/desktop/lib/src/update/`.
- `bin/minesync_release.dart`: release tool (`keygen`, `pack`, `sign`,
  `gui-subsystem`). The private key is never in the repository.

## Install layout

```
<root>/
  state.json           {current, previous, pending, pendingAttempts, bad[]}, atomic writes
  state.lock           read-modify-write lock shared by launcher and app
  launcher.lock        one supervising launcher
  launcher.log         launcher diary (rotated at 1 MiB)
  versions/<v>/        complete app + .manifest.json
  downloads/           archive being downloaded (cleaned)
  run/healthy-<v>      written by the app after its first frame
```

| OS | `<root>` | launcher | first version |
|---|---|---|---|
| Windows | `%LOCALAPPDATA%\MineSync` | `MineSync.exe` in `<root>` | `versions\<v>\` from the installer |
| Linux portable | launcher folder | `minesync-launcher` | `versions/<v>/` next to it |
| Linux AppImage | `$XDG_DATA_HOME/MineSync` | inside the AppImage | `$APPDIR/bootstrap` |
| macOS | `~/Library/Application Support/MineSync` | `MineSync.app` | `MineSync.app/Contents/Resources/bootstrap` |

A *bootstrap* folder is a version folder (with `.manifest.json`) shipped in a
read-only package; the launcher copies it into `versions/` when it is newer
than `current`. With no valid `current`, the newest complete folder in
`versions/` is adopted. On AppImage and macOS the launcher never replaces
itself (read-only, code signature); elsewhere it replaces itself by rename
after a `--selftest`.

## Hub layout

Served by the hub under `/dl/`:

```
/dl/update/<platform>/manifest.json       exact signed bytes
/dl/update/<platform>/manifest.json.sig   base64 ed25519 signature of those bytes
/dl/update/<platform>/<archive>.tar.gz
```

`<platform>` is `linux-x64`, `linux-arm64`, `windows-x64`, `macos-arm64`,
`macos-x64`. The private key is a 32-byte ed25519 seed in base64;
signatures are base64. The app embeds the public key at build time:
`--dart-define=MINESYNC_UPDATE_PUBKEY=<base64>`; without it, self-update is
off.

## Rules

- The signature is verified on the received bytes before parsing or
  downloading anything; only strictly newer semver versions are accepted;
  versions in `bad` are never installed again.
- Every archive entry is checked against the manifest (path traversal,
  absolute paths, case collisions, symlinks leaving the tree or written
  through, no hardlinks or devices, per-file SHA-256, nothing missing).
- The app stages into `versions/<v>.partial`, renames it, then sets
  `pending` and exits with 75. The launcher persists `pendingAttempts` before
  starting the trial; `run/healthy-<v>` promotes it; two failed starts or no
  marker within 60 s mark it bad and start `current` again.
- A second launcher, while one is supervising, starts `current` with
  `MINESYNC_SECONDARY=1` and does not touch the state: the app finds the
  running instance, asks it to show its window and exits.

## Tests

`dart test` runs format and staging tests in-process and the end-to-end
scenarios (`test/scenarios_test.dart`, tag `scenario`): real AOT launcher and
fake app, kill mid-download/extract/commit, crash and hang rollback, launcher
killed during a trial, bootstrap install, second launcher. They are headless
and run on Linux, Windows and macOS.
