// docs/APPSTORE.md → fastlane deliver metadata files.
//
//   node metadata.mjs
//
// Parses the canonical metadata doc (see its "Parse rules" header) and emits
// metadata/<locale>/<field>.txt (localized) + metadata/<field>.txt
// (non-localized), per platform: iOS → metadata/, macOS → metadata-mac/.
// Platforms whose `status` is "planned" are parsed but not emitted.

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { currentApp } from "./apps.mjs";

const ROOT = dirname(fileURLToPath(import.meta.url));
const LOCALE = "en-US";

export const LIMITS = {
  name: 30, subtitle: 30, promotional_text: 170,
  description: 4000, keywords: 100, release_notes: 4000,
};
const LOCALIZED = new Set([
  "name", "subtitle", "promotional_text", "description", "keywords",
  "release_notes", "support_url", "marketing_url", "privacy_url",
]);
const NON_LOCALIZED = new Set(["copyright", "primary_category", "secondary_category"]);

export function parseAppstoreMd() {
  const md = readFileSync(join(ROOT, "..", ...currentApp().metadataDoc.split("/")), "utf8");
  const platforms = [];
  const platRe = /^## Platform: (.+?) \((.+?)\)\s*$/gm;
  const blocks = [...md.matchAll(platRe)];
  blocks.forEach((m, i) => {
    // A platform ends at the next level-2 heading (another platform, or
    // ## Screenshots / ## Workflow), so later sections never leak in as fields.
    const rest = md.slice(m.index + m[0].length);
    const end = rest.search(/^## /m);
    const body = end === -1 ? rest : rest.slice(0, end);
    const fields = {};
    const fieldRe = /^### (\w+)\s*$/gm;
    const fm = [...body.matchAll(fieldRe)];
    fm.forEach((f, j) => {
      const raw = body.slice(f.index + f[0].length, fm[j + 1]?.index ?? body.length);
      // Drop blockquote annotations and horizontal rules from values.
      const val = raw.split("\n").filter((l) => !l.startsWith(">")).join("\n")
        .split("\n---")[0].trim();
      fields[f[1]] = val;
    });
    platforms.push({ platform: m[1], bundleId: m[2], fields, planned: fields.status === "planned" });
  });
  return platforms;
}

// "## Screenshots" → { iPhone: [{ slug, scene, callout, title, sub }], … }.
// One table per "### <device>" heading; columns come from the header row.
export function parseScreenshots() {
  const md = readFileSync(join(ROOT, "..", ...currentApp().metadataDoc.split("/")), "utf8");
  const start = md.search(/^## Screenshots\s*$/m);
  if (start === -1) return {};
  const rest = md.slice(start).replace(/^## Screenshots\s*$/m, "");
  const section = rest.slice(0, rest.search(/^## /m) === -1 ? rest.length : rest.search(/^## /m));
  const out = {};
  const heads = [...section.matchAll(/^### (.+?)\s*$/gm)];
  heads.forEach((h, i) => {
    const body = section.slice(h.index + h[0].length, heads[i + 1]?.index ?? section.length);
    const rows = body.split("\n").filter((l) => l.trim().startsWith("|"))
      .map((l) => l.trim().replace(/^\||\|$/g, "").split("|").map((c) => c.trim()));
    if (rows.length < 2) { out[h[1]] = []; return; }
    const [cols, , ...data] = rows; // header, --- separator, rows
    out[h[1]] = data.map((cells) => Object.fromEntries(cols.map((c, j) => [c, cells[j] ?? ""])));
  });
  return out;
}

// iOS → the app's metadata dir; anything else (macOS) → its mac metadata dir.
const metadataDirFor = (platform) => {
  const app = currentApp();
  return platform === "iOS" ? app.metadataDir : app.metadataMacDir;
};

if (import.meta.url === `file://${process.argv[1]}`) {
  for (const p of parseAppstoreMd()) {
    if (p.planned) { console.log(`· ${p.platform}: planned, skipped`); continue; }
    const base = join(ROOT, metadataDirFor(p.platform));
    mkdirSync(join(base, LOCALE), { recursive: true });
    for (const [field, value] of Object.entries(p.fields)) {
      if (LOCALIZED.has(field)) writeFileSync(join(base, LOCALE, `${field}.txt`), value + "\n");
      else if (NON_LOCALIZED.has(field)) writeFileSync(join(base, `${field}.txt`), value + "\n");
    }
    console.log(`✓ ${p.platform} (${p.bundleId}) → ${metadataDirFor(p.platform)}/`);
  }
}
