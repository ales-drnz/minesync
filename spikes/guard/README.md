# Spike: `guard` — no orphaned Minecraft server

**Question.** Dart's `Process.start` has no pre-exec hook (no Go-style `Pdeathsig`/`Setpgid`).
Can a small Dart AOT `guard` process, launched by the app with piped stdio, make sure the
Minecraft server is stopped **cleanly** (`stop` on the console, then a tree kill after a grace
period), and **never left orphaned**, however the app dies?

## Design

```
app ──pipes(JSON lines)──▶ guard ──pipes──▶ sh/cmd ──▶ java (──▶ grandchildren)
```

* `bin/guard.dart` is the guard. It starts the server as its own child and forwards the console
  as JSON lines (`{"t":"o"|"e","l":...}`, plus `started`/`state`/`diag`/`exit`). App → guard:
  `{"t":"cmd","l":...}`, `{"t":"stop"}`, `{"t":"kill"}`.
* Triggers for a clean stop: **EOF on the guard's stdin**, **a dead parent** (`getppid()` poll
  on POSIX; `OpenProcess` + `WaitForSingleObject(h,0)` on Windows, with `--parent-pid`),
  **Linux `PR_SET_PDEATHSIG(SIGUSR2)` set by the guard on itself** (a spurious signal is
  ignored when `getppid()` has not changed), and SIGTERM. SIGHUP is ignored.
* Containment: on **Linux**, its own process group (`setpgid(0,0)` on itself, which the server
  inherits) plus `PR_SET_CHILD_SUBREAPER`, so grandchildren that leave the group
  (`setsid`/daemonize) are re-parented to the guard. On **macOS**, a process group only. On
  **Windows**, a `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` job that the guard joins *before*
  spawning, so its children inherit it.
* "Server finished" means the direct child exited, its pipes closed **and** the tree is empty
  (from `/proc` or `ps`, or the job's PID list). That covers `sh` dying while java keeps saving.
* The guard never crashes on EPIPE. Once the app is gone, its output goes to `--log`.
* FFI is written by hand with `dart:ffi` plus `package:ffi` 2.2.0 (BSD-3). There are no other
  dependencies.
* Test doubles: `bin/fake_server.dart` mimics the vanilla console. It ignores stdin EOF,
  answers `stop` or SIGTERM by printing "Saving..." and exiting after 2 s (it writes
  `<state>/saved`), spawns a grandchild, and does `burst N R` with sequence numbers and
  timestamps. `bin/fake_app.dart` stands in for the app. `bin/scenarios.dart` is the driver,
  which kills things and checks for orphans by PID files plus a `ps`/CIM scan of every process
  whose command line contains the scenario directory.

## Run

```
./run.sh                 # Linux / macOS  (exit 0 only if all gating scenarios pass)
pwsh -File run.ps1       # Windows
./run.sh --only kill9-app,burst-5000-lines-per-s
```
Results are written to `.tmp/work/results-<os>.json`. A proposed CI job is in `ci/guard-spike.yml`
(ubuntu, windows and macos runners).

## Results (measured)

Machine: Linux x64, CachyOS kernel 7.3.4, 16 cores, Dart 3.13.4 AOT. Scripts use `sh` without
`exec`, so the server's parent is `sh`, as with the java started by a modpack's `start.sh`.
`treeGoneMs` is the time from the action until every process is gone; it includes the fake's
2 s save.

| scenario | result |
|---|---|
| normal stop, app exits without stop, app closes the guard's stdin, SIGTERM to the app | clean, 0 orphans, ~2040 ms |
| `kill -9` app (all triggers on) | clean, 0 orphans, 2043 ms; PDEATHSIG is the first to fire |
| `kill -9` app, stdin EOF only / getppid poll (250 ms) only / PDEATHSIG only | clean, 0 orphans; 2098 / 2298 / 2041 ms |
| `kill -9` app during a 5000 lines/s burst | clean, 0 orphans (the guard survives EPIPE) |
| server ignores `stop`, grandchild left via setsid, grace 3 s | killed, 0 orphans, 3061 ms (the subreaper catches the escapee) |
| burst 50,000 lines at 5000/s | **0 lost**, 0 duplicates, latency p50 0.1 ms / p99 1.0 ms / max 2.1 ms |
| burst 500,000 lines at full speed (info) | 0 lost; ~500k lines/s; latency p50 30 ms / max 68 ms |
| `kill -9` guard, app alive, app fallback (SIGTERM to the guard's pgid) | clean (JVM-style SIGTERM save), 0 orphans |
| `kill -9` guard, no fallback (info) | **orphans: 3** (sh, server, grandchild) |
| `kill -9` app and guard together (info) | **orphans: 3** |
| same, with `setpriv --pdeathsig TERM` wrapper and an `exec` script (info) | clean, 0 orphans |
| same, with the wrapper and an `sh` script without exec (info) | **orphans: 2**: only `sh` gets the signal |
| idle 20 s with both PDEATHSIGs armed | no spurious signal |

The key Linux scenarios (kill9-app, stdin-EOF-only, during-burst, hang/grace, guard+fallback)
were repeated 10× in a row and all passed, leaving 0 stray processes.

**Not verified (no hardware):** Windows (Job Object, `taskkill /F`, `taskkill /F /T`, the
parent-handle poll) and macOS. `run.ps1` and `run.sh` cover these in CI. The fake mimics
vanilla's behaviour; no real Minecraft server or JVM was used.

## Conclusion

**PASS on Linux**: no orphan in any app-kill scenario, a clean stop on `kill -9` of the app,
and zero lines lost at 5000 lines/s. The residual hole is **the guard itself dying with nobody
alive to notice**. Mitigations:

1. The app's fallback (measured): it kills the guard's pgid, which outlives its leader.
2. On Windows, the Job Object kills the tree; this is a hard kill, not clean.
3. On Linux, the optional `setpriv --pdeathsig` protects only the direct child, so it only works
   if the launch script `exec`s java.

On a real desktop, a simultaneous kill of app and guard mostly comes from session or cgroup
teardown, which kills the server too.
