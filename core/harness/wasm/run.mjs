// Runs every registry/conformance/*.json file through the shared core's WASM
// package in Node (ADR 0025), then reports the Brotli size of the .wasm file.
// Usage: node run.mjs <pkg dir from wasm-bindgen --target nodejs> <fixture dir>
import { createRequire } from "node:module";
import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";

const [pkgDir, fixtureDir] = process.argv.slice(2);
const require = createRequire(import.meta.url);
const core = require(path.resolve(pkgDir, "septena_core_wasm.js"));

const files = fs.readdirSync(fixtureDir).filter((f) => f.endsWith(".json")).sort();
if (files.length === 0) throw new Error(`no fixtures in ${fixtureDir}`);

const failures = [];
const times = [];
let cases = 0;
for (const file of files) {
  const fixture = file.replace(/\.json$/, "");
  const json = fs.readFileSync(path.join(fixtureDir, file), "utf8");
  for (let round = 0; round < 50; round++) {
    const start = process.hrtime.bigint();
    const report = JSON.parse(core.runConformance(fixture, json));
    times.push(Number(process.hrtime.bigint() - start) / 1e6);
    if (round === 0) {
      cases += report.cases;
      failures.push(...report.failures.map((f) => `${fixture}: ${f}`));
    }
  }
}

const id = JSON.parse(core.invoke("occurrenceId", JSON.stringify({ sourceTaskID: "task-1", scheduled: "2026-11-22" })));
if (id !== "recur-27f6e5d56dadf4cc") failures.push(`occurrenceId: got ${id}`);
const error = JSON.parse(core.invoke("planPullRow", JSON.stringify({ entity: "turn", row: { seq: 1 } })));
if (error.error !== "Pulled turn is missing taskId") failures.push(`planPullRow error: got ${JSON.stringify(error)}`);
let threw = false;
try { core.invoke("noSuchFunction", "{}"); } catch { threw = true; }
if (!threw) failures.push("invoke of an unknown function should throw");

times.sort((a, b) => a - b);
const p95 = times[Math.min(times.length - 1, Math.floor(times.length * 0.95))];
const wasmFile = fs.readdirSync(pkgDir).find((f) => f.endsWith(".wasm"));
const raw = fs.readFileSync(path.join(pkgDir, wasmFile));
const brotli = zlib.brotliCompressSync(raw, { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 11 } }).length;
console.log(`SEPTENA_CORE_METRICS platform=wasm-node cases=${cases} calls=${times.length} p95_ms_per_fixture=${p95.toFixed(3)} wasm_bytes=${raw.length} wasm_brotli_bytes=${brotli} version=${core.coreVersion()}`);

const budget = Number(process.env.BUDGET_WASM_BROTLI ?? 307200);
if (brotli > budget) failures.push(`WASM is ${brotli} bytes Brotli, over the ${budget} budget`);
if (p95 > 5) failures.push(`p95 per fixture run is ${p95.toFixed(3)} ms, over the 5 ms budget`);
if (failures.length) {
  for (const f of failures) console.error(f);
  process.exit(1);
}
