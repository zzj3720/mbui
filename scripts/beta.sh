#!/bin/bash
# The beta test app (fail.still.mbui, "still.fail mbui": APP=stillfail's release build, android/app/build.gradle.kts),
# built and published as .github/workflows/beta.yml does it on Mini1's runner (mbui-mini1), each step warm:
#
#   scripts/beta.sh tools     MoonBit, the latest release (installed again only when cli.moonbitlang.com has a newer
#                             one: its ETag), a JDK, the PATH (into $GITHUB_ENV when there is one)
#   scripts/beta.sh ember     still.fail's sources for the core at core/ember.rev (a clone kept in the cache; the core's
#                             packages installed once a commit)
#   scripts/beta.sh build     the APK (scripts/android.sh build, VARIANT=release): moonc's C compiled where it changed,
#                             core.hbc from the cache when its inputs are the same, Gradle's daemon kept between runs
#   scripts/beta.sh publish   the APK on the GitHub release `beta` (a prerelease, its tag moved to this commit) as
#                             mbui-beta.apk, the notes saying the commit and the build
#
# MBUI_CACHE: what is kept between runs (default: the runner's tool cache, else ~/.cache/mbui-beta): moon/, ember/,
# hbc/, gradle/ (GRADLE_USER_HOME: this app's daemon and caches, apart from the machine's other builds).
# The build's number and name: MBUI_VERSION_CODE (CI: the run number), MBUI_VERSION_NAME (0.1.<number>-<commit>).
# Signing: MBUI_KEYSTORE_B64 (the keystore, base64), MBUI_KEYSTORE_PASSWORD, MBUI_KEY_ALIAS, MBUI_KEY_PASSWORD (CI:
# the repository's secrets); without them the APK is not signed and publish refuses it.
set -eo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
cd "$D/.."
ROOT=$PWD
C=${MBUI_CACHE:-${RUNNER_TOOL_CACHE:+$RUNNER_TOOL_CACHE/mbui}}
C=${C:-$HOME/.cache/mbui-beta}
mkdir -p $C
APK=android/app/build/outputs/apk/release/app-release.apk
REPO=${GITHUB_REPOSITORY:-zzj3720/mbui}
SHA=${GITHUB_SHA:-$(git rev-parse HEAD)}
RUN=${GITHUB_RUN_NUMBER:-${MBUI_VERSION_CODE:-1}}
export MBUI_VERSION_CODE=${MBUI_VERSION_CODE:-$RUN}
export MBUI_VERSION_NAME=${MBUI_VERSION_NAME:-0.1.$RUN-${SHA:0:7}}
SDK=${ANDROID_HOME:-$HOME/Library/Android/sdk}
BT=$(ls -d $SDK/build-tools/* 2>/dev/null | sort -V | tail -1)

now() { python3 -c 'import time;print(time.time())'; }
secs() { python3 -c "print(f'{$(now)-$1:.1f}')"; }
say() { echo "beta: $*"; }
# into the job's environment for its later steps, and this one's
setenv() { export "$1=$2"; [ -n "${GITHUB_ENV:-}" ] && echo "$1=$2" >> $GITHUB_ENV; return 0; }
summary() { [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "$*" >> $GITHUB_STEP_SUMMARY; echo "$*"; }

# The latest MoonBit, in $C/moon/<its ETag's hash>: the ETags of the release's two downloads (the binaries and the
# core) asked each run (a HEAD each, a few hundred ms), the install only when they changed; the one before is kept
# (the newest 2).
moon_tools() {
  local base=https://cli.moonbitlang.com bin=moonbit-darwin-aarch64.tar.gz tag dir
  tag=$( { curl -sfI --max-time 5 $base/binaries/latest/$bin; curl -sfI --max-time 5 $base/cores/core-latest.tar.gz; } \
    | tr -d '\r' | awk -F': ' 'tolower($1) == "etag" { print $2 }' | tr -d '\n')
  if [ -z "$tag" ] || [ "$(echo "$tag" | grep -o '"' | wc -l | tr -d ' ')" != 4 ]; then
    # (cli.moonbitlang.com not answering: the one there is)
    dir=$(readlink $C/moon/current 2>/dev/null || true)
    [ -n "$dir" ] || { echo "beta: no MoonBit, and cli.moonbitlang.com does not answer" >&2; exit 1; }
    say "MoonBit: cli.moonbitlang.com did not answer; keeping $(basename $dir)"
  else
    dir=$C/moon/$(echo "$tag" | shasum -a 256 | cut -c1-16)
    if [ ! -x $dir/bin/moon ]; then
      local t0=$(now) tmp=$C/moon/new.$$
      say "MoonBit: a new release ($tag); installing"
      rm -rf $tmp && mkdir -p $tmp
      # (its HOME for the download; its bin first on PATH so that it leaves the shell's rc files alone)
      curl -fsSL --max-time 60 https://cli.moonbitlang.com/install/unix.sh -o $tmp/install.sh
      HOME=$tmp MOON_HOME=$tmp PATH=$tmp/bin:$PATH bash $tmp/install.sh > $C/moon/install.log 2>&1 \
        || { tail -20 $C/moon/install.log; rm -rf $tmp; exit 1; }
      rm -f $tmp/install.sh
      mv $tmp $dir
      say "MoonBit installed in $(secs $t0) s"
    fi
    ln -sfn $dir $C/moon/current.new && mv -fh $C/moon/current.new $C/moon/current
    # the newest two (the one in use and the one before)
    ls -dt $C/moon/*/ | grep -v '/current/' | tail -n +3 | xargs rm -rf
  fi
  setenv MOON_HOME $dir
}

