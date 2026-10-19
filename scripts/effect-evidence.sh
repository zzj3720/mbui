# effect.mb: the evidence (docs/effect-spike.md). The suites as CI would run them, then the demo's
# injected race as a failing test that names its seed, and that seed replayed.
. scripts/env.sh
F='^Warning\|^ *│\|^ *╭\|^ *╰\|^─\|^ *[0-9]* │'
mkdir -p out/ef
if [ -z "$ONLY_BUG" ]; then
echo "== effect.mb tests, native"; moon test --target native -p mbui/effecttest -p mbui/effectport 2>&1 | grep -v "$F" | tail -5
echo "== effect.mb tests, js"; moon test --target js -p mbui/effecttest -p mbui/effectport 2>&1 | grep -v "$F" | tail -5
echo "== demo (screen + core + sim backend), js"; /usr/bin/time -p moon test --target js -p mbui/effectdemo 2>&1 | grep -v "$F" | tail -6
fi
echo "== the buggy app as a seeded test (EF_DEMO_BUG=1)"
EF_DEMO_BUG=1 moon test --target js -p mbui/effectdemo 2>&1 | grep -v "$F" > out/ef/bug-run.txt
grep -m1 -o 'seed [0-9]*:[^\\]*' out/ef/bug-run.txt | head -1; grep -o 'replay: SEED=[0-9]*' out/ef/bug-run.txt | head -1; tail -1 out/ef/bug-run.txt
S=$(grep -o 'replay: SEED=[0-9]*' out/ef/bug-run.txt | head -1 | cut -d= -f2)
echo "== replayed: SEED=$S, twice"
SEED=$S EF_DEMO_BUG=1 moon test --target js -p mbui/effectdemo 2>&1 | grep -v "$F" > out/ef/replay1.txt
SEED=$S EF_DEMO_BUG=1 moon test --target js -p mbui/effectdemo 2>&1 | grep -v "$F" > out/ef/replay2.txt
tail -1 out/ef/replay1.txt
cmp -s out/ef/bug-run.txt out/ef/replay1.txt && echo "the seed sweep's failing run and SEED=$S: identical output ($(wc -c < out/ef/replay1.txt) bytes)" || { echo "sweep vs replay differ:"; diff out/ef/bug-run.txt out/ef/replay1.txt | head -20; }
cmp -s out/ef/replay1.txt out/ef/replay2.txt && echo "replay 1 and replay 2: identical" || echo "replays differ"
echo "== a seed that does not fail, replayed: SEED=1 EF_DEMO_BUG=1"
SEED=1 EF_DEMO_BUG=1 moon test --target js -p mbui/effectdemo 2>&1 | grep -v "$F" | tail -1
