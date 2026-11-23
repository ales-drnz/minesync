# Running the hub

The hub is one always-on process that stores every world, its history and
the lock, and serves the web UI and the desktop downloads. It is reachable
only inside your ZeroTier network, and it recognises people by their
ZeroTier membership through [ZTNET](https://ztnet.network): there are no
accounts or passwords.

What you need:

- a machine that is always on (a NAS or a small home server), Linux on
  amd64 or arm64, with Docker and Compose;
- a ZeroTier network managed by ZTNET (the Compose example can run ZTNET
  too) and a ZTNET API token;
- a **local** disk for `/data` (ext4, btrfs, …), never SMB/NFS: the hub
  relies on atomic renames and `fsync`.

## Docker Compose with ZeroTier

The image is `ghcr.io/<owner>/minesync-hub`, for linux/amd64 and
linux/arm64, with three kinds of tag: `:latest` for the newest release,
`:X.Y` to stay on a minor version and get its fixes, `:X.Y.Z` for an exact
release. It runs as user 65532 without a shell, on a read-only root file
system; only `/data` is written.

1. Copy [`deploy/docker-compose.example.yml`](../../deploy/docker-compose.example.yml)
   to the NAS as `docker-compose.yml` and replace every `<...>`:
   `ZTNET_API_TOKEN` (ZTNET → Account → API), `ZTNET_NETWORK_ID`
   (`<network-id>`) and `MINESYNC_ADMINS` (your 10-hex ZeroTier node id).
   If you do not run ZTNET yet, the `ztnet` profile of the same file starts
   it with Postgres (`docker compose --profile ztnet up -d`); follow the ZTNET
   documentation for its first setup.
2. Start it and join the hub to your network:

   ```sh
   docker compose up -d
   docker compose exec zerotier zerotier-cli join <network-id>
   docker compose exec zerotier zerotier-cli listnetworks   # the hub's ZeroTier IP
   ```

3. Authorise the new member in ZTNET (give it a recognisable name, e.g.
   `hub`).
4. From a PC in the network open `http://<hub-ip>:8084/`. If you see the
   overview, you are in; `/dl` offers the desktop downloads.

The `minesync` service uses `network_mode: service:zerotier`: it shares the
ZeroTier container's network namespace, so its ports exist only there.
**Do not publish 8084 on the LAN.** The only published port is ZeroTier's
own `9993/udp`.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `ZTNET_URL` | unset | ZTNET base URL, e.g. `http://ztnet:3000` |
| `ZTNET_API_TOKEN` | unset | ZTNET API token (sent as `x-ztnet-auth`) |
| `ZTNET_NETWORK_ID` | unset | the ZeroTier network whose members may enter |
| `MINESYNC_ADMINS` | empty | comma-separated ZTNET member names or node ids that are always admins |
| `MINESYNC_ADDR` | `:8084` | HTTP listen address (API, web UI, `/dl`): `:port`, `ip:port` or `[ipv6]:port` |
| `MINESYNC_HOSTS` | empty | extra host names accepted in the `Host` header, comma-separated |
| `MINESYNC_DNS_ZONE` | unset | turns on the built-in DNS for `zerotier.<server>.<zone>` |
| `MINESYNC_DNS_ADDR` | `:53` when a zone is set | DNS listen address, or `off` |
| `MINESYNC_MIN_FREE` | unset | free-space floor for uploads (`5GiB`, `500MB`, bytes); overrides Admin › History and disk |
| `MINESYNC_MAX_UPLOADS` | `4` | blob uploads read in parallel (≥ 1) |
| `MINESYNC_RCVBUF` | `1MiB` | socket receive buffer of accepted connections (`0` = kernel default) |
| `MINESYNC_DATA` | `/data` | data folder |
| `MINESYNC_WEB` | `/app/web` in the image | folder of the web UI build; unset = no web UI |
| `MINESYNC_DL` | `/app/dl` in the image | folder of downloads and `update/`; unset = no downloads |
| `TZ` | system (UTC in the image) | time zone of the logs and of the Telegram bot |
| `MINESYNC_DEV_USER` | unset | development only: every loopback request is this user. Never on a real hub |

All ZTNET variables must be set for ZTNET to be used. Without ZTNET (and
without `MINESYNC_DEV_USER`) nobody can enter: the hub logs it at start.
Invalid values stop the hub with exit code 2 and a message. Variables are
read at start and shown read-only in Admin › System; everything else is set
live from the Admin area.

The image also sets `DART_VM_OPTIONS=--old_gen_heap_size=128` (a 128 MB cap
on the Dart old heap, which keeps memory flat during large uploads).

## Volumes and ports

| Where | What |
|---|---|
| `/data` (volume) | worlds, history, settings, events, `telegram.json` (with the bot token, mode 0600) |
| `zerotier` volume | the ZeroTier identity of the hub; keep it, or the hub gets a new node id and IP |
| `8084/tcp` | API, web UI, downloads; in the ZeroTier namespace only |
| `53/udp`, `53/tcp` | optional DNS, only with `MINESYNC_DNS_ZONE` |
| `9993/udp` | ZeroTier peer traffic (published by the zerotier container) |

To use a bind mount instead of the named volume, set
`- /volume1/docker/minesync:/data` and either `chown 65532:65532` the folder
or set `user: "<uid>:<gid>"` on the service to its owner.

## Optional DNS

With `MINESYNC_DNS_ZONE: internal` the hub answers `zerotier.<server>.internal`
with the ZeroTier IP of whoever hosts that server now, plus an SRV record
(`_minecraft._tcp`) with the game port, so friends can save one address in
Minecraft. It is only a lookup: game traffic stays peer to peer. Use a
private name such as `internal`, not `.local` (mDNS).

1. Set `MINESYNC_DNS_ZONE` (and optionally `MINESYNC_DNS_ADDR`, e.g.
   `192.0.2.10:53` to bind the ZeroTier address only).
2. In ZTNET, set the network DNS: search domain `internal`, server
   `<hub-ip>`.

In the ZeroTier container's own namespace (bridge network, Docker 20.10 or
newer) port 53 opens without root. If the ZeroTier container uses
`network_mode: host`, the host's limit applies: add
`sysctls: [net.ipv4.ip_unprivileged_port_start=53]` to the container that
owns the namespace, or run the hub with `user: "0"`, `cap_drop: [ALL]`,
`cap_add: [NET_BIND_SERVICE]`. If port 53 cannot be opened the hub logs it,
shows it in Admin › System and keeps running. Names in the zone are always
accepted as `Host`, also with `MINESYNC_DNS_ADDR: off`.

