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
// Scans (scripts/lib/copy-scan.mjs, shared with lint-retired-terms.mjs):
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
import { lintCopy } from "./lib/copy-scan.mjs";

const NAMES = /\b(iPhone|iPad|Mac|macOS|iOS|iPadOS|Windows|Android|Apple Watch|watchOS)\b/;

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

const hits = lintCopy({
  rule: "platform-copy",
  script: "scripts/lint-platform-copy.mjs",
  test: (text) => (NAMES.test(text) ? "names a platform" : null),
  allow: ALLOW,
});

if (hits.length) {
  console.log('Copy names a platform. Say "all your devices" or "another device"; per-platform detail belongs in per-platform data.');
  for (const hit of hits) console.log(hit);
  process.exit(1);
}
