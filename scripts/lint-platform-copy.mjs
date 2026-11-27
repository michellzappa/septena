#!/usr/bin/env node
// platform-copy: user copy names a platform.
//
// mz, 2026-11-26: every platform gets every feature. Copy says "all your
// devices" or "another device", never a list of platforms and never which
// platform lacks something. Per-platform detail lives only in per-platform
// data (registry/capabilities.json, the site's comparison table, the
// changelog). The site (septena/site) runs the same rule on
// its pages.
//
// Scans:
//   - every string value in registry/*.json and registry/cast/*.json, minus the
//     data files and data keys listed below;
//   - backend/skill.md, backend/onboard.md, Septena/Shell/Tasks/TasksSkill.swift
//     and skills/*/SKILL.md, line by line.
// It flags iPhone, iPad, Mac, macOS, iOS, iPadOS, Windows, Android, Apple
// Watch and watchOS. A "web app" in a platform list always sits next to one of
// these names, so the list is caught by them.
//
// Exceptions:
//   - Markdown and Swift: `septena-lint:allow platform-copy` on the line, with
//     the reason next to it or in a comment above.
//   - JSON cannot hold comments: ALLOW below, keyed by file and JSON path, each
//     with a category and a reason. An entry that no longer matches fails, so
//     the list only shrinks.
//
// Run standalone: node scripts/lint-platform-copy.mjs. scripts/lint-design.sh
// runs it. Prints one line per violation; exit 1 on any.
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const NAMES = /\b(iPhone|iPad|Mac|macOS|iOS|iPadOS|Windows|Android|Apple Watch|watchOS)\b/;

// Registry files that are data, not copy.
const DATA_FILES = new Set([
  "capabilities.json", // per-platform status cells and platform ids
  "device-frames.json", // device frame geometry per platform
  "entities.json", // sync wire schema
  "readers-allowlist.json", // generator bookkeeping
  "icons.json", // symbol names per platform
]);
// Keys whose value is data in any registry file.
const DATA_KEYS = new Set(["id", "ids", "key", "keys", "platform", "platforms", "icon", "symbol", "sfSymbol", "material", "lucide", "url", "href", "bundleId", "productId", "$schema", "$comment"]);
// A root-level `description` documents the file for developers.
const ROOT_DOC_KEYS = new Set(["description"]);

// category "control-location": the line says where a control is on one
// platform. Open question for mz (2026-11-26): keep, or move into per-platform
// data. Allowed until mz decides.
const ALLOW = [
  { file: "registry/surfaces.json", path: "notices.items[0].platformDetails[0].detail", category: "this-device", reason: "Per-platform variant, shown only on that device: names the device the user holds." },
  { file: "registry/surfaces.json", path: "notices.items[0].platformDetails[1].detail", category: "this-device", reason: "Per-platform variant, shown only on that device: names the device the user holds." },
  { file: "registry/surfaces.json", path: "notices.items[0].platformDetails[2].detail", category: "this-device", reason: "Per-platform variant, shown only on that device: names the device the user holds." },
  { file: "registry/surfaces.json", path: "notices.items[2].steps[2].platformDetails[0].detail", category: "control-location", reason: "Says where the global capture shortcut works." },
  { file: "registry/surfaces.json", path: "taskDetail.controls.historyYouOnMac", category: "device-attribution", reason: "History names the device that made a change." },
  { file: "registry/surfaces.json", path: "taskDetail.controls.historyYouOnIphone", category: "device-attribution", reason: "History names the device that made a change." },
  { file: "registry/settings.json", path: "copy.access_devices[5].label", category: "device-name", reason: "The kind of a signed-in device in Settings > Account > Devices." },
  { file: "registry/settings.json", path: "copy.access_devices[6].label", category: "device-name", reason: "The kind of a signed-in device in Settings > Account > Devices." },
  { file: "registry/settings.json", path: "copy.access_devices[7].label", category: "device-name", reason: "The kind of a signed-in device in Settings > Account > Devices." },
  { file: "registry/settings.json", path: "copy.access_devices[8].label", category: "device-name", reason: "The kind of a signed-in device in Settings > Account > Devices." },
];

const SKILL_FILES = readdirSync(path.join(ROOT, "skills"), { withFileTypes: true })
  .filter((d) => d.isDirectory()).map((d) => `skills/${d.name}/SKILL.md`).sort();
const LINE_FILES = ["backend/skill.md", "backend/onboard.md", "Septena/Shell/Tasks/TasksSkill.swift", ...SKILL_FILES];

const hits = [];
const used = new Set();
const allowKey = (file, p) => `${file}#${p}`;
const allowed = new Map(ALLOW.map((a) => [allowKey(a.file, a.path), a]));

function walk(file, value, p, depth) {
  if (typeof value === "string") {
    if (!NAMES.test(value)) return;
    const k = allowKey(file, p);
    if (allowed.has(k)) used.add(k);
    else hits.push(`${file}: ${p}: "${value.slice(0, 120)}"`);
  } else if (Array.isArray(value)) {
    value.forEach((v, i) => walk(file, v, `${p}[${i}]`, depth + 1));
  } else if (value && typeof value === "object") {
    for (const [key, v] of Object.entries(value)) {
      if (DATA_KEYS.has(key)) continue;
      if (depth === 0 && ROOT_DOC_KEYS.has(key)) continue;
      walk(file, v, p ? `${p}.${key}` : key, depth + 1);
    }
  }
}

const jsonFiles = [
  ...readdirSync(path.join(ROOT, "registry")).filter((f) => f.endsWith(".json") && !DATA_FILES.has(f)).map((f) => `registry/${f}`),
  ...readdirSync(path.join(ROOT, "registry", "cast")).filter((f) => f.endsWith(".json")).map((f) => `registry/cast/${f}`),
];
for (const file of jsonFiles) walk(file, JSON.parse(readFileSync(path.join(ROOT, file), "utf8")), "", 0);

for (const file of LINE_FILES) {
  readFileSync(path.join(ROOT, file), "utf8").split("\n").forEach((line, i) => {
    if (NAMES.test(line) && !line.includes("septena-lint:allow platform-copy")) hits.push(`${file}:${i + 1}: ${line.trim().slice(0, 160)}`);
  });
}

for (const a of ALLOW) {
  if (!used.has(allowKey(a.file, a.path))) hits.push(`${a.file}: ${a.path}: allow entry no longer matches; remove it from scripts/lint-platform-copy.mjs`);
}

if (hits.length) {
  console.log('Copy names a platform. Say "all your devices" or "another device"; per-platform detail belongs in per-platform data.');
  for (const hit of hits) console.log(hit);
  process.exit(1);
}
