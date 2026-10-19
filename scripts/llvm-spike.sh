#!/bin/bash
# The LLVM backend spike (docs/llvm-spike.md): mbui built three ways on one machine, at the same time, so the
# toolchain's version and the backend are told apart:
#   s   the stable toolchain (scripts/env.sh), --target native: moonc writes C, cc compiles it
#   nn  the nightly toolchain, --target native
#   nl  the nightly toolchain, --target llvm: moonc's link-core lowers the program through LLVM to an object
# The nightly is its own install in NIGHTLY (default: lv-nightly/moon beside this checkout), never in place of the
# stable one; each configuration builds into its own _build-<cfg>.
#   scripts/llvm-spike.sh install                 the nightly into $NIGHTLY (the steps of the official install script,
#                                                 without its edits to the shell's rc files)
#   scripts/llvm-spike.sh run CFG CMD...          CMD with CFG's toolchain (MBUI_MOON_HOME/MBUI_TARGET/MBUI_TARGET_DIR)
#   scripts/llvm-spike.sh build CFG PKG [debug]   src/PKG built release (or debug) into _build-<cfg>
#   scripts/llvm-spike.sh compile [ROUNDS] [PKG] [debug]
#                                                 compile times, the configurations interleaved round by round: a clean
#                                                 build, one line changed in src/sfapp, a function added to src/ui,
#                                                 nothing changed; per step from moon's trace -> out/lv/compile.jsonl
#   scripts/llvm-spike.sh bench [ROUNDS]          src/bench (release) for each configuration, run interleaved
#                                                 -> out/lv/bench.jsonl (one line per run, with the machine's load)
#   scripts/llvm-spike.sh report                  medians of both, as Markdown tables
#   scripts/llvm-spike.sh android                 the llvm object for aarch64-linux-android linked into libmbui.so
#   scripts/llvm-spike.sh ios-sim                 the llvm object for arm64-apple-ios-simulator linked into the demo app
set -e
D="$(cd "$(dirname "$0")" && pwd)"
cd "$D/.."
ROOT=$PWD
NIGHTLY=${NIGHTLY:-$(cd .. && pwd)/lv-nightly/moon}
CFGS=${CFGS:-s nn nl}
OUT=out/lv
mkdir -p $OUT/logs
now() { python3 -c 'import time;print(time.time())'; }
load() { uptime | sed 's/.*load averages*: //'; }

# CFG's toolchain and target for what follows (in a subshell: the PATH is changed)
use() {
  case $1 in
    s) unset MBUI_MOON_HOME; export MBUI_TARGET=native ;;
    nn) export MBUI_MOON_HOME=$NIGHTLY MBUI_TARGET=native ;;
    nl) export MBUI_MOON_HOME=$NIGHTLY MBUI_TARGET=llvm ;;
    *) echo "unknown configuration $1 (s, nn, nl)" >&2; exit 2 ;;
  esac
  export MBUI_TARGET_DIR=_build-$1
  . "$D/env.sh"
}

