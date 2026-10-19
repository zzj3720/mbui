// A Hermes driver script (drive-*.js) in Node: the core as the desktop app bundles it (core-node.cjs: esbuild of
// src/hosts/node.ts), __stillfail / __native / __bench as bench/hermes-host gives them.
//   node --expose-gc node-drive.cjs <core-node.cjs> <drive.js> <data dir>     (HOSTWIRE=1: no iroh, as bench/first-view.ts)
const { readFileSync } = require("node:fs");
const vm = require("node:vm");
const [, , bundle, drive, dir] = process.argv;
const core = require(require("node:path").resolve(bundle));
let c = null;
globalThis.__native = { emit() {}, now: () => Date.now() };
globalThis.__bench = {
  now: () => performance.now(),
  rss: () => process.memoryUsage().rss,
  heap: () => process.memoryUsage().heapUsed,
  gc: () => globalThis.gc?.(),
  print: (s) => process.stdout.write(s + "\n"),
  exit: () => process.exit(0),
};
globalThis.__stillfail = {
  start(origin) {
    c = core.start(dir, origin, (client, json) => globalThis.__native.emit(client, json), undefined, { hostWire: process.env.HOSTWIRE === "1" });
  },
  connect: () => c.connect(),
  receive: (ui, json) => c.receive(ui, json),
};
vm.runInThisContext(readFileSync(drive, "utf8"), { filename: drive });
