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
import { fileURLToPath , pathToFileURL} from "node:url";
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
const blenderBin = process.env.BLENDER || firstExisting([
  "/opt/homebrew/bin/blender",
  "/Applications/Blender.app/Contents/MacOS/Blender",
]) || "blender";
const photoScreenScript = join(ROOT, "../tools/3d-studio/replace_photo_screen.py");
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

const shotDataURL = (device, src, look = appearance, accent = null, layout = null) => {
  const { png } = shotPaths(device, src, look ?? appearance, accent, layout);
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
const SITE = process.env.SEPTENA_SITE ?? join(ROOT, "../../site");
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

// Notices the app shows, from registry/surfaces.json.
const SURFACES = (() => {
  const file = JSON.parse(readFileSync(join(ROOT, "..", "registry", "surfaces.json"), "utf8"));
  const out = [];
  const walk = (v) => { if (Array.isArray(v)) v.forEach(walk); else if (v && typeof v === "object") { if (v.id && v.title && v.kind) out.push(v); Object.values(v).forEach(walk); } };
  walk(file);
  return out;
})();
// The app's symbols per platform (registry/icons.json).
const ICONS = (() => { const j = JSON.parse(readFileSync(join(ROOT, "..", "registry", "icons.json"), "utf8")); return j.icons ?? j; })();
// "Pause all agents" and the like: labels the app shows, from registry/settings.json.
const SETTINGS = JSON.parse(readFileSync(join(ROOT, "..", "registry", "settings.json"), "utf8"));
const settingLabel = (key) => {
  for (const g of SETTINGS.rootGroups) for (const item of g.items ?? []) if (item.key === key) return item.label;
  throw new Error(`setting ${key} is not in registry/settings.json`);
};
// The agent's face: always the round "Your agent" face the site's /agents
// page shows, in the panel's accent, so every slide shows the same agent. The
// triangle read as a warning sign (mz, 2026-11-23).
const SAMPLE_FACE = (() => {
  const file = join(SITE, "content", "agent-avatars.json");
  return existsSync(file) ? JSON.parse(readFileSync(file, "utf8")).sample ?? null : null;
})();
const agentFace = (color) => {
  if (!SAMPLE_FACE) throw new Error(`no sample agent face in ${SITE}/content/agent-avatars.json (run scripts/sync-agent-avatars.mjs there)`);
  return { ...SAMPLE_FACE, color };
};
// Builds a panel's card from what its screen shows (see card() in components.mjs).
function resolveCard(device, panel) {
  const c = panel.card;
  const m = shotElements(device, panel.shot.src, panel.shot.appearance, panel.shot.accent);
  const el = (id) => {
    const e = m?.elements.find((x) => x.id === id);
    if (!e) throw new Error(`${device.key}/${panel.id}: card element "${id}" is not on screen ${panel.shot.src}`);
    return e.label.split("\n").map((l) => l.trim()).filter(Boolean);
  };
  const face = c.face === false ? null : agentFace(c.tint);
  const base = { top: c.top, left: c.left, right: c.right, tint: c.tint, face };
  if (c.kind === "discussion") {
    const [question, ...chips] = el(c.element);
    return { ...base, title: el(c.taskElement ?? "task-detail")[0], subtitle: c.subtitle, question, chips };
  }
  if (c.kind === "agent") {
    const [status, ...buttons] = el(c.element);
    return { ...base, title: el(c.taskElement ?? "task-detail")[0], subtitle: status, actions: c.actions === false ? [] : buttons.map((label) => ({ label, kind: label === "Stop" ? "destructive" : "tinted" })), toggle: c.toggleSetting ? settingLabel(c.toggleSetting) : null };
  }
  if (c.kind === "page") {
    // The task page's Discuss card, both moments: the question with the
    // answer you tapped, and the agent at work with Stop.
    const [status, stop, question, answer] = el("conversation");
    return { ...base, title: el("task-page")[0], subtitle: el("discuss")[0], question, chips: [], answer, status, actions: [{ label: stop, kind: "destructive" }] };
  }
  if (c.kind === "review") {
    const lines = el(c.element);
    const actions = lines.slice(-2);
    return { ...base, title: lines[0], subtitle: lines[1], artifact: c.artifact && lines.length > 4 ? lines[2] : null, actions: actions.map((label, i) => ({ label, kind: label === "Accept" ? "primary" : "tinted" })) };
  }
  if (c.kind === "notice") {
    // A registry notice (registry/surfaces.json), its count from the screen.
    const n = SURFACES.find((x) => x.id === c.notice);
    if (!n) throw new Error(`${device.key}/${panel.id}: notice ${c.notice} is not in registry/surfaces.json`);
    const count = (m?.elements ?? []).filter((e) => e.id.startsWith("task-")).length;
    const title = typeof n.title === "string" ? n.title : (count === 1 ? n.title.one : n.title.other).replace("{count}", String(count));
    // style "accent": the panel's accent fills the card, with the notice's own
    // symbol (registry/icons.json, Lucide column), so it reads as the app's
    // notice and not as an agent's card (mz, 2026-11-24).
    const icon = c.style === "accent" ? ICONS[n.icon]?.lucide : null;
    if (c.style === "accent" && !icon) throw new Error(`${device.key}/${panel.id}: notice icon ${n.icon} has no lucide name in registry/icons.json`);
    return { ...base, face: null, style: c.style, icon, title, subtitle: n.detail, actions: n.primaryTitle && c.actions !== false ? [{ label: n.primaryTitle, kind: "primary" }] : [] };
  }
  if (c.kind === "section") {
    // A settings section's own header and footer (registry/settings.json), not its rows.
    const page = SETTINGS.pages?.find((x) => x.id === c.page);
    const section = page?.sections.find((x) => x.id === c.section);
    if (!section?.header) throw new Error(`${device.key}/${panel.id}: settings section ${c.page}/${c.section} with a header is not in registry/settings.json`);
    return { ...base, face: null, title: section.header, subtitle: section.footer ?? null, actions: [] };
  }
  if (c.kind === "list") {
    const rows = c.elements.map((id) => {
      const [title, meta] = el(id);
      const proposal = meta === "Proposal";
      return { title, meta, proposal, face: proposal ? face : null };
    });
    return { ...base, face: null, title: c.title ?? null, rows };
  }
  throw new Error(`${device.key}/${panel.id}: unknown card kind ${c.kind}`);
}

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
    if (panel.shot?.ring) {
      const m = shotElements(device, panel.shot.src, panel.shot.appearance, panel.shot.accent);
      const el = m?.elements.find((e) => e.id === panel.shot.ring.element);
      if (!el) throw new Error(`${device.key}/${panel.id}: ring element "${panel.shot.ring.element}" is not on screen ${panel.shot.src}`);
      panel.shot.ring = { ...panel.shot.ring, frame: el.frame, screenWidth: m.width };
    }
    if (panel.shot?.incoming) {
      const m = shotElements(device, panel.shot.src, panel.shot.appearance, panel.shot.accent);
      // An entry is a row id, or { id, icon } when the style draws a symbol.
      const icons = panel.shot.incoming.map((e) => e.icon).filter(Boolean);
      const twice = icons.find((x, i) => icons.indexOf(x) !== i);
      if (twice) throw new Error(`${device.key}/${panel.id}: incoming symbol ${twice} appears twice`);
      panel.shot.incoming = { screenWidth: m.width, style: panel.shot.incomingStyle ?? "pill", rows: await Promise.all(panel.shot.incoming.map(async (entry) => {
        const { id, icon, y, ...place } = typeof entry === "string" ? { id: entry } : entry;
        const node = icon && await lucideNode(icon, `${device.key}/${panel.id}`);
        // An entry without a row id is a free symbol at a screen height y (points).
        if (!id) return { frame: [0, y, 0, 0], label: icon, node, ...place };
        const el = m?.elements.find((e) => e.id === id);
        if (!el) throw new Error(`${device.key}/${panel.id}: incoming element "${id}" is not on screen ${panel.shot.src}`);
        return { frame: el.frame, label: el.label.split("\n")[0], node, ...place };
      })) };
    }
    if (panel.shot?.callout) {
      const el = meta?.elements.find((e) => e.id === panel.shot.callout.element);
      if (!el) throw new Error(`${device.key}/${panel.id}: callout element "${panel.shot.callout.element}" is not on screen ${panel.shot.src}`);
      panel.shot.callout = { ...panel.shot.callout, frame: el.frame, label: el.label, screenWidth: meta.width };
    }
    const html = renderPanelHTML(
      {
        ...panel,
        photo: panel.photo && {
          ...panel.photo,
          img: (() => {
            const file = join(ROOT, panel.photo.src);
            if (!existsSync(file)) throw new Error(`${device.key}/${panel.id}: photo ${panel.photo.src} is missing`);
            // A photo never shows a generated screen (docs/photo-composite/SKILL.md):
            // it names the scene that goes on the device, or declares that its
            // screens were rendered from PNGs (3D Studio).
            if (!panel.photo.screen && !panel.photo.rendered) throw new Error(`${device.key}/${panel.id}: photo ${panel.photo.src} needs a "screen" scene, or "rendered: true" for a 3D Studio render`);
            if (!panel.photo.screen) return `data:image/png;base64,${readFileSync(file).toString("base64")}`;
            const { png: screenFile } = shotPaths(device, panel.photo.screen.src, panel.photo.screen.appearance ?? appearance, panel.photo.screen.accent ?? null, panel.photo.screen.layout ?? null);
            if (!existsSync(screenFile)) throw new Error(`${device.key}/${panel.id}: photo screen ${panel.photo.screen.src} is missing (${screenFile}; run node export-scenes.mjs)`);
            const composited = join(buildDir, `${i}_${panel.id}_photo.png`);
            execFileSync(blenderBin, ["-b", "--python-exit-code", "1", "--python", photoScreenScript, "--", "--photo", file, "--ios", screenFile, "--out", composited], { stdio: "pipe" });
            return `data:image/png;base64,${readFileSync(composited).toString("base64")}`;
          })(),
          // The photo's aspect (height / width) from the PNG header, so a
          // width-fitted photo knows where its bottom edge falls.
          aspect: (() => { const b = readFileSync(join(ROOT, panel.photo.src)); return b.readUInt32BE(20) / b.readUInt32BE(16); })(),
        },
        // A small watch: its rows are the first task titles on the named scene's
        // screen (that screen's .elements.json), never typed by hand.
        // The card's words, from the screen's elements and the app registry.
        card: panel.card && await (async (c) => c.icon ? { ...c, iconNode: await lucideNode(c.icon, `${device.key}/${panel.id}`) } : c)(resolveCard(device, panel)),
        // Claims with a Lucide symbol each (the icon set the app's registry maps
        // to), drawn from the site's lucide-react package.
        badges: panel.badges && await Promise.all(panel.badges.map(async (b) => ({ ...b, node: await lucideNode(b.icon, `${device.key}/${panel.id}`) }))),
        claims: panel.claims && await Promise.all(panel.claims.map(async (c) => {
          return { ...c, node: await lucideNode(c.icon, `${device.key}/${panel.id}`) };
        })),
        chat: panel.chat && (() => {
          return { ...panel.chat, face: agentFace(panel.chat.tint) };
        })(),
        watch: panel.watch && (() => {
          const meta = shotElements(device, panel.watch.src, "light", panel.watch.from ?? null);
          const rows = (meta?.elements ?? []).filter((e) => e.id.startsWith("task-")).slice(0, panel.watch.rows ?? 3).map((e) => e.label.split("\n")[0]);
          if (!rows.length) throw new Error(`${device.key}/${panel.id}: no task rows on ${panel.watch.src} for the watch`);
          return { ...panel.watch, rows };
        })(),
        shot: panel.shot && { ...withFaces(panel.shot), img: shotDataURL(device, panel.shot.src, panel.shot.appearance, panel.shot.accent) },
        // Extra phones behind the main one (a fan). Fails closed: every one needs a real capture.
        shots: (panel.shots ?? []).map((s) => {
          const img = shotDataURL(device, s.src, s.appearance, s.accent, s.layout);
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

// A Lucide icon's drawing, from the site's lucide-react package.
async function lucideNode(name, where) {
  const file = join(SITE, "node_modules", "lucide-react", "dist", "esm", "icons", `${name}.mjs`);
  if (!existsSync(file)) throw new Error(`${where}: Lucide icon ${name} is not in ${SITE}/node_modules/lucide-react`);
  const { __iconNode } = await import(pathToFileURL(file).href);
  if (!__iconNode) throw new Error(`${where}: ${name} is an alias in lucide-react; use the icon it points to`);
  return __iconNode;
}
