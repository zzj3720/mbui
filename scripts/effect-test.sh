# effect.mb: check (errors, and the effect packages' warnings), then its tests on native and JS and the demo on JS. UPDATE=1 refreshes snapshots.
. scripts/env.sh
filt() { python3 -c "
import sys,json
n=0
for line in sys.stdin:
    line=line.strip()
    if not line.startswith('{'):
        if 'rror' in line or 'failed' in line: print('RAW', line[:300])
        continue
    try: d=json.loads(line)
    except Exception: continue
    p=d.get('path','')
    if d.get('level')=='error' or ('/effect' in p and d.get('level')=='warning' and 'deprecated' not in d.get('message','') and 'implicit_impl' not in d.get('message','')):
        n+=1
        if n<60: print(d.get('level'), p.split('/src/')[-1], d.get('loc'), d.get('message','')[:500])
print('count', n)
"; }
F='^Warning\|^ *│\|^ *╭\|^ *╰\|^─\|^ *[0-9]* │'
ok=1
for t in native js; do echo "== check $t"; moon check --target $t --output-json 2>&1 | filt | tee /tmp/ef-chk.txt; grep -q '^error\|^RAW.*[Ff]ailed' /tmp/ef-chk.txt && ok=0; done
[ $ok = 1 ] || { echo "check failed: no tests"; exit 1; }
echo "== test native"; moon test --target native -p mbui/effecttest -p mbui/effectport ${UPDATE:+-u} 2>&1 | grep -v "$F" | tail -60
echo "== test js"; moon test --target js -p mbui/effecttest -p mbui/effectport 2>&1 | grep -v "$F" | tail -60
echo "== demo js"; moon test --target js -p mbui/effectdemo 2>&1 | grep -v "$F" | tail -${DEMO_LINES:-40}
