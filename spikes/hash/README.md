# Spike: fast SHA-256 in Dart (system crypto via FFI + isolate pool)

Throwaway prototype for MineSync 0.1.0. Question: can a Dart AOT sync engine hash
changed files and content-defined chunks (256 KiB / 512 KiB / 2 MiB, see
`client/internal/syncx/chunker.go`) at Go-like speed, without shipping any native library?

## What it is

- `lib/sha256.dart`: API: `sha256File(path)`, `sha256Bytes(bytes)`, `sha256BytesSync`,
  `sha256FileSync(path, offset:, length:)`, incremental `Sha256Hasher`, and `HashPool`
  (N isolates; `file`, `ranges(path, [off,len,...])` for chunk batches, `bytes` via
  `TransferableTypedData`; 2 jobs in flight per worker).
- Native backends through `dart:ffi`, calling the OS crypto library:
  - Linux: OpenSSL `libcrypto` EVP (`libcrypto.so.3`, then `.so.4`, then `.so.1.1`;
    `MINESYNC_LIBCRYPTO` sets the name to try first)
  - macOS: CommonCrypto `CC_SHA256_*` in `libSystem.B.dylib`
  - Windows: CNG `bcrypt.dll` (`BCryptCreateHash` with `BCRYPT_HASH_REUSABLE_FLAG`)
- Fallback: `package:crypto`, used when no native library loads. The fallback and its
  reason are logged. `MINESYNC_HASH_BACKEND=crypto|hashlib` forces a pure backend.
- Zero-copy file path: each context owns a 1 MiB **native** staging buffer. Files are read
  with `readIntoSync` straight into it, then hashed by pointer. `Uint8List.address` cannot be
  used here: it only works with static `@Native` functions, not with symbols looked up at
  runtime. Data already on the Dart heap costs one memcpy (2106 vs 2266 MB/s).
- Gotcha found: an "owner" field that is never read gets removed by AOT. Its finalizer then
  freed the buffer while it was still in use, and the program segfaulted. The buffer is now a
  `sublistView` of the owning external list.

Dependencies (all BSD-3): `crypto`, `ffi`, `hashlib` (benchmark comparison only).

## Run

```
./run.sh                                   # Linux/macOS; exit 0 = all criteria pass
HASH_SPIKE_DATA=/tmp/x HASH_SPIKE_QUICK=1 HASH_SPIKE_DOCKER=1 ./run.sh
pwsh -File run.ps1                         # Windows
```

The run generates about 3.3 GiB of test data: 2000 × 512 KiB, 8 × 256 MiB and 1 × 1 GiB.
CI job: `ci/hash-spike.yml` (ubuntu x64 + arm64, windows-latest, macos-latest), to copy
into `.github/workflows/`.

## Results (measured)

Machine: AMD Ryzen 7 5800X (8C/16T, SHA-NI), CachyOS, Dart 3.13.4 AOT, system OpenSSL
4.1.0 (`libcrypto.so.3` compat). Data on tmpfs (page cache), MB = 10^6 B.
Command: `HASH_SPIKE_DATA=/tmp/claude-1000/hash-spike/data ./run.sh`

| test | MB/s |
|---|---|
| OpenSSL, 1 GiB from Dart heap (NIST "long message", digest verified) | 2106–2117 |
| OpenSSL, 1 GiB from native staging (pure hash) | 2266–2270 |
| OpenSSL, 1 GiB file, 1 MiB reads, main isolate | 1888–1977 |
| package:crypto (fallback) | 179–180 |
| hashlib 2.4.4 (pure Dart, slower than crypto in AOT, not used) | 112 |
| 2000 × 512 KiB, sequential / pool 2 / 4 / 8 / 16 | 1792 / 3491 / 6742 / 12168 / 15964 |
| 8 × 256 MiB, sequential / pool 8 | 1895 / 13397 |
| 256 MiB as 512 KiB ranges (16 per job), pool 8 / 16 | 12477 / 16557 |

For reference, Go `crypto/sha256` runs at 2145 MB/s on the same machine.

Correctness, all PASS:
- FIPS vectors on every backend, plus the NIST 1 GiB message.
- Cross-check of OpenSSL, hashlib and crypto on 14 sizes at block boundaries, with irregular split updates and context reuse.
- Pool output identical to `sha256sum` on 2009 files.
- Pool ranges and bytes identical to direct hashing.

Docker (same AOT binary):
- `debian:stable-slim` (13.7) ships `libcrypto.so.3`, because `coreutils` and `apt` depend on
  `libssl3t64`. Native backend, PASS. Throughput inside the container was 2128 MB/s
  single-thread and 13354 MB/s with pool 16.
- `debian:bookworm` has no libcrypto. The log shows `backend=crypto native=false (...)` and
  correctness still passes.

Not verified locally: Windows CNG, macOS CommonCrypto, linux-arm64. The CI job covers them.

## Conclusion

PASS on Linux: native hashing is 2.1 GB/s single-thread (about Go speed). The pool on small
files is 6.8× at 8 workers and 8.9× at 16. Output is identical to `sha256sum`.

Hub image: base it on `debian:stable-slim` (libcrypto already present) or install
`libssl3t64`. A `FROM scratch` image with the Dart `/runtime/` must also copy
`libcrypto.so.3`, otherwise the hub falls back to package:crypto, which is 12× slower.
