// Validate the App Store package and write review.<app>.json, the review data
// the website's /about/brand page shows (septena-site scripts/sync-appstore.mjs).
//
//   node validate.mjs
//
// Checks (errors fail the exit code; warnings don't):
//   metadata    char limits (name 30, subtitle 30, promo 170, desc 4000, keywords 100)
//   screenshots exact device dimensions, 1–10 per device class, RGB (alpha → warn)
//   copy        no em/en dashes or <placeholders> in any field; keywords with
//               no space after a comma, no empty or repeated keyword
//   panels      (## Screenshots tables, Bipe's rules) unique slugs, at most
//               10 rows, title <= 28 chars without *marks* (a two-part title
//               "Claim. How.": claim <= 32, whole <= 90), sub <= 90 chars and
//               one sentence, scene screen exists, callout element is on it
//   raw         capture inventory per device/appearance (info only)

import { readFileSync, readdirSync, existsSync, writeFileSync, mkdirSync, openSync, readSync, closeSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { allDevices, shotPaths } from "./devices.mjs";
import { currentApp } from "./apps.mjs";
import { panelsFor } from "./panels.config.mjs";
import { parseAppstoreMd, parseScreenshots, LIMITS } from "./metadata.mjs";

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

// ----- copy rules (Bipe's check-appstore) -----
const DASH = /[\u2013\u2014]/;
for (const p of platforms) {
  if (p.planned) continue;
  for (const [k, v] of Object.entries(p.fields)) {
    if (DASH.test(v)) err(`${p.platform} ${k}: contains an em or en dash`);
    if (/<[a-z][^>]*>/i.test(v)) err(`${p.platform} ${k}: contains a <placeholder>`);
  }
  const kw = p.fields.keywords ?? "";
  if (/,\s/.test(kw)) err(`${p.platform} keywords: space after a comma wastes a character`);
  const words = kw.split(",").map((w) => w.trim().toLowerCase());
  if (words.some((w) => !w)) err(`${p.platform} keywords: empty keyword`);
  const dup = words.filter((w, i) => w && words.indexOf(w) !== i);
  if (dup.length) err(`${p.platform} keywords: repeated ${[...new Set(dup)].join(", ")}`);
}

// ----- panel copy ("## Screenshots" tables) -----
const TABLE_FOR = { iphone69: "iPhone", ipad13: "iPad", mac: "Mac" };
const tables = parseScreenshots();
for (const [device, rows] of Object.entries(tables)) {
  if (rows.length > 10) err(`panels ${device}: ${rows.length} rows > ASC max 10`);
  const seen = new Set();
  for (const r of rows) {
    const where = `panels ${device}/${r.slug || "?"}`;
    if (!/^[a-z0-9-]+$/.test(r.slug ?? "")) err(`${where}: slug must be lowercase letters, digits and dashes`);
    if (seen.has(r.slug)) err(`${where}: duplicate slug`);
    seen.add(r.slug);
    const title = (r.title ?? "").replace(/\*/g, "");
    if (!title) err(`${where}: no title`);
    // One sentence: at most 28 characters. "Claim. How it works.": the claim at most
    // 32, the whole title at most 90 (both parts render at one size).
    const cut = title.indexOf(". ");
    if (cut < 0 && title.length > 28) err(`${where}: title ${title.length} chars > 28`);
    if (cut >= 0 && (cut + 1 > 32 || title.length > 90)) err(`${where}: two-part title: claim ${cut + 1} chars (max 32), whole ${title.length} (max 90)`);
    if ((r.sub ?? "").length > 90) err(`${where}: sub ${r.sub.length} chars > 90`);
    if ((r.sub ?? "").split(/[.!?](?:\s|$)/).filter((x) => x.trim()).length > 1) err(`${where}: sub is more than one sentence`);
    for (const f of ["title", "sub"]) if (DASH.test(r[f] ?? "")) err(`${where}: ${f} contains an em or en dash`);
  }
}

// ----- screenshots + raw -----
let sceneSource = null;
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
      if (!p.shot?.src) continue;
      // Each shot in the appearance and accent it renders with (export-scenes.mjs).
      for (const extra of p.shots ?? []) {
        if (d.sceneDir && !existsSync(shotPaths(d, extra.src, extra.appearance ?? "light", extra.accent ?? null).png)) err(`${key}/${p.id}: extra phone "${extra.src}" is missing. ${d.captureNote}.`);
      }
      const { png, elements } = shotPaths(d, p.shot.src, p.shot.appearance ?? "light", p.shot.accent ?? null);
      const ok = d.sceneDir ? existsSync(png) : have.has(`${p.shot.src}.png`);
      if (!ok) {
        err(`${key}/${p.id}: panel copy promises a screenshot but "${p.shot.src}" is missing → a placeholder would ship. ${d.captureNote}.`);
        continue;
      }
      const el = p.shot.callout?.element;
      if (el) {
        const list = elements && existsSync(elements) ? JSON.parse(readFileSync(elements, "utf8")).elements : [];
        if (!list.some((e) => e.id === el)) err(`${key}/${p.id}: callout element "${el}" is not on screen ${p.shot.src}`);
      }
    }
    if (d.sceneDir) {
      // The scene-colour set and every accent set carry a manifest; read the first one.
      const sets = [join(ROOT, d.sceneDir, "manifest.json"), ...[...new Set(panelsFor(key).map((p) => p.shot?.accent).filter(Boolean))].map((a) => join(ROOT, d.sceneDir, `accent-${a}`, "manifest.json"))];
      const mf = sets.find(existsSync) ?? sets[0];
      if (!existsSync(mf)) err(`${key}: ${d.sceneDir}/manifest.json missing. ${d.captureNote}.`);
      else {
        const m = JSON.parse(readFileSync(mf, "utf8"));
        sceneSource = { fixture: m.fixtureRevision, site: m.sourceRevision?.slice(0, 8), scale: m.scale };
        if (m.scale < 3) warn(`${key}: scenes exported at ${m.scale}x; store panels want SCENE_SCALE=3`);
      }
    }
    if (TABLE_FOR[key] && d.sceneDir && !(tables[TABLE_FOR[key]]?.length)) err(`${key}: no "### ${TABLE_FOR[key]}" rows in ## Screenshots`);
  }
  return {
    key, label: d.label, registryDevice: d.registryDevice ?? null, active: d.active, width: d.width, height: d.height,
    platform: d.platform, captureNote: d.captureNote,
    panelsConfigured: panelsFor(key).length, shots, raw,
  };
});

// ----- review data for the website (/about/brand, the App Store section) -----
const manifest = {
  generatedAt: new Date().toISOString(),
  app: { name: platforms[0]?.fields.name?.trim() ?? "Septena", bundleId: platforms[0]?.bundleId },
  metadata: metadataReport,
  sceneSource,
  devices: deviceReport,
  issues,
};
const REVIEW = join(ROOT, `review.${currentApp().key}.json`);
writeFileSync(REVIEW, JSON.stringify(manifest, null, 2) + "\n");

for (const i of issues) console.log(`${i.level === "error" ? "✗" : "⚠"} ${i.msg}`);
const errors = issues.filter((i) => i.level === "error").length;
console.log(`${errors ? "✗" : "✓"} validate: ${errors} error(s), ${issues.length - errors} warning(s) → ${REVIEW.split("/").pop()}`);
process.exit(errors ? 1 : 0);
