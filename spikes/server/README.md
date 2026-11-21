# Spike: MineSync hub as a Dart AOT server in Docker

Throwaway prototype (Phase 0 of 0.1.0). It checks whether the hub can be a
`dart compile exe` binary in a small multi-arch image on a NAS. The prototype
does push begin, then streaming PUT of a blob, then commit. It also serves
streaming GET with Range, SSE with keepalive, and an authoritative A/SRV DNS on
UDP. RSS has to stay bounded throughout. The Go 3.x code
(`server/internal/{api,store,mcdns}`) was used only as the behaviour spec.

## What is here

| path | what |
|---|---|
| `bin/hub.dart` | entrypoint (env config, `hub healthcheck` subcommand for distroless) |
| `lib/api.dart` | HTTP on **dart:io** (no shelf), SSE, upload concurrency gate, SO_RCVBUF |
| `lib/store.dart` | content-addressed blobs, temp file, fsync, rename, dir fsync, temp sweep at start |
| `lib/hasher.dart` | SHA-256 worker pool (package:crypto, or OpenSSL via FFI, or none), native-memory slots |
| `lib/fsync.dart` | directory fsync via FFI (`open(O_RDONLY)`, `fsync`, `close` from libc) |
| `lib/dns.dart` | RawDatagramSocket DNS: A, SRV + glue, NXDOMAIN+SOA, REFUSED, TTL 5 |
| `deploy/Dockerfile` | multi-stage: `dart:3.13.4` cross-compiles, then `distroless/cc-debian12:nonroot` |
| `tool/bench.dart` | load client (latency, SSE, abort, Range, commit) |
| `tool/probe.dart` | I/O primitive probes |
| `run.sh` | builds both images, runs every test, exits 0 only if all criteria pass |

Dependencies: `crypto` 3.0.8 and `ffi` 2.2.0 (both BSD-3, dart.dev). In the
image there are glibc, libgcc and OpenSSL 3 (Apache-2.0) from distroless.

## How to run

```
./run.sh                 # ~12 min, needs ~17 GiB free in .tmp/
THROUGHPUT_MODE=dart ./run.sh   # judge the 200 MB/s criterion with package:crypto
```

The hub runs in `docker run --cpus=2 --memory=1g` (a simulated NAS) with the
data dir bind-mounted on the host NVMe. The clients (curl, `bench`) run on the
host. Results go to `.tmp/results.txt`.

## Design decisions (measured, see "iterations")

- **dart:io instead of shelf.** We need direct control of the request stream
  (backpressure), `bufferOutput=false` for SSE, the response stream for Range,
  and the accepted sockets (`HttpServer.listenOn` with a wrapper that sets
  SO_RCVBUF). Shelf adds a layer and no capability that we need here.
- **fsync.** `RandomAccessFile.flush()` *is* fsync(2). Evidence from the probe:
  `Dirty` in /proc/meminfo went from 601 MiB to 60 MiB during a 104 ms
  `flush()` of 512 MiB. It runs on the VM I/O pool and does not block the
  event loop. **Directory fsync has no dart:io API.** `File(dir).open()` fails
  with EISDIR. So it goes through FFI to libc, run in `Isolate.run` because
  the call blocks. We deliberately do not use `O_DIRECTORY`: its value differs
  between x86_64 (0x10000) and arm64 (0x4000).
- **Hashing never runs on the event loop.** A fixed pool of workers
  (effective cgroup CPUs − 1, at least 1). Blocks travel through native
  `malloc` slots (8 × 256 KiB per upload), so there are zero copies and zero
  garbage on the hash side. The disk write and the hash of each block run in
  parallel.
- **Heap cap `DART_VM_OPTIONS=--old_gen_heap_size=128`** (in the Dockerfile) and
  **`HUB_MAX_UPLOADS=4`**. These two keep RSS under 150 MB. See the findings
  for why they are needed.

## Results (measured on this host)

Host: CachyOS x64, 16 cores, NVMe, Docker 29.1. Hub limits: `--cpus=2 --memory=1g`.
Clients are on localhost (worst case: the sender is effectively infinitely fast).

