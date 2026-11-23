# The desktop app and the CLI

The MineSync app runs on every PC that plays. Whoever presses Play hosts the
server on their own PC; the others join it from Minecraft. The app needs
ZeroTier installed and joined to your group's network.

## Install

Download the app from your hub's web page, `http://<hub-ip>:8084/dl`, or
from the GitHub release. The packages are **not code-signed** yet, so the
first start shows a warning. Updates are not affected: each one is verified
against the ed25519 key built into the app.

| System | Minimum | Package |
|---|---|---|
| Windows | Windows 10 22H2 (build 19045), x64 | `MineSync-<v>-windows-x64-setup.exe` |
| macOS | macOS 13 Ventura, Apple Silicon or Intel | `MineSync-<v>-macos-arm64.dmg` / `-macos-x64.dmg` |
| Linux | glibc 2.31 (Ubuntu 20.04, Debian 11, Fedora 32 or newer), x64 or arm64 | `MineSync-<v>-linux-x64.AppImage` / `-linux-arm64.AppImage` |

**Windows.** Run the setup. If SmartScreen says "Windows protected your
PC", click *More info*, then *Run anyway*. The installer is per user and never
asks for administrator rights: the app goes to `%LOCALAPPDATA%\MineSync` and
a *MineSync* entry is added to the Start menu. The uninstaller removes the
app and asks before removing your settings in `%APPDATA%\MineSync`.

**macOS.** Open the dmg and drag `MineSync.app` to Applications. Gatekeeper
will say the app "cannot be opened because the developer cannot be
verified" (or that it "is damaged"). Right-click the app and choose *Open*
(on macOS 15 and later: *System Settings → Privacy & Security → Open
Anyway*), or remove the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/MineSync.app
```

Versions are installed to `~/Library/Application Support/MineSync/versions/`.

**Linux.** Make the AppImage executable and start it (no `libfuse2` needed):

```sh
chmod +x MineSync-0.1.0-linux-x64.AppImage
./MineSync-0.1.0-linux-x64.AppImage
```

The AppImage is only the launcher: on first start it installs the app into
`~/.local/share/MineSync/versions/`. Keep the AppImage where it is.

## First run

1. Make sure ZeroTier is running and this PC is joined and approved in the
   group's network (the network's admin approves new members in ZTNET).
2. Enter the hub address the admin gave you, e.g. `http://192.0.2.10:8084`
   (`192.0.2.10:8084` is accepted too).
3. The app reaches the hub and asks the network who you are. If it says "You
   are not on the ZeroTier network", this PC is not joined or not approved
   yet.
4. Choose where to keep the worlds on your PC (default: `MineSync` in your
   home folder) and whether MineSync starts with the computer.

You can change hub at any time from Settings.

## Playing

On a server's page (tabs *Overview*, *Mods*, *History*; *More* holds the
manual download, upload, integrity check and open folder):

- **Free**: press *Play*. The app takes the server's lock, downloads what
  changed since your last game, starts the server on your PC through
  `minesync-guard`, and shows you the address friends use. The first time
  the server is downloaded into `MineSync/<server>` in the worlds folder
  (*Change…* in *On your PC* picks another folder) and you accept the
  Minecraft EULA (one click writes `eula=true`).
- **On your PC** also holds this PC's choices for the server: Java, memory
  and autostop. **To join** shows what friends need (Minecraft version, the
  players pack for modded servers) and the fixed address if the hub has DNS.
- **Someone is playing**: the page shows who and the address to join (open
  Minecraft, *Multiplayer*, *Add Server*, paste it). *Tell me when it is
  free* sends a desktop notification.
- **Stale**: the host's app has stopped sending signs of life. Wait for them,
  or force it (two confirmations; for a live host, admins only). At most the
  minutes since their last save are lost.

While you host, the server's page becomes the session: the steps, the
console (with filter, search and commands), the players, the address and the
hub's port test.

- **Autosave**: every 5 minutes (Admin setting) the app saves the world
  without stopping the game and uploads it to the hub in the background,
  within the bandwidth limit. *Save now* forces one.
- **Crashes**: if the server closes unexpectedly, the app saves what it can
  and restarts it (2 times by default). After that it stops and points you to
  the console; out-of-memory crashes suggest raising the memory.
- **Autostop**: an empty server stops by itself after 30 minutes without
  players (hub default; each PC can switch it off per server).
- **Stop and save** (or `stop` in the console, or closing the app): the app
  saves, uploads the final state, frees the server and only then exits.
  Keep the PC on until it finishes.
- **Lock lost**: if someone forced the server, your session stops and the
  page says control moved to another PC.

The friends' address is your ZeroTier IP and port (the *direct IP*), or, if
the hub's DNS is on, a fixed name like `zerotier.survival.internal` that
always points to the current host.

### Local changes

