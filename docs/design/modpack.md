# MineSync: modpacks

The modpack of a server is described by one file in the server folder,
`minesync-pack.json`. It is synced through the hub like any other file, so
every change is a new generation and the history works as usual (go back to
generation N = go back to its pack). Code: `packages/ms_modpack`
(`lib/ms_modpack.dart` is pure Dart and web-safe; `lib/io.dart` adds files,
real HTTP and the server installers).

## Server folder layout

| Path (server root) | Content |
|---|---|
| `minesync-pack.json` | the pack file (below) |
| `mods/<file>.jar` | mods with side `server` or `both` |
| `client-overrides/mods/<file>.jar` | mods with side `client` (the server never loads them) |
| `client-overrides/**` | other files only for players (from a `.mrpack`'s `client-overrides/`) |
| `<location>.disabled` | a disabled mod: the file stays, the loader skips it |
| `.minesync-modpack.tmp/` | temporary downloads; excluded by the system pattern `.minesync*` |

None of the default exclusions (`packages/ms_protocol/lib/src/exclusions.dart`)
matches `minesync-pack.json`, `client-overrides/**` or `*.jar.disabled`
(tested in `ms_modpack/test/pack_test.dart`). Partial files use the
`.minesyncpart` suffix, which is excluded.

## Pack file format (`format: 1`)

```json
{
  "format": 1,
  "name": "Survival",
  "minecraft": "1.21.1",
  "loader": "fabric",
  "loaderVersion": "0.16.14",
  "shared": ["config/**"],
  "mods": [
    {
      "path": "mods/create-fabric-6.0.8+mc1.21.1.jar",
      "name": "Create",
      "side": "both",
      "source": "modrinth",
      "projectId": "AAAAAAAA",
      "versionId": "BBBBBBBB",
      "versionNumber": "6.0.8",
      "size": 14800000,
      "sha1": "<40 hex>",
      "sha512": "<128 hex>",
      "downloads": ["https://cdn.modrinth.com/data/AAAAAAAA/versions/BBBBBBBB/create-fabric-6.0.8+mc1.21.1.jar"],
      "requires": ["CCCCCCCC"]
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `minecraft` | Minecraft version (`1.21.1`, `26.1`) |
| `loader` | `vanilla`, `fabric`, `quilt`, `forge`, `neoforge` (`paper` is refused) |
| `loaderVersion` | required except for `vanilla`, where it must be absent |
| `shared` | exclusion-syntax patterns of server files that also go to players (`overrides/` of the client `.mrpack`) |
| `updatedAt` | optional ms timestamp; part of the bytes, so leave it unchanged when nothing changed |
| `mods[].path` | path inside the game instance (`mods/x.jar`, `resourcepacks/y.zip`), validated like manifest paths (no `..`, no absolute path, no reserved names, no `.minesync` prefix) and never under `overrides/`, `client-overrides/`, `server-overrides/`, never ending in `.disabled` |
| `side` | `client`, `server` or `both` |
| `optional` | optional for players ("Facoltative", a per-PC checkbox); the server always installs `server`/`both` mods |
| `source` | `modrinth` (needs `projectId` + `versionId`; updatable), `curseforge` (reference only), `manual` (never updated) |
| `sha1`, `sha512`, `size` | always present; every download is verified against them |
| `downloads` | `https` URLs only |
| `requires` | Modrinth project ids required by this version, so dependents are known offline |
| `curseforge` | `{projectId?, fileId?, pageUrl?, allowDistribution?}` |
| `pinned` | "update all" skips it |
| `disabled` | file renamed with `.disabled` |
| `auto` | added by MineSync as a required dependency (removed as an orphan when nobody needs it) |

Encoding is canonical: fixed key order, default values omitted, mods sorted
by path (UTF-8 byte order), two-space indent, final `\n`. The same pack always
gives the same bytes, so the file only changes (and only creates a
generation) when something really changed. Mod identity is `projectId` for
Modrinth mods, otherwise the case-folded path; paths and locations must be
unique ignoring case.

### What counts as a change

Any byte difference of the file. `PackDiff(from, to)` groups it for the UI:
`mcVersion`, `loader` (loader or its version), `added`, `removed`, `updated`
(different version or hash), `toggled` (only enabled/disabled), `changed`
(side, optional, pinned, name, URLs) and `sharedChanged`. `touchesFiles` says
whether files must be downloaded, moved or deleted.

### Unrecognised jars

`checkPack(pack, files)` compares the pack with the jars in `mods/` and
`client-overrides/mods/` (top level, also `.disabled`): `missing` (in the pack,
not on disk), `mismatched` (same location, other SHA-1: replaced by hand) and
`untracked` (on disk, unknown). The desktop first asks Modrinth
(`version_files` by SHA-1); what stays unknown becomes a `manual` entry with
its hashes (`manualEntry`), side chosen by the admin, **default `server`**
(a jar under `client-overrides/mods/` defaults to `client`). Manual entries
are never updated or replaced; MineSync never deletes a file whose hash it
does not know.

### Sides from Modrinth

`client_side`/`server_side` (`required`, `optional`, `unsupported`,
`unknown`): client only → `client` (optional if `client_side` is
`optional`); server only → `server`; both supported → `both` (optional for
players if `client_side` is `optional`); unknown → `both`. A side chosen by
the admin survives updates.

## `.mrpack` mapping (Modrinth format v1)

`modrinth.index.json`: `formatVersion: 1`, `game: "minecraft"`, `versionId`,
`name`, `summary?`, `files[]` (`path`, `hashes.sha1`, `hashes.sha512`,
`env.client`/`env.server` = `required|optional|unsupported`, `downloads`,
`fileSize`), `dependencies` (`minecraft` plus one of `fabric-loader`,
`quilt-loader`, `forge`, `neoforge`). Folders: `overrides/` (both sides),
`client-overrides/`, `server-overrides/`.

**Import** (`readMrpack`, `readMrpackFile`): every `files[].path` and every
override path is validated with ms_protocol `checkPath` (no `..`, absolute,
reserved or `.minesync*` paths, no Windows-forbidden characters) and may not
target `minesync-pack.json` or, outside `client-overrides/`, the
`client-overrides/` folder. Errors are `MrpackError(reason)`: `badZip`,
`noIndex`, `badIndex`, `badPath`, `tooLarge` (total uncompressed size above
the limit, 1 GiB by default), `unsupportedFormat`, `unsupportedGame`,
`badLoader` (more than one loader). Mapping:

- `env` → side/optional (no `env` → `both`, required);
- a `cdn.modrinth.com/data/<project>/versions/<version>/…` URL → `modrinth`
  with both ids; a `forgecdn.net` URL → `curseforge` with
  `allowDistribution: true`; anything else → `manual` with its URLs;
- `overrides/x` and `server-overrides/x` → `x` in the server root (server
  overrides win); `client-overrides/x` → `client-overrides/x`;
- jars inside the override folders become `manual` entries (hashes computed);
- top-level entries of `overrides/` (not mods) become `shared` patterns.

Hashes of downloaded files are verified at download time (`Downloader`).

**Export of the player pack** (`planClientPack` → `ClientPackPlan`, written by
`writeMrpack` or streamed by the hub):

- enabled mods with side `client` or `both`; `server` and disabled mods are left out;
- referenced by URL when a download is on a host the format allows
  (`cdn.modrinth.com`, `github.com`, `raw.githubusercontent.com`,
  `gitlab.com`); `env.server` is `required` for `both`, `unsupported` for
  `client`;
- otherwise the jar from the server folder becomes an override
  (`overrides/` for `both`, `client-overrides/` for `client`);
- CurseForge mods without `allowDistribution`, and jars that are not in the
  folder, go to `missing` (`PackMissingMod`, with the page URL): players
  download them by hand. The hub never redistributes them;
- files matching `shared` → `overrides/`; files under `client-overrides/`
  (not pack mods) → `client-overrides/`;
- `chosenOptional` (desktop, per PC): only the chosen optional mods, written
  as required; `null` (hub) keeps every optional mod as `optional`.

`modsZip` lists the jars of the "mods only" ZIP (`mods/x.jar`), same rules.

### Server from a players-only modpack (`server_split.dart`)

Many modpacks are published for players only (Modrinth `server_side:
unsupported`, no server pack). They are not refused: `splitForServer` (pure)
and `resolveServerSplit` (asks Modrinth) decide for every entry of an imported
`.mrpack` whether it stays on the server (`SplitFate.server`), is for players
only (`clientOnly`) or is `unknown`, trying in order:

1. the side from the index (`env`, or the `server-overrides/` folder): `client`
   and `server` entries are kept as they are;
2. the Modrinth project (by the id in the CDN URL, or by SHA-1 through
   `version_files` for other files): `server_side: unsupported` → players only
   (this wins over an `env` that says otherwise, since such mods often stop a
   server from starting); `required`/`optional` → server;
3. for jars inside the override folders, `environment` in `fabric.mod.json`
   or `quilt.mod.json` (`jarEnvironment`): `client` → players only;
4. an `env` in the index → server;
5. `resourcepacks/` and `shaderpacks/` → players only;
6. otherwise `unknown`: the admin decides, **default: keep on the server**.

`ServerSplit.apply(excluded:)` returns the import for the server: players-only
entries (and the unknown ones the admin removed) get side `client`, so they
are installed under `client-overrides/mods/` (the server never loads them) and
the player pack still contains them; their jars from the override folders move
under `client-overrides/`. Without Modrinth the split uses the index and the
jars only. Tests: `test/server_split_test.dart`.

Project descriptions (Markdown that often embeds HTML) are shown as plain text
through `plainMarkdown` (`description_text.dart`): headings, paragraphs and
bullets, no HTML and no images, and only `http`/`https` links, opened in the
system browser.

## Resolver (pure, deterministic)

Works on a `ModCatalog` already filled by `CatalogLoader` (Modrinth); the same
inputs always give the same plan. A version fits a target when it lists the
Minecraft version and a compatible loader (Quilt also accepts Fabric).
`bestVersion` picks the newest release (date, then `featured`, then id);
betas/alphas only when allowed (`maxType`) and no release fits.

- **Add** (`planAdd`): chosen or best version, then required dependencies
  recursively. A dependency already in the pack is accepted even if Modrinth
  names another exact version (launcher behaviour). An exact version that
  does not fit → `dependencyIncompatible` (with the game versions it needs);
  no version → `dependencyUnavailable`; `incompatible` dependencies in either
  direction → `conflict`; only pre-releases → `onlyPrerelease`. Optional
  dependencies are returned as `suggested`.
- **Update** (`checkUpdate`, `checkUpdates`, `applyUpdates`): release →
  releases only; beta → up to beta. States `upToDate`, `available`,
  `blocked` (with `Blocker`s), `pinned`, `notTracked` (manual/CurseForge),
  `unknown` (not loaded). An update may bring new dependencies (`alsoAdd`)
  or move an installed dependency forward to the exact version it requires
  (`alsoUpdate`), never backwards. "Update all" skips pinned mods.
- **Remove** (`planRemove`): dependents (via `requires`, transitively) go
  with it; `auto` dependencies nobody requires any more are `orphans`.
- **Change Minecraft version or loader** (`planRetarget` → `CompatReport`):
  per mod `ready` (current version kept if it already fits, otherwise the
  best release), `blocked` (with the reason; a mod whose required dependency
  is blocked is blocked too) or `manual` (MineSync cannot tell). `apply()`
  builds the new pack: ready mods moved, blocked removed, manual kept (or
  removed with `keepManual: false`), new dependencies added.

## Server install plan

`planInstall(from, to, files)` compares the old and new pack with the files
on disk: download what is missing (verified), move instead of re-downloading
(enable/disable, side change, a manual jar in the wrong folder), delete only
files that the old pack knew **with the same SHA-1**. An unknown jar that
occupies the destination is never overwritten: the mod is reported in
`unavailable`, as are mods without URL. `applyInstallPlan` downloads and
verifies everything into `.minesync-modpack.tmp/` first; if anything fails
nothing in the folder changes. Then deletes, moves, places the new files and
writes `minesync-pack.json` atomically. While someone plays the desktop
queues changes and applies them when the lock is free (UI rule, not enforced
here).

## Server installers (`lib/io.dart`, user-driven)

| Loader | Source | Verification |
|---|---|---|
| vanilla | `piston-meta.mojang.com/mc/game/version_manifest_v2.json` → version JSON → `downloads.server` | SHA-1 of the version JSON (from the manifest) and of `server.jar` |
| Fabric | `meta.fabricmc.net/v2` loader and installer lists, server launcher jar saved as `fabric-server-launch.jar` | none given by the source |
| Quilt | `meta.quiltmc.org/v3` versions, installer from `maven.quiltmc.org`, `install server <mc> <loader> --install-dir=<dir>` | `.sha1` next to the jar when published |
| NeoForge | `maven.neoforged.net` versions API and installer, `--installServer <dir>` | `.sha1` when published |
| Forge | `promotions_slim.json`, installer from `maven.minecraftforge.net`, `--installServer <dir>` | `.sha1` when published |

`server.jar` is always installed first (the loaders use it). Installers run
with the Java path given by the caller (ms_minecraft `pickJava` +
`requiredJava`); without one → `InstallFailed('java')` and the UI links to
Temurin (`temurinUrl(major)`), never an automatic download. `eula.txt` is
written only with `acceptEula: true`, i.e. after the user's explicit click.
Tests use fake transports and a fake process runner only.

## Modrinth client

`ModrinthClient` (API v2, `https://api.modrinth.com/v2/`) with an injected
`HttpTransport`: `search` (facets `project_type`, `versions`,
`categories` = loader, `client_side`/`server_side`), `project`, `projects`,
`versions` (filtered by `game_versions` and `loaders`), `version`,
`versionsByIds`, `versionFiles` (hash → version, `sha1`/`sha512`), `updates`
(`version_files/update`), `gameVersions`. User-Agent
`minesync/<version> (+<project homepage>)`. Rate limits: `X-Ratelimit-*`
are read after every response; with `remaining: 0` the next request waits for
the reset; `429` waits `Retry-After` (or the reset, at most 60 s) and retries;
`5xx` and network errors retry with backoff, then `ModrinthUnavailable`
("Modrinth is not answering"). Responses are cached by method, URL and body
(`MemoryCache`, or `FileResponseCache` on disk; 10 min, 24 h for hash lookups).

## CurseForge

Model only: `source: curseforge`, `CurseForgeRef` and `curseForgeEntry` for a
file the admin downloaded by hand from the page. No API client (it needs a
per-application key). Mods whose author disabled third-party distribution are
never put in the player pack: players get the same page link.

## Hub

See protocol.md, "Player pack": `GET /spaces/{id}/pack`,
`/pack.mrpack`, `/pack-mods.zip`, built from HEAD without network.

## Desktop app and hub web (user interface)

**Mods tab** (server detail: Overview · Session · Mods · History), with a
"Server mods | Player pack" switch. State: `apps/desktop/lib/src/state/modpack_state.dart`
(`ModpackController`, one per server, from `AppState.modpack(id)`); services
are injected through `AppDeps.modpack` (`ModpackEnv`: HTTP transport, response
cache in `<config>/cache/modrinth`, process runner, `ClientTools`), fakes in
tests.

- First open without `minesync-pack.json`: the jars are recognised by SHA-1
  (`versionFiles`) and the pack is built in memory (unknown jars → `manual`,
  side `server`, or `client` under `client-overrides/mods/`). The file is
  written only when the changes are applied.
- Every edit (add with dependencies, update, enable/disable, side, optional,
  pin, remove with dependents, change Minecraft version or loader) changes a
  draft; the bottom bar lists the changes. "Apply and upload": refused while
  the lock is live (anyone, including this PC), with the option to apply
  automatically when the server is free (a desktop notification first); the
  local copy is pulled first if it is behind; a new server/loader is installed
  when version or loader change; `applyInstallPlan` downloads and verifies
  everything before touching the folder; then the normal push (new
  generation, revertible from History).
- Changing version or loader runs `planRetarget` first; "Tell me when they
  are ready" stores the target in the preference `modpack.watch.<id>` and the
  check runs again at every open of the tab.
- Modrinth unreachable: installed mods keep working, search and updates show
  the reason and retry every 30 s.

**Player pack** (desktop): required / optional (per-PC choice, preference
`modpack.optional.<id>`) / server-only lists; `.mrpack` export to the user's
Downloads folder (`<name>-<generation>.mrpack`); "Open in Prism" exports and
runs `prismlauncher --import <file>`; the generation prepared last is stored
in `modpack.client.<id>` and a copy of that pack in
`<config>/modpack/<id>.client.json`, to show what changed when the server
moves on. The pack is built from the local copy, which must be at HEAD.

**Official launcher profile** (`state/launcher_profile.dart`), only when the
launcher folder (`~/.minecraft`, `%APPDATA%\.minecraft`,
`~/Library/Application Support/minecraft`) and its `launcher_profiles.json`
exist, and only for vanilla, Fabric and Quilt (Forge and NeoForge need their
own installer: the UI points to Prism):

1. the loader version JSON is fetched from `meta.fabricmc.net` /
   `meta.quiltmc.org` (`…/profile/json`), before touching any launcher file;
2. the player mods are downloaded and verified (SHA-1/SHA-512) into a
   temporary folder, overrides are copied from the server folder, then moved
   into `<launcher>/minesync/<server id>/`; files placed the previous time and
   no longer in the pack are removed (list in `.minesync-files.json` there);
3. `versions/<id>/<id>.json` is written (`fabric-loader-<loader>-<mc>` or
   `quilt-loader-<loader>-<mc>`; vanilla uses the Minecraft version and the
   launcher downloads it);
4. `launcher_profiles.json` is copied to
   `launcher_profiles.json.minesync-<UTC yyyyMMddHHmmss>.bak`, then the entry
   `profiles["minesync-<server id>"]` is set to `{name: "MineSync · <server>",
   type: "custom", icon: "Grass" (kept if present), lastVersionId, gameDir,
   created, lastUsed}` (other keys of an existing entry are kept); every other
   profile and top-level key is left as it was.

**New server wizard** (`state/new_server_state.dart`, admin only, replaces
the old dialog): origin (from scratch, from a modpack, from an existing folder: the old
flow, copied into the worlds folder), version and loader with an immediate Java check (Temurin link
and "Search again", no automatic download), recommended mods, one-click EULA
(only then `acceptEula: true`), creation with per-step status. Everything is
prepared in `<worlds>/.minesync-new-<ts>` first; the space is created on the
hub only after the server and mods are in place, then the folder is moved to
`<worlds>/<id>` and pushed as #1. A failed step is retried from where it
stopped.

**Modpack step of the wizard** (`state/pack_browser.dart`,
`screens/pack_browser.dart`): "Browse Modrinth" opens on the most downloaded
modpacks without typing (Prism Launcher's Modrinth tab was the model for the
interaction only), 20 per page with offset paging (scrolling near the end or
"Load more"); search runs 300 ms after the last key; sort (most downloaded,
relevance, newest, recently updated) and filters for loader (exact, a Quilt
modpack is not a Fabric one) and Minecraft release restart from the first page.
Rows show icon (fetched through the modpack transport, cached in memory and in
`<config>/cache/icons`, pixel texture fallback), title, author, description,
downloads, loaders and latest Minecraft version; players-only packs carry a
"players only" chip. The details pane (side by side above 820 px, instead of
the list below) has the version picker (releases, betas on request; default:
latest release matching the filters), "Use this modpack", the description as
plain text and the links. After download the summary shows the split ("N mods
on the server, M for players only"), the collapsible lists and the unknown
mods with a "On the server" checkbox each. "I already have a .mrpack file" is
the second option of the same step.

**Hub web**: the Mods tab of a server starts with the "Player pack" card
(`GET /spaces/{id}/pack`, download links to `/pack.mrpack` and
`/pack-mods.zip`), the same for members and admins; a server without
`minesync-pack.json` shows the vanilla (or "not managed yet") state. The side
of each mod comes from `minesync-pack.json` of HEAD, read through the HEAD
manifest and `GET /blobs/{hash}` (no new endpoint).