| test | result |
|---|---|
| image size | amd64 **48.5 MB**, arm64 **58.9 MB** (distroless/cc + 7.5 MB binary), user 65532, HEALTHCHECK via `hub healthcheck` |
| arm64 image | builds (cross-compiled, final stage has no RUN). **Startup NOT verified**: no qemu/binfmt on this host |
| 4 GiB upload, hash=none | 488 MiB/s, RSS peak 62 MB |
| 4 GiB upload, hash=openssl | **437 MiB/s**, RSS peak 60 MB |
| 4 GiB upload, hash=dart (package:crypto) | **130 MiB/s** (hash-bound: 166 MiB/s/core raw), RSS peak 44 MB |
| 4 GiB upload at 1 GbE rate (`--limit-rate 112M`), dart | 112 MiB/s, RSS peak 48 MB |
| 4 GiB download (+ `sha256sum` on client) | 690 MiB/s – 1.16 GiB/s, hash OK; Range (6 cases incl. suffix and 416) OK |
| 16 × 256 MiB concurrent, dart | 160 MiB/s aggregate (hash-bound), 16/16 OK, RSS peak **156 MiB in the first run (FAIL), 149 MB in the repeat**; 139 MB in two separate runs |
| small GET latency | idle p50 0.26 ms / p99 0.42 ms; **during 16 uploads p50 0.34 ms / p99 4.7 ms** (max 90 ms) |
| 200 SSE clients, 60 s | 200/200 open, 400/400 keepalives, 200/200 commit events, RSS 8 → 12 MB, CPU 10–20 ms total |
| client drops mid-upload | temp file removed, no blob, hub alive |
| `kill -9` × 5 at different points (`docker kill -s KILL`) | 0 corrupt blobs (all files re-hashed), leftover temps removed at start, blobs accumulate 0 → 16. Note: this is a process kill, not a power cut; power-loss durability relies on the fsync sequence and was not tested |
| DNS (`dig`) | A, SRV + glue A, TTL 5, NXDOMAIN + SOA, REFUSED off-zone, NOERROR empty for space without host |
| DNS :53 in container | binds as **non-root with CapEff = 0** on the bridge network (Docker sets `ip_unprivileged_port_start=0` per netns), published on host port 15353 |
| DNS with `--network host` | non-root: EACCES. A file capability (`setcap`) did not survive the classic builder's `COPY --from` (measured), and distroless has no RUN. What works: `--user 0 --cap-drop ALL --cap-add NET_BIND_SERVICE --cap-add DAC_OVERRIDE` |

## Findings (iterations)

1. **First version** used one hasher isolate per upload, passing data with
   TransferableTypedData. With 16 uploads RSS reached 777 MiB and the
   container hit OOM (15/16 uploads failed). GET p99 was 465 ms, because 16
   hashing threads drained the CFS quota of `--cpus=2`. This was fixed with
   the pool (CPUs − 1) and native slots: p99 went to 5 ms.
2. **Even without hashing, RSS peaked at 170–230 MB** at 500+ MiB/s. Root
   cause is in the SDK: `_NativeSocket.read()` with no count
   (`sdk/lib/_internal/vm/bin/socket_patch.dart`) loops until it has more than
   4 MiB and then copies the result with `BytesBuilder.toBytes()`. The
   HttpServer body therefore arrives in chunks of up to ~6 MiB. Those chunks
   are allocated straight into old space, and only mark-sweep frees them. The
   peak follows the ingress rate. We tried GC flags (new-gen size,
   `concurrent_mark=false`, growth ratios), malloc arenas and SO_RCVBUF. None
   of them helped, because SO_RCVBUF does not bound the loop on a fast
   sender. **The only effective lever is `--old_gen_heap_size`**: with 48 MB,
   a single upload peaks at 55 MB.
3. **The heap cap has a failure mode.** Every connection whose headers have
   been parsed holds its first chunk (~4–6 MiB), even while queued behind
   `HUB_MAX_UPLOADS`. With 16 parallel uploads, a 64 or 96 MB cap gave
   "Exhausted heap space" on 2–5 connections. Those were dropped
   (curl 000). The process survived, but those uploads failed. With 128 MB
   and 4 active uploads: 16/16 succeeded, RSS 139 MB. The same happens with
   16 clients at `curl --limit-rate 7M` (~1 GbE aggregate; curl still sends
   in bursts). Cap 96 with 4 active uploads gave 16/16 and RSS 130–133 MB.
   Cap 96 with the gate removed (16 active) gave 4–6 OOM drops and RSS up to
   153 MB. So RSS ≈ heap cap + 10–40 MB, and the gate is required. A single
   upload at 1 GbE stays around 45 MB.

## Conclusion

PARTIAL. The last `run.sh` exits 1 on a single check: RSS during 16 uploads was 156 MiB against the 150 MB limit (a second measurement got 149 MB). Atomic and durable storage, kill -9 safety, Range, SSE (200
clients for ~4 MB and almost no CPU), DNS, image size, non-root and multi-arch
build all pass. Throughput is disk-bound (≥ 425 MiB/s) only with a native
hash. package:crypto caps it at ~130–170 MiB/s. RSS stays under 150 MB only
with the heap cap plus the upload gate, and the margin is thin in the
localhost worst case. Recommendation for Phase 1: dart:io + distroless is
viable. Use a native SHA-256 (see the hash spike). Keep the pool and slots
design. Either replace the upload-body read path with a RawSocket reader that
uses `read(n)` (bounded chunks, which removes the heap-cap dependency), or ship
the heap cap with an explicit limit on concurrent uploading connections.
Verify arm64 startup in CI (`docker/setup-qemu-action`, or an
`ubuntu-24.04-arm` runner).
