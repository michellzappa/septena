#!/usr/bin/env node
// retired-term: user copy uses a name the product no longer uses (ADR 0065).
//
// registry/retired-terms.json lists each retired word and the word to use
// instead. This lint scans the same copy as lint-platform-copy.mjs
// (scripts/lib/copy-scan.mjs): registry strings, backend/skill.md,
// backend/onboard.md, TasksSkill.swift and skills/*/SKILL.md. Terms match as
// whole words, ignoring case; a file name (docs/SEPTASK.md) is not a match.
// The site runs the same list over its rendered
// pages (septena/site scripts/check-copy.mjs --rendered).
//
// Exceptions:
//   - Markdown and Swift: `septena-lint:allow retired-term` on the line.
//   - JSON: ALLOW below, keyed by file and JSON path, with a reason. An entry
//     that no longer matches fails, so the list only shrinks.
//
// Run standalone: node scripts/lint-retired-terms.mjs. scripts/lint-design.sh
// runs it. Prints one line per violation; exit 1 on any.
import { readFileSync } from "node:fs";
import path from "node:path";
import { ROOT, lintCopy } from "./lib/copy-scan.mjs";

const file = JSON.parse(readFileSync(path.join(ROOT, "registry", "retired-terms.json"), "utf8"));
const errors = [];
if (file.version !== 1 || !Array.isArray(file.terms) || file.terms.length === 0) errors.push("registry/retired-terms.json: needs version 1 and a non-empty terms list");
for (const [i, t] of (file.terms ?? []).entries()) {
  for (const k of ["term", "use", "since", "adr"]) if (typeof t[k] !== "string" || !t[k]) errors.push(`registry/retired-terms.json: terms[${i}] needs "${k}"`);
  if (t.since && !/^\d{4}-\d{2}-\d{2}$/.test(t.since)) errors.push(`registry/retired-terms.json: terms[${i}].since must be YYYY-MM-DD`);
  if (t.adr && !/^\d{4}$/.test(t.adr)) errors.push(`registry/retired-terms.json: terms[${i}].adr must be a four-digit ADR number`);
  for (const k of Object.keys(t)) if (!["term", "use", "since", "adr", "note"].includes(k)) errors.push(`registry/retired-terms.json: terms[${i}] has unknown field "${k}"`);
}
if (errors.length) {
  for (const e of errors) console.log(e);
  process.exit(1);
}
const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const RULES = file.terms.map((t) => ({ ...t, re: new RegExp(`(?<![\\w/.-])${escape(t.term)}(?![\\w/-]|\\.\\w)`, "i") }));

const ALLOW = [
  { file: "registry/settings.json", path: "copy.ai_explainer[19].label", reason: "Whose turn it is in one conversation, not a list name." },
];

const hits = lintCopy({
  rule: "retired-term",
  script: "scripts/lint-retired-terms.mjs",
  test: (text) => {
    const t = RULES.find((r) => r.re.test(text));
    return t ? `"${t.term}" is retired (ADR ${t.adr}); use "${t.use}"` : null;
  },
  allow: ALLOW,
  // File paths and developer notes name code targets, which keep the working name.
  dataKeys: ["path", "notes"],
});

if (hits.length) {
  console.log("Copy uses a retired term (registry/retired-terms.json).");
  for (const hit of hits) console.log(hit);
  process.exit(1);
}
