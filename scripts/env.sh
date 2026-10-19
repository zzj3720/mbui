# Source on Studio: toolchain paths for this session (elsewhere, e.g. on
# Windows or CI, the toolchain on PATH is used as is).
TOOLS=/Users/zuozijian/.stillfail/remote/sessions/df5e90815f47b3e730078057bed8feea81b11db927ea4ae88c9346fdc9260bb1/work/tools
if [ -d "$TOOLS" ]; then
  export MOON_HOME=$TOOLS/moon
  export PATH=$MOON_HOME/bin:$TOOLS/go/bin:$HOME/.local/bin:$PATH
fi
# Another toolchain and backend for one run (docs/llvm-spike.md): MBUI_MOON_HOME a moon install (e.g. a nightly) put
# before the usual one, MBUI_TARGET native|llvm, MBUI_TARGET_DIR the build directory (default _build; give another one
# to a second toolchain so the two never share a build database). MBUI_OUT is where the scripts find the programs.
if [ -n "${MBUI_MOON_HOME:-}" ]; then
  export MOON_HOME=$MBUI_MOON_HOME
  export PATH=$MOON_HOME/bin:$PATH
fi
MBUI_TARGET=${MBUI_TARGET:-native}
MBUI_OUT=${MBUI_TARGET_DIR:-_build}/$MBUI_TARGET
MOON_TARGET_FLAGS="--target $MBUI_TARGET${MBUI_TARGET_DIR:+ --target-dir $MBUI_TARGET_DIR}"
