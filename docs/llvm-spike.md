# Spike: MoonBit's LLVM backend for mbui (2026-10-19)

`moon build --target llvm` ("experimental, only supported on nightly") against what we use, `--target native`
(moonc writes C, cc compiles it). Branch `llvm-spike`; not for main. Everything here is reproducible with
`scripts/llvm-spike.sh` (see its header).

## Toolchains and machine

| | moon | moonc | where |
|---|---|---|---|
| stable (ours) | 0.1.20261012 (748b63c) | v0.10.15+943464bfa | Studio's `work/tools/moon`, copied bit for bit to Mini1 |
| nightly | 0.1.20261016 (40f18d2) | v0.10.15+ae6e546fb-nightly, links `libLLVM.dylib` **18.1.8** | `work/lv-nightly/moon` on Studio and Mini1 (own MOON_HOME) |

Three configurations, so the toolchain's version and the backend are told apart:

- **s**: stable, `--target native` (what main does)
- **nn**: nightly, `--target native`
- **nl**: nightly, `--target llvm`
- **sp**: stable, `--target native` with fast-release's split C (`scripts/mbc.py` as moon's `cc`, `MBC_GROUP=package
  MBC_LTO=thin`, as `scripts/mac.sh` on fast-release 018083f builds; added at the coordinator's request)
- **nlto** (bench only, an experiment): nl's program as LLVM bitcode, linked with ThinLTO together with the runtime's
  C compiled to bitcode (see "Runtime" for why)

**Machine.** MBA was offline the whole time. Studio was the fallback but was at load 15–70 on 12 cores (an emulator at
400 %, other agents' builds): its compile times swung 2–5× from run to run (a stable clean build took 50 s, then
216 s) and were useless for comparing. All the numbers below are from **Mini1** (Apple M4, 10 cores, 16 GB, macOS
26.5, Xcode's clang 21), whose load stayed at 2.4–5 during the runs (it is also a CI runner; the debug rounds 2–3 met
one of its jobs, load 13, which is marked). Every configuration ran on it in the same session, interleaved round by
round in a rotating order. The Studio runs are kept in the appendix for their shape only.

## 1. Does it build? What had to change

Yes, mbui builds and links with `--target llvm` with **one kind of change**: the files kept to the native target
(`targets: { "host_native.mbt": [ "native" ] … }`) are not compiled for `llvm`, so every `[ "native" ]` became
`[ "or", "native", "llvm" ]` (src/host, core, stillfail, coredemo, bench, photos `moon.pkg`). The stable toolchain
accepts that form (its builds are unchanged). Nothing else:

