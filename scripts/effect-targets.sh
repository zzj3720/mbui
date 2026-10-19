# effect.mb on our targets: macOS native and JS (moon run), the iOS simulator
# (moon's C + the runtime, with the repo's ios/shim, run in the simulator) and
# Android (NDK clang, arm64, linked; no device to run it on).
. scripts/env.sh
echo "== macOS native"; moon run --target native src/effectprobe 2>&1 | grep EFFECT-PROBE
echo "== js"; moon run --target js src/effectprobe 2>&1 | grep EFFECT-PROBE
moon build --target native --release src/effectprobe 2>&1 | python3 scripts/errs.py | grep -v '^errors: 0'
C=_build/native/release/build/effectprobe/effectprobe.c; ls -la $C | awk '{print "generated C:", $5, "bytes"}'
for tgt in ios android; do
  mkdir -p out/ef/$tgt; rm -f out/ef/$tgt/*.o; ok=1
  if [ $tgt = ios ]; then
    SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
    CC="xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -isysroot $SDK"; X="-Iios/shim"
  else
    CC=$HOME/Library/Android/sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android29-clang; X=""
  fi
  F="-I$MOON_HOME/include $X -fwrapv -fno-strict-aliasing -Wno-unused-value -O2 -DMOONBIT_ALLOCATOR=MOONBIT_ALLOCATOR_SYSTEM -w"
  $CC $F -c $C -o out/ef/$tgt/main.o || ok=0
  for f in $MOON_HOME/lib/runtime/*.c; do $CC $F -c $f -o out/ef/$tgt/rt_$(basename $f .c).o 2>out/ef/$tgt/rt.err || { echo "runtime FAIL $(basename $f): $(grep error out/ef/$tgt/rt.err | head -1)"; ok=0; }; done
  $CC out/ef/$tgt/*.o -o out/ef/$tgt/probe -lm 2>out/ef/$tgt/link.err || { ok=0; grep -E 'Undefined|error' out/ef/$tgt/link.err | head -8; }
  echo "== $tgt compiled+linked: $ok, $(ls -la out/ef/$tgt/probe 2>/dev/null | awk '{print $5}') bytes"; file out/ef/$tgt/probe | cut -d: -f2
done
DEV=$(xcrun simctl list devices booted -j | python3 -c "import json,sys;d=[x['udid'] for v in json.load(sys.stdin)['devices'].values() for x in v if x['state']=='Booted'];print(d[0] if d else '')")
if [ -n "$DEV" ] && [ -x out/ef/ios/probe ]; then codesign -s - -f out/ef/ios/probe 2>&1 | tail -1; echo "== run in the iOS simulator ($DEV)"; xcrun simctl spawn $DEV $PWD/out/ef/ios/probe; echo "exit $?"; else echo "no booted simulator: iOS not run"; fi
