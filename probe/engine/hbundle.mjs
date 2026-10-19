// Any entry to Hermes bytecode exactly as scripts/hermes-bundle.ts makes the app's (esbuild ES2020 IIFE, Babel's class
// transform, hermesc -O -block-scoping), without its not-carried check (a bench entry is not the app's).
//   HERMESC=… node bench/engine/hbundle.mjs <entry.ts> <out.js> <out.hbc>
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { transformSync } from "@babel/core";
import { build } from "esbuild";
const [entry, out, hbc] = process.argv.slice(2);
await build({ entryPoints: [entry], bundle: true, format: "iife", platform: "neutral", mainFields: ["module", "main"], target: "es2020", minifyWhitespace: true, minifySyntax: true, minifyIdentifiers: true, legalComments: "none", outfile: out, logLevel: "warning" });
const lowered = transformSync(readFileSync(out, "utf8"), { babelrc: false, configFile: false, compact: true, plugins: ["@babel/plugin-transform-classes"] });
writeFileSync(out, lowered.code);
execFileSync(process.env.HERMESC, ["-emit-binary", "-O", "-block-scoping", "-out", hbc, out], { stdio: "inherit" });