tools() {
  local t0=$(now)
  mkdir -p $C/moon
  moon_tools
  setenv MBUI_OWN_TOOLS 1
  # node, pnpm (Mini1: ~/.local/bin), gh, Homebrew's JDK
  setenv PATH "$MOON_HOME/bin:$HOME/.local/bin:/opt/homebrew/bin:$PATH"
  if [ -z "${JAVA_HOME:-}" ]; then
    local j
    j=$(/usr/libexec/java_home -v 17+ 2>/dev/null || true)
    for c in /opt/homebrew/opt/openjdk@21 /opt/homebrew/opt/openjdk@17 /opt/homebrew/opt/openjdk; do
      [ -z "$j" ] && [ -d $c/libexec/openjdk.jdk/Contents/Home ] && j=$c/libexec/openjdk.jdk/Contents/Home
    done
    [ -n "$j" ] || { echo "beta: no JDK" >&2; exit 1; }
    setenv JAVA_HOME "$j"
  fi
  setenv GRADLE_USER_HOME $C/gradle
  # this app's daemon stays a day between builds (the project's 30 minutes are for shared machines' builds by hand)
  mkdir -p $C/gradle
  grep -q '^org.gradle.daemon.idletimeout=' $C/gradle/gradle.properties 2>/dev/null \
    || echo "org.gradle.daemon.idletimeout=86400000" >> $C/gradle/gradle.properties
  summary "- MoonBit: $(moon version 2>/dev/null | head -1) ($(basename $MOON_HOME)); $("$JAVA_HOME/bin/java" -version 2>&1 | head -1); tools in $(secs $t0) s"
}

# still.fail's sources at core/ember.rev (the commit the port follows; bump it there): $C/ember, a clone of
# AFK-surf/still.fail without blobs it does not check out; client/core-ts's packages installed once a commit.
ember() {
  local t0=$(now) E=$C/ember rev
  rev=$(tr -d ' \n' < core/ember.rev)
  if [ ! -d $E/.git ]; then
    say "cloning still.fail (once)"
    git clone -q --filter=blob:none --no-checkout https://github.com/AFK-surf/still.fail.git $E
  fi
  if [ "$(git -C $E rev-parse HEAD 2>/dev/null)" != "$rev" ] || [ -n "$(git -C $E status --porcelain -uno)" ]; then
    git -C $E cat-file -e "$rev^{commit}" 2>/dev/null || git -C $E fetch -q --filter=blob:none origin $rev
    git -C $E -c advice.detachedHead=false checkout -q --force --detach $rev
  fi
  if [ "$(cat $C/ember.installed 2>/dev/null)" != "$rev" ]; then
    say "installing the core's packages at ${rev:0:9}"
    (cd $E/client/core-ts && pnpm install --frozen-lockfile --prefer-offline 2>&1 | tail -3)
    echo $rev > $C/ember.installed
  fi
  setenv EMBER $E
  summary "- still.fail at ${rev:0:9}: $(git -C $E log -1 --format=%s | cut -c1-70); ember in $(secs $t0) s"
}

