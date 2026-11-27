#!/usr/bin/env node
// Septena conformance runner (agent spec v0, https://septena.app/spec.md).
//
// Usage:
//   node run.mjs <impl.mjs> [--dir <vectors folder>] [--only <file>]
//
// <impl.mjs> exports one object per vector file (the file name without
// `.json`, with `-x` turned into `X`: task-dates.json is `taskDates`), and in
// it one function per suite it implements:
//
//   export const refs = { normalizeRefKey: (c, ctx) => myNormalize(c.input) };
//
// Each function gets the case and the file's context (its top-level fields
// that are not lists, such as `today`) and returns its result, or a promise of
// it. The runner compares the result with the case's `expected`: deep
// equality, key order ignored, a field set to undefined counts as absent.
// A suite the module does not export is skipped. Exit code 1 when a case fails.
//
// No dependencies: Node 20 or newer.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const args = process.argv.slice(2);
function flag(name) {
  const i = args.indexOf(name);
  if (i === -1) return null;
  const value = args[i + 1];
  args.splice(i, 2);
  return value ?? null;
}

const dir = path.resolve(flag("--dir") ?? path.dirname(fileURLToPath(import.meta.url)));
const only = flag("--only");
const implPath = args[0];
if (!implPath) {
  console.error("usage: node run.mjs <impl.mjs> [--dir <vectors folder>] [--only <file>]");
  process.exit(2);
}

/// `task-dates` → `taskDates`.
export function exportName(file) {
  return file.replace(/\.json$/, "").replace(/-([a-z0-9])/g, (_, ch) => ch.toUpperCase());
}

/// JSON with sorted keys and undefined fields dropped.
export function canonical(value) {
  if (value === undefined) return "null";
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map((v) => (v === undefined ? "null" : canonical(v))).join(",")}]`;
  const keys = Object.keys(value).filter((k) => value[k] !== undefined).sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`).join(",")}}`;
}

const impl = await import(pathToFileURL(path.resolve(implPath)).href);
const files = fs.readdirSync(dir).filter((f) => f.endsWith(".json") && (!only || f === only || f === `${only}.json`)).sort();
if (!files.length) {
  console.error(`no vector files in ${dir}`);
  process.exit(2);
}

let passed = 0;
let failed = 0;
let skipped = 0;
for (const file of files) {
  const data = JSON.parse(fs.readFileSync(path.join(dir, file), "utf8"));
  const context = Object.fromEntries(Object.entries(data).filter(([, v]) => !Array.isArray(v)));
  const module = impl[exportName(file)] ?? {};
  for (const [suite, cases] of Object.entries(data)) {
    if (!Array.isArray(cases)) continue;
    const fn = module[suite];
    if (typeof fn !== "function") {
      skipped += cases.length;
      console.log(`skip  ${file} ${suite} (${cases.length})`);
      continue;
    }
    let suiteFailed = 0;
    for (const [i, c] of cases.entries()) {
      let actual;
      try {
        actual = await fn(c, context);
      } catch (e) {
        actual = { thrown: e instanceof Error ? e.message : String(e) };
      }
      if (canonical(actual) === canonical(c.expected)) {
        passed++;
      } else {
        failed++;
        suiteFailed++;
        console.log(`FAIL  ${file} ${suite} #${i}${c.name ? ` ${c.name}` : ""}`);
        console.log(`      expected ${canonical(c.expected)}`);
        console.log(`      actual   ${canonical(actual)}`);
      }
    }
    console.log(`${suiteFailed ? "fail" : "pass"}  ${file} ${suite} (${cases.length - suiteFailed}/${cases.length})`);
  }
}

console.log(`\n${passed} passed, ${failed} failed, ${skipped} skipped`);
process.exit(failed ? 1 : 0);
