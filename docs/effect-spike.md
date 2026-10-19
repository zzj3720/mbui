# effect.mb: still.fail's core in MoonBit? (spike, 2026-10-19)

Branch `effect-spike`. The question: could still.fail's core (`client/core-ts`, TypeScript on Effect, 133 files, about 42k lines plus 21k lines of tests) be written in MoonBit, with a small MoonBit library, effect.mb, in place of Effect? The point the user put first is **controllability**: the whole program (UI and core) should run deterministically under test, on one clock, replayable by seed.

**Recommendation: go, with conditions** (see the end). The deterministic whole-program test works today. A UI and a backend ran on one virtual clock across 200 seeds; seed 11 found a race injected on purpose; `SEED=11` replays it byte for byte. Everything below was built and run on Studio.

## 1. The heart: one scheduler, one clock, one seed

effect.mb does not use moonbitlang/async's event loop. It has its own scheduler, `Runtime` (`src/effect/runtime.mbt`, about 400 lines of code). It is built on the same language primitives async is built on: `%async.suspend`, `%async.run` and the cancellation intrinsics, bound in `src/effect/prim.mbt`. So the code is ordinary MoonBit `async fn` with `raise`, `defer` and language-level cancellation, while effect.mb decides who runs when.

- **Single-threaded.** A ready queue plus a timer heap. It never runs on its own: whoever owns it says when it runs.
- **Virtual time (tests).** `Runtime::new(seed?, start?)`:
  - `advance(ms)` moves from timer to timer and runs what each instant wakes before the next.
  - `settle()` runs until nothing is left.
  - `run_ready()` runs only what is ready.
  - Nothing waits for real time: a test that sleeps a day of virtual time takes microseconds.
- **Seeded order.** With a seed, the next ready task is drawn from the seed. `rt.rng` is a second stream from the same seed for the sims: jitter, loss, arrival order, user timing. A run is a function of its seed.
- **Seed sweeps and replay.** `for_seeds(count)` runs seeds 1..n, or only `$SEED`. A failure says `seed N: … replay: SEED=N (the same run, step for step)`.
- **Production: the same scheduler on the host's loop.**
  - `Runtime::live(now)` uses the host's clock.
  - The host calls `tick()` from its run loop or frame, and arms a timer for `next_timer()`.
  - `on_wake(f)` tells the host when something became ready outside a turn, e.g. a host callback completed a request through `host_call`.
  - The UI hosts already own the run loop, so the core needs no thread or event loop of its own.
- **One clock with mbui.** The demo's `World::step` advances the core to the frame's time (`rt.advance(16)`), then draws the frame (`Tester::frame(16)`), and checks that the two clocks agree.
  - A tap's handler runs in a frame; what it starts runs at the start of the next step. The sequence "frame, tasks, frame" is fixed.
  - mbui's `Tester` already owns UI time, input and offscreen frames, so the whole program is steppable.
- **All IO through injectable services, each with a sim version** (`src/effect/services.mbt`). These are Effect's `R` as plain structs of functions:
  - `Net`: send, plus recv that waits. `SimNet` has latency, seeded jitter (reordering) and loss, and logs every packet with its time.
  - `Files`: `SimFiles` keeps files in memory, with seeded latency and `fail_writes`.
  - `host_call`: any host operation that answers by callback (fetch, socket, dialog), with cancel on interrupt.
  - The ported `wake.ts` shows the pattern with a `Host` struct, and `waking(inner, wakes)` builds a new host as `{ ..inner, fetch: … }`.

### The demonstration (`src/effectdemo`)

The setup:
- **Screen:** a tiny mbui view with a Send button, a "reply: …" line and a "waiting: n" line.
- **Core:** `Chat`, on effect.mb. It sends `id|text` over the `SimNet`, a correlator fiber matches replies to requests by id, and each send times out after 5 s.
- **Backend:** one fiber per request, taking 5–60 ms (seeded).
- **Network:** 10 ms latency plus 0–40 ms jitter.
- **The person:** taps Send, waits 0–3 frames (seeded), taps Send again.
- **The invariant:** at the end the screen shows the reply to the second message and "waiting: 0".
- **The injected race (`fixed=false`):** a reply is shown when it arrives. A slow reply to message 1 can therefore land after the reply to message 2 and replace it. The fixed app drops replies older than the one shown.

