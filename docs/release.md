# Making a release

A release is built entirely by `.github/workflows/release.yml` from a
`v<version>` tag. It produces the desktop packages for five platforms, the
signed self-update payloads, the hub binaries, the hub image on ghcr.io and
a **draft** GitHub release that you publish by hand.

## One-time setup: the update signing key

Apps verify every update with an ed25519 public key built into them at
compile time. Generate the key pair once, on a trusted machine:

```sh
flutter pub get --enforce-lockfile
dart run apps/launcher/bin/minesync_release.dart keygen --out ~/minesync-keys
# prints the public key; writes signing.key (0600) and signing.pub
```

The private key is a 32-byte ed25519 seed in base64, the public key is
base64 too, and signatures are base64.

In the GitHub repository (Settings → Secrets and variables → Actions):

- variable `MINESYNC_UPDATE_PUBKEY` = the content of `signing.pub`;
- secret `MINESYNC_UPDATE_KEY` = the content of `signing.key`.

```sh
gh variable set MINESYNC_UPDATE_PUBKEY < ~/minesync-keys/signing.pub
gh secret set MINESYNC_UPDATE_KEY < ~/minesync-keys/signing.key
```

Keep `signing.key` offline and never commit it. Installed apps accept
updates only from the key they were built with: if you change the key, every
user must install the next version by hand.

## Steps

1. **Version.** Set the new version in `VERSION` and in every copy that
   `tools/check_version.sh` checks (the version constants of hub, CLI,
   desktop app, web UI and session, client user agents, and the `version:`
   of every workspace `pubspec.yaml`). Run it until it says the version is
   consistent:

   ```sh
   tools/check_version.sh
   ```

   A version with a suffix (`0.2.0-rc.1`) becomes a GitHub prerelease. The
   image is published only as `:<version>`, never `:latest`.
2. **Changelog.** Date the entry in `CHANGELOG.md`.
3. **Checks.** `tools/check.sh` must pass, and the CI of the branch must be
   green.
4. **Tag.** Commit, then tag the commit and push the tag:

   ```sh
   git tag v0.1.0
   git push origin v0.1.0
   ```

   The workflow refuses a tag that is not `v$(cat VERSION)`, and a release
   without the variable or the secret above.

## What the workflow does

| Job | Result |
|---|---|
| `version` | checks the tag against `VERSION` (`tools/check_version.sh --tag`) and the key settings |
| `desktop` | `tools/package/desktop.sh` on Linux x64 and arm64, Windows x64, macOS arm64 and x64: AppImage, setup.exe, dmg, CLI archives and unsigned `update/<platform>/` |
| `hub-cli` | `minesync-hub-<v>-linux-x64` and `-linux-arm64` (Dart AOT, cross-compiled) |
| `sign` | `tools/package/sign.sh` signs every `update/*/manifest.json` and writes `SHA256SUMS` + `SHA256SUMS.sig`; `tools/verify_release.sh` checks them with the public key |
| `image` | `.github/workflows/hub-image.yml`: builds amd64 + arm64 with the signed downloads in `/app/dl`, smoke-tests it, pushes `ghcr.io/<owner>/minesync-hub:<v>` |
| `github-release` | draft release `MineSync <v>` with every file and `minesync-hub-<v>-dl.tar.gz` (the content of `/dl` for hubs without Docker) |

Packaging details (layouts, minimum OS, unsigned apps) are in
[tools/package/README.md](../tools/package/README.md).

## Before publishing the draft

- Download the release assets into an empty folder and extract
  `minesync-hub-<v>-dl.tar.gz` into the same folder (it brings `update/`).
  Then check checksums and signatures with the public key only (needs
  OpenSSL 3):

  ```sh
  tools/verify_release.sh <folder> "$(cat ~/minesync-keys/signing.pub)" \
    linux-x64 linux-arm64 windows-x64 macos-arm64 macos-x64
  ```

- Pull the image and smoke-test it: `deploy/smoke-test.sh
  ghcr.io/<owner>/minesync-hub:<v>`. The first time, make the ghcr.io package
  public (or give your NAS credentials to pull it).
- Install the packages on a test PC per system, and upgrade a test hub: an
  app of the previous version connected to it should offer the update.

Then publish the draft on GitHub. Hub owners move to the new hub by changing the image version in their
compose file; their apps then update from the hub.

## Dry run

Run **Actions → Release → Run workflow** (`workflow_dispatch`) on any branch.
A push to `main` that touches `release.yml`, `hub-image.yml`,
`tools/package/` or `deploy/` does the same. A dry run executes every job with
a throwaway key generated in the run (its private half lives only in a
one-day artifact), builds and smoke-tests the image without pushing it, and
creates no GitHub release. The signed result is the `release` artifact of the
run.
