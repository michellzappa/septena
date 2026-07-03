// Validate the App Store package and emit viz/manifest.json for the viz app.
//
//   node validate.mjs
//
// Checks (errors fail the exit code; warnings don't):
//   metadata    char limits (name 30, subtitle 30, promo 170, desc 4000, keywords 100)
//   screenshots exact device dimensions, 1–10 per device class, RGB (alpha → warn)
//   raw         capture inventory per device/appearance (info only)

import { readFileSync, readdirSync, existsSync, writeFileSync, mkdirSync, openSync, readSync, closeSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { allDevices } from "./devices.mjs";
import { panelsFor } from "./panels.config.mjs";
import { parseAppstoreMd, LIMITS } from "./metadata.mjs";

const ROOT = dirname(fileURLToPath(import.meta.url));
const issues = []; // { level: "error"|"warn", msg }
const err = (msg) => issues.push({ level: "error", msg });
const warn = (msg) => issues.push({ level: "warn", msg });

// PNG IHDR: width @16 BE, height @20 BE, bit depth @24, color type @25 (2=RGB, 6=RGBA).
function pngInfo(file) {
  const buf = Buffer.alloc(26);
  const fd = openSync(file, "r");
  readSync(fd, buf, 0, 26, 0);
  closeSync(fd);
  return { w: buf.readUInt32BE(16), h: buf.readUInt32BE(20), colorType: buf[25] };
}

// ----- metadata -----
const platforms = parseAppstoreMd();
const metadataReport = platforms.map((p) => {
  const fields = Object.entries(p.fields)
    .filter(([k]) => k !== "status")
    .map(([k, v]) => {
      const limit = LIMITS[k] ?? null;
      const count = v.length;
      const ok = limit === null || count <= limit;
      if (!ok && !p.planned) err(`${p.platform} ${k}: ${count} chars > limit ${limit}`);
      return { field: k, value: v, count, limit, ok };
    });
  return { platform: p.platform, bundleId: p.bundleId, planned: p.planned, fields };
});

// ----- screenshots + raw -----
const deviceReport = Object.entries(allDevices()).map(([key, d]) => {
  const outDir = join(ROOT, d.outDir);
  // Validate exactly the CURRENT panels' expected files (so a stale leftover
  // from a renamed/removed panel can't pollute the set — important where the
  // filesystem forbids deletes and render.mjs can't clean up).
  const expected = panelsFor(key).map((p, i) => `${i}_${key}_${p.id}.png`);
  const shots = expected.map((f) => {
    const fp = join(outDir, f);
    if (!existsSync(fp)) {
      if (d.active) err(`${key}/${f}: missing (run render.mjs)`);
      return { file: f, path: `${d.outDir}/${f}`, ok: false, problems: ["not rendered"] };
    }
    const { w, h, colorType } = pngInfo(fp);
    const sizeOk = w === d.width && h === d.height;
    const probs = [];
    if (!sizeOk) probs.push(`expected ${d.width}×${d.height}, got ${w}×${h}`);
    if (colorType === 6 || colorType === 4) probs.push("has alpha channel (ASC wants RGB)");
    if (d.active) for (const m of probs) (m.includes("alpha") ? warn : err)(`${key}/${f}: ${m}`);
    return { file: f, path: `${d.outDir}/${f}`, w, h, ok: sizeOk && colorType !== 6 && colorType !== 4, problems: probs };
  });
  if (d.active && shots.length > 10) err(`${key}: ${shots.length} panels > ASC max 10`);
  // Flag stray files matching this device that aren't current panels (cleanup hint).
  if (existsSync(outDir)) {
    for (const f of readdirSync(outDir)) {
      if (f.includes(`_${key}_`) && f.endsWith(".png") && !expected.includes(f)) {
        warn(`${key}: stray screenshot ${f} (not a current panel — safe to delete)`);
      }
    }
  }
  const raw = {};
  for (const ap of ["light", "dark"]) {
    const dir = join(ROOT, d.rawDir, ap);
    raw[ap] = existsSync(dir)
      ? readdirSync(dir).filter((f) => f.endsWith(".png")).sort()
        .map((f) => ({ file: f, path: `${d.rawDir}/${ap}/${f}` }))
      : [];
  }
  // Parity guard: a panel that declares a `shot` must have its raw capture, or
  // render.mjs silently substitutes a branded placeholder that still passes the
  // dimension checks above. Statement panels (no `shot`, e.g. privacy/close) are
  // intentionally shot-less and exempt. This is what stops a placeholder from
  // shipping with copy that promises a screenshot.
  if (d.active) {
    const have = new Set((raw.light ?? []).map((r) => r.file));
    for (const p of panelsFor(key)) {
      if (p.shot?.src && !have.has(`${p.shot.src}.png`)) {
        err(`${key}/${p.id}: panel copy promises a screenshot but raw "${p.shot.src}.png" is missing → a placeholder would ship. Run appstore/capture.sh ${key}.`);
      }
    }
  }
  return {
    key, label: d.label, active: d.active, width: d.width, height: d.height,
    platform: d.platform, captureNote: d.captureNote,
    panelsConfigured: panelsFor(key).length, shots, raw,
  };
});

// ----- manifest for the viz -----
const manifest = {
  generatedAt: new Date().toISOString(),
  app: { name: platforms[0]?.fields.name?.trim() ?? "Septena", bundleId: platforms[0]?.bundleId },
  metadata: metadataReport,
  devices: deviceReport,
  issues,
};
mkdirSync(join(ROOT, "viz"), { recursive: true });
writeFileSync(join(ROOT, "viz", "manifest.json"), JSON.stringify(manifest, null, 2));

for (const i of issues) console.log(`${i.level === "error" ? "✗" : "⚠"} ${i.msg}`);
const errors = issues.filter((i) => i.level === "error").length;
console.log(`${errors ? "✗" : "✓"} validate: ${errors} error(s), ${issues.length - errors} warning(s) → viz/manifest.json`);
process.exit(errors ? 1 : 0);
