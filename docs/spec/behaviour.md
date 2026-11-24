# MineSync — behaviour specification

The observable behaviour of MineSync (hub, sync engine, Minecraft session, apps), stated as testable rules. This is a specification of *what must happen*, not of how it is implemented.

## How to use

Each rule `B-<AREA>-<nn>` states one observable behaviour (inputs → expected outcome) and is covered by at least one test. The tag says which part of the system it belongs to:

- `[core]` — sync engine and hub core;
- `[session]` — Minecraft session: server run, console, autosave, Java;
- `[ui]` — client user interface and user-facing text;
- `[hub-extra]` — Telegram, DNS, world metadata, statistics.

Concrete values (TTLs, limits, error codes) are part of the rule unless a rule says otherwise; error *codes* are contracts, error *texts* are examples. Identifiers, names, addresses and chat ids are generic placeholders (`alice`, `bob`, `<space>`, `<zone>`, `<chat>`). Tests cite the rule id in their name or description; when a rule is deliberately changed, edit it here first. The **Additional rules** section at the end (`G-<nn>`) lists further behaviours on crash safety, verification, defaults and timings; they are tested in the same way.

## Summary

| Area | Rules | core | session | ui | hub-extra |
|---|---:|---:|---:|---:|---:|
| STORE | 14 | 14 | · | · | · |
| GEN | 15 | 15 | · | · | · |
| LOCK | 15 | 15 | · | · | · |
| PUSH | 23 | 23 | · | · | · |
| PULL | 13 | 13 | · | · | · |
| SCAN | 8 | 8 | · | · | · |
| RET | 3 | 3 | · | · | · |
| GUARD | 11 | 11 | · | · | · |
| ATOMIC | 3 | 3 | · | · | · |
| PATH | 6 | 6 | · | · | · |
| EXCL | 8 | 8 | · | · | · |
| GC | 8 | 8 | · | · | · |
| SPACE | 3 | 3 | · | · | · |
| AUTH | 12 | 12 | · | · | · |
| EVENTS | 3 | 2 | · | · | 1 |
| DNS | 7 | · | · | · | 7 |
| TG | 29 | · | · | · | 29 |
| META | 5 | · | · | · | 5 |
| DL | 3 | 2 | · | 1 | · |
| UPDATE | 8 | 7 | · | 1 | · |
| SESSION | 29 | · | 29 | · | · |
| I18N | 6 | 5 | · | 1 | · |
| UI | 15 | · | · | 15 | · |
| **Total** | **247** | **158** | **29** | **18** | **42** |

## STORE — content-addressed blobs and chunking

- **B-STORE-01** `[core]` — A blob uploaded under a declared SHA-256 that does not match its content is rejected (bad request) and nothing is left on disk under that hash.
- **B-STORE-02** `[core]` — A gzip-compressed upload is verified against the hash of the *decompressed* content; reads return the decompressed bytes transparently; a raw read reports that the stored blob is compressed.
- **B-STORE-03** `[core]` — A compressed upload whose decompressed content does not match the declared hash is rejected and no compressed file remains on disk.
- **B-STORE-04** `[core]` — Identical content is stored once: a push begin whose manifest only references blobs the hub already holds reports zero missing blobs.
- **B-STORE-05** `[core]` — A file may be described as an ordered list of chunks (`{hash,size}` each); the hub asks for each chunk as a separate blob, never for the whole-file blob, and reading the file reassembles bytes whose SHA-256 equals the declared whole-file hash.
- **B-STORE-06** `[core]` — A manifest entry whose chunk sizes do not sum to the declared file size is rejected at push begin.
- **B-STORE-07** `[core]` — Chunking is content-defined and deterministic: on a 9 MiB random file it yields at least 3 chunks, every chunk is at most `chunkMax` (2 MiB), every non-final chunk is at least `chunkMin` (256 KiB), the chunks cover the file exactly, each chunk hash is the SHA-256 of its byte range, and the same content always gives the same chunks.
- **B-STORE-08** `[core]` — A local edit has a local effect: overwriting a few bytes in the middle of an 8 MiB file reuses most chunks and changes at most 3.
- **B-STORE-09** `[core]` — Small files (around 7 kB, below the chunking threshold) are not chunked.
- **B-STORE-10** `[core]` — Hashing while streaming chunks to a consumer (tee) produces exactly the same whole hash and chunk boundaries as plain chunking, every delivered chunk matches its hash, and the delivered bytes recompose the file.
- **B-STORE-11** `[core]` — Region-file integrity check accepts: a well-formed region, a header-only (empty) region, and a region whose last sector is not padded (normal when chunk writes are not synced).
- **B-STORE-12** `[core]` — Region-file integrity check flags as corrupt: a chunk truncated mid-payload, an offset beyond end of file, overlapping chunks, and a declared length larger than the allocated sectors.
- **B-STORE-13** `[core]` — A sector count of 255 (the Paper/Spigot "see real length in payload" convention) is not treated as corruption even if later chunks fall inside those 255 sectors.
- **B-STORE-14** `[core]` — Region files are recognised by extension `.mca`/`.mcr` (case-insensitive) under `region/`, `entities/`, `poi/`; `server.properties`, `.jar`, `level.dat` are not region files.

## GEN — generations, digest, restore

- **B-GEN-01** `[core]` — The first commit on an empty space creates generation 1; each commit records stats: added / changed / removed relative to the parent (e.g. gen 2 with one file changed, one removed, one new → 1/1/1).
- **B-GEN-02** `[core]` — Historic manifests remain readable by generation number after later commits.
- **B-GEN-03** `[core]` — Push is compare-and-swap on the parent: beginning a push with a parent that is not the current HEAD fails with a conflict.
- **B-GEN-04** `[core]` — Every generation carries `digest` = SHA-256 of a canonical encoding of its file map; it is identical in the commit summary, the stored generation and the history listing, and does not depend on key insertion order.
- **B-GEN-05** `[core]` — The canonical file-map encoding is compact JSON with sorted keys, short field names (`h`, `s`, …) and no HTML escaping (e.g. path `<&>` stays literal). The empty manifest has a fixed 64-hex digest, which is also the digest of generation 0.
- **B-GEN-07** `[core]` — Push begin with `parent=N` and the correct `parentDigest` succeeds; same N with a different digest ("same number, different history") fails with `stale_base` (a conflict); a parent N that does not exist on the hub (hub restored to an older state) also fails with `stale_base`; an empty space accepts `parent=0` with the empty digest.
- **B-GEN-09** `[core]` — Over HTTP: the manifest of generation 0 includes a 64-hex `digest`; the commit summary, `manifest?gen=N` and the generations list report the same digest; a wrong `parentDigest` returns 409 with `code: stale_base` and a non-empty, localised error message naming the generation.
- **B-GEN-10** `[core]` — Restore never rewrites history: restoring generation 1 when HEAD is 2 creates generation 3 marked `restore: 1` whose content equals generation 1.
- **B-GEN-11** `[core]` — A generation can carry a list of files flagged corrupt at push time (e.g. a damaged region file); the commit summary reports them.
- **B-GEN-12** `[core]` — Restore-file with "auto" source (0) brings back only the given file from the most recent earlier generation where it was not flagged corrupt, as a new generation; every other file keeps its HEAD version.
- **B-GEN-13** `[core]` — Restoring a chunked generation works (chunks are blobs like any other).
- **B-GEN-14** `[core]` — Restore and restore-file are refused with a "locked" error while any live lock is held on the space.
- **B-GEN-15** `[core]` — HEAD cannot be deleted. Deleting a non-HEAD generation removes it from the history and removes blobs referenced only by it, keeping blobs still referenced by surviving generations.
- **B-GEN-16** `[core]` — An unreadable or invalid `HEAD` (empty, garbage, NUL bytes, or pointing at a missing generation such as 99) is rebuilt on open from the highest valid generation and rewritten on disk; if the highest generation file is itself unreadable, HEAD falls back to the previous valid one.
- **B-GEN-17** `[core]` — Reading a non-existent generation returns 404 with a localised message (e.g. "generation 99: not found").