Results (Studio, `scripts/effect-evidence.sh`, tasks `ef-evidence1` and `ef-evidence2`):

```
== demo (screen + core + sim backend), js
race found at seed 11 (after 11 seeds): replay with SEED=11
Total tests: 4, passed: 4, failed: 0.          # the fixed app holds on 200 seeds; whole package 0.49 s
== the buggy app as a seeded test (EF_DEMO_BUG=1)
seed 11: Failure(… the screen ended on a stale reply
replay: SEED=11
== replayed: SEED=11, twice
the seed sweep's failing run and SEED=11: identical output (837 bytes)
replay 1 and replay 2: identical
== a seed that does not fail, replayed: SEED=1 EF_DEMO_BUG=1
Total tests: 4, passed: 4, failed: 0.
```

The failure as CI prints it (excerpt: the first frames trimmed): the core's trace, the network's, then the screen frame by frame, all on the shared clock.

```
1140 shown reply 2
1167 shown reply 1
--
1092 app->server 1|message 1
1111 app->server 2|message 2
1140 server->app 2|MESSAGE 2
1167 server->app 1|MESSAGE 1
--
1128 none yet (2 waiting)
1144 MESSAGE 2 (1 waiting)
1160 MESSAGE 2 (1 waiting)
1176 MESSAGE 1 (0 waiting)
  replay: SEED=11 (the same run, step for step)
```

The test "the injected race is found by some seed, and that seed replays it exactly" also runs the found seed twice in-process. It asserts that the two traces and the two screen dumps (`Tester::dump`) are equal.

## 2. Per-target feasibility

The probe program is two tasks plus a cancel: `a` sleeps 50 ms and answers; `b` would sleep 10 s but is cancelled at 100 ms, and its finalizer must run. effect.mb was probed twice, once on virtual time and once on the real clock driven like a host loop (`tick`, then wait for `next_timer`).

