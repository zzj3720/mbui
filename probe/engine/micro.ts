// Engine comparison (core-engine-pc.md): pure-JS parts of the core's real work, the same source in Hermes (bytecode,
// as the Android app runs it) and in Node (V8). No host: JSON of a big view, the keyed and index diffs and applying them,
// markdown, Effect's runtime, the core's crypto (noble). Each case: a warm-up, then N timed runs; the median in ms.
import { Effect } from "effect";
import { ed25519, x25519 } from "@noble/curves/ed25519.js";
import { p256 } from "@noble/curves/nist.js";
import { chacha20poly1305 } from "@noble/ciphers/chacha.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { applyKeyed, diffKeyed, specOf } from "../../src/collections.ts";
import { parse as parseMarkdown } from "../../src/markdown.ts";
import { pairSession, pakeKeys, pakeStart } from "../../src/pair.ts";

type Bench = { now(): number; rss(): number; heap(): number; gc(): void; print(s: string): void; exit(): void };
// deno-lint-ignore no-explicit-any
let B: Bench;

const NOW = Date.UTC(2026, 9, 3, 12);
function row(st: string, i: number, at: number, text = `好的，已经改完了第 ${i} 处，测试都过了。`) {
  const key = `k${i}`;
  return {
    station: st, id: key, session: key, thread: i, title: `第 ${i} 个对话：排查 ${st} 上的构建`, mine: i % 3 === 0, unread: i % 7 === 0, connect: null, origin: null,
    lastActiveAt: at, pinned: null,
    agents: [{ key, runtime: "claude", model: "claude-opus-4-1", effort: null, process: i % 50 === 0 ? "running" : "warm", pending: 0, lastTurn: { kind: "chat", declared: "final", outcome: "completed", detail: null, startedAt: at - 5000, endedAt: at } }],
    last: { seq: 3, thread: i, ts: `${i}.3`, authorKind: "agent", author: key, authorName: null, text, attachments: [], quotes: [], declared: "final", createdAt: at, editedAt: null },
  };
}
/// The chat list's value as the core sends it (days of rows), `n` rows over 3 stations.
function chats(n: number, top?: ReturnType<typeof row>) {
  const rows = Array.from({ length: n }, (_, i) => row(`w/s${i % 3}`, i, NOW - i * 60_000));
  if (top) rows.unshift(top);
  const days: { daysAgo: number; items: unknown[] }[] = [];
  for (const r of rows) {
    const daysAgo = Math.floor((NOW - r.lastActiveAt) / 86_400_000);
    const last = days[days.length - 1];
    if (last && last.daysAgo === daysAgo) last.items.push(r);
    else days.push({ daysAgo, items: [r] });
  }
  return { days, more: false };
}

function message(): string {
  const parts: string[] = ["## 改动说明", ""];
  for (let i = 0; i < 12; i++) {
    parts.push(`${i + 1}. 在 \`src/module${i}.ts\` 里把 **第 ${i} 个**检查挪到读之前，_避免_ 重复读取；见 https://example.com/pr/${i}`);
    parts.push(`   - 子项：~~旧写法~~ 换成新的，测试 \`test/case${i}.test.ts\` 覆盖`);
  }
  parts.push("", "| 文件 | 行数 | 结果 |", "|---|---|---|");
  for (let i = 0; i < 20; i++) parts.push(`| src/f${i}.ts | ${i * 13} | 通过 |`);
  parts.push("", "```ts");
  for (let i = 0; i < 60; i++) parts.push(`export function step${i}(x: number): number { return x * ${i} + ${i * 7}; }`);
  parts.push("```", "", "- [x] 类型检查", "- [ ] 端到端", "", "> 注意：这一段是引用，说明为什么这么改。");
  return parts.join("\n");
}

function median(xs: number[]): number {
  const s = xs.slice().sort((a, b) => a - b);
  return s[s.length >> 1]!;
}

type Case = { name: string; runs: number; run: () => unknown | Promise<unknown> };

