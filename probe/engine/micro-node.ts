// micro.ts in Node: __bench as bench/hermes-host gives it to Hermes.
import { runMicro } from "./micro.ts";

// deno-lint-ignore no-explicit-any
(globalThis as any).__bench = {
  now: () => performance.now(),
  rss: () => process.memoryUsage().rss,
  heap: () => process.memoryUsage().heapUsed,
  // deno-lint-ignore no-explicit-any
  gc: () => (globalThis as any).gc?.(),
  print: (s: string) => console.log(s),
  exit: () => process.exit(0),
};
void runMicro();
