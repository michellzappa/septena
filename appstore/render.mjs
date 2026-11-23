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
import { stripTypeScriptTypes } from "node:module";
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

const shotDataURL = (device, src, look = appearance, accent = null) => {
  const { png } = shotPaths(device, src, look ?? appearance, accent);
  return existsSync(png) ? `data:image/png;base64,${readFileSync(png).toString("base64")}` : null;
};
// The scene's element list ({ width, height, elements:[{id,label,frame}] }),
// so a callout can point at real on-screen text. Fails closed: a callout
// whose element is missing stops the render.
const shotElements = (device, src, look = appearance, accent = null) => {
  const { elements } = shotPaths(device, src, look ?? appearance, accent);
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

// The app's header textures, from the site's port of HeaderWashEngine.swift
// (components/task-ui/header-wash-canvas.tsx). The drawing part has no React;
// strip its types and inline it. SEPTENA_SITE overrides the site checkout.
const SITE = process.env.SEPTENA_SITE ?? join(ROOT, "../../_/septena-site");
const washCode = (() => {
  const dir = join(SITE, "components/task-ui");
  const dataFile = join(dir, "header-wash-data.ts"), file = join(dir, "header-wash-canvas.tsx");
  if (!existsSync(file) || !existsSync(dataFile)) return null;
  // header-wash-data.ts holds the accents and texture list; the canvas file
  // holds the drawing code between its imports and the React component.
  // Its accents and textures import the registry's tokens.json; inline this
  // repo's registry/tokens.json in place of that import (same file, synced).
  const tokensImport = /^import tokensFile from .*tokens\.json.*;$/m;
  const rawData = readFileSync(dataFile, "utf8");
  if (!tokensImport.test(rawData)) throw new Error(`${dataFile}: expected the tokens.json import; update render.mjs`);
  const data = rawData.replace(tokensImport, `const tokensFile = ${readFileSync(join(ROOT, "../registry/tokens.json"), "utf8")};`);
  const src = readFileSync(file, "utf8");
  const start = src.indexOf("function hexToRgb"), end = src.indexOf("export function HeaderWashCanvas");
  if (start < 0 || end < 0) throw new Error(`${file}: header-wash layout changed; update render.mjs`);
  return stripTypeScriptTypes(`${data}\n${src.slice(start, end)}`.replace(/^export /gm, ""));
})();

// Vendor-free agent faces (the site's content/agent-avatars.json "crew", from
// Starlings' avatar recipe), for panels that show agents at work.
const CREW = (() => {
  const file = join(SITE, "content", "agent-avatars.json");
  return existsSync(file) ? JSON.parse(readFileSync(file, "utf8")).crew ?? [] : [];
})();
const withFaces = (s) => {
  if (!s?.faces) return s;
  return { ...s, faces: s.faces.map((f) => {
    const face = CREW[f.face];
    if (!face) throw new Error(`agent face ${f.face} is not in ${SITE}/content/agent-avatars.json crew (run scripts/sync-agent-avatars.mjs there)`);
    return { ...f, ...face };
  }) };
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

  const exported = [];
  for (const [i, panel] of list.entries()) {
    if (onlyPanel && panel.id !== onlyPanel) continue;
    // A shot may pick its own appearance (shot.appearance), so one set mixes
    // light and dark screens.
    const meta = panel.shot?.callout ? shotElements(device, panel.shot.src, panel.shot.appearance, panel.shot.accent) : null;
    if (panel.shot?.callout) {
      const el = meta?.elements.find((e) => e.id === panel.shot.callout.element);
      if (!el) throw new Error(`${device.key}/${panel.id}: callout element "${panel.shot.callout.element}" is not on screen ${panel.shot.src}`);
      panel.shot.callout = { ...panel.shot.callout, frame: el.frame, label: el.label, screenWidth: meta.width };
    }
    const html = renderPanelHTML(
      {
        ...panel,
        shot: panel.shot && { ...withFaces(panel.shot), img: shotDataURL(device, panel.shot.src, panel.shot.appearance, panel.shot.accent) },
        // Extra phones behind the main one (a fan). Fails closed: every one needs a real capture.
        shots: (panel.shots ?? []).map((s) => {
          const img = shotDataURL(device, s.src, s.appearance, s.accent);
          if (!img) throw new Error(`${device.key}/${panel.id}: no capture for extra shot ${s.src} (${s.appearance ?? appearance})`);
          return { ...s, img };
        }),
      },
      device,
      { fontFace, appearance, washCode },
    );
    const htmlFile = join(buildDir, `${i}_${panel.id}.html`);
    writeFileSync(htmlFile, html);
    const file = join(outDir, `${i}_${device.key}_${panel.id}.png`);
    await chrome.screenshot(htmlFile, file, { width: device.width, height: device.height, ready: "(window.__layoutCallouts?.(), document.documentElement.dataset.overlap ? (() => { throw Error('phone covers the title by ' + document.documentElement.dataset.overlap + 'px') })() : true)" });
    flattenAlpha(file);
    exported.push({ order: i, slug: panel.id, file: `${i}_${device.key}_${panel.id}.png`, title: panel.headline.replace(/\*/g, "") });
    const missing = panel.shot && shotDataURL(device, panel.shot.src, panel.shot.appearance, panel.shot.accent) === null;
    console.log(`✓ ${device.key} ${i}_${panel.id} ${device.width}×${device.height}${missing ? "  (placeholder shot)" : ""}`);
  }
  // One manifest per device class, in Bipe's store-set shape. The website's
  // brand page reads it (septena-site scripts/sync-appstore.mjs).
  if (!onlyPanel) writeFileSync(join(outDir, `manifest.${device.key}.json`), JSON.stringify({
    device: device.key, label: device.label, platform: device.landscape ? "macos" : "ios", locale: "en-US",
    width: device.width, height: device.height, exports: exported,
  }, null, 2) + "\n");
}

await chrome.close();
if (!canFlatten) console.log("⚠ alpha not flattened (python3+Pillow unavailable) — validate.mjs will flag it");