async function time(c: Case): Promise<{ name: string; ms: number; runs: number }> {
  await c.run();
  const ms: number[] = [];
  for (let i = 0; i < c.runs; i++) {
    const t0 = B.now();
    await c.run();
    ms.push(B.now() - t0);
  }
  return { name: c.name, ms: Math.round(median(ms) * 1000) / 1000, runs: c.runs };
}

export async function runMicro(): Promise<void> {
  // deno-lint-ignore no-explicit-any
  B = (globalThis as any).__bench as Bench;
  const t0 = B.now();
  const spec = specOf({ topic: "chats", scope: "w" } as never);
  const big = chats(6000);
  const bigJson = JSON.stringify(big);
  const moved = chats(5999, row("w/s1", 99999, NOW + 1000, "新消息"));
  const md = message();
  const seed = new Uint8Array(32).fill(7);
  const pub = ed25519.getPublicKey(seed);
  const msg = new Uint8Array(256).fill(3);
  const sig = ed25519.sign(msg, seed);
  const pSecret = p256.utils.randomSecretKey();
  const pPub = p256.getPublicKey(pSecret);
  const pSig = p256.sign(msg, pSecret);
  const mib = new Uint8Array(1 << 20).fill(9);
  const key = new Uint8Array(32).fill(1);
  const nonce = new Uint8Array(12).fill(2);
  const sealed = chacha20poly1305(key, nonce).encrypt(mib);
  const rnd = (b: Uint8Array) => {
    for (let i = 0; i < b.length; i++) b[i] = (i * 31 + 7) & 255;
  };
  const session = pairSession("a".repeat(64), "b".repeat(64), ["w"]);

  const cases: Case[] = [
    { name: "json.stringify chats 6000 rows (" + Math.round(bigJson.length / 1024) + " KB)", runs: 15, run: () => JSON.stringify(big) },
    { name: "json.parse chats 6000 rows", runs: 15, run: () => JSON.parse(bigJson) },
    { name: "diffKeyed chats 6000, one row to top", runs: 15, run: () => diffKeyed(big, moved, spec) },
    { name: "applyKeyed that delta", runs: 15, run: () => applyKeyed(big, diffKeyed(big, moved, spec)) },
    { name: "markdown parse " + Math.round(md.length / 1024) + " KB message", runs: 15, run: () => parseMarkdown(md) },
    { name: "effect: 100k Effect.gen steps", runs: 9, run: () => Effect.runSync(Effect.gen(function* () { let n = 0; for (let i = 0; i < 100_000; i++) n += yield* Effect.succeed(i); return n; })) },
    { name: "effect: forEach 20k runPromise", runs: 9, run: () => Effect.runPromise(Effect.forEach(Array.from({ length: 20_000 }, (_, i) => i), (i) => Effect.sync(() => i + 1))) },
    { name: "ed25519 sign x20", runs: 7, run: () => { for (let i = 0; i < 20; i++) ed25519.sign(msg, seed); } },
    { name: "ed25519 verify x20", runs: 7, run: () => { for (let i = 0; i < 20; i++) ed25519.verify(sig, msg, pub); } },
    { name: "x25519 shared x20", runs: 7, run: () => { for (let i = 0; i < 20; i++) x25519.getSharedSecret(seed, pub); } },
    { name: "p256 verify x10", runs: 7, run: () => { for (let i = 0; i < 10; i++) p256.verify(pSig, msg, pPub); } },
    { name: "pair PAKE (ristretto255) start+keys x5", runs: 7, run: () => { for (let i = 0; i < 5; i++) { const a = pakeStart("123456", session, rnd); pakeKeys(a, a.share, "new"); } } },
    { name: "chacha20poly1305 decrypt 1 MiB", runs: 7, run: () => chacha20poly1305(key, nonce).decrypt(sealed) },
    { name: "sha256 1 MiB", runs: 7, run: () => sha256(mib) },
  ];
  const out: unknown[] = [];
  for (const c of cases) out.push(await time(c));
  B.gc();
  B.print(JSON.stringify({ micro: out, totalMs: Math.round(B.now() - t0), rssMB: Math.round(B.rss() / 1048576), heapMB: Math.round(B.heap() / 1048576) }));
  B.exit();
}
