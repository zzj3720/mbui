// Cold start (core-engine-pc.md): an empty data directory, the core started offline, `accounts` subscribed; prints when
// the script began and when the first value came (wall clock, ms since the epoch: the runner knows when it spawned the
// process), and memory then. Runs as is in Hermes (bench/hermes-host) and in Node (node-drive.cjs).
(function () {
  var driveAt = __native.now();
  var done = false;
  __native.emit = function (client, json) {
    if (done || json.indexOf('{"id":1,') !== 0) return;
    var m = JSON.parse(json);
    if (!("value" in m)) return;
    done = true;
    var firstAt = __native.now();
    __bench.gc();
    __bench.print(JSON.stringify({ driveAt: driveAt, firstAt: firstAt, accounts: m.value, rssMB: Math.round(__bench.rss() / 104857.6) / 10, heapMB: Math.round(__bench.heap() / 104857.6) / 10 }));
    __bench.exit();
  };
  __stillfail.start("http://127.0.0.1:9", false);
  var ui = __stillfail.connect();
  __stillfail.receive(ui, JSON.stringify({ id: 1, subscribe: { topic: "accounts" } }));
})();
