# Spike: signed self-update of the desktop app

Throwaway prototype. Question: can a Flutter desktop app, which ships as a
**folder** (exe + .so/.dll + `data/`) rather than a single binary, update itself
from the hub safely (signed, atomic, crash-safe, with automatic rollback)?

Spec being replaced: `client/internal/selfupdate/selfupdate.go` (semver-only
upgrades, signed `SHA256SUMS`, `.old` kept until the new binary works).

## Design

```
<root>/                         Windows: %LOCALAPPDATA%\MineSync   Linux: portable folder
  minesync[.exe]                launcher (Dart AOT, ~5 MB) - the only thing shortcuts point to
  state.json                    {current, previous, pending, pendingAttempts, bad[]}  (atomic write)
  state.lock / update.lock / launcher.lock
  versions/<ver>/               full app + .manifest.json
  versions/<ver>.partial/       extraction in progress (never started, cleaned)
  downloads/*.part              download in progress (cleaned)
  run/healthy-<ver>             written by the app once it is up
```

Hub layout: `update/<platform>/manifest.json`, `manifest.json.sig` (base64
ed25519 over the exact bytes), `<archive>.tar.gz`. The manifest lists version,
platform, kind (`archive` | `file`), archive size+sha256, entrypoint, optional
bundled launcher, and every file (path, size, sha256, mode, or symlink target).

App side (`lib/src/updater.dart`): fetch manifest+sig → **verify signature
before parsing or downloading anything** → strictly newer semver, not in `bad`
→ stream download with size cap + sha256 → stream-extract (own minimal tar
reader, `dart:io` gzip) into `versions/<v>.partial`, checking every entry
against the manifest (path traversal, absolute/drive paths, case collisions,
symlinks escaping or being written through, no hardlinks/devices, per-file
sha256, all files present) → fsync → rename to `versions/<v>` → set
`pending=<v>` in `state.json` (second commit point) → exit 75 ("restart me").

Launcher (`lib/src/launcher.dart`): single instance; if `pending` exists it
increments **and persists** `pendingAttempts` *before* starting it, then waits
for `run/healthy-<v>`. Healthy → promote (`previous=current`, `current=v`),
cleanup keeping one previous version, self-update of the launcher. Exit before
healthy → retry; after 2 attempts, or no marker within 60 s (process killed),
→ `bad += v`, start `current`. The app never touches its own running folder.

Launcher self-update: the new launcher ships inside the version folder; after
promotion the running launcher copies it to `minesync.new`, runs
`minesync.new --selftest` (must report the same launcher protocol), then
`minesync → minesync.old`, `minesync.new → minesync` (renaming a running
executable is allowed on Linux, macOS **and Windows**; overwriting it is not on
Windows). `.old` is deleted on the next start.

Signing tool: `bin/signtool.dart` (`keygen`, `pack`, `pack-file`, `sign`). Key
format is the same as `scripts/sign` (base64 32-byte seed / base64 signature):
a signature made by the Go tool with the same key is byte-identical and
verifies in Dart (checked manually, see below), so the existing release key can
be kept.

Dependencies: `cryptography` 2.9.0 (Apache-2.0, pure-Dart Ed25519), `crypto`
3.0.8, `ffi` 2.2.0, `path` 1.9.1 (BSD-3-Clause). No `archive` package (own
~250-line tar, so extraction streams and hashes per file).

## Run

```
./run.sh            # Linux/macOS
./run.ps1           # Windows
```
Compiles launcher (2 builds), fake app, sign tool; builds signed releases of a
fake bundle shaped like a Flutter Linux bundle (exe, 6 MB `lib/libapp.so`,
8 MB `lib/libflutter_linux_gtk.so`, a symlink, `data/icudtl.dat`, 300
`flutter_assets` files; 21 MB tar.gz); starts an in-process fake hub
(`lib/src/fake_hub.dart`, also `bin/fake_hub.dart`); runs the scenarios. Logs in
`.tmp/e2e/logs/e2e.log`. CI proposal for all three OSes: `ci/update-spike.yml`.

## Results (measured, Linux x64 CachyOS, 16 cores, Dart 3.13.4)

`./run.sh` → **98/98 checks, 11/11 scenarios PASS**, exit 0, in 2 consecutive runs; 50-81 s wall
(machine shared with other jobs, timings below vary by that much).