build() {
  local t0=$(now) ks=
  export EMBER=${EMBER:-$C/ember} GRADLE_USER_HOME=${GRADLE_USER_HOME:-$C/gradle} MBUI_OWN_TOOLS=1
  if [ -n "${MBUI_KEYSTORE_B64:-}" ]; then
    ks=$(mktemp -d ${RUNNER_TEMP:-/tmp}/mbui-key.XXXXXX)/beta.p12
    printf '%s' "$MBUI_KEYSTORE_B64" | base64 -d > $ks
    export MBUI_KEYSTORE=$ks
  fi
  rm -f android/app/build/outputs/apk/release/*.apk
  mkdir -p out/android
  # Gradle's daemon outlives the job: the runner ends at the job's end what carries its RUNNER_TRACKING_ID
  local r=0
  env -u RUNNER_TRACKING_ID APP=stillfail VARIANT=release HBC_CACHE=$C/hbc scripts/android.sh build 2>&1 | tee out/android/beta-build.log || r=$?
  [ -n "$ks" ] && rm -rf "$(dirname $ks)"
  [ $r = 0 ] || exit $r
  [ -f $APK ] || { echo "beta: no signed APK (the keystore's variables?)" >&2; ls android/app/build/outputs/apk/release/ >&2; exit 1; }
  # what it is: the package, the build, the key
  local badging cert
  badging=$($BT/aapt2 dump badging $APK | head -1)
  echo "$badging" | grep -q "name='fail.still.mbui' versionCode='$MBUI_VERSION_CODE'" \
    || { echo "beta: not the APK this build should have made: $badging" >&2; exit 1; }
  cert=$($BT/apksigner verify --print-certs $APK | grep 'certificate SHA-256 digest' | head -1 | sed 's/.*: //')
  summary "- APK: $(wc -c < $APK | tr -d ' ') bytes, $MBUI_VERSION_NAME ($MBUI_VERSION_CODE), signed by $cert"
  summary "- $(grep '^android.sh: APP=' out/android/beta-build.log | sed 's/^android.sh: //')"
  summary "- $(grep '^core.hbc ' out/android/beta-build.log | head -1); build in $(secs $t0) s"
}

# The release `beta`: its tag moved to this commit, the APK uploaded under a name of its own then given the stable
# name (the old one deleted just before: the download is missing for that moment only), the notes saying what it is.
publish() {
  local t0=$(now) rel up old n sum cert subject
  [ -f $APK ] || { echo "beta: no APK (scripts/beta.sh build)" >&2; exit 1; }
  sum=$(shasum -a 256 $APK | cut -d' ' -f1)
  cert=$($BT/apksigner verify --print-certs $APK | grep 'certificate SHA-256 digest' | head -1 | sed 's/.*: //')
  subject=$(git log -1 --format=%s $SHA)
  gh api -X PATCH repos/$REPO/git/refs/tags/beta -f sha=$SHA -F force=true >/dev/null 2>&1 \
    || gh api -X POST repos/$REPO/git/refs -f ref=refs/tags/beta -f sha=$SHA >/dev/null
  n=$(mktemp ${RUNNER_TEMP:-/tmp}/beta-notes.XXXXXX)
  cat > $n <<EOF
The mbui build of still.fail's Android app, as a test app of its own: **still.fail mbui** (\`fail.still.mbui\`), beside still.fail's apps. Rebuilt on every push to main ([beta.yml](https://github.com/$REPO/blob/main/.github/workflows/beta.yml)).

**Download:** https://github.com/$REPO/releases/download/beta/mbui-beta.apk

| | |
|---|---|
| commit | [\`${SHA:0:9}\`](https://github.com/$REPO/commit/$SHA) $subject |
| build | $MBUI_VERSION_CODE (version $MBUI_VERSION_NAME) |
| built | $(date -u +%Y-%m-%dT%H:%MZ), [run](https://github.com/$REPO/actions/runs/${GITHUB_RUN_ID:-0}) |
| APK SHA-256 | \`$sum\` |
| signing certificate SHA-256 | \`$cert\` |
EOF
  if ! gh release view beta -R $REPO >/dev/null 2>&1; then
    gh release create beta -R $REPO --prerelease --verify-tag --title "beta (rolling)" --notes-file $n >/dev/null
  fi
  rel=$(gh api repos/$REPO/releases/tags/beta --jq .id)
  # leftovers of a run that stopped half way
  for a in $(gh api repos/$REPO/releases/$rel/assets --paginate --jq '.[] | select(.name | test("^mbui-beta-[0-9]+\\.apk$")) | .id'); do
    gh api -X DELETE repos/$REPO/releases/assets/$a
  done
  local tu=$(now)
  up=$(curl -sSf --retry 2 -X POST -H "Authorization: Bearer $GH_TOKEN" -H "Content-Type: application/vnd.android.package-archive" \
    --data-binary @$APK "https://uploads.github.com/repos/$REPO/releases/$rel/assets?name=mbui-beta-$MBUI_VERSION_CODE.apk" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
  local upload=$(secs $tu)
  old=$(gh api repos/$REPO/releases/$rel/assets --paginate --jq '.[] | select(.name == "mbui-beta.apk") | .id')
  [ -n "$old" ] && gh api -X DELETE repos/$REPO/releases/assets/$old
  gh api -X PATCH repos/$REPO/releases/assets/$up -f name=mbui-beta.apk -f label="still.fail mbui $MBUI_VERSION_NAME" >/dev/null
  gh release edit beta -R $REPO --prerelease --title "beta: $MBUI_VERSION_NAME" --notes-file $n >/dev/null
  rm -f $n
  summary "- published https://github.com/$REPO/releases/download/beta/mbui-beta.apk (upload $upload s, publish in $(secs $t0) s)"
}

case "${1:-}" in
  tools) tools ;;
  ember) ember ;;
  build) build ;;
  publish) publish ;;
  all) tools; ember; build; publish ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
