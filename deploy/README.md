# Hub image and NAS setup

The MineSync hub runs as one container, `ghcr.io/<owner>/minesync-hub`
(linux/amd64 and linux/arm64). It holds:

| Path | What |
|---|---|
| `/app/hub` | the hub (Dart AOT) |
| `/app/web` | the web UI build (`MINESYNC_WEB`) |
| `/app/dl` | desktop downloads, `SHA256SUMS(.sig)` and `update/` for self-update (`MINESYNC_DL`) |
| `/data` | volume: worlds, history, settings (`MINESYNC_DATA`) |

The base is `gcr.io/distroless/cc-debian12:nonroot`: no shell, user
65532:65532. The image's health check runs `/app/hub healthcheck` (an HTTP
request to `/` on `MINESYNC_ADDR`; it asks no identity and writes no log).
This page covers the setup and the image only; the full guide is
[docs/guide/hub.md](../docs/guide/hub.md).

## Setup on a NAS

1. Copy `docker-compose.example.yml` to the NAS as `docker-compose.yml`,
   replace every `<...>` (network id, ZTNET token, admin node id).
2. `docker compose up -d`, then join the hub's ZeroTier node to your network
   and authorise it in ZTNET:

   ```sh
   docker compose exec zerotier zerotier-cli join <network-id>
   docker compose exec zerotier zerotier-cli listnetworks   # shows the hub's ZeroTier IP
   ```

3. From a member device open `http://<hub-zerotier-ip>:8084/`. The web UI
   offers the desktop downloads; the desktop app uses the same address.

Rules that matter:

- `/data` must be on a local disk (ext4, btrfs, …), never SMB/NFS: the hub
  relies on atomic renames and `fsync`.
- The hub shares the ZeroTier container's network namespace
  (`network_mode: service:zerotier`), so it is reachable only through
  ZeroTier. Do not publish 8084 on the LAN.
- Admins are listed in `MINESYNC_ADMINS` (ZTNET names or node ids); roles of
  everyone else are set from the web UI's Admin area.
- `MINESYNC_DEV_USER` and `MINESYNC_DEV_USERS` are for development only
  (they accept requests from loopback); never set them on a real hub.

## Optional DNS (port 53)

With `MINESYNC_DNS_ZONE=internal` the hub answers `zerotier.<space>.internal`
with the ZeroTier IP of whoever hosts that server now. In a container's own
network namespace (the ZeroTier container on a bridge network, Docker 20.10
or newer) ports below 1024 can be opened without root, so port 53 works as
is. If the ZeroTier container runs with `network_mode: host`, the host's
limit applies: either add `sysctls: [net.ipv4.ip_unprivileged_port_start=53]`
to the container that owns the namespace, or run the hub with
`user: "0"`, `cap_drop: [ALL]`, `cap_add: [NET_BIND_SERVICE]`. If port 53
cannot be opened the hub logs it and keeps running. Then, in ZTNET, set the
network DNS to search domain `internal`, server `<hub-zerotier-ip>`.

## Building the image

From the repository root (BuildKit):

```sh
docker build --build-arg VERSION=$(cat VERSION) -t minesync-hub -f deploy/Dockerfile .
docker buildx build --platform linux/amd64,linux/arm64 \
  --build-arg VERSION=$(cat VERSION) -f deploy/Dockerfile .
```

Without buildx (Docker's classic builder) pass the host platform yourself
and no `--platform`:

```sh
DOCKER_BUILDKIT=0 docker build --build-arg BUILDPLATFORM=linux/arm64 \
  --build-arg TARGETARCH=arm64 -t minesync-hub -f deploy/Dockerfile .
```

The build stages run on the build machine's architecture: they fetch
Flutter (pinned to the CI version and checked against its commit), build
the web UI once and cross-compile the hub for each target with
`dart compile exe --target-os linux --target-arch`. The final stage has no
`RUN`, so arm64 images need no emulation. `--build-arg BROTLI=0` skips the
brotli precompression of the web UI (faster builds, gzip only).

`deploy/dl/` becomes `/app/dl`. It is empty in the repository (the image
then shows an empty download page); the release workflow fills it with the
signed desktop downloads and `update/` before building.
`deploy/smoke-test.sh <image>` starts an image with a temporary `/data` and
checks the API, the web UI, `/b/<buildId>/…`, `/dl` and the health check.

## Releases

- `.github/workflows/hub-image.yml`: every push to `main` and every pull
  request builds both architectures and smoke-tests the amd64 image; nothing
  is published.
- `.github/workflows/release.yml`: on a `v*` tag (which must equal
  `v$(cat VERSION)`), builds and signs the desktop packages, builds the hub
  binaries, publishes `ghcr.io/<owner>/minesync-hub` as `:X.Y.Z`, `:X.Y` and
  `:latest` with the signed downloads in `/dl`, and creates a draft GitHub
  release.
  Run by hand (`workflow_dispatch`) it is a dry run with a throwaway signing
  key: CI artifacts only.