| Scenario | Result |
|---|---|
| update_ok: 1.0.0 → 1.1.0 → 1.2.0, launcher self-update b1→b2, cleanup keeps one previous | PASS (update+restart+promotion: 2.0-2.3 s for 21 MB over loopback) |
| bad_signature: other key / manifest edited after signing / non-base64 sig | PASS - rejected, archive never requested, 1.0.0 byte-identical |
| bad_hash: archive byte flipped / truncated / wrong per-file hash (validly signed) | PASS - rejected, no `.partial`, no downloads left |
| older_version: hub offers 0.9.0 or 1.0.0 | PASS - ignored, no download |
| kill (SIGKILL app + launcher) mid-download / mid-extraction / between dir rename and state commit | PASS - current still starts, residue cleaned, retry succeeds |
| crash_rollback: new version exits 3 at start | PASS - 2 attempts, rollback, 1.0.0 runs, version marked bad and not re-downloaded (2.2-5.9 s incl. update) |
| hang_rollback: no healthy marker within timeout (3 s in test, 60 s default) | PASS - killed, rollback |
| launcher_killed_during_trial: launcher SIGKILLed twice during trial | PASS - attempt counter persisted, 3rd start rolls back |
| appimage: single file replaced by rename while the old one runs | PASS - old process alive, next start new, `.old` kept; bad sig / mid-download kill leave `$APPIMAGE` intact |

Go/Dart key compatibility (manual): `cd scripts/sign && go run . sign <signing.key> <manifest.json>`
then `verifyManifest` in Dart → OK, signature identical to the Dart one.

Not verified: real Flutter bundle (the fake mimics its layout; Flutter's
`$ORIGIN/lib` RPATH makes the folder relocatable), real AppImage (the test file
is a shell script; what is tested is rename-over-running-file), Windows, macOS.

## Platforms

**Linux portable folder** - as tested. Root = launcher's folder; it must be
user-writable (otherwise: notify "download the new version").

**Linux AppImage** - a single read-only squashfs; there is no folder to put
`versions/` in. Tested option A: `AppImageUpdater` downloads next to
`$APPIMAGE`, verifies, `chmod +x`, hardlinks the old one to `.old`, `rename()`s
the new over `$APPIMAGE` (the running instance keeps its inode/FUSE mount).
Limits: no automatic rollback (nothing supervises the first start), needs write
access to the AppImage's directory. Recommended option B: the AppImage *is* the
launcher + a bootstrap version; updates go to
`$XDG_DATA_HOME/MineSync/versions/` and the launcher picks the newest healthy
one (same code as the folder mode, rollback included, $APPIMAGE never
rewritten).

**Windows** - per-user install in `%LOCALAPPDATA%\MineSync` (no admin, no UAC;
Start-menu shortcut in `%APPDATA%\Microsoft\Windows\Start Menu\Programs`
pointing at `MineSync.exe` = launcher). Running DLL/EXE in `versions\1.0.0\`
cannot be overwritten or deleted, but nothing needs to be: the new version goes
to a new folder; deleting the old one is best-effort and retried on the next
start. The launcher updates itself by rename (see above; a stale
`.old-<timestamp>` is used if `.old` is still locked). `renameRetry` absorbs
transient AV/indexer locks on freshly written files. Kill uses TerminateProcess;
the launcher should also put the app in a Job Object (as 3.x does for java).
No symlinks in Windows packages (rejected). SmartScreen: sign both exes with
Authenticode; the ed25519 check is independent of it. To verify in CI:
`run.ps1` on windows-latest (same 10 scenarios, AppImage skipped).

**macOS** - recommended: the user-installed `MineSync.app` is the launcher
bundle (small, signed + notarized, rarely changes); versions are full signed +
notarized + stapled `.app` bundles under
`~/Library/Application Support/MineSync/versions/<v>/MineSync.app`, started by
exec'ing `Contents/MacOS/MineSync`. Why: no write access to `/Applications`
needed (standard users), no App Translocation of updates (files downloaded by
our own HttpClient get no quarantine xattr), each version's code signature
stays intact because the bundle is never modified in place. Required: the tar
must preserve symlinks (`Frameworks/*.framework/Versions/Current`) and modes -
supported and tested by the extractor. Launcher self-update = replacing the
whole launcher `.app` by rename, only possible if its parent is writable; if it
runs translocated (path under `/private/var/folders/.../AppTranslocation/`) or
from a read-only location, ask the user to move it to /Applications and skip
launcher updates. Alternative (Sparkle-style: replace `/Applications/MineSync.app`
wholesale) needs admin for non-admin users - rejected. To verify in CI:
`run.sh` on macos-latest covers the generic mechanism (incl. symlinks, arm64);
`.app`/notarization/Gatekeeper need a manual test with a real Developer ID.

## Conclusion

The launcher + `versions/<v>/` + atomic `state.json` design works on Linux for
every required scenario, with ~1500 lines of Dart (plus a 530-line e2e harness) and only permissive deps.
Recommend it for Phase 1 on all three OSes (AppImage as option B).
Open: Windows/macOS CI runs, a real Flutter bundle, "healthy" = first frame +
engine init (not hub contact: offline users must not roll back), crash
fallback when `current` itself breaks (currently: exit with its code).