## Allowed hosts

To block DNS rebinding the hub answers only when the `Host` header is an IP
address, `localhost` (or `*.localhost`), a name in the DNS zone, or a name
listed in `MINESYNC_HOSTS`. If you open the web UI through your own name
(say `minesync.lan`), add it there. State-changing requests also need the
`X-MineSync: 1` header and are refused when the browser marks them
cross-site: the web UI and the apps do this for you.

## Admins and members

Everyone authorised in the ZeroTier network (in ZTNET) is a member. Admins
are:

- the people in `MINESYNC_ADMINS` (bootstrap admins: they cannot be demoted
  from the UI). Node ids are safer than names, since two members may share a
  name;
- members promoted in Admin › Access and members. The hub refuses to remove
  the last admin.

Members can play, see the history and download ZIPs and packs; admins also
create, rename and delete servers, restore versions, force a lock, delete
generations, clean up the disk and change settings. While ZTNET is down,
members already known stay recognised for `members.trustHours` (24 h by
default).

## Upgrading

```sh
docker compose pull
docker compose up -d
```

The container stops cleanly on `SIGTERM` (`stop_grace_period: 30s` in the
example). The desktop apps update themselves from the hub's `/dl`: a few
minutes after the new hub is up (the app checks 30 s after start and every
6 hours) they download the new version, verify its signature and offer a
restart, never while someone hosts. To upgrade the hub, change the
version tag in the compose file (or, on `:X.Y` or `:latest`, run
`docker compose pull`) and run `docker compose up -d`.