If your copy has changes that never reached the hub and someone else played
meanwhile, Play stops and asks:

- *Use the hub version*: your touched files are first copied into the
  server folder's `.minesync/backup/`, then the hub version is downloaded.
  Nothing is lost.
- *Upload mine as a new version…*: your copy becomes the new version for
  everyone (two confirmations); the replaced one stays in the history.

## History and restore

The **History** tab lists every version (generation) with author, size and
the files added, changed and removed. Admins can *Restore #n…* when nobody
is playing: it creates a new version identical to the old one, so nothing is
ever lost. The hub web UI's history also offers a ZIP of any version, the
restore of a single damaged file, and (admins) deleting old versions.

## Settings

Settings apply to this PC only; the rules shared by everyone are in the hub's
Admin area.

- **General**: hub, language, theme and style, interface size, less motion,
  start with the computer, keep running in the background when the window is
  closed (a running server stays on), desktop notifications.
- **Network**: upload bandwidth limit while playing (automatic = 70 % of the
  measured speed, a percentage, a fixed KB/s, or none).
- **Info**: version, automatic updates, *Check now*, *Copy diagnostic info*
  (paste it to whoever runs the hub).

The configuration is `config.json` in `%APPDATA%\MineSync` (Windows),
`~/Library/Application Support/MineSync` (macOS) or `~/.config/minesync`
(Linux; `MINESYNC_CONFIG_DIR` overrides it).

## Updates and rollback

The app checks the hub 30 seconds after start and then every 6 hours. A new
version is downloaded from the hub's `/dl/update/`, its signature and every
file are verified, and you are offered *Restart now* (or later; never while
you host a server). The launcher then starts the new version on trial: if it
fails to start twice, or does not confirm within 60 seconds, the launcher
marks it bad, goes back to the previous version and never installs that
version again. The current and the previous version are kept; the
launcher's diary is `launcher.log` in the install folder.

Self-update works only in the packaged app started through its launcher;
builds without the public key never update.

## The CLI

`minesync` is the same engine without a window, for scripts or a headless
PC. It ships inside the app (next to the app binary in
`versions/<v>/`) and as a separate archive,
`MineSync-<v>-<platform>-cli.tar.gz` (`.zip` on Windows), with
`minesync-guard`, which `play` needs next to it (or set `MINESYNC_GUARD`).
It shares `config.json` with the app.

| Command | What it does |
|---|---|
| `minesync login <hub-address>` | connect this PC to a hub (port 8084 if omitted) |
| `minesync spaces` | list the hub's servers with HEAD, lock and linked folder |
| `minesync link <server> <folder>` | link a server to a local folder |
| `minesync status [server]` | hub and local copy status |
| `minesync pull [server] [--discard-local]` | download the latest version |
| `minesync push [server] [-m message]` | upload the local copy as a new version |
| `minesync verify [server]` | re-read every file and compare with the last sync |
| `minesync play [server] [--discard-local] [--accept-eula] [--java PATH] [--xmx MiB]` | host the server: download, start, autosave, upload at the end |
| `minesync --version`, `minesync help` | version, usage |

`[server]` can be omitted when only one server is linked. During `play` the
console is on stdout, typed lines go to the server and Ctrl+C stops and
saves. `MINESYNC_UPLOAD_LIMIT` (KiB/s) limits background uploads. Exit
codes: 0 success, 1 error, 2 usage.

## Troubleshooting

**Cannot reach the hub.** Check that ZeroTier is running and connected to
the group's network on this PC, that the address is right
(`http://<hub-ip>:8084`) and that the hub is up (`docker compose ps` on the
NAS). "Not on the network" means the hub answered but ZTNET does not list
this PC as an authorised member.

**Port closed.** The hub tests the host's game port (25565 by default) for
3 minutes after the server starts. If it reports "Port closed", allow Java
through this PC's firewall for the ZeroTier network (on Windows, the
ZeroTier network is often classified as *Public*: allow Java there or make
the network *Private*), and check `server-port` in `server.properties`.
*Try again* reruns the test.

**Java missing.** The app looks in the server folder, `JAVA_HOME`, `PATH`
and the usual install folders, and picks the version the server needs. If
none fits, install that Java version (for example Eclipse Temurin from
adoptium.net), then on the server's page, in *On your PC*, choose
*Change…* next to Java and *Search again*, or pick a runtime there. The app never downloads Java by itself.

**Disk full.** On this PC: free space in the worlds folder, then retry. On
the hub: below its free-space floor the hub refuses uploads ("the hub is
out of space"); the world stays on the host PC and the hub keeps the last
version it accepted. An admin frees space in Admin
› History and disk (cleanup) or deletes old versions.

**The server crashes at start.** Read the console in the Session tab; for
modded servers check the Mods tab (a mod for the wrong loader or version).