## LOCK — TTL, heartbeat, takeover, force

- **B-LOCK-01** `[core]` — Acquiring a free lock returns a lock with a secret session id and no takeover. A second acquirer gets a "locked" error carrying the holder's owner name, with the session id redacted.
- **B-LOCK-02** `[core]` — Heartbeat and release with the wrong session id fail with a conflict while the lock is live; release with the right session clears the lock.
- **B-LOCK-03** `[core]` — A lock whose last heartbeat is older than its TTL is stale: anyone may acquire it, and the acquisition reports the previous holder as taken over.
- **B-LOCK-04** `[core]` — A held lock survives a hub restart (it is persisted). A live lock restarts its TTL; a lock that was already stale before the restart stays stale with its last real heartbeat and is not announced again; a holder that resumed after being stale is live after a restart.
- **B-LOCK-05** `[core]` — The session id is the authority, the name only a label: after the member is renamed, a heartbeat with the right session succeeds and updates the displayed owner; a push begun with the right session but a different author name succeeds and its commit updates the owner label; a wrong session still fails.
- **B-LOCK-06** `[core]` — Lock timestamps are serialised in UTC (`…Z`), both in the store and in the heartbeat HTTP response.
- **B-LOCK-07** `[core]` — Lock expiry is computed on a monotonic clock; if the wall clock goes backwards (last beat "in the future"), hosting statistics never become negative.
- **B-LOCK-08** `[core]` — Values returned by heartbeat/current-lock are copies: mutating them does not change the stored lock info; stats and lock can be read and serialised concurrently with heartbeats.
- **B-LOCK-09** `[core]` — Force-release of a live lock is admin-only (member → 403, admin → 200); releasing a stale lock with force is allowed to any member.
- **B-LOCK-10** `[core]` — A lock snapshot (owner, info, no session) can be read without waiting for the space mutex (e.g. during a long commit or GC); it is cleared on release and rebuilt from disk after restart.
- **B-LOCK-11** `[core]` — A heartbeat on a deleted space fails with `space_gone` (404, non-empty message), distinct from a lost lock.
- **B-LOCK-12** `[core]` — Client keep-alive: a push lasting five times the lock TTL keeps the lock alive through periodic heartbeats; stopping the keeper is idempotent, is not a loss, and no heartbeat is sent afterwards.
- **B-LOCK-13** `[core]` — Client keep-alive: a 409 heartbeat cancels the operation with a "lock lost" error whose message mentions the lock; a 404 cancels it with "space gone"; a 500 / network error is transient and retried; cancellation by the caller (Ctrl+C) is not a lock loss.
- **B-LOCK-14** `[core]` — Client error classification: 409 with code `locked` (or holder info) is a lost lock; 409 `stale_base` or `mass_delete` is not; 500 is not; 404 is "space gone" only with code `space_gone`; 400 is a bad request.
- **B-LOCK-16** `[core]` — A manual (non-session) push keeps the lock alive with heartbeats while uploading slowly and succeeds; if the lock is stolen mid-push the push aborts with "lock lost" and no commit is made.

## PUSH — begin, missing blobs, commit

