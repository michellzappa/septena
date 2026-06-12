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
  const md = readFileSync(join(ROOT, "..", "docs", "APPSTORE.md"), "utf8");
  const platforms = [];
  const platRe = /^## Platform: (.+?) \((.+?)\)\s*$/gm;
  const blocks = [...md.matchAll(platRe)];
  blocks.forEach((m, i) => {
    const body = md.slice(m.index + m[0].length, blocks[i + 1]?.index ?? md.length);
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

const metadataDirFor = (platform) =>
  platform === "iOS" ? "metadata" : `metadata-${platform.toLowerCase().replace("os", "")}`; // macOS → metadata-mac

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