## Backup

Everything is in `/data`. Every write is atomic, but for a consistent copy
stop the hub first (nobody can play meanwhile):

```sh
docker compose stop minesync
docker run --rm --volumes-from minesync -v "$PWD":/backup debian:12-slim \
  tar -czf /backup/minesync-data.tar.gz -C /data .
docker compose start minesync
```

With a bind mount, copy the folder with your NAS backup tool while the hub
is stopped. `cache/` can be left out (it is rebuilt); `tmp/` is wiped at
start anyway. To restore, put the files back in an empty `/data` owned by the
hub's user and start it. Also keep the `zerotier` volume, or re-join the
network and tell everyone the new address.

Layout of `/data`: see [protocol.md, "Hub data layout"](../design/protocol.md#hub-data-layout-data).

## Without Docker

Each release ships `minesync-hub-<v>-linux-x64` and
`minesync-hub-<v>-linux-arm64` (Dart AOT, dynamically linked to glibc) and
`minesync-hub-<v>-dl.tar.gz`, the content of `/dl` (desktop downloads,
`update/`, `SHA256SUMS`), and `minesync-hub-<v>-web.tar.gz`, the web UI.
`SHA256SUMS` lists every release asset, so check a partial folder with
`sha256sum --ignore-missing -c SHA256SUMS`. ZeroTier must run on the host and the host must be
a member of the network.

```sh
sudo install -m 755 minesync-hub-0.1.0-linux-x64 /usr/local/bin/minesync-hub
sudo mkdir -p /srv/minesync/data /srv/minesync/dl
sudo tar -xzf minesync-hub-0.1.0-dl.tar.gz -C /srv/minesync/dl

MINESYNC_DATA=/srv/minesync/data \
MINESYNC_DL=/srv/minesync/dl \
MINESYNC_ADDR=192.0.2.10:8084 \
ZTNET_URL=http://127.0.0.1:3000 ZTNET_API_TOKEN=... ZTNET_NETWORK_ID=<network-id> \
MINESYNC_ADMINS=<node-id> \
  minesync-hub
```

Bind `MINESYNC_ADDR` to the ZeroTier address (here `192.0.2.10`) so the hub
is not reachable from the LAN. Run it as an unprivileged user under your
service manager; it stops cleanly on `SIGTERM`. `minesync-hub healthcheck`
exits 0 when the hub at `MINESYNC_ADDR` answers.

For the web UI extract `minesync-hub-<v>-web.tar.gz` into a folder (for
example `/srv/minesync/web`) and set `MINESYNC_WEB` to it. Without it the API
and the apps work, the browser pages do not.

## The Admin area

Open `http://<hub-ip>:8084/admin` as an admin. Every change applies live
(no restart) and is saved automatically; each field shows its default and a
*Restore* button.

| Section | What it controls |
|---|---|
| General | hub name (shown in the apps), language of the bot and of clients without a choice |
| Access and members | ZTNET status and refresh, members, roles; trust window and refresh period |
| History and disk | retention (last 30 generations, all of the last 24 hours, one a day for 7 days), free-space floor (max of 1 GiB and 2 % of the volume by default), cleanup now |
| Game sessions | autosave every 5 minutes, crash restarts (2), stop when empty (30 minutes), port test |
| Protection | mass-delete guard: a push removing more than half of the files is refused when the server has at least 20 files |
| Exclusions | default exclusions of the `minecraft` and `generic` profiles, with a tester |
| Telegram | bot token, chat, language, which notifications, topics per server, test message |
| Statistics | play sessions kept per server (40) |
| System | version, variables set at start, DNS, disk, ZTNET, signed updates |

Each server also has an *Admin* tab (`/server/<id>/admin`) to rename it and
override the session, history and protection values for that server only.