- **B-PUSH-01** `[core]` — A full push is begin (manifest → `pushId` + `missing[]`) → upload each missing blob → commit (→ new generation).
- **B-PUSH-02** `[core]` — Commit is refused while any referenced blob or chunk is missing.
- **B-PUSH-03** `[core]` — A push needs the lock: begin without a lock, with a missing session, or with another session (even under the holder's name) fails with "locked" (409 over HTTP).
- **B-PUSH-04** `[core]` — A push is bound to the lock session it began with: if that lock expires and someone else takes it, or if it is released, the commit is refused and HEAD does not move.
- **B-PUSH-05** `[core]` — `?nolock=1` (push without a lock) is admin-only: a member gets 403.
- **B-PUSH-06** `[core]` — Commit is idempotent: committing the same `pushId` again returns the same generation (same N, stats, timestamp), flagged as a replay, creates no new generation and publishes no new event. An unknown `pushId` is 404.
- **B-PUSH-07** `[core]` — The commit response does not include the manifest file map.
- **B-PUSH-08** `[core]` — Uploading to an unknown `pushId` is 404; uploading a blob that is not in that push's manifest is rejected.
- **B-PUSH-09** `[core]` — At most `maxPushesPerUser` (4) open push sessions per user; opening more evicts the oldest. Push sessions expire on inactivity, not on age since creation (a session created 3 h ago but used now survives).
- **B-PUSH-10** `[core]` — Push begin accepts a gzip body (`Content-Encoding: gzip`); invalid gzip → 400; a body that decompresses beyond the JSON limit (32 MiB) → 413.
- **B-PUSH-11** `[core]` — The client sends push begin gzip-compressed and includes `parentDigest`.
- **B-PUSH-13** `[core]` — Lost commit response: the client retries the same `pushId`, the hub records exactly one commit, the client reports the generation and its local base advances so the next push is a no-change. The lock session is forwarded with the push.
- **B-PUSH-15** `[core]` — A blob rejected by the hub for a hash mismatch is not retried with the same hash: exactly one PUT, then a "blob rejected" error.
- **B-PUSH-16** `[core]` — After a pull the client stores the generation digest as its base; a push declares it as `parentDigest`; after the push the stored base is the new generation number and digest.
- **B-PUSH-18** `[core]` — Changing only the executable bit makes the manifests differ, so it is pushed (and pulled as a chmod without re-download).
- **B-PUSH-19** `[core]` — An unreadable local file does not abort a push: the push proceeds keeping the hub's version of that file, and a warning names it.
- **B-PUSH-20** `[core]` — Every client request (status, lock, push begin, blob upload and download) carries the `X-MineSync` header.
- **B-PUSH-21** `[core]` — Snapshot/outbox: a snapshot freezes the changed blobs into a local outbox (with a `pending.json`); the upload reads only from the outbox, so files changed after the snapshot do not leak into that generation; after success the outbox is empty, the base advances, and the next push picks up the later changes.
- **B-PUSH-22** `[core]` — If the hub asks for a blob the snapshot assumed it already had (e.g. collected by GC) and the live file has changed since, the snapshot upload is abandoned with a "snapshot stale" error rather than uploading wrong content.
- **B-PUSH-23** `[core]` — Without enough local free space for the outbox (margin 256 MiB) the snapshot fails with a dedicated "outbox no space" error (the session then falls back to a synchronous push).
- **B-PUSH-24** `[core]` — Upload rate limiting respects the configured bandwidth (with an initial burst); a limit of 0 means no limiter.
- **B-PUSH-25** `[core]` — Upload limit resolution: no measurement and no config → unlimited; automatic = 70 % of measured upstream, never below `autoLimitMin` (128 KiB/s); a configured value is KiB/s; −1 = unlimited; env `MINESYNC_UPLOAD_LIMIT` overrides config.
- **B-PUSH-26** `[core]` — A transfer that stops making progress (download or upload) is aborted by an idle watchdog with a "stalled" error within seconds instead of hanging.

## PULL — checkout and local-change protection

- **B-PULL-01** `[core]` — Local changes not yet pushed (e.g. a failed push) block the pull: it fails with a "dirty local" error, non-diverged when the hub HEAD equals the local base, listing changed and removed files; no local file is overwritten.
- **B-PULL-02** `[core]` — Non-diverged dirty local state is resolved by fast-forward: push first (new generation), then pull succeeds and the hub holds the local changes.
- **B-PULL-03** `[core]` — If someone else pushed after our base, the dirty-local error is diverged (base N, hub HEAD M > N) and matches the generic dirty-local error kind.
- **B-PULL-04** `[core]` — Pull with "discard local" overwrites local changes with HEAD, but first copies the local versions into a backup directory `.minesync-backup/…` next to (not inside) the space folder, and reports the backup path.
- **B-PULL-05** `[core]` — Files only missing locally (folder emptied or recreated, a file deleted) are not work at risk: pull re-downloads them. If there is also a modified file, the pull is blocked as dirty (changed 1, removed 1).
- **B-PULL-06** `[core]` — An interrupted pull can be repeated and completes the checkout; afterwards a push is a no-change.
- **B-PULL-07** `[core]` — After an interrupted pull, files edited locally that are neither the base version nor the hub version are backed up before being overwritten by the repeated pull; files at the base or hub version are not backed up.
- **B-PULL-08** `[core]` — A hub generation replaced with different content under the same number (hub restored from a backup) is an unknown base: pull fails as diverged dirty-local, push fails with "stale base", and a hub `409 stale_base` maps to the same client error.
- **B-PULL-09** `[core]` — A manifest from the hub with an unsafe path (`../x`, `a/../../x`, `/etc/x`, `C:/x`, backslash, empty) or a malformed hash (short, uppercase, short chunk hash) is rejected with "bad manifest" by pull and prefetch, and nothing is written inside or outside the space folder.
- **B-PULL-10** `[core]` — Pull does not start when the local disk lacks space for the download ("local disk full"); nothing is written.
- **B-PULL-11** `[core]` — The local hash cache is bound to the folder it was built for: loading it for a different root yields an empty cache; for the same root it returns its entries and base generation.
- **B-PULL-12** `[core]` — Pruning of empty directories after a pull skips excluded directories (some backup mods do not recreate theirs) and prunes empty managed ones.
- **B-PULL-13** `[core]` — A chmod refused by the filesystem (EPERM) is ignored, with a single warning however many times it happens.

## SCAN — local tree scan and hash cache

- **B-SCAN-01** `[core]` — Excluded files are absent from the scanned manifest. A second scan of unchanged files whose mtime is older than the racy window re-hashes nothing and yields identical hashes.
- **B-SCAN-02** `[core]` — A cache entry for a file modified close to the scan time (racy window, e.g. FAT/exFAT 2 s granularity) is marked racy and re-hashed on the next scan; once the file is old it is no longer re-hashed.
- **B-SCAN-03** `[core]` — A file that changes while it is being hashed is re-read; the recorded hash and size are those of a stable read, never a torn one.
- **B-SCAN-04** `[core]` — A symlink to a directory makes the scan fail (ignoring it would delete its subtree on the next push).
- **B-SCAN-05** `[core]` — A symlink to a file is followed and its target content is hashed.
- **B-SCAN-06** `[core]` — A broken symlink is skipped without failing the scan.
- **B-SCAN-07** `[core]` — The scan skips names invalid on Windows and case-insensitive duplicates (keeping the first in sorted order, e.g. `Foo.txt` over `foo.txt`, `World/` over `world/`), keeps going, and emits one warning per category.
- **B-SCAN-08** `[core]` — Quiescence wait: returns true once the folder has been stable for the requested time (a late write extends the wait); a folder that never stops changing makes it return false at the cap.

## RET — automatic retention

- **B-RET-01** `[core]` — Automatic retention never deletes generations younger than 24 h: with `KeepLast=3`, 30 consecutive empty pushes leave all 31 generations and the original world blob intact.
- **B-RET-02** `[core]` — Beyond 24 h retention keeps the last `KeepLast` generations plus the newest generation of each calendar day (local time) for the last 7 days, and drops the rest (e.g. gens at 20 d, 20 d, 3 d, 3 d, 2 d, 1 d, now, now with `KeepLast=2` → keep 4,5,6,7,8).
- **B-RET-03** `[core]` — Retention runs in the background after commits; while it reads manifests, heartbeat, begin and commit are not blocked; when it finishes the old generation is pruned and its orphan blob deleted, other generations are kept.

## GUARD — mass-deletion and wrong-base guards

- **B-GUARD-01** `[core]` — Hub: a push that removes more than half of HEAD's files is refused with a mass-delete conflict reporting removed and total (e.g. 20 of 30). Removing exactly half is allowed.
- **B-GUARD-02** `[core]` — Hub: the mass-delete guard applies only when HEAD has at least 20 files (a 10-file HEAD can be emptied).
- **B-GUARD-03** `[core]` — HTTP: mass delete is 409 `code: mass_delete`; `?allowMassDelete=1` bypasses it for an admin and is 403 for a member.
- **B-GUARD-04** `[core]` — Client: pushing from an empty local folder against a hub with files fails locally with "mass delete" before any push request is sent.
- **B-GUARD-05** `[core]` — Client: pulling an empty hub (generation 0) into a non-empty folder is refused as non-diverged dirty-local (the answer is to push); with "discard local" it is still refused ("empty remote"); no local file is deleted.
- **B-GUARD-06** `[core]` — Client: pulling an empty hub into an empty folder succeeds.
- **B-GUARD-07** `[core]` — Client: push is refused with "stale base" (no request sent) when the local base is older than HEAD (base 30, HEAD 50).
- **B-GUARD-08** `[core]` — Client: after an interrupted first pull, or with the local cache lost while the hub is non-empty, push is refused with "stale base", push begin is never called and HEAD is unchanged.
- **B-GUARD-09** `[core]` — Hub disk guard: minimum free space = max(2 % of the volume, 1 GiB) unless `MINESYNC_MIN_FREE` sets it explicitly; below it lock acquire, push begin, blob upload and restore fail with "disk full". Sizes parse as `5GiB`, `500MB`, `1024`, `1.5 GiB`; a size without a number is an error.
- **B-GUARD-10** `[core]` — HTTP: disk full is 507 `code: disk_full` with a message; repeated refusals emit only one `disk` event (at most one per hour); `/status` exposes `diskFree` and `diskTotal`.
- **B-GUARD-11** `[core]` — Client: a hub `disk_full` error is recognisable and its message tells the user the hub storage is full.

## ATOMIC — atomic writes and crash safety

- **B-ATOMIC-01** `[core]` — An atomic write that fails midway leaves the destination with its old content and leaves no temporary file in the directory.
- **B-ATOMIC-02** `[core]` — Deleting a space while uploads to it are in flight leaves no space directory recreated by those uploads.
- **B-ATOMIC-03** `[core]` — On open the hub skips directories without a space descriptor (orphans are not loaded as spaces) and completes interrupted deletions (`.deleted-*` directories are removed).

## PATH — path validation

- **B-PATH-01** `[core]` — Hub rejects manifest paths that are traversal (`../x`, `a/../b`), absolute (`/x`), contain a backslash, or are empty.
- **B-PATH-02** `[core]` — Hub rejects names invalid on Windows on every OS: characters `: < > " | ? *`, control characters, reserved device names case-insensitively and with any extension in any segment (`con`, `NUL.txt`, `aux.tar.gz`, `COM1`, `lpt9.log`), segments ending in `.` or space. Accepted: `COM0`, `LPT10.txt`, `CONx`, `console.log`, `config/a b.txt`, `.minesync`. The error names the offending path.
- **B-PATH-03** `[core]` — Hub rejects paths that collide case-insensitively (`World/a` and `world/a`), naming the second in sorted order and the one it duplicates.
- **B-PATH-04** `[core]` — HTTP: invalid paths and case collisions are 400 `code: bad_path` with a `path` field that also appears in the error message.
- **B-PATH-05** `[core]` — Client relative-path validator accepts `a`, `a/b.txt`, `.minesync`, `a..b/c` and rejects `""`, `/a`, `../a`, `a/../../b`, `a/./b`, `./a`, `a//b`, `a/`, `C:/x`, `c:x`, `a\b`, NUL bytes.
- **B-PATH-06** `[core]` — Client Windows-name check agrees with the hub: rejects `a?b`, `x/CON`, `con.txt`, `Com1.dat`, `LPT9`, `nul.tar.gz`, trailing `.` or space, `< > " | *`, control chars, reserved names as directory segments (`aux/ok.txt`); accepts `COM10`, `LPT0.txt`, `con-fig.toml`, `console.log`, `a.b.c`.

## EXCL — exclusions

- **B-EXCL-01** `[core]` — `dir/**` excludes everything under `dir` at any depth and the directory itself, but not similarly-prefixed siblings (`logs/**` does not match `logsx/…`).
- **B-EXCL-02** `[core]` — A bare file pattern without `/` (`session.lock`, `*.lock`) matches at any depth; `**/x/**` matches at any depth; `config/*.bak` matches one level only (`config/sub/a.bak` not excluded).
- **B-EXCL-03** `[core]` — Globs work inside any segment: `world_backup*/**` matches `world_backup_2024/…`, `world_backup/…` and the directory `world_backup`, but not `my_world_backup/x`.
- **B-EXCL-04** `[core]` — Lines starting with `#` and blank lines in the exclusion list are ignored.
- **B-EXCL-05** `[core]` — Directory pruning: `MatchDir` is true for directories whose whole subtree is excluded (`logs`, `mods/foo/logs`, `world_backup_2024/region`) and false for `world`, `config`; a file pattern like `*.lock` never prunes a directory.
- **B-EXCL-06** `[core]` — An exact name pattern (`node_modules`, `**/cache`) excludes that name at any depth together with its subtree, and prunes such directories.
- **B-EXCL-07** `[core]` — On Windows matching is case-insensitive and `\` is normalised to `/`; on other systems matching is case-sensitive.
- **B-EXCL-08** `[core]` — A missing (nil) matcher excludes nothing.

## GC — garbage collection

- **B-GC-01** `[core]` — `GC(keep=2)` on 5 generations prunes 3, keeps HEAD and HEAD−1, deletes the 3 blobs only they referenced, and the history lists exactly the 2 survivors.
- **B-GC-02** `[core]` — The sweep deletes orphan blobs in both raw and compressed form.
- **B-GC-03** `[core]` — Chunks referenced by a generation count as referenced and are never swept.
- **B-GC-04** `[core]` — Blobs of an open push (uploaded, or deduplicated against an older generation and therefore not re-uploaded) survive both GC and generation deletion; the push can still commit afterwards.
- **B-GC-05** `[core]` — If any generation is unreadable, GC and delete-generation fail and delete nothing (no blob, no generation).
- **B-GC-06** `[core]` — A commit that reuses an orphan blob while GC is computing candidates keeps that blob; the resulting HEAD has all its blobs; other orphans are still deleted. Heartbeat and lock snapshot are not blocked during the GC's long phases.
- **B-GC-07** `[core]` — A push begun after GC has computed the referenced set (deduplicating against a blob GC considers orphan) can still commit.
- **B-GC-08** `[core]` — HTTP `gc?keep=` rejects non-numeric, zero or negative values with 400; an absent value uses the default.

## SPACE — space lifecycle

- **B-SPACE-01** `[core]` — Deleting a space with a live lock is refused with "locked" (HTTP 409 `code: locked`); once the lock is stale the deletion succeeds.
- **B-SPACE-02** `[core]` — After a space is deleted, its lock snapshot is absent.
- **B-SPACE-03** `[core]` — Generation ZIP export: an intact generation streams as `application/zip`; if any blob is missing the request fails with 409 before any ZIP byte is sent.

## AUTH — membership authentication and request guards

- **B-AUTH-01** `[core]` — Identity resolution: the first lookup with an empty cache waits for the membership fetch; a known address resolves to the member name; admins are matched case-insensitively by name; an unknown address is denied.
- **B-AUTH-02** `[core]` — With a cache that is old but present, lookups answer immediately (never wait for the membership API) while one background refresh runs; concurrent refreshes are coalesced into one fetch.
- **B-AUTH-03** `[core]` — While the membership API is down, known members keep being served from the last good list (even hours later), unknown addresses are denied, a failed refresh does not empty the cache and marks the API as down. Beyond a configured grace period lookups are denied; a grace ≤ 0 means unlimited. A missing resolver authenticates no one.
- **B-AUTH-04** `[core]` — A member removed upstream is denied only after a successful refresh says so; a failed refresh keeps them; a successful refresh clears the "down" state.
- **B-AUTH-05** `[core]` — CSRF guard: state-changing requests without `X-MineSync` → 403 (also blob PUT and settings PUT); with it → allowed; GETs do not need it; `Sec-Fetch-Site: cross-site` → 403, `same-origin` → allowed.
- **B-AUTH-06** `[core]` — DNS-rebinding guard: `Host` must be an IPv4/IPv6 literal (port allowed), `localhost`, `*.localhost`, or a name inside the hub's DNS zone (`<name>.<zone>`); a foreign or empty host is 403 on both the API and `/dl`; a name that merely ends with the zone text without a dot is 403.
- **B-AUTH-07** `[core]` — `MINESYNC_HOSTS` adds allowed host names: comma-separated, trimmed, case-insensitive, port ignored; other names stay 403.
- **B-AUTH-08** `[core]` — Every response, including guard 403s, carries `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY` and a CSP with `frame-ancestors 'none'`.
- **B-AUTH-09** `[core]` — A development identity (`MINESYNC_DEV_USER`) applies only to loopback callers (127.0.0.1, ::1); remote callers get 401.
- **B-AUTH-10** `[core]` — Unauthenticated callers get 401 whose message tells them to join the private network and never mentions passwords or tokens.
- **B-AUTH-11** `[core]` — Admin-only endpoints (settings read/write/test, force-release of a live lock, nolock push, allowMassDelete) return 403 to members.
- **B-AUTH-12** `[core]` — The client ignores the system HTTP proxy when talking to the hub (identity is the source address); `MINESYNC_USE_PROXY=1` re-enables it.
- **B-AUTH-13** `[core]` — Several development identities (`MINESYNC_DEV_USERS=127.0.0.1=alice,127.0.0.2=bob`): the hub listens on every listed loopback address on the `MINESYNC_ADDR` port and the player is chosen by the address the client connected to, only for loopback callers. The hub refuses to start when an entry is not an IPv4 loopback address, when `MINESYNC_ADDR` is not an IPv4 loopback address, on duplicate addresses or names, or together with `MINESYNC_DEV_USER`.

## EVENTS — event log

- **B-EVENTS-01** `[core]` — Events carry a message key and arguments plus a rendered `msg`; the API renders `msg` in the request language (`Accept-Language`, overridable with `?lang=`); events re-read from the on-disk log (numbers decoded from JSON) still render in any language.
- **B-EVENTS-03** `[core]` — Acquiring a lock publishes a lock event naming the member ("<owner> took the lock").
- **B-EVENTS-04** `[hub-extra]` — Changing the Telegram settings publishes a structured `settings` event ("<admin> changed the Telegram settings") that never contains the token.

## DNS — built-in DNS for spaces

- **B-DNS-01** `[hub-extra]` — `A zerotier.<space>.<zone>` with a live host answers NOERROR with one record: the first published host address (the private-network one).
- **B-DNS-02** `[hub-extra]` — Split horizon: when the querier's address equals the host's private-network address, the answer is the host's second (LAN) address; any other querier gets the private-network address.
- **B-DNS-03** `[hub-extra]` — `SRV _minecraft._tcp.zerotier.<space>.<zone>` returns the published port (one answer) plus a glue A record (one additional).
- **B-DNS-04** `[hub-extra]` — Existing space with nobody hosting: NOERROR, no answers, one SOA in AUTHORITY (negative caching). Unknown space: NXDOMAIN with one SOA. Positive answers carry no SOA.
- **B-DNS-05** `[hub-extra]` — Out-of-zone names get REFUSED without SOA; AAAA queries get NOERROR empty.
- **B-DNS-06** `[hub-extra]` — Packets that are responses (QR=1) or have an opcode other than QUERY are dropped without reply.
- **B-DNS-07** `[hub-extra]` — DNS answers follow lock changes immediately (acquire → answer, release → empty, space deleted → NXDOMAIN), reading the lock snapshot rather than the space mutex.

## TG — Telegram notifications and settings

- **B-TG-01** `[hub-extra]` — A play lock produces an "open" message (space, host, DNS name `zerotier.<space>.<zone>`, private-network address); its release produces a "closed" message.
- **B-TG-02** `[hub-extra]` — A lock that goes stale without release produces exactly one "closed — not responding" message.
- **B-TG-03** `[hub-extra]` — On hub restart, locks already held are adopted silently (no re-announcement) but tracked, so their close is still announced.
- **B-TG-04** `[hub-extra]` — The open message: every line starts with an emoji; the host's LAN address is never shown; the default port 25565 is implied, a non-default port is shown as `address:port`; with no published address there is no address line (3 lines).
- **B-TG-05** `[hub-extra]` — `/status` lists open spaces with host, players (`a, b`) and DNS name, and closed spaces as closed.
- **B-TG-06** `[hub-extra]` — Push watchdog: a live session without a push for `pushWarnAfter` (30 min) triggers one warning; the next push re-arms it. With alerts disabled nothing is sent and the session is not marked, so re-enabling alerts sends the warning.
- **B-TG-07** `[hub-extra]` — The bot is active only with enabled + token + chat id.
- **B-TG-08** `[hub-extra]` — Durations render as `""` under a minute, `5m`, `1h 30m`, `3h 0m`.
- **B-TG-09** `[hub-extra]` — A lock with `action=push` (manual push) is never announced as open/closed, even with a host, and `/status` shows the space closed.
- **B-TG-10** `[hub-extra]` — On HTTP 429 the bot waits `retry_after` instead of its default backoff; if `retry_after` exceeds the retry budget it gives up after one attempt and records the error.
- **B-TG-11** `[hub-extra]` — Coalescing: close then reopen by the same owner within the window sends nothing and keeps the original start time; the later real close is announced once. Reopened by a different owner, the close is sent immediately, before the new open.
- **B-TG-12** `[hub-extra]` — A stale lock announced closed that comes back with a heartbeat is re-announced open once, and its release is announced; if it comes back within the coalescing window no message is sent and it stays tracked.
- **B-TG-13** `[hub-extra]` — Sessions of a deleted space are forgotten silently (via the deletion event or the periodic sweep).
- **B-TG-14** `[hub-extra]` — A hub `disk` event is forwarded as an alert with free space and threshold.
- **B-TG-15** `[hub-extra]` — Sessions are tracked while the bot is disabled; re-enabled with another chat, the close goes to the new chat. Open/close flags suppress the respective messages.
- **B-TG-16** `[hub-extra]` — With `/status` disabled the bot does not poll for updates at all; enabled, it answers `/status` (also `/status@<bot-username>`) only in the configured chat; disabled again, polling stops.
- **B-TG-17** `[hub-extra]` — Messages queued before the bot is disabled are dropped; nothing is queued while disabled.
- **B-TG-18** `[hub-extra]` — Test message: a Telegram error is surfaced verbatim and recorded with its time in the bot status; a success clears it and records the send time; a network error never contains the token.
- **B-TG-19** `[hub-extra]` — Per-space topics: a mapped space posts in its thread; an unmapped one posts in the main chat without a thread id; a thread id ≤ 1 is never sent.
- **B-TG-20** `[hub-extra]` — `/status` in a space's topic answers only for that space, in that thread; in the main chat or an unmapped topic it answers for all spaces, in the same thread.
- **B-TG-21** `[hub-extra]` — A deleted topic ("thread not found") makes the announcement fall back to the main chat once, and the bot status names the missing topic until the mapping is changed. A test message to a deleted topic returns a clear error without dirtying the status.
- **B-TG-22** `[hub-extra]` — Bot messages use the configured language (e.g. English "is open", "hosted by", "Server status", "closed").
- **B-TG-23** `[hub-extra]` — Settings file defaults: section absent, disabled, open/close/alerts/status notifications on; an update notifies subscribers; the file is written with mode 0600 and re-reads identically; missing notify flags default to on.
- **B-TG-24** `[hub-extra]` — Validation (bad request, nothing saved, section not created): enabled without token or chat, malformed token, chat id that is not `-100…`, digits, or `@channel`, language not in the supported set.
- **B-TG-26** `[hub-extra]` — Topic parsing: blank → main chat; positive integer → thread; `1` → main chat; `https://t.me/c/<chat>/<thread>[/<msg>]`, `t.me/…`, `telegram.me/…` with query → thread; `https://t.me/<username>/<thread>[/<msg>]` → thread; `0`, negative, decimal, words, other domains, links without thread or with thread 0, values beyond int64 → invalid; a link for a different chat than the configured one → chat-mismatch error naming the link's chat (only when both are comparable).
- **B-TG-27** `[hub-extra]` — The topics map returned by settings is a copy; a rejected update changes nothing, in memory or on disk.
- **B-TG-28** `[hub-extra]` — `GET /settings` never returns the token, only `tokenSet` and `tokenHint` (last 4 chars) plus `state` (`disabled`/`active`); `PUT` is a partial update (empty token = unchanged, absent keys kept); enabling without token/chat is 400 with a localised message; clearing the token of an enabled bot is 400, allowed together with disabling. No response ever contains the token.
- **B-TG-29** `[hub-extra]` — Test endpoint: without any config → 400; with token/chat/lang in the body it tests them without saving; a second test within 3 s → 429; a Telegram failure → 502 with the upstream error text. With `spaceId` it uses that space's saved topic, or a `topic` from the body (not saved); a topic link for another chat → 400; unknown space → 404.
- **B-TG-30** `[hub-extra]` — Topics via `PUT`: accepts numbers and links, drops unknown spaces, replaces the whole map when present and leaves it untouched otherwise; `""` and `1` mean main chat (entry removed); invalid or negative values → 400 naming the space; a link for another chat → 400 naming both chats, but changing chat and link together validates against the new chat; deleted spaces disappear from GET and from the file on next save.

## META — world metadata for the web UI

- **B-META-01** `[hub-extra]` — `level.dat` (gzip NBT) parsing yields name, version name, seed (from `WorldGenSettings.seed`), difficulty, hardcore, DataVersion, in-game day (`Time / 24000`), age in ticks and spawn coordinates.
- **B-META-02** `[hub-extra]` — Forge/NeoForge mod jars (`META-INF/mods.toml`): id, name, version, homepage, authors, license, multi-line description, icon (`logoFile`) extractable as `image/png`.
- **B-META-03** `[hub-extra]` — Fabric mod jars (`fabric.mod.json`): loader `fabric`, authors as strings or objects joined with `, `, `contact.homepage`, icon extractable.
- **B-META-04** `[hub-extra]` — The NBT parser never panics or allocates disproportionately on arbitrary input; a list declaring more elements than the remaining bytes is rejected; the total node count is capped (300 000 single-byte nodes are rejected); a valid level still parses.
- **B-META-05** `[hub-extra]` — Mod homepages keep only `http`/`https` URLs (trimmed); `javascript:` (any case), `data:`, protocol-relative and `ftp:` become empty.
- **B-META-06** `[hub-extra]` — The world chip of a space summary (Minecraft version, loader, mod count) is computed in the background when a new version arrives; until it is ready the summary keeps the chip of the last computed version instead of none.

## DL — client downloads

- **B-DL-01** `[core]` — The download listing (`/api/v1/dl` and the `/dl` page) shows client binaries and hides `SHA256SUMS` and `SHA256SUMS.sig`, which are still served (without an attachment disposition); binaries are served with `Content-Disposition: …filename=minesync…`; downloads do not need the `X-MineSync` header.
- **B-DL-02** `[ui]` — The `/dl` page follows `Accept-Language` (`<html lang>` and texts, including the "no binaries" message).
- **B-DL-03** `[core]` — Release signing tool: key generation refuses to overwrite an existing key; `SHA256SUMS` lists only `minesync-*` files as `<hex>  <name>\n`; the ed25519 signature written to `SHA256SUMS.sig` verifies with the public key.

## UPDATE — self-update and versions

- **B-UPDATE-01** `[core]` — A valid update replaces the binary, keeps the previous one as `.old` until the new version has started, after which cleanup removes it.
- **B-UPDATE-02** `[core]` — Without an embedded public key no signature is required (checksums only).
- **B-UPDATE-03** `[core]` — With an embedded key, a bad or missing signature, a SHA-256 mismatch, a wrong executable format, a too-small binary (< 1 MiB) or a 404 aborts the update with a specific error; the current binary is untouched and no `.new` file is left.
- **B-UPDATE-04** `[core]` — Update only to a strictly newer version: downgrade, same version, a `dev` client or a `dev` hub → "not newer", binary untouched.
- **B-UPDATE-05** `[core]` — If the `.old` path is busy (still running on Windows), the backup gets a unique `.old-<ts>` name and the update succeeds; cleanup removes it later. A running `.old`/`.old-<n>` binary resolves its target by stripping that suffix (but not `.older`).
- **B-UPDATE-06** `[core]` — Executable format check per OS: ELF on Linux, PE (`MZ`) on Windows, Mach-O (`cffaedfe` or fat `cafebabe`) on macOS; any other combination is rejected.
- **B-UPDATE-07** `[core]` — Version comparison is SemVer: optional `v` prefix, numeric parts compared numerically, pre-release lower than release, pre-release identifiers compared numerically/lexically (`rc.2 < rc.10`, `alpha < alpha.1`, numeric < alpha), build metadata ignored; `dev`, `1.2`, leading zeros, trailing `-`, empty → not comparable.
- **B-UPDATE-08** `[ui]` — Version display adds a `v` prefix unless present; `dev` stays `dev`.

## SESSION — Minecraft session

- **B-SESSION-01** `[session]` — At session start, non-diverged local changes (e.g. last final push failed) are pushed before the pull; the hub gets them as a new generation and the local file is kept.
- **B-SESSION-02** `[session]` — At session start, diverged local changes stop the session with the dirty-local error and the hub is untouched; with "discard local" the session backs them up, takes the hub version and continues.
- **B-SESSION-03** `[session]` — Lock stolen during a session → blocking alert and a stop request; 409s after a voluntary release are not a lost lock.
- **B-SESSION-04** `[session]` — Autosave with a slow uplink: `save-on` is sent right after the snapshot (within 3 s of `save-all flush`), not after the upload; no new `save-off` starts during the upload (ticks are skipped); the console stays responsive; the saved event's hub time is the snapshot time; the next cycle starts after the upload; at stop every `save-off` has a matching `save-on`.
- **B-SESSION-05** `[session]` — A manual save requested during an upload is queued ("already saving") and does not overlap; stop during a slow upload cancels it, the final push from the real files reaches the hub, the session closes promptly, and the cancelled autosave is not reported as saved.
- **B-SESSION-06** `[session]` — A server crash during an upload is detected promptly, the state is pushed to the hub post-crash, and the session ends with an error.
- **B-SESSION-07** `[session]` — The snapshot waits for writes after the save confirmation (a mod writing 400 ms later is included).
- **B-SESSION-08** `[session]` — Space deleted on the hub during a session → clean stop with "space gone" (the server receives `stop` exactly once), no endless "hub unreachable".
- **B-SESSION-09** `[session]` — An unreadable file does not fail the autosave: it is skipped with a warning naming it and the hub keeps its previous version.
- **B-SESSION-10** `[session]` — The lock info of a play session has `action: play` plus the published host addresses.
- **B-SESSION-11** `[session]` — Console parsing recognises system join/leave lines across loaders (vanilla, Forge prefix, missing timestamp, Bedrock names starting with `.`) and never treats chat (`<name> …`, `[Not Secure] <name> …`) as join/leave.
- **B-SESSION-12** `[session]` — "Done", "Saving…", "Saved the game" and "Stopping server" are recognised only as system lines, never from chat.
- **B-SESSION-13** `[session]` — Save confirmation is recognised only as the exact body of an INFO line of the server thread, in real formats (vanilla, Forge, NeoForge timestamps, `(Minecraft)`, Paper `[ts INFO]:`, `> ` prompt prefix, "All dimensions are saved", trailing CR).
- **B-SESSION-14** `[session]` — Save confirmation cannot be forged: `/me`, `/say` (vanilla, Forge, Paper), renamed items in death messages, chat-mod separators, `<name>` chat, other threads, WARN level, bare text, extra trailing text are all rejected.
- **B-SESSION-15** `[session]` — A save confirmation counts only while a `save-all flush` is pending, and only once per flush; other facts (stopping) do not depend on it.
- **B-SESSION-16** `[session]` — An over-long console line (> 64 KiB) is truncated and reading continues; the following line is intact.
- **B-SESSION-17** `[session]` — Recognised facts are queued (started, join, saved) even if nobody reads the lines; chat adds nothing; draining empties the queue.
- **B-SESSION-18** `[session]` — Sending a console command to a full queue fails with a timeout error (never drops silently or blocks forever); after process exit it fails with "not running".
- **B-SESSION-19** `[session]` — Commands reach the real process stdin and its stdout lines are delivered; after exit `Running()` is false and sends fail.
- **B-SESSION-20** `[session]` — Cancelling the session sends `stop` on the console and lets the server exit cleanly, instead of killing it (works even if the process ignores SIGTERM).
- **B-SESSION-21** `[session]` — On Windows the client and every process it launches share a kill-on-close job, so the server dies with the client.
- **B-SESSION-22** `[session]` — Server detection on real pack layouts finds a launch command and the Minecraft version: Forge `run.sh` + `unix_args.txt`; NeoForge (`21.1.x` → `1.21.1`); Fabric launcher jar without script; Fabric with intermediary libraries; Forge 1.12.2 `ServerStart.sh`; vanilla/Paper `server.jar` only; a Windows-only `start.bat` on a Linux host; several candidate scripts (prefers `run.sh` over a helper `start.sh`).
- **B-SESSION-23** `[session]` — A pack wrapped in a single sub-folder is detected and that folder becomes the working directory.
- **B-SESSION-24** `[session]` — An empty linked folder is reported as empty (label `?`), not as "script/Java missing"; with a `start.sh` the label is the script.
- **B-SESSION-25** `[session]` — Minecraft version from libraries: Forge `forge/<mc>-<ver>`, NeoForge `20.4.x` → `1.20.4`, Fabric `intermediary/<mc>`; nothing → unknown.
- **B-SESSION-26** `[session]` — Required Java: MC ≤ 1.16.5 → 8; 1.17 … 1.20.4 → 17 (not 16); ≥ 1.20.5 → 21; year-numbered versions (26.1 and later) → 25; unknown → 0.
- **B-SESSION-27** `[session]` — Java version strings parse to a major: `1.8.0_x`→8, `17.0.9`, `21`, `21.0.1+12`, `11.0.20.1`, early access `24-ea`, `25-ea+3`, `1.8.0-ea`, `17-internal`; garbage → 0.
- **B-SESSION-28** `[session]` — A Java runtime inside the synced folder (chosen manually or bundled in the pack) is never executed before Play: it is reported found but unverified.
- **B-SESSION-29** `[session]` — Java preview picks the detected runtime matching the required major (17 for 1.20.1 even if 21 is listed first). Path containment check works on cleaned paths (`dir+"x"` is not inside `dir`).
- **B-SESSION-30** `[session]` — When a save or its upload fails because the hub is unreachable, the session probes the hub every few seconds without touching the server and, as soon as it answers, uploads the pending snapshot (or takes a new one) instead of waiting for the next autosave.

## I18N — localisation

- **B-I18N-01** `[core]` — API errors follow `Accept-Language`, else the hub default; locked errors keep structured fields (`holder`) with a translated message; guard errors are translated too.
- **B-I18N-02** `[core]` — Language parsing accepts `it`, `it_IT.UTF-8`, `it-IT`, `IT`, `it_CH@euro`, `en…` and lists (first supported wins, `q=0` excluded); `C`, `POSIX`, `C.UTF-8`, unsupported languages → no match.
- **B-I18N-03** `[core]` — Language resolution order: `MINESYNC_LANG` > configured language > system locale > English fallback.
- **B-I18N-04** `[core]` — Wrapped errors keep their identity (`is`) and render fully in either language; plain errors are returned as-is; sentinel errors translate lazily at render time.
- **B-I18N-05** `[core]` — The client sends `Accept-Language` with the current language on every request and shows the hub's (already localised) error messages verbatim; network errors are localised ("hub unreachable: …").
- **B-I18N-08** `[ui]` — CLI usage and errors exist in both languages (e.g. `usage: minesync link <space> <dir>`).

## UI — user interface

- **B-UI-01** `[ui]` — Every screen, in both languages, at the supported window sizes, renders without overflow.
- **B-UI-02** `[ui]` — In English no Italian word leaks into any screen, label or hint.
- **B-UI-03** `[ui]` — The language can be switched from the settings; the choice is saved in the client configuration and applies immediately.
- **B-UI-04** `[ui]` — The session view shows when the hub last received the state ("never" before the first save), and during a background upload its progress instead.
- **B-UI-05** `[ui]` — Serious conditions (lock lost, space gone, hub disk full) show an alert in the session view; an ordinary warning does not.
- **B-UI-06** `[ui]` — The home screen warns when the hub is nearly out of disk (free space below 5 % of the volume or below twice the hub's minimum free space); no warning when the hub does not report disk data.
- **B-UI-07** `[ui]` — A diverged dirty-local refusal shows the changed/removed counts and offers to download the hub version anyway ("discard local", with a backup of the local files); a non-diverged one offers to upload the local changes instead.
- **B-UI-08** `[ui]` — Force-release is offered only to admins, or to anyone when the lock is stale; a non-admin finding a busy lock at Play is told who is playing.
- **B-UI-09** `[ui]` — Cancelling or dismissing a destructive confirmation never runs the action.
- **B-UI-10** `[ui]` — Java status on the server screen comes from a cache (rendering never runs Java); it warns only if the runtime is older than required, and says an unverified bundled runtime is checked at Play. Java resolution requests are de-duplicated; an explicit detection refreshes the list and clears the cache.
- **B-UI-11** `[ui]` — After the pull the session reports actual Java, script and port, and the panels update instead of staying on "missing".
- **B-UI-12** `[ui]` — Console view: the buffer is capped; filters show all lines, warnings and errors, or errors only; search is case-insensitive and applies to new lines; log level classification (ERROR or exception → error, WARN → warning, else normal).
- **B-UI-13** `[ui]` — The activity feed strips the stats tail from push events and badges unlock events as "stop".
- **B-UI-14** `[ui]` — The "server struggling" indicator turns off once lag warnings leave the time window.
- **B-UI-15** `[ui]` — The hub connection status is decided by reachability alone; a failed identity lookup is retried, and a result from a superseded connection is ignored.

## Additional rules

Further behaviours on crash safety, verification, defaults and timings, numbered `G-<nn>`. Data-safety items first.

### Data safety

- **G-01** `[core]` — **Crash-safe writes on the hub.** Every hub write is temp file → fsync → rename → fsync of the directory, so a power cut leaves the old or the new file, never an empty or partial one.
- **G-02** `[core]` — **Client verifies every downloaded byte.** Pull verifies each chunk and each whole file against SHA-256 before it lands and writes through a temp file; a hub serving wrong bytes for a hash fails the pull and leaves the existing local file untouched.
- **G-03** `[core]` — **Corrupt local blob cache.** A cached blob that fails verification is deleted and fetched again from local files or the network.
- **G-04** `[core]` — **Chunk reuse from local files is verified.** Pull rebuilds files from chunks found in other local files; each reused range is re-verified, so a local file changed meanwhile cannot inject wrong data.
- **G-05** `[core]` — **Authorisation of destructive hub endpoints.** Create/delete space, edit exclusions/profile, delete generation, restore, restore-file and GC are admin-only: a member gets 403, and DELETE/PATCH also need the `X-MineSync` header.
- **G-06** `[core]` — **Forwarded headers are never trusted.** Identity comes only from the TCP source address; `X-Forwarded-For` and similar headers must not change who the caller is.
- **G-07** `[core]` — **Default exclusions of the Minecraft profile.** The hub defaults (logs, crash reports, `session.lock` and `*.lock`, loader caches, backup-mod folders such as `backups/**`, `world_backup*/**`, …) hold as a set. In particular `session.lock` must never be synced.
- **G-08** `[core]` — **Lock TTL and heartbeat.** The lock TTL is 90 s and the client heartbeat every 20 s; both are returned with the grant.
- **G-09** `[core]` — **Idempotency window of commits.** Committed pushes stay replayable for 3 h; open push sessions expire after 1 h idle. A retry after the window must never create a second generation from a stale push.
- **G-10** `[core]` — **Hash parameter of blob endpoints.** `GET …/blobs/{hash}` and `PUT …/push/{id}/blobs/{hash}` must accept only 64 lowercase hex characters; anything else (traversal, uppercase, short) is 400 and never touches the filesystem.
- **G-11** `[core]` — **Pull retries.** Transfers run in parallel with retries and backoff; a transient download error is retried and then succeeds, a persistent one fails the pull without leaving partial files.
- **G-12** `[core]` — **ZIP export content.** The export contains exactly the generation's files with correct content and exec bits.
- **G-13** `[core]` — **Client configuration writes.** The client configuration (`config.json`: hub address, space → folder links) is written atomically so a crash cannot lose the links.
- **G-14** `[core]` — **Self-update rollback.** The previous binary is kept until the new one has started; if the new binary fails to start, the old one must still be usable.

### Session

- **G-15** `[session]` — **Server stopped when the client exits for any reason** (normal quit, Ctrl+C, window closed, crash): a clean `stop` first, kill only after the shutdown timeouts.
- **G-16** `[session]` — **Crash auto-restart.** After a crash the server is restarted up to 2 times, but never after an intentional stop, a lost lock or a deleted space.
- **G-17** `[session]` — **Auto-stop when empty.** A server with no players for 30 minutes stops cleanly and pushes.
- **G-18** `[session]` — **Save confirmation timeout.** If no save confirmation arrives within `flushWait` (60 s, re-armed on progress lines) the autosave must not snapshot a half-written world and `save-on` must still be sent.
- **G-19** `[session]` — **Default autosave interval** of 5 minutes.

### Hub extras and other

- **G-20** `[core]` — **Live event stream** (`GET /events/stream`, SSE): delivery order, reconnection, no buffering timeout.
- **G-21** `[hub-extra]` — **Hosting and play-time statistics**: the accounting of sessions and play time is correct and never negative.
- **G-22** `[core]` — **Space id derivation** from the display name (e.g. `World A` becomes id `world-a`), including collisions and names that would be invalid paths.
