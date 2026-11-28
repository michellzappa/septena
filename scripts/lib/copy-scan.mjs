// The user copy that the app's copy lints read (lint-platform-copy.mjs,
// lint-retired-terms.mjs): every string value in registry/*.json and
// registry/cast/*.json, minus data files and data keys, and the agent briefs
// line by line. One list, so the lints never disagree about what is copy.
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

// Registry files that are data, not copy.
const DATA_FILES = new Set([
  "capabilities.json", // per-platform status cells and platform ids
  "device-frames.json", // device frame geometry per platform
  "entities.json", // sync wire schema
  "readers-allowlist.json", // generator bookkeeping
  "icons.json", // symbol names per platform
  "retired-terms.json", // the retired words themselves
]);
// Keys whose value is data in any registry file.
const DATA_KEYS = new Set(["id", "ids", "key", "keys", "platform", "platforms", "icon", "symbol", "sfSymbol", "material", "lucide", "url", "href", "bundleId", "productId", "$schema", "$comment"]);
// A root-level `description` documents the file for developers.
const ROOT_DOC_KEYS = new Set(["description"]);

const SKILL_FILES = readdirSync(path.join(ROOT, "skills"), { withFileTypes: true })
  .filter((d) => d.isDirectory()).map((d) => `skills/${d.name}/SKILL.md`).sort();
const LINE_FILES = ["backend/skill.md", "backend/onboard.md", "Septena/Shell/Tasks/TasksSkill.swift", ...SKILL_FILES];

/**
 * Every copy string. JSON strings come as { file, path, text }; lines of the
 * Markdown and Swift briefs as { file, line, text }. `dataKeys` adds keys that
 * are data for one lint only (a file path, a developer note).
 */
export function copyStrings({ dataKeys = [] } = {}) {
  const skip = new Set([...DATA_KEYS, ...dataKeys]);
  const out = [];
  const walk = (file, value, p, depth) => {
    if (typeof value === "string") out.push({ file, path: p, text: value });
    else if (Array.isArray(value)) value.forEach((v, i) => walk(file, v, `${p}[${i}]`, depth + 1));
    else if (value && typeof value === "object") {
      for (const [key, v] of Object.entries(value)) {
        if (skip.has(key)) continue;
        if (depth === 0 && ROOT_DOC_KEYS.has(key)) continue;
        walk(file, v, p ? `${p}.${key}` : key, depth + 1);
      }
    }
  };
  const jsonFiles = [
    ...readdirSync(path.join(ROOT, "registry")).filter((f) => f.endsWith(".json") && !DATA_FILES.has(f)).map((f) => `registry/${f}`),
    ...readdirSync(path.join(ROOT, "registry", "cast")).filter((f) => f.endsWith(".json")).map((f) => `registry/cast/${f}`),
  ];
  for (const file of jsonFiles) walk(file, JSON.parse(readFileSync(path.join(ROOT, file), "utf8")), "", 0);
  for (const file of LINE_FILES) {
    readFileSync(path.join(ROOT, file), "utf8").split("\n").forEach((text, i) => out.push({ file, line: i + 1, text }));
  }
  return out;
}

/**
 * Runs one rule over the copy. `test(text)` returns a reason string or null.
 * JSON exceptions are `allow` entries keyed by file and path; a Markdown or
 * Swift line is excepted by `septena-lint:allow <rule>` on it. An allow entry
 * that no longer matches is a hit, so the list only shrinks. Returns the hits.
 */
export function lintCopy({ rule, script, test, allow = [], dataKeys = [] }) {
  const key = (file, p) => `${file}#${p}`;
  const allowed = new Set(allow.map((a) => key(a.file, a.path)));
  const used = new Set();
  const hits = [];
  for (const s of copyStrings({ dataKeys })) {
    const reason = test(s.text);
    if (!reason) continue;
    if (s.line !== undefined) {
      if (!s.text.includes(`septena-lint:allow ${rule}`)) hits.push(`${s.file}:${s.line}: ${reason}: ${s.text.trim().slice(0, 160)}`);
    } else if (allowed.has(key(s.file, s.path))) used.add(key(s.file, s.path));
    else hits.push(`${s.file}: ${s.path}: ${reason}: "${s.text.slice(0, 120)}"`);
  }
  for (const a of allow) {
    if (!used.has(key(a.file, a.path))) hits.push(`${a.file}: ${a.path}: allow entry no longer matches; remove it from ${script}`);
  }
  return hits;
}