- `native-stub` (our `.m`/`.c` hosts), `stub-cc-flags`, `cc-link-flags` (frameworks, the shell's `.a`): moon reads
  `link.native` for the llvm target too and compiles/links them the same way.
- C stubs and `moonbit.h`: unchanged; the LLVM object calls the same runtime ABI.

Script plumbing (not needed by the build itself): `scripts/env.sh` takes `MBUI_MOON_HOME` (another moon install
first on PATH), `MBUI_TARGET` (native|llvm) and `MBUI_TARGET_DIR`; `mac.sh`, `shots.sh`, `win.sh` and `e2e/run.sh`
follow them. Defaults are what they were.

## 2. Compile time (Mini1, src/stillfail; median of 3 rounds, seconds)

Steps: **clean** (empty build dir), **sfapp-line** (one string in `src/sfapp/strings.mbt` changed), **ui-fn** (a
`pub fn` added to `src/ui/app.mbt`: the interface changes, every dependent package rebuilds), **nothing**.
Columns from `moon build --trace` (n2.task spans, summed per kind; packages and stubs run in parallel, so only wall is
the critical path): build-package = `moonc build-package`, link-core = `moonc link-core` (C generation for native;
**LLVM's optimisation and code generation for llvm**), cc-stub = our `.m`/`.c` stubs and the runtime, make-exe = the
final `cc` (native: compiles the 32 MB generated C *and* links; llvm: links only; sp: split + parallel compile +
ThinLTO link).

### release (what scripts/mac.sh builds)

| step | cfg | wall | build-package | link-core | cc-stub | make-exe |
|---|---|---|---|---|---|---|
| clean | s | 20.2 | 1.25 | 0.99 | 6.8 | 17.6 |
| clean | nn | 20.2 | 1.15 | 0.92 | 5.8 | 17.8 |
| clean | nl | **18.0** | 1.14 | **16.5** | 6.0 | 0.14 |
| clean | sp | **11.3** | 1.00 | 0.90 | 6.4 | 8.4 |
| sfapp-line | s | 18.6 | 0.38 | 0.89 | – | 17.2 |
| sfapp-line | nn | 19.1 | 0.38 | 0.91 | – | 17.7 |
| sfapp-line | nl | **16.9** | 0.38 | **16.3** | – | 0.14 |
| sfapp-line | sp | **11.7** | 0.61 | 1.03 | 8.1¹ | 9.3 |
| ui-fn | s | 19.0 | 0.73 | 0.89 | – | 17.3 |
| ui-fn | nn | 19.6 | 0.78 | 0.90 | – | 17.9 |
| ui-fn | nl | **17.0** | 0.72 | **16.1** | – | 0.13 |
| ui-fn | sp | **12.2** | 1.11 | 0.99 | 8.2¹ | 9.4 |
| nothing | s / nn / nl | 0.05 | | | | |
| nothing | sp | **4.8**¹ | – | – | 7.7¹ | 3.5 |

sp's make-exe, from mbc's own log: split 0.6–0.8 s, 12 units on 10 jobs 4.6–6.0 s (the critical path is `init.c`,
moonbit_init at -O0; the others 1.1–1.7 s), ThinLTO link 3.0–3.4 s. Every incremental step recompiled all 12 units
("12 of 12 compiled (0 up to date)").

¹ **Found on the way (fast-release):** `scripts/mac.sh` regenerates the `cc` shim (`mbc.py shim` rewrites
`out/mbc/bin/cc`) on every build, so moon sees a new compiler each time and reruns all 14 C stubs and the final
link even when nothing changed: a no-op build takes 4.4–4.9 s instead of 0.05 s, and every incremental build carries
the stubs again. Writing the shim only when its contents change should fix it.

**Debug** (`moon build` without `--release`; s/nn/nl only, sp does not apply: there is no C):

| step | s | nn | nl |
|---|---|---|---|
| clean | 3.2 (round 1) / 8.0 (median, load 7–13) | 3.3 | 6.4 |
| sfapp-line | 2.2 / 4.3 | 2.2 | 5.6 |
| ui-fn | 2.3 / 2.5 | 2.6 | 5.4 (round 1) / 15.9 (median, load 10–13) |
| nothing | 0.05 | 0.05 | 0.11 |

In debug, s and nn spend ~1.6 s in link-core (moonc's own machine backend writing the object) and nl ~4.7 s
(LLVM at -O0). Round 1 (load 3.6–4.3) is the clean comparison; rounds 2–3 met a CI job on Mini1.

**What this says.** The LLVM backend's codegen (link-core, single-threaded inside moonc) costs about what clang -O2
on the generated C costs (16.3 s vs 17.3 s): release builds are ~2 s (11 %) faster, not more, and every change,
however small, pays the whole program's codegen again (there is no per-package object; link-core is whole-program).
The split C build is faster than both (11–12 s) because it uses the cores. In debug the LLVM backend is ~2.5× slower
than what we have.

## 3. Output

| | s | nn | nl | sp |
|---|---|---|---|---|
| stillfail.exe (release, with the shell) | 24 803 792 | 23 775 040 | 24 450 928 | 25 100 656 |
| its __TEXT | 17 334 272 | 17 088 512 | 16 875 520 | 17 793 024 |
| stillfail.exe (debug) | 26 784 256 | 26 784 096 | 25 865 648 | – |
| demo.exe, Windows (CI, MSVC) | – | 980 992 | 947 200 | – |
| libmbui.so, Android demo (NDK, unstripped) | 844 184 (C, stable, scripts/android.sh) | – | 934 704 | – |
| iOS-simulator demo binary | | | 1 059 376 | |

The LLVM objects carry DWARF even in release (`file`: "with debug_info"); on macOS it stays in the `.o`, on Android
the APK packaging strips it.

**The mac app starts and draws the same pixels.** On Mini1, `scripts/llvm-spike.sh app-shots mac home chat composer`
ran `scripts/shots.sh` for both s and nl: all 16 pages (the demo; sffix's Home, its sheet, swipe and dark; the chat,
scrolled up, loading, glass, dark, solid; the composer's five states) are **0 px** apart between s and nl. Against
goldens/ both give the same small differences (0–0.14 %, Mini1's macOS 26.5 against goldens made on Studio's
macOS 27), so they come from the machine, not the backend. still.fail itself (src/stillfail, the JavaScriptCore core
in it) started from each build, signed out with no reachable cloud (MBUI_CLOUD on a closed port), drew its sign-in
page at frame 120 and exited 0; the two screenshots are **0 px** apart. The e2e flows (01-signin, 03-send-text) were
not run: they need the local backend stack, which was not cheap on a Studio at load 40.

## 4. Runtime (Mini1, src/bench release, 5 runs per configuration interleaved, each run best of 3 × 300 frames; median, ms per frame)

| scene | metric | s | nn | nl | sp | nlto |
|---|---|---|---|---|---|---|
| boxes | frame | 0.061 | 0.063 | 0.101 | 0.065 | 0.111 |
| | cpu | 0.118 | 0.121 | 0.159 | 0.124 | 0.180 |
| | build / layout / paint | .030 / .018 / .013 | .031 / .019 / .013 | .057 / .031 / .014 | .033 / .019 / .013 | .059 / .030 / .013 |
| text | frame | 0.225 | 0.237 | 0.350 | 0.212 | 0.345 |
| | cpu | 0.301 | 0.321 | 0.433 | 0.294 | 0.428 |
| | build / layout / paint | .024 / .172 / .029 | .024 / .185 / .029 | .030 / .289 / .030 | .024 / .160 / .028 | .030 / .286 / .036 |
| scroll | frame | 0.281 | 0.291 | 0.420 | 0.281 | 0.414 |
| | cpu | 0.335 | 0.344 | 0.475 | 0.338 | 0.470 |
| | build / layout / paint | .153 / .110 / .019 | .151 / .122 / .018 | .194 / .206 / .021 | .151 / .113 / .019 | .189 / .206 / .019 |
| list | frame | 0.037 | 0.039 | 0.054 | 0.036 | 0.053 |
| | cpu | 0.092 | 0.092 | 0.108 | 0.091 | 0.107 |
| dashboard | frame | 0.029 | 0.031 | 0.049 | 0.029 | 0.048 |
| | cpu | 0.081 | 0.084 | 0.103 | 0.082 | 0.103 |

Load during the bench 3.6–4.5 (bench_quiet: all processes 19 % CPU before it). A first 3-configuration run an hour
earlier gave the same picture (nl 0.102 / 0.359 / 0.420 / 0.053 / 0.047).

**The LLVM backend's code is 1.5–1.7× slower per frame** (layout 1.7–1.9×, build 1.25–1.9×; paint and GPU equal).
The toolchain version is not it: nn is within 0–8 % of s. nlto shows it is not the runtime calls either: the LLVM
object calls `moonbit_incref`/`moonbit_decref`/`moonbit_malloc` & co. out of line (`nm -u` lists them; the C backend
gets them inline from `moonbit.h`), but linking it with the runtime under ThinLTO (so they can be inlined) gains
nothing measurable. The difference is in the code moonc's LLVM IR makes (release passes no `-llvm-opt`; the default's object is within 16 bytes of `-llvm-opt 2`'s, so it is likely 2; 3
made a 1 % bigger object and was not benchmarked). sp is as fast as s.

## 5. Cross targets

`moonc link-core` takes `-llvm-target TRIPLE` (`-llvm-opt 0|1|2|3|s|z`, `-emit-llvm-ir`, `-S`). moon itself only
passes `-llvm-target x86_64-pc-windows-msvc` on Windows; for anything else `scripts/llvm-spike.sh cross PKG TRIPLE
OUT` runs moon's own link-core command again with the triple. The `.core` files are target-independent (built once on
macOS); only link-core knows the target, and our host/stub files are separate, so it is the same program the C
backend would generate.

| target | object | linked | ran |
|---|---|---|---|
| arm64-apple-macosx (default) | Mach-O arm64 | yes (moon) | **yes**: bench, 16 mac pages and still.fail 0 px from s |
| x86_64-pc-windows-msvc | COFF x86-64 | yes, by moon on the CI runner (`.github/workflows/llvm-spike.yml`) | **yes**: demo's scripted shot **0 px** from goldens/windows.png, same as nn's C build |
| aarch64-pc-windows-msvc | an object of 1.7 MB was written (not inspected further: macOS `file` does not name COFF) | not tried (no arm64 Windows runner here) | – |
| aarch64-unknown-linux-android29 | ELF AArch64, PIC-compatible relocs (GOT, PREL) | **yes**: `libmbui.so` with the NDK's clang, the runtime and android_host.c, `-Wl,--no-undefined` | **not run** (see below) |
| x86_64-linux-android29 | ELF x86-64 | not tried | – |
| arm64-apple-ios17.0 / -simulator | Mach-O arm64, LC_BUILD_VERSION platform 7 (simulator), minos 17.0 | **yes**: the demo app with ios_app.m & co. as scripts/ios.sh links it, signed ad hoc | **not run** (see below) |
| x86_64-apple-macosx | Mach-O x86-64 | not tried | – |
| wasm32-unknown-unknown | wasm module | not tried | – |

**Device runs.** Not done, and not claimed. Android: the APK with the llvm `libmbui.so` was never packed (the
re-pack ran Gradle without ANDROID_HOME; fixed in the script, not re-run); an earlier attempt found port 5600 taken by
another agent's emulator, used it and stopped it (`emu kill`) before the script checked whose it was. The script now
refuses a taken port, checks the AVD's name and defaults to 5606. iOS: the simulator (lv-iphone, iOS 26.4) never
finished `simctl bootstatus` in 18 minutes on Studio at load 35–42; the app was built, not installed. Both
simulator and AVD were deleted. The coordinator asked to stop there.

Two ways in for Android: the object straight from moonc, or LLVM bitcode (`-emit-llvm-ir`, LLVM 18) compiled by the
NDK's clang 19 (`BITCODE=1`; it reads it, with a warning about debug info). Both link. `main` is renamed to
`mbui_main` with `llvm-objcopy --redefine-sym` (the C path uses `-Dmain=mbui_main`). Windows on CI: the LLVM build
of the demo took 20.8 s against 59.9 s for nightly's C through cl /O2 (a clean build, one run, windows-latest).

## 6. Debug builds: what `--target native` debug does today

It does **not** go through C or tcc. `moon build --target native` without `--release` on macOS AArch64 runs
`moonc link-core … -target aarch64-apple-darwin -O0 -g -o …/__moonbit_link_core__/stillfail.o`: moonc's own machine
backend ("direct object native output") writes the object itself; then `/usr/bin/cc` links and `dsymutil` runs
(dry-run of both toolchains, `s-native-debug-dry.log`). Release instead runs `link-core -target native -o
stillfail.c` and `cc -O2 … stillfail.c`. The stable moonc does not link LLVM (`otool -L`: libSystem only) and has
its own Mach-O/ELF/COFF writers (strings: "Mach-O frame relocation cannot be emitted in ELF", "COFF relocation
refers to unknown symbol"); its `-target` lists `aarch64-apple-darwin`, `aarch64-unknown-linux-gnu`,
`x86_64-unknown-linux-gnu`, `x86_64-pc-windows-msvc`. moon's docs (moonbitlang/moon `docs/manual/src/native.md`):
debug builds on macOS AArch64, Linux x86_64 and Windows x86_64 use "the new native backend by default, with moonc
emitting object files directly"; `MOONBIT_NEW_NATIVE=0` goes back to C; release builds and packages with
`link.native.cc-flags` always use C. tcc (`bin/internal/tcc`, `libtcc1.a`) is still shipped; in moon it is only a
C-compiler kind (`TccAr`, "Use tcc without set MOONBIT_NATIVE_NO_SYS_HEADER") that none of our builds pick: every
stub and link command is `/usr/bin/cc`.

So the fast edit-compile loop exists already (debug, 2–3 s for stillfail on Mini1), and the LLVM backend's -O0 is
slower than it (5–6 s).

## Risks

- Experimental and nightly-only; the nightly also changes moon/moonc themselves (here 4 days newer than ours).
- 1.5–1.7× slower frames today, the opposite of what we would switch for.
- Every change re-runs whole-program LLVM codegen (16 s), single-threaded; no incremental or parallel codegen.
- moonc carries a 100 MB libLLVM 18; the NDK is on 19, Xcode on 21 (bitcode only goes forward).
- Cross targets need moon's link-core command run by hand (`-llvm-target` is not exposed by moon except on Windows).
- `[ "or", "native", "llvm" ]` in moon.pkg is harmless for the stable toolchain, but is a second target to keep.

## Recommendation

**Not yet.** Keep `--target native` everywhere. The LLVM backend works further than expected (macOS, Windows x86_64
with a 0 px screenshot, Android and iOS-simulator objects that link with the platforms' own tools), but its code is
1.5–1.7× slower and its release builds are only ~11 % faster on macOS (fast-release's split C is 40 % faster and as
fast at runtime). The one place it wins clearly is **Windows release builds** (21 s vs 60 s through cl /O2), which
fast-release's split also addresses. Worth re-measuring when the backend leaves nightly or when moonc's LLVM output
catches up (this spike's script does it in one command: `scripts/llvm-spike.sh compile 3 && scripts/llvm-spike.sh
bench 5 && scripts/llvm-spike.sh report`).

## Reusing this

- `scripts/llvm-spike.sh install` puts the nightly in `NIGHTLY` (default `../lv-nightly/moon`; the official script
  is not used because it edits the shell's rc files). It was removed from Studio and Mini1 after this spike.
- `CFGS="s nn nl sp" FR=<fast-release checkout> scripts/llvm-spike.sh compile 3`, `… bench 5`, `… report`.
- `scripts/llvm-spike.sh cross PKG TRIPLE OUT.o [moonc args]`, `android`, `android-run` (own AVD lv-avd on
  EMU_PORT, default 5606; it stops if the port is taken), `ios-sim` (`RUN=1`: own simulator lv-iphone, deleted after),
  `app-shots mac home chat composer`.
- Any script with another toolchain/backend: `MBUI_MOON_HOME=… MBUI_TARGET=llvm MBUI_TARGET_DIR=_build-nl
  scripts/shots.sh home`.

## Appendix: Studio (M2 Max, 12 cores), load 15–70

Release, src/stillfail, median of 3–4 rounds (wall s): clean s 66 / nn 51 / nl 64; sfapp-line s 39 / nn 74 / nl 53;
ui-fn s 49 / nn 100 / nl 53. Debug (2 rounds): clean 6.4 / 4.7 / 13.0; sfapp-line 3.9 / 4.2 / 9.8; ui-fn 4.5 / 4.6 /
11.1. One stable clean build in the same session took 216 s. Same shape as Mini1 (LLVM codegen ≈ clang on the C;
debug LLVM 2.5× slower), but the absolute numbers mean nothing.