install() {
  mkdir -p "$NIGHTLY/lib"
  local tmp; tmp=$(mktemp -d)
  curl -fsSL -o $tmp/moonbit.tar.gz https://cli.moonbitlang.com/binaries/nightly/moonbit-darwin-aarch64.tar.gz
  curl -fsSL -o $tmp/core.tar.gz https://cli.moonbitlang.com/cores/core-nightly.tar.gz
  rm -rf "$NIGHTLY/lib" "$NIGHTLY/include"; mkdir -p "$NIGHTLY/lib"
  tar xf $tmp/moonbit.tar.gz -C "$NIGHTLY"
  ln -sfn moon "$NIGHTLY/bin/moonx"
  chmod +x "$NIGHTLY"/bin/* "$NIGHTLY/bin/internal/tcc" 2>/dev/null || true
  tar xf $tmp/core.tar.gz -C "$NIGHTLY/lib"
  rm -rf $tmp
  export MOON_HOME=$NIGHTLY PATH=$NIGHTLY/bin:$PATH
  moon -C "$NIGHTLY/lib/core" bundle --warn-list -a --all
  moon -C "$NIGHTLY/lib/core" bundle --warn-list -a --target llvm
  moon version --all
}

build() {  # CFG PKG [debug]
  (use $1
   flag=--release; [ "${3:-}" = debug ] && flag=
   moon build $MOON_TARGET_FLAGS $flag src/$2)
}

# the edits the compile steps make, undone at the end however it ends
SF_FILE=src/sfapp/strings.mbt
SF_FROM='"android-chat.archive": "归档",'
SF_TO='"android-chat.archive": "归档 ",'
UI_FILE=src/ui/app.mbt
restore() {
  [ -f $OUT/orig/strings.mbt ] && cp -p $OUT/orig/strings.mbt $SF_FILE
  [ -f $OUT/orig/app.mbt ] && cp -p $OUT/orig/app.mbt $UI_FILE
  return 0
}

timed() {  # CFG STEP ROUND PKG PROFILE: one build with the trace, one line in compile.jsonl
  local cfg=$1 st=$2 r=$3 pkg=$4 prof=$5
  (use $cfg
   flag=--release; [ "$prof" = debug ] && flag=
   rm -f trace.json
   l=$(load)
   t0=$(now)
   moon build $MOON_TARGET_FLAGS $flag src/$pkg --trace >$OUT/logs/$cfg-$prof-$st-$r.log 2>&1 && ok=1 || ok=0
   t1=$(now)
   exe=$MBUI_OUT/$prof/build/$pkg/$pkg.exe
   size=$(stat -f %z $exe 2>/dev/null || echo 0)
   text=$(size $exe 2>/dev/null | awk 'NR==2{print $1}')
   python3 "$D/llvm_trace.py" trace.json cfg=$cfg step=$st round=$r pkg=$pkg profile=$prof ok=$ok \
     wall_s=$(python3 -c "print(round($t1-$t0,3))") exe_bytes=$size text_bytes=${text:-0} "load=$l" >>$OUT/compile.jsonl)
}

compile() {  # [ROUNDS] [PKG] [debug]
  local rounds=${1:-3} pkg=${2:-stillfail} prof=${3:-release}
  mkdir -p $OUT/orig
  cp -p $SF_FILE $OUT/orig/strings.mbt
  cp -p $UI_FILE $OUT/orig/app.mbt
  grep -qF "$SF_FROM" $SF_FILE || { echo "llvm-spike: $SF_FILE has no $SF_FROM" >&2; exit 1; }
  trap restore EXIT
  for r in $(seq 1 $rounds); do
    # each round in another order, so no configuration always comes after the same one
    order=$(echo $CFGS | tr ' ' '\n' | python3 -c "import sys;l=sys.stdin.read().split();k=$r%len(l);print(' '.join(l[k:]+l[:k]))")
    for cfg in $order; do
      restore
      rm -rf _build-$cfg
      timed $cfg clean $r $pkg $prof
      sed -i '' "s|$SF_FROM|$SF_TO|" $SF_FILE
      timed $cfg sfapp-line $r $pkg $prof
      printf '\n///|\npub fn lv_spike_probe(x : Int) -> Int {\n  x * 2 + 1\n}\n' >>$UI_FILE
      timed $cfg ui-fn $r $pkg $prof
      timed $cfg nothing $r $pkg $prof
      echo "round $r $cfg done ($(load))"
    done
  done
  restore
}

bench() {  # [ROUNDS]
  local rounds=${1:-3}
  for cfg in $CFGS; do build $cfg bench >$OUT/logs/bench-build-$cfg.log 2>&1 || { tail -20 $OUT/logs/bench-build-$cfg.log; exit 1; }; done
  for r in $(seq 1 $rounds); do
    order=$(echo $CFGS | tr ' ' '\n' | python3 -c "import sys;l=sys.stdin.read().split();k=$r%len(l);print(' '.join(l[k:]+l[:k]))")
    for cfg in $order; do
      (use $cfg
       l=$(load)
       rm -f $OUT/bench-one.jsonl
       BENCH_LABEL="$cfg" BENCH_SCENES="${SCENES:-}" BENCH_FRAMES="${FRAMES:-}" BENCH_REPEAT="${REPEAT:-}" \
         BENCH_HISTORY=$OUT/bench-one.jsonl ./$MBUI_OUT/release/build/bench/bench.exe >$OUT/logs/bench-$cfg-$r.log 2>&1
       python3 -c "
import json,sys
d=json.loads(open('$OUT/bench-one.jsonl').read().strip().splitlines()[-1])
d.update(cfg='$cfg',round=$r,load='$l')
print(json.dumps(d))" >>$OUT/bench.jsonl
       echo "bench round $r $cfg ($l)")
    done
  done
}

report() {
  python3 - "$OUT" <<'EOF'
import json, os, statistics as st, sys
out = sys.argv[1]
def rows(p):
    return [json.loads(l) for l in open(p)] if os.path.exists(p) else []
c = rows(f"{out}/compile.jsonl")
if c:
    print("## compile (median of rounds; seconds)\n")
    steps = ["clean", "sfapp-line", "ui-fn", "nothing"]
    cols = ["wall_s", "build-package", "link-core", "cc-stub", "make-exe", "dsym"]
    for prof in sorted({x["profile"] for x in c}):
        for pkg in sorted({x["pkg"] for x in c}):
            print(f"### {pkg}, {prof}\n")
            print("| step | cfg | n | " + " | ".join(cols) + " | exe bytes |")
            print("|" + "---|" * (len(cols) + 4))
            for s in steps:
                for cfg in ["s", "nn", "nl"]:
                    xs = [x for x in c if x["step"] == s and x["cfg"] == cfg and x["pkg"] == pkg and x["profile"] == prof]
                    if not xs: continue
                    med = lambda k: st.median([float(x.get(k, 0)) for x in xs])
                    print(f"| {s} | {cfg} | {len(xs)} | " + " | ".join(f"{med(k):.2f}" for k in cols) + f" | {int(med('exe_bytes'))} |")
            print()
    print("loads seen: " + "; ".join(sorted({x['load'] for x in c})[:3]) + " …\n")
b = rows(f"{out}/bench.jsonl")
if b:
    print("## bench (median over runs of each run's best-of-REPEAT; ms per frame)\n")
    keys = ["frame_ms", "cpu_ms", "build_ms", "layout_ms", "paint_ms", "encode_ms", "gpu_ms"]
    scenes = []
    for x in b:
        for r in x["results"]:
            if r["scene"] not in scenes: scenes.append(r["scene"])
    print("| scene | cfg | runs | " + " | ".join(keys) + " |")
    print("|" + "---|" * (len(keys) + 3))
    for s in scenes:
        for cfg in ["s", "nn", "nl"]:
            rs = [r for x in b if x["cfg"] == cfg for r in x["results"] if r["scene"] == s]
            if not rs: continue
            print(f"| {s} | {cfg} | {len(rs)} | " + " | ".join(f"{st.median([r[k] for r in rs]):.3f}" for k in keys) + " |")
    print("\nloads seen: " + "; ".join(x["load"] for x in b))
EOF
}

# PKG TRIPLE OBJ [moonc args…]: the program as an object for another target: the llvm build's own link-core (from
# moon's plan) run again with -llvm-target TRIPLE. The .core files are the macOS build's: MoonBit's packages are
# compiled once, only link-core (where LLVM runs) knows the target. Our macOS-only files are in the plan as stubs, not
# in the object, so the object is the same program the C backend's generated C is.
cross_obj() {
  local pkg=$1 triple=$2 obj=$3; shift 3
  (use nl
   moon build $MOON_TARGET_FLAGS --release src/$pkg >$OUT/logs/cross-$pkg.log 2>&1 || true
   cmd=$(moon build $MOON_TARGET_FLAGS --release src/$pkg --dry-run 2>/dev/null | grep '^moonc link-core' | head -1)
   [ -n "$cmd" ] || { echo "llvm-spike: no link-core in moon's plan for src/$pkg" >&2; exit 1; }
   cmd=$(echo "$cmd" | sed -e "s|\\\$MOON_HOME|$MOON_HOME|g" -e "s| -o [^ ]*| -o $obj|")
   t0=$(now)
   eval "$cmd -llvm-target $triple $*"
   echo "link-core for $triple: $(python3 -c "print(round($(now)-$t0,2))") s, $(stat -f %z $obj) bytes")
}

# Android (arm64-v8a): the object for aarch64-linux-android linked into libmbui.so with the NDK, the way
# scripts/android.sh links the C backend's (runtime, android_host.c, -Dmain=mbui_main as a renamed symbol).
# APP=demo|… ; BITCODE=1 takes LLVM bitcode (-emit-llvm-ir) and lets the NDK's clang compile it instead.
android() {
  local pkg=${APP:-demo}
  SDK=${ANDROID_HOME:-$HOME/Library/Android/sdk}
  NDK=${ANDROID_NDK_HOME:-$SDK/ndk/28.2.13676358}
  TC=$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin
  CC="$TC/aarch64-linux-android29-clang"
  A=$OUT/android; rm -rf $A; mkdir -p $A/obj
  CFLAGS="-I$NIGHTLY/include -Isrc/host -fPIC -fwrapv -fno-strict-aliasing -Wno-unused-value -O2 -DMOONBIT_ALLOCATOR=MOONBIT_ALLOCATOR_SYSTEM"
  if [ "${BITCODE:-0}" = 1 ]; then
    cross_obj $pkg aarch64-unknown-linux-android29 $ROOT/$A/$pkg.bc -emit-llvm-ir
    $CC $CFLAGS -c $A/$pkg.bc -o $A/$pkg-llvm.o
  else
    cross_obj $pkg aarch64-unknown-linux-android29 $ROOT/$A/$pkg-llvm.o
  fi
  file $A/$pkg-llvm.o
  $TC/llvm-readelf -h $A/$pkg-llvm.o | grep -E 'Class|Machine|Type'
  echo "relocations by type: $($TC/llvm-readelf -r $A/$pkg-llvm.o | awk '/R_AARCH64/{print $3}' | sort | uniq -c | sort -rn | head -8 | tr '\n' ' ')"
  echo "undefined: $($TC/llvm-nm -u $A/$pkg-llvm.o | grep -v ' mb_\| mbui_\| mbc_' | awk '{print $2}' | tr '\n' ' ' | cut -c1-600)"
  $TC/llvm-objcopy --redefine-sym main=mbui_main $A/$pkg-llvm.o $A/obj/$pkg.o
  for f in runtime env utf sync_io backtrace; do
    $CC $CFLAGS -c $NIGHTLY/lib/runtime/$f.c -o $A/obj/rt_$f.o 2>$A/rt_$f.err || { echo "skip runtime/$f.c: $(grep error $A/rt_$f.err | head -1)"; rm -f $A/obj/rt_$f.o; }
  done
  $CC $CFLAGS -c src/host/android_host.c -o $A/obj/android_host.o
  $CC -shared -o $A/libmbui.so $A/obj/*.o -lGLESv3 -llog -lm -Wl,--no-undefined
  echo "libmbui.so (llvm) $(stat -f %z $A/libmbui.so) bytes"
}

# The iOS simulator (arm64): the object for arm64-apple-ios17.0-simulator linked with the runtime and the Objective-C
# host the way scripts/ios.sh links the C backend's, into out/lv/ios/MBUI.app. RUN=1 then boots a simulator of its own
# (lv-iphone), takes the demo's shot (out/lv/ios/shots/main.png, compared with goldens/ios.png) and deletes it.
ios_sim() {
  local pkg=demo I=$OUT/ios
  rm -rf $I; mkdir -p $I/obj $I/MBUI.app
  SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
  CC="xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -isysroot $SDK"
  CFLAGS="-I$NIGHTLY/include -Isrc/host -Iios/shim -fwrapv -fno-strict-aliasing -Wno-unused-value -O2 -DMOONBIT_ALLOCATOR=MOONBIT_ALLOCATOR_SYSTEM"
  cross_obj $pkg arm64-apple-ios17.0-simulator $ROOT/$I/obj/$pkg.o
  otool -l $I/obj/$pkg.o | grep -A4 LC_BUILD_VERSION | head -5
  for f in runtime env utf sync_io backtrace; do
    [ -f $NIGHTLY/lib/runtime/$f.c ] && { $CC $CFLAGS -c $NIGHTLY/lib/runtime/$f.c -o $I/obj/rt_$f.o 2>$I/rt_$f.err || echo "skip runtime/$f.c: $(head -1 $I/rt_$f.err)"; }
  done
  for f in apple_render apple_text apple_image apple_listen apple_browser_login apple_views ios_app; do
    $CC $CFLAGS -fobjc-arc -c src/host/$f.m -o $I/obj/$f.o
  done
  $CC $I/obj/*.o -o $I/MBUI.app/mbui -framework UIKit -framework Metal -framework QuartzCore \
    -framework CoreText -framework CoreGraphics -framework ImageIO -framework Foundation \
    -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework WebKit -lm
  cp ios/Info.plist $I/MBUI.app/Info.plist
  codesign -s - --force $I/MBUI.app >/dev/null 2>&1
  echo "MBUI.app (llvm) binary $(stat -f %z $I/MBUI.app/mbui) bytes"
  [ "${RUN:-0}" = 1 ] || return 0
  rt=$(xcrun simctl list runtimes -j | python3 -c "import json,sys;r=[x for x in json.load(sys.stdin)['runtimes'] if x['platform']=='iOS' and x['isAvailable']];print(r[-1]['identifier'])")
  dt=$(xcrun simctl list devicetypes -j | python3 -c "import json,sys;t=[x for x in json.load(sys.stdin)['devicetypes'] if x['name'].startswith('iPhone 1') and 'Pro' in x['name'] and 'Max' not in x['name']];print(t[-1]['identifier'])")
  id=$(xcrun simctl create lv-iphone "$dt" "$rt")
  echo "simulator lv-iphone $id ($dt, $rt)"
  xcrun simctl boot $id
  xcrun simctl bootstatus $id -b >/dev/null
  xcrun simctl install $id $I/MBUI.app
  mkdir -p $ROOT/$I/shots
  SIMCTL_CHILD_MBUI_SCRIPT=shot SIMCTL_CHILD_MBUI_BENCH=-1 SIMCTL_CHILD_MBUI_SHOT_DIR=$ROOT/$I/shots \
    xcrun simctl launch $id dev.mbui.demo
  for i in $(seq 1 60); do [ -f $I/shots/main.png ] && break; sleep 1; done
  sleep 1
  ls -la $I/shots
  xcrun simctl shutdown $id || true
  xcrun simctl delete $id
  [ -f $I/shots/main.png ] && NODE_PATH=$ROOT/out/node/node_modules node scripts/imgdiff.mjs goldens/ios.png $I/shots/main.png $I/shots/main-review.png || true
}

case "${1:-}" in
  install) install ;;
  cross) cross_obj "$2" "$3" "$4" "${@:5}" ;;
  android) android ;;
  ios-sim) ios_sim ;;
  run) cfg=$2; shift 2; (use $cfg; "$@") ;;
  build) build "$2" "$3" "${4:-}" ;;
  compile) compile "${2:-3}" "${3:-stillfail}" "${4:-release}" ;;
  bench) bench "${2:-3}" ;;
  report) report ;;
  *) sed -n 2,30p "$0"; exit 2 ;;
esac