| Target | moonbitlang/async 0.22.5 (2026-10-14) | effect.mb |
|---|---|---|
| macOS native | compiles, runs correctly (`ef-async2`: `a woke, a=1, b finalizer ran, under 1 s: true`) | compiles, runs correctly, virtual and live (`ef-targets1`); 45/45 tests (`ef-evidence1`) |
| JS | compiles, runs correctly (`ef-async2`) | runs correctly (`ef-targets1`); 45/45 tests; demo 4/4 |
| iOS simulator (scripts/ios.sh pattern: moon's C, the runtime, `-DMOONBIT_ALLOCATOR_SYSTEM`) | unpatched: fails. `fs.c` needs `sys/vnode.h` (absent from the iOS SDK) and `thread_pool.c` uses `posix_spawn_file_actions_addchdir_np` (unavailable on iOS). The runtime's env.c also needs `sys/random.h`, which the repo already shims. With a `vnode.h` shim and that one call patched to `ENOSYS`, it builds and runs correctly in the simulator (`ef-async-ios2`) | builds with the repo's existing `ios/shim`, nothing patched; runs correctly in the simulator, virtual and live (`ef-targets1`; 187 KB executable) |
| Android NDK (scripts/android.sh clang, arm64) | compiles and links an arm64 PIE (`ef-async2`); not run (no device or emulator for this spike) | compiles and links an arm64 PIE (162 KB); not run, same reason |
| Windows | not measured (CI runs only on push to main). The source has `iocp.c` and `event_loop_windows.mbt` | not measured. It is plain MoonBit with no C of its own, so it builds wherever mbui's Windows CI builds; no evidence yet |

What async lacks for this design:
- **No virtual clock.** Its timers read `now()` from C (`time/get_ms_since_epoch`).
- **Fixed task order.** The ready queue is FIFO, with nothing to seed it.
- **Wrong owner of the loop.** `external_loop_integration` is a trait (`poll`, `get_wakeup_callback_for_foreign_thread`, `terminate`) through which async drives an external loop. That is the inverse of a UI host that owns the loop and calls the core.

So async cannot be stepped deterministically. effect.mb's own scheduler is the better design here anyway: tests step it, and in production the host's run loop drives it.

effect.mb needs nothing from async. It has no C stubs, so iOS needs no extra patches.

## 3. effect.mb as built (`src/effect`, 1436 lines, about 1000 of code)

Effect → effect.mb:
- **`Effect<A,E>` + `gen`** → `async fn … -> A raise E`, written sequentially.
- **`fail`, `mapError`, `result`, `orElseSucceed`** → `raise`, `catch`, and `try … catch … noraise`. `try?` is deprecated in this toolchain.
- **`Runtime`:**
  - creation: `new(seed?, start?)` (virtual), `live(now)` (host clock);
  - stepping: `advance`, `settle(max_ms?)`, `run_ready`, `tick`, `next_timer`, `idle`;
  - forking and shutdown: `fork(f, name?)` (into the root scope), `scope()`, `root()`, `shutdown()`;
  - host hooks: `on_wake`, `on_defect`;
  - inspection: `now`, `trace`/`trace_text`, `defects`, `rng`, `seed`, `after(ms, f)` (sync code at a time: sims, deliveries).
- **Inside a fiber:** `now()`, `sleep(ms)`, `pause()`, `trace(s)`, `runtime()`, `never()`, `uninterruptible(f)`, `is_interrupted()`.
- **`Scope`** (Scope, addFinalizer, acquireRelease, forkScoped, FiberSet):
  - `fork`, `add_finalizer`, `acquire_release`, `child`, `close`, `close_now`, `running`, `is_closed`;
  - `scoped(body)` (Effect.scoped).
  - Closing interrupts the scope's fibers and waits for them, then runs finalizers last-first, uninterruptibly. A failing finalizer is a defect; the others still run.
- **`Fiber[X]`:** `join` (raises the error, or `Interrupt`), `wait` (returns `Exit`: `Succeeded`, `Failed(Error)` or `Interrupted`), `poll`, `interrupt`, `interrupt_and_wait`, `is_done`, `id`.
- **Combinators:**
  - `race_first` (raceFirst);
  - `race` (first success; `BothFailed(e1, e2)` when both fail);
  - `all` (first failure fails it and interrupts the rest);
  - `timeout(ms, f) -> X?`.
- **Primitives:**
  - `Deferred[X]`: `new`, `succeed`, `fail`, `wait`, `poll`, `is_done`;
  - `Queue[X]`: `unbounded`, `bounded`, `offer` (waits for room), `try_offer`, `take`, `try_take`, `size`, `shutdown`;
  - `Semaphore`: `acquire`, `release`, `try_acquire`, `with_permit`, `available`.
- **Determinism helpers:** `Rng` (xorshift32, the same draws on every backend: a test pins `[791, 314, 751, 389, 144]` for seed 42 on native and JS), `seeds`, `for_seeds`.
- **Services:** `Net`, `Packet`, `SimNet`, `Files`, `SimFiles`, `IoError`, `host_call`.

Tests (`src/effecttest`: 37 tests; `src/effectport`: 8): **45/45 pass on native and on JS.** They cover:
- finalizers in reverse order on success, failure and interruption;
- interruption arriving during a slow finalizer (all finalizers still run);
- a failing finalizer;
- interruption during acquisition (it completes, is released, and the fiber stops right there);
- child scopes;
- forking into a closed scope;
- a fiber closing its own scope;
- join of a value, a failure and an interrupted fiber;
- interruption before a fiber's first run (it never runs, as in Effect);
- race and race_first: the loser's finalizers run, a failure comes first, both fail, the race itself is interrupted;
- all, timeout, Deferred, and a bounded Queue's backpressure and shutdown;
- multi-seed properties: an interrupted taker loses no item (50 seeds); a semaphore never exceeds its permits and releases on failure and interrupt (50 seeds);
- the host-clock path (`live`, `tick`, `on_wake`, a host callback);
- defects;
- SimNet reordering and loss by seed, SimFiles.

## 4. The port: `wake.ts` (`src/effectport`)

Why `wake.ts`:
- It is self-contained (241 lines) and has its own deterministic test file.
- It exercises exactly the hard part: Deferred-based waiting (`Wakes.next`), `raceFirst` with a loser that must be interrupted (`unlessDropped`, `quietEnds`), and a scoped hedge spawning up to three attempts that share one Deferred (`hedged`).
- It uses the clock (`host.nowMs`), and it wraps a host as a service (`WakingHost`), the pattern the whole core uses for IO.
- `mesh.ts` and `station/link.ts` use more primitives but are 2k and 0.5k lines, tied to iroh and the store.

| | TypeScript | MoonBit |
|---|---|---|
| module | wake.ts 241 lines (193 code), plus wake-words.ts 8 | wake.mbt 297 lines (194 code) |
| tests | wake.test.ts 154 lines (131 code), 7 tests, each run once | wake_wbtest.mbt 265 lines (215 code), the same 7 tests by name and check, each over 20 seeds, plus 1 new test over 50 seeds |
| passing | (main) | 8/8 on native and JS |

What got easier:
- **Sequential code.** `Wakes.until` is a `while` loop instead of a recursive `flatMap`, and `hedged` reads top to bottom. `Effect.ensuring` becomes `defer`.
- **Delegation for free.** WakingHost's roughly 70 lines of delegation (20 members forwarded one by one) become `{ ..inner, fetch: …, fetch_stream: … }`.
- **Exact test stepping.** The TS tests `await flush()` Node's event loop to let fibers move and hope that was enough. Here `run_ready()` is exact, the host's answers take seeded latency on the virtual clock, and each test also tries 20 scheduler interleavings.
- **A test TS couldn't write cheaply.** The new test checks, over 50 seeds, that a read hedged through `waking()` takes the first answer to arrive and interrupts the other two attempts, whose `defer`s run.

What got harder, and the semantic gaps:
- **Typed error unions.** A MoonBit function has one error type. effect.mb's combinators raise `Error` (any error), so the port narrows at the boundary (`as_host_error`, 6 lines) to keep `raise HostError` in its signatures. The narrowing turns a foreign error into its text, which is lossy. Effect's `E1 | E2` unions need a sum suberror or plain `Error`. For the core this is workable (core-ts mostly uses one `CoreError`/`HostError` per layer), but it is a real loss of precision.
- **Interruption points.**
  - Effect can interrupt between any two steps; effect.mb interrupts only at suspensions (park, sleep, pause, wait, take) and where an `uninterruptible` region ends.
  - Sync code between suspensions is atomic. That mostly removes races, but a long sync loop cannot be interrupted, and code that relied on Effect stopping it between two `yield*`s needs a `pause()`.
  - An interruption that arrives after a fiber's body ended but during its finalizers does not change its outcome. That is tested and documented.
- **Joining an interrupted fiber** raises an `Interrupt` error in the joiner. Effect would interrupt the joiner.
- **No `Cause` tree.** Concurrent failures are not collected (only `BothFailed` for `race`); a finalizer's failure goes to `on_defect`.
- **Closures and mutable state.** Mutable state shared by closures needs `Ref` (`open`, `sent`, `heard` in the port).
- **Toolchain friction.** `method` is reserved (the field became `verb`); `derive(Show)` and `try?` are deprecated in this toolchain; a non-test file in a test package must be addressed by its package name.

## 5. Risks

- **The intrinsics.**
  - `%async.suspend`, `%async.run`, `%async.raise_cancellation_signal` and `%async.capture_cancellation` are compiler primitives without a stability promise.
  - moonbitlang/async uses the same ones (effect.mb copies its bindings), so a change would hit async too.
  - effect.mb's dependence is 25 lines (`prim.mbt`).
- **Native memory is reference-counted.**
  - Cycles leak (mbui's notes). Long-lived fibers that capture their scope, or a `Chat` that captures itself in its inbox fiber, are cycles.
  - The runtime must break them on scope close and fiber end, by clearing watchers and the task's continuation. This needs a leak audit, e.g. a soak test counting live tasks after `shutdown`. Not done in this spike.
- **iroh and the native pieces via the C ABI.**
  - The TS core reaches iroh through a host interface (`iroh.ts`, the prebuilt `libstillfail_shell`). The MoonBit core would call the same C ABI with callbacks into `host_call` or `Deferred`, with `on_wake` to tick on the host's thread.
  - Callbacks from other threads must be marshalled to the loop thread; the host does that today for JS.
  - Not prototyped here.
- **Libraries the TS core gets from npm.**
  - Crypto (@noble ed25519, P-256, sha2, hmac, hkdf, chacha20; bip39 words) needs C (e.g. monocypher plus a P-256 implementation, or the platform's). Each needs vectors from the TS tests.
  - zstd (fzstd) needs C zstd.
  - SQLite: the hosts already open DBs (`host.openDb`); on native the core could link sqlite.c directly.
  - GFM Markdown: mbui has `src/md`.
  - JSON codecs for all protocol and shape types need `derive(ToJson, FromJson)` or hand-written codecs, instead of TS's structural typing.
- **Web.** The user's decision is that web is developed separately. One core for all clients would mean compiling the MoonBit core with the JS backend for web and desktop. effect.mb and its tests already pass on JS, but the JS bundle's size and speed are unmeasured.
- **Performance.** Scheduler overhead is unmeasured, but cheap in shape: a context switch is a closure call. 200 demo runs, with UI layout every frame, finished well inside 0.5 s.
- **Removing Hermes** (measured on an existing coredemo build on Studio, `ef-apk`, uncompressed arm64):
  - `core.hbc` 3.52 MB, `libhermes.so` 2.14 MB, `libjsi.so` 0.96 MB, `libfbjni.so` 0.18 MB, `libstillfail_hermes.so` (the bridge) 1.64 MB, for **8.4 MB** that a MoonBit core replaces.
  - `libc++_shared.so` (9.24 MB) also goes if nothing else needs it. That is unverified: `libstillfail_shell.so`, 25 MB, stays.
  - A MoonBit core compiled to C would likely add 1–3 MB, inferred from the 160–190 KB probe executables and the 732 KB of C generated for effect.mb plus the probe.
  - Also gone: the JS↔native bridge on every call and subscription, the second GC heap, and Hermes's startup.

## 6. Recommendation and plan

**Go, with conditions.** The design question is answered positively: MoonBit's `async fn` plus `raise` plus effect.mb's scheduler covers what core-ts uses Effect for. It also gives what the TS core can't: the whole program, UI included, steppable on one clock and replayable by seed. Conditions before committing to the full migration:

1. **Spike the native edges first (about 1 week):**
   - iroh over its C ABI driven by `host_call` and `on_wake` on macOS and Android;
   - one crypto primitive and SQLite through C;
   - a leak soak on native;
   - the core built to JS for web (size and speed).
2. **Keep the station ↔ core protocol the only contract.** Core and UI shapes ship together. Run the MoonBit core against the real TS station through `scripts/e2e-local.sh` from the first slice.
3. **Port tests with the code, by name** (as wake.ts was ported from wake.rs and then to MoonBit). The sims come first: `sim-iroh.ts` becomes a `SimNet`-like mesh. Every test runs over seeds.

Rough plan and size. core-ts is about 38k lines in src (top-level modules 19.5k, views 8.1k, station 4.0k, shapes 3.4k, hosts 2.0k, sync 0.8k) plus 21k lines of tests in 76 files:

| Phase | What | Size |
|---|---|---|
| 0 | effect.mb hardening: leak audit, Cause-lite, mbui hosts calling `tick`/`next_timer`/`on_wake` on mac, iOS, Android and Windows, plus the edge spikes above | 1–2 weeks |
| 1 | Foundations: JSON codecs for protocol and shapes, crypto and zstd via C, store/SQLite, the Host service struct, the sim mesh (sim-iroh) | 3–4 weeks |
| 2 | Concurrency core: mesh, station link and requests, wake, sync scheduler, outbox, doing (with their tests over seeds) | 3–4 weeks |
| 3 | Data: store, views, shapes (mostly mechanical transforms) | 3–4 weeks |
| 4 | The rest: accounts, cloud, vault, lock, pair, drive, modules; host integration replacing Hermes and JSC; e2e flows on mac and Android | 3–4 weeks |

Total: about **13–18 person-weeks**, i.e. 3–4 months for one engineer. Agents with review could compress it, the spike's pace being wake.ts plus its tests in roughly an hour once effect.mb existed. The schedule risk is in phases 0–1 (native edges, crypto), not in the async model.

## Reproduce (Studio)

- `bash scripts/effect-test.sh`: check, then effect.mb's tests on native and JS, and the demo on JS (`UPDATE=1` refreshes snapshots).
- `bash scripts/effect-evidence.sh`: the suites, then the injected race as a failing seeded test (`EF_DEMO_BUG=1`), the reported seed replayed twice and compared byte for byte, and a passing seed replayed.
- `bash scripts/effect-targets.sh`: the probe (`src/effectprobe`) on macOS, JS, the iOS simulator (run) and Android (linked).
- Replay any seeded failure: `SEED=<n> moon test --target js -p mbui/effectdemo` (or `-p mbui/effecttest`, native or JS).
- The async probes (`ef-async*`) were run from a scratch module outside the repo; their output is quoted above.
