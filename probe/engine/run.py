#!/usr/bin/env python3
"""Hermes (bench/hermes-host, bytecode) vs Node (V8, .node-version's) on the same machine, alternating, medians.
   python3 run.py <W> [rounds] [tests...]   tests: cold first micro (default all); prints JSON lines and a summary.
Each run gets a fresh copy (APFS clone) of its data; the 1-minute load average is noted before each run."""
import json, os, shutil, statistics, subprocess, sys, tempfile, time

W = os.path.abspath(sys.argv[1])
ROUNDS = int(sys.argv[2]) if len(sys.argv) > 2 else 5
TESTS = sys.argv[3:] or ["cold", "first", "micro"]
OUT = os.path.join(W, "out")
NODE = shutil.which("node")
ENV = dict(os.environ, STILLFAIL_MESH_NATIVE=os.path.join(OUT, "mesh.node"))
HOST = os.environ.get("HERMES_HOST") or os.path.join(W, "hermes-host.exe" if os.name == "nt" else "hermes-host")
TMP = os.environ.get("EB_TMP") or ("/tmp" if os.name != "nt" else tempfile.gettempdir())

def load1():
    try:
        return round(os.getloadavg()[0], 2)
    except (AttributeError, OSError):
        return None

def cmd(engine, test, data):
    if test == "micro":
        if engine == "hermes":
            return [HOST, os.path.join(OUT, "micro.hbc"), os.path.join(OUT, "micro-drive.js"), data]
        return [NODE, "--expose-gc", os.path.join(OUT, "micro-node.mjs")]
    drive = os.path.join(OUT, "drive-cold.js" if test == "cold" else "drive-first.js")
    if engine == "hermes":
        return [HOST, os.path.join(OUT, "core.hbc"), drive, data]
    return [NODE, "--expose-gc", os.path.join(OUT, "node-drive.cjs"), os.path.join(OUT, "core-node.cjs"), drive, data]

def fresh(test, engine, i):
    d = os.path.join(TMP, f"eb-{test}-{engine}-{i}")
    shutil.rmtree(d, ignore_errors=True)
    if test == "first":
        if sys.platform == "darwin":
            subprocess.run(["cp", "-c", "-R", os.path.join(W, "data-seed"), d], check=True)
        else:
            shutil.copytree(os.path.join(W, "data-seed"), d)
    else:
        os.makedirs(d)
    return d

def one(engine, test, i):
    data = fresh(test, engine, i)
    load = load1()
    t0 = time.time() * 1000
    p = subprocess.run(cmd(engine, test, data), capture_output=True, text=True, env=ENV, timeout=300)
    t1 = time.time() * 1000
    shutil.rmtree(data, ignore_errors=True)
    line = [l for l in p.stdout.splitlines() if l.startswith("{")]
    if p.returncode != 0 or not line:
        return {"engine": engine, "test": test, "error": (p.stderr or p.stdout)[-1500:], "code": p.returncode}
    r = json.loads(line[-1])
    r.update(engine=engine, test=test, round=i, load1=load, wallMs=round(t1 - t0))
    if "driveAt" in r:
        r["spawnToDriveMs"] = round(r["driveAt"] - t0)
    if "firstAt" in r:
        r["spawnToFirstMs"] = round(r["firstAt"] - t0)
    if isinstance(r.get("first"), dict) and "at" in r["first"]:
        r["spawnToFirstMs"] = round(r["first"]["at"] - t0)
    r.pop("accounts", None)
    return r

results = []
for i in range(ROUNDS):
    for test in TESTS:
        order = ["hermes", "node"] if i % 2 == 0 else ["node", "hermes"]
        for engine in order:
            r = one(engine, test, i)
            results.append(r)
            print(json.dumps(r, ensure_ascii=False), flush=True)

def med(xs):
    xs = [x for x in xs if x is not None]
    return round(statistics.median(xs), 1) if xs else None

summary = {}
for test in TESTS:
    for engine in ["hermes", "node"]:
        rs = [r for r in results if r.get("test") == test and r.get("engine") == engine and "error" not in r]
        s = {"n": len(rs), "load1": [r["load1"] for r in rs]}
        if test == "cold":
            for k in ["spawnToDriveMs", "spawnToFirstMs", "rssMB", "heapMB", "wallMs"]:
                s[k] = med([r.get(k) for r in rs]); s[k + "_all"] = [r.get(k) for r in rs]
        elif test == "first":
            s["spawnToFirstMs"] = med([r.get("spawnToFirstMs") for r in rs]); s["spawnToFirst_all"] = [r.get("spawnToFirstMs") for r in rs]
            s["firstMs"] = med([r["first"]["ms"] for r in rs if r.get("first")])
            s["firstRows"] = med([r["first"]["rows"] for r in rs if r.get("first")])
            s["firstRssMB"] = med([r["first"]["memory"]["rssMB"] for r in rs if r.get("first")])
            s["firstHeapMB"] = med([r["first"]["memory"]["heapMB"] for r in rs if r.get("first")])
            s["wholeMs"] = med([r["whole"]["ms"] for r in rs]); s["whole_all"] = [r["whole"]["ms"] for r in rs]
            s["wholeRows"] = med([r["whole"]["rows"] for r in rs])
            s["settledRssMB"] = med([r["settled"]["rssMB"] for r in rs]); s["settledHeapMB"] = med([r["settled"]["heapMB"] for r in rs])
        else:
            names = [c["name"] for c in rs[0]["micro"]] if rs else []
            s["cases"] = {n: med([next(c["ms"] for c in r["micro"] if c["name"] == n) for r in rs]) for n in names}
            s["rssMB"] = med([r["rssMB"] for r in rs]); s["heapMB"] = med([r["heapMB"] for r in rs]); s["totalMs"] = med([r["totalMs"] for r in rs])
        summary[f"{test}/{engine}"] = s
errors = [r for r in results if "error" in r]
print("SUMMARY " + json.dumps({"summary": summary, "errors": len(errors)}, ensure_ascii=False, indent=1))
for e in errors[:4]:
    print("ERROR", json.dumps(e)[:1500])
