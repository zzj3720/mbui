#!/usr/bin/env python3
"""Sums a `moon build --trace` trace.json by step: the n2.task spans (one per command moon ran), by what they ran.

  scripts/llvm_trace.py trace.json [key=value ...]   prints one JSON line: the keys given, wall_s, and per step
                                                       its summed seconds and count

Steps: build-package (moonc build-package, per package), link-core (moonc link-core: the whole program to C for
native release, to an object for native debug's machine backend and for LLVM), cc-stub (C stubs and the runtime
compiled), archive (libtool/ar), make-exe (cc: for native release it compiles the generated C and links; for LLVM
and native debug it only links), dsym (dsymutil), other.
"""
import json
import sys


def step(cmd):
    if "moonc build-package" in cmd:
        return "build-package"
    if "moonc link-core" in cmd:
        return "link-core"
    if "dsymutil" in cmd:
        return "dsym"
    if "libtool" in cmd or cmd.split(" ", 1)[0].endswith("/ar"):
        return "archive"
    if " -c " in cmd or cmd.rstrip().endswith(" -c"):
        return "cc-stub"
    if ".exe" in cmd:
        return "make-exe"
    return "other"


def main():
    path = sys.argv[1]
    extra = dict(a.split("=", 1) for a in sys.argv[2:])
    with open(path) as f:
        text = f.read().strip()
    if text.endswith(","):
        text = text[:-1]
    if not text.endswith("]"):
        text += "]"
    ev = json.loads(text)
    open_ = {}
    out = {}
    ts = [e["ts"] for e in ev if "ts" in e]
    for e in ev:
        if e.get("name") != "n2.task":
            continue
        key = (e.get("tid"), e.get("args", {}).get("desc"))
        if e["ph"] == "B":
            open_[key] = e
        elif e["ph"] == "E" and key in open_:
            b = open_.pop(key)
            s = step(b.get("args", {}).get("cmdline", ""))
            d = (e["ts"] - b["ts"]) / 1e6
            sec, n = out.get(s, (0.0, 0))
            out[s] = (sec + d, n + 1)
    line = dict(extra)
    line["trace_s"] = round((max(ts) - min(ts)) / 1e6, 3) if ts else 0
    for s, (sec, n) in sorted(out.items()):
        line[s] = round(sec, 3)
        line[s + "_n"] = n
    print(json.dumps(line, ensure_ascii=False))


if __name__ == "__main__":
    main()
