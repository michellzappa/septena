// Render marketing panels → App Store-ready PNGs at exact ASC pixel sizes.
//
//   node render.mjs [--device iphone69] [--appearance light] [--only <panelId>]
//
// Pipeline per active device: panels.config.mjs composition → components.mjs
// HTML (debug copies kept in build/<device>/) → Playwright Chromium screenshot
// at devices.mjs dimensions → <outDir>/<n>_<device>_<id>.png. Raw captures are
// read from raw/<device>/<appearance>/ (see sync-shots.sh); missing ones get a
// branded placeholder so the pipeline never blocks on capture order.
// If python3+Pillow is available, alpha is flattened (ASC wants RGB, no alpha).

import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync, unlinkSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import { chromium } from "playwright";
import { activeDevices } from "./devices.mjs";
import { panelsFor } from "./panels.config.mjs";
import { renderPanelHTML } from "./components.mjs";

const ROOT = dirname(fileURLToPath(import.meta.url));
const arg = (name, dflt) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > -1 ? process.argv[i + 1] : dflt;
};
const appearance = arg("appearance", "light");
const onlyDevice = arg("device", null);
const onlyPanel = arg("only", null);

// Brand serif, inlined so panels use the genuine Fraunces regardless of
// what's installed. Same file serves italic (Fraunces variable has the axes).
const fontPath = join(ROOT, "..", "Septena", "Resources", "Fraunces-Regular.ttf");
const fontFace = existsSync(fontPath)
  ? ["normal", "italic"].map((style) =>
      `@font-face { font-family:"Fraunces"; font-style:${style}; font-weight:100 900;
       src:url(data:font/ttf;base64,${readFileSync(fontPath).toString("base64")}) format("truetype"); }`
    ).join("\n")
  : "/* Fraunces not found — falling back to Georgia */";

const shotDataURL = (device, src) => {
  const p = join(ROOT, device.rawDir, appearance, `${src}.png`);
  return existsSync(p) ? `data:image/png;base64,${readFileSync(p).toString("base64")}` : null;
};

let canFlatten = true;
const flattenAlpha = (file) => {
  if (!canFlatten) return;
  try {
    execFileSync("python3", ["-c",
      `from PIL import Image; im=Image.open(${JSON.stringify(file)}).convert("RGB"); im.save(${JSON.stringify(file)})`],
      { stdio: "pipe" });
  } catch { canFlatten = false; } // no python3/Pillow — validate.mjs will warn
};

const browser = await chromium.launch();
const page = await browser.newPage();

for (const device of activeDevices()) {
  if (onlyDevice && device.key !== onlyDevice) continue;
  const list = panelsFor(device.key);
  if (!list.length) { console.log(`· ${device.key}: no panels configured, skipping`); continue; }

  const outDir = join(ROOT, device.outDir);
  const buildDir = join(ROOT, "build", device.key);
  mkdirSync(outDir, { recursive: true });
  mkdirSync(buildDir, { recursive: true });

  // Clear this device class's previous renders (other classes share en-US/).
  for (const f of readdirSync(outDir)) if (f.includes(`_${device.key}_`)) unlinkSync(join(outDir, f));

  await page.setViewportSize({ width: device.width, height: device.height });
  for (const [i, panel] of list.entries()) {
    if (onlyPanel && panel.id !== onlyPanel) continue;
    const html = renderPanelHTML(
      { ...panel, shot: panel.shot && { ...panel.shot, img: shotDataURL(device, panel.shot.src) } },
      device,
      { fontFace, appearance },
    );
    writeFileSync(join(buildDir, `${i}_${panel.id}.html`), html);
    await page.setContent(html, { waitUntil: "load" });
    await page.evaluate(() => document.fonts.ready);
    const file = join(outDir, `${i}_${device.key}_${panel.id}.png`);
    await page.screenshot({ path: file });
    flattenAlpha(file);
    const missing = panel.shot && !panel.shot.img && shotDataURL(device, panel.shot.src) === null;
    console.log(`✓ ${device.key} ${i}_${panel.id} ${device.width}×${device.height}${missing ? "  (placeholder shot)" : ""}`);
  }
}

await browser.close();
if (!canFlatten) console.log("⚠ alpha not flattened (python3+Pillow unavailable) — validate.mjs will flag it");
