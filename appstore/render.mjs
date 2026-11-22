// Render marketing panels → App Store-ready PNGs at exact ASC pixel sizes.
//
//   node render.mjs [--device iphone69] [--appearance light] [--only <panelId>]
//
// Pipeline per active device: panels.config.mjs composition → components.mjs
// HTML (kept in build/<device>/) → installed Chrome (chrome.mjs) screenshot
// at devices.mjs dimensions → <outDir>/<n>_<device>_<id>.png. Screens come
// from the scene builder export (appstore/scenes/) for classes that use it,
// else from raw/<device>/<appearance>/. Missing ones get a branded
// placeholder, and validate.mjs then refuses the set.
// If python3+Pillow is available, alpha is flattened (ASC wants RGB, no alpha).

import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync, unlinkSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import { openChrome } from "./chrome.mjs";
import { activeDevices, shotPaths } from "./devices.mjs";
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

const firstExisting = (paths) => paths.find((p) => existsSync(p));
const fontDataUrl = (file) => `url(data:font/otf;base64,${readFileSync(file).toString("base64")}) format("opentype")`;
const newYorkRegular = firstExisting([
  "/Library/Fonts/NewYorkLarge-Semibold.otf",
  "/System/Library/Fonts/NewYork.ttf",
]);
const newYorkItalic = firstExisting([
  "/Library/Fonts/NewYorkLarge-SemiboldItalic.otf",
  "/Library/Fonts/NewYorkItalic.ttf",
  "/System/Library/Fonts/NewYorkItalic.ttf",
]);
const fontFace = [
  newYorkRegular
    ? `@font-face { font-family:"New York Large"; font-weight:600; font-style:normal; src:${fontDataUrl(newYorkRegular)}; }`
    : "/* New York Semibold not found — falling back to system serif */",
  newYorkItalic
    ? `@font-face { font-family:"New York Large"; font-weight:600; font-style:italic; src:${fontDataUrl(newYorkItalic)}; }`
    : "/* New York Semibold Italic not found — falling back to system serif italic */",
].join("\n");

const shotDataURL = (device, src) => {
  const { png } = shotPaths(device, src, appearance);
  return existsSync(png) ? `data:image/png;base64,${readFileSync(png).toString("base64")}` : null;
};
// The scene's element list ({ width, height, elements:[{id,label,frame}] }),
// so a callout can point at real on-screen text. Fails closed: a callout
// whose element is missing stops the render.
const shotElements = (device, src) => {
  const { elements } = shotPaths(device, src, appearance);
  return elements && existsSync(elements) ? JSON.parse(readFileSync(elements, "utf8")) : null;
};

let canFlatten = true;
// Chrome's screenshots of an opaque page are already RGB (PNG colour type 2).
// Flatten only a file that really carries alpha.
const flattenAlpha = (file) => {
  if (readFileSync(file).subarray(25, 26)[0] !== 6) return;
  if (!canFlatten) return;
  try {
    execFileSync("python3", ["-c",
      `from PIL import Image; im=Image.open(${JSON.stringify(file)}).convert("RGB"); im.save(${JSON.stringify(file)})`],
      { stdio: "pipe" });
  } catch { canFlatten = false; } // no python3/Pillow — validate.mjs will warn
};

const chrome = await openChrome();

for (const device of activeDevices()) {
  if (onlyDevice && device.key !== onlyDevice) continue;
  const list = panelsFor(device.key);
  if (!list.length) { console.log(`· ${device.key}: no panels configured, skipping`); continue; }

  const outDir = join(ROOT, device.outDir);
  const buildDir = join(ROOT, "build", device.key);
  mkdirSync(outDir, { recursive: true });
  mkdirSync(buildDir, { recursive: true });

  // Clear this device class's previous renders (other classes share en-US/).
  // Same-named files are overwritten anyway; this only catches renamed or
  // removed panels. Some environments forbid deletes — warn, don't die.
  for (const f of readdirSync(outDir)) if (f.includes(`_${device.key}_`)) {
    try { unlinkSync(join(outDir, f)); }
    catch { console.log(`⚠ could not remove stale ${f} (will overwrite same-named renders)`); }
  }

  for (const [i, panel] of list.entries()) {
    if (onlyPanel && panel.id !== onlyPanel) continue;
    const meta = panel.shot?.callout ? shotElements(device, panel.shot.src) : null;
    if (panel.shot?.callout) {
      const el = meta?.elements.find((e) => e.id === panel.shot.callout.element);
      if (!el) throw new Error(`${device.key}/${panel.id}: callout element "${panel.shot.callout.element}" is not on screen ${panel.shot.src}`);
      panel.shot.callout = { ...panel.shot.callout, frame: el.frame, label: el.label, screenWidth: meta.width };
    }
    const html = renderPanelHTML(
      { ...panel, shot: panel.shot && { ...panel.shot, img: shotDataURL(device, panel.shot.src) } },
      device,
      { fontFace, appearance },
    );
    const htmlFile = join(buildDir, `${i}_${panel.id}.html`);
    writeFileSync(htmlFile, html);
    const file = join(outDir, `${i}_${device.key}_${panel.id}.png`);
    await chrome.screenshot(htmlFile, file, { width: device.width, height: device.height, ready: "window.__layoutCallouts?.()" });
    flattenAlpha(file);
    const missing = panel.shot && !panel.shot.img && shotDataURL(device, panel.shot.src) === null;
    console.log(`✓ ${device.key} ${i}_${panel.id} ${device.width}×${device.height}${missing ? "  (placeholder shot)" : ""}`);
  }
}

await chrome.close();
if (!canFlatten) console.log("⚠ alpha not flattened (python3+Pillow unavailable) — validate.mjs will flag it");
