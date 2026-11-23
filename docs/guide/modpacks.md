# Modpacks

MineSync describes a server's mods in one file in the server folder,
`minesync-pack.json`. It is synced like any other file, so every change of
mods is a new version on the hub and can be undone from the history. The
file format, the resolver and the `.mrpack` mapping are specified in
[docs/design/modpack.md](../design/modpack.md).

Supported loaders: vanilla, Fabric, Quilt, Forge and NeoForge (Paper is not
a modpack loader). Mods come from Modrinth; CurseForge and other jars are
kept as references or manual entries.

## Managing server mods

Open a server, tab **Mods**, view *Server mods*.

- The first time, MineSync recognises the jars already in `mods/` by their
  hash on Modrinth. Jars it does not know become *manual* entries (side
  *server* by default) and are never updated or deleted by MineSync.
- Search Modrinth and add mods: required dependencies come along, optional
  ones are suggested, incompatible ones are refused with the reason.
- Per mod: update (releases only, or betas if you allow them), pin (skipped
  by *Update all*), enable or disable (the jar is renamed `.disabled`), side
  (*server*, *client*, *both*), optional for players, remove (dependents go
  with it; dependencies nobody needs any more are offered for removal).
- *Change version…* switches Minecraft version or loader: MineSync checks
  every mod first and lists what is ready, blocked or unknown. *Tell me when
  they are ready* checks again each time you open the tab.

Every edit goes into a draft listed at the bottom. **Apply and upload to the
hub** then:

1. refuses while anyone hosts the server (offering *Apply when the server is
   free*, with a notification first);
2. brings your copy to the hub's latest version;
3. installs the new server or loader if version or loader changed;
4. downloads and verifies every file into a temporary folder before touching
   the server folder (if anything fails, nothing changes);
5. uploads the result as a new version.

Client-only mods live in `client-overrides/mods/` of the server folder: the
server never loads them, but they go into the player pack. If Modrinth is
unreachable, installed mods keep working and search and updates retry every
30 seconds.

## Creating a server

Admins press **New server**. Three origins:

- **From scratch**: pick the Minecraft version and loader; recommended mods
  can be added now or later.
- **From a modpack**: a `.mrpack` file (the format of Modrinth and Prism
  Launcher) or a modpack found on Modrinth; versions and mods come from it.
- **From a folder**: an existing server on this PC. It is copied into the
  worlds folder and uploaded as it is; the original folder is not touched.

MineSync checks Java right away for the chosen version (with a Temurin link
and *Search again*; it never downloads Java by itself), asks you to accept
the Minecraft EULA with one click, and prepares everything in a temporary
folder. The server is created on the hub only when the files are in place,
then the folder is uploaded as version #1. A failed step resumes from where
it stopped.

Server software comes from the official sources: Mojang's version manifest
for `server.jar`, `meta.fabricmc.net`, `meta.quiltmc.org`,
`maven.neoforged.net` and `maven.minecraftforge.net` for the loaders, with
the published hashes checked where the source provides them.

## The player pack

Players need the same client mods to join. The **Player pack** view of the
Mods tab lists required, optional (each PC chooses) and server-only mods,
and prepares the pack from your local copy (which must be at the hub's
latest version). Playing needs a Microsoft account, which only approved
launchers can use, so MineSync prepares an instance and you start it from
the launcher.

- **Prism Launcher** (recommended; handles accounts, Java and every loader):
  *Open in Prism* exports `<name>-<version>.mrpack` to your Downloads folder
  and runs `prismlauncher --import <file>`; confirm with OK and Prism
  downloads the mods. Without Prism, *Export the .mrpack file* only writes
  the file, to import later or send to someone.
- **Official launcher** (vanilla, Fabric and Quilt only; Forge and NeoForge
  need their own installer, so use Prism). Offered only when the launcher
  folder and its `launcher_profiles.json` exist. MineSync:
  1. fetches the loader profile from `meta.fabricmc.net` or
     `meta.quiltmc.org`;
  2. downloads and verifies the player mods, copies the shared files from
     the server folder, and places them in
     `<launcher folder>/minesync/<server id>/` (files from an older pack that
     are no longer in it are removed; the list is in `.minesync-files.json`);
  3. writes `versions/<id>/<id>.json` for the loader;
  4. backs up `launcher_profiles.json` as
     `launcher_profiles.json.minesync-<UTC timestamp>.bak`, then adds or
     updates only the profile `minesync-<server id>`, named
     "MineSync · <server>"; every other profile is left as it was.

  The launcher folder is `%APPDATA%\.minecraft` on Windows,
  `~/Library/Application Support/minecraft` on macOS and `~/.minecraft` on
  Linux.

The hub web UI offers the same pack to everyone, on the server's Mods tab:
the `.mrpack` and a ZIP of the player mods only (`mods/<file>.jar`), built
from the hub's latest version without contacting any other service.

## CurseForge

MineSync has no CurseForge API client (it needs a per-application key).
CurseForge mods are references: if a mod's author disallows third-party
downloads, MineSync shows *Open the page on CurseForge*, you download the jar
yourself and point MineSync to it. Such mods are never put in the player
pack: players get the same page link and download them by hand. CurseForge
files referenced in a `.mrpack` with a `forgecdn.net` URL are kept as
allowed downloads.

## What MineSync does not do

- It does not start Minecraft and never sees your Microsoft account: you
  play from Prism Launcher or the official launcher.
- It does not download Java, nor install Prism Launcher.
- It does not update manual or CurseForge mods, and never deletes a jar
  whose hash it does not know.
- It does not change mods while someone is playing on the server.
