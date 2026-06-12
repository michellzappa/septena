// Component library for App Store marketing panels.
// Pure functions: panel config (panels.config.mjs) + theme (theme.mjs) → HTML.
// Everything is designed in the device's own pixel space (devices.mjs
// designWidth); render.mjs screenshots the page at exact ASC dimensions.
//
// Component vocabulary (all optional per panel):
//   background — solid / wash / split, with optional dot grid
//   badge      — small pill above the headline
//   headline   — Fraunces display; *stars* mark accent-colored italic spans
//   sub        — supporting line, system font
//   shot       — real capture in a CSS device frame (placeholder if missing)
//   overlays   — floating annotation cards, positioned in panel fractions
//   chips      — colored section pills (the "sections, not silos" panel)
//   founder    — quote card (final panel)
//   footnote   — small print at the very bottom

import { theme } from "./theme.mjs";

const esc = (s = "") =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

// "*the Week*" → accent-colored italic Fraunces span.
const rich = (s = "") =>
  esc(s).replace(/\*([^*]+)\*/g, `<em>$1</em>`);

// ---------------------------------------------------------------- background
function background(bg = {}) {
  const tint = bg.tint ?? theme.accent;
  const base =
    bg.style === "solid" ? tint :
    bg.style === "split" ? `linear-gradient(180deg, ${theme.wash(tint, bg.pct ?? 16)} 0%, ${theme.wash(tint, 40)} 100%)` :
    theme.wash(tint, bg.pct ?? 14); // "wash" default
  const dots = bg.dots
    ? `background-image: radial-gradient(color-mix(in oklab, ${tint} 28%, transparent) 3.5px, transparent 3.5px); background-size: 64px 64px;`
    : "";
  return `<div class="bg" style="background: ${base};"><div class="bg-dots" style="${dots}"></div></div>`;
}

// --------------------------------------------------------------------- badge
function badge(b, tint) {
  if (!b) return "";
  return `<div class="badge" style="color:${tint}; border-color: color-mix(in oklab, ${tint} 35%, transparent); background: color-mix(in oklab, ${tint} 8%, white);">${esc(b)}</div>`;
}

// ---------------------------------------------------------------- device shot
// frame:"phone" → bezel + dynamic island. img is a data URL or null.
function shot(s, device, tint) {
  if (!s) return "";
  const widthFrac = s.width ?? 0.74;
  const rotate = s.rotate ?? 0;
  const offsetY = s.offsetY ?? 0;            // fraction of panel height pushed below the fold
  const w = Math.round(1320 * widthFrac);    // design space is 1320-wide portrait
  const screen = s.img
    ? `<img class="screen" src="${s.img}" alt="">`
    : placeholderScreen(s.src, tint);
  const island = device.frame === "phone" ? `<div class="island"></div>` : "";
  return `
  <div class="shot-zone" style="transform: translateY(${Math.round(offsetY * 100)}%);">
    <div class="frame" style="width:${w}px; transform: rotate(${rotate}deg);">
      ${screen}${island}
    </div>
  </div>`;
}

function placeholderScreen(src, tint) {
  const rows = Object.values(theme.sections).slice(0, 7).map(
    (c) => `<div class="ph-row"><span class="ph-dot" style="background:${c}"></span><span class="ph-bar" style="background: color-mix(in oklab, ${c} 18%, white)"></span></div>`
  ).join("");
  return `<div class="screen ph" style="background:${theme.paper};">
    <div class="ph-head" style="background: color-mix(in oklab, ${tint} 12%, white)"></div>${rows}
    <div class="ph-note">missing capture<br><b>${esc(src ?? "?")}.png</b><br>run scripts/screenshots.sh<br>then appstore/sync-shots.sh</div>
  </div>`;
}

// ------------------------------------------------------------------ overlays
// Icons are inline SVGs (24×24 viewBox, currentColor) so they render
// identically everywhere — no reliance on an emoji font. Add to taste.
const ICONS = {
  check: `<path d="M4 13l5 5L20 7" fill="none" stroke="currentColor" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"/>`,
  watch: `<rect x="7" y="6" width="10" height="12" rx="3.4" fill="none" stroke="currentColor" stroke-width="2.6"/><path d="M9.5 6l.7-3h3.6l.7 3M9.5 18l.7 3h3.6l.7-3" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linejoin="round"/>`,
  spark: `<path d="M4 17l4-6 4 3 4-8 4 5" fill="none" stroke="currentColor" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"/>`,
  lock: `<rect x="5.5" y="10.5" width="13" height="9.5" rx="2.6" fill="none" stroke="currentColor" stroke-width="2.6"/><path d="M8.5 10.5V8a3.5 3.5 0 017 0v2.5" fill="none" stroke="currentColor" stroke-width="2.6"/>`,
  bolt: `<path d="M13 2L5 14h6l-1 8 8-12h-6l1-8z" fill="currentColor"/>`,
};
const icon = (name) =>
  ICONS[name]
    ? `<svg viewBox="0 0 24 24" width="46" height="46">${ICONS[name]}</svg>`
    : esc(name ?? "✓");

function overlays(list = []) {
  return list.map((o) => {
    const tint = o.tint ?? theme.accent;
    return `
    <div class="card" style="left:${o.x * 100}%; top:${o.y * 100}%; width:${o.w ?? 560}px; transform: rotate(${o.rotate ?? 0}deg);">
      <span class="card-ic" style="background: color-mix(in oklab, ${tint} 14%, white); color:${tint};">${icon(o.icon)}</span>
      <span class="card-tx"><b>${esc(o.title ?? "")}</b>${o.sub ? `<i>${esc(o.sub)}</i>` : ""}</span>
    </div>`;
  }).join("");
}

// --------------------------------------------------------------------- chips
function chips(c) {
  if (!c) return "";
  const items = (c.items ?? Object.entries(theme.sections).map(([k, v]) => ({ label: k[0].toUpperCase() + k.slice(1), color: v })))
    .map((i) => `<span class="chip" style="color:${i.color}; background: color-mix(in oklab, ${i.color} 10%, white); border-color: color-mix(in oklab, ${i.color} 30%, transparent);">${esc(i.label)}</span>`)
    .join("");
  return `<div class="chips" style="left:${(c.x ?? 0.5) * 100}%; top:${(c.y ?? 0.52) * 100}%; width:${c.w ?? 1100}px;">${items}</div>`;
}

// ------------------------------------------------------------------- founder
function founder(f) {
  if (!f) return "";
  return `
  <div class="founder">
    <p class="fq">“${esc(f.quote)}”</p>
    <p class="fn">${esc(f.name)}</p>
    <p class="fr">${esc(f.role)}</p>
  </div>`;
}

// ---------------------------------------------------------------- the panel
export function renderPanelHTML(panel, device, { fontFace = "", appearance = "light" } = {}) {
  const tint = panel.background?.tint ?? theme.accent;
  const zoom = device.width / device.designWidth;
  return `<!doctype html><html><head><meta charset="utf-8"><style>
${fontFace}
* { margin:0; padding:0; box-sizing:border-box; }
html,body { width:${device.width}px; height:${device.height}px; overflow:hidden; }
.panel { position:relative; width:${device.designWidth}px; height:${Math.round(device.height / zoom)}px; zoom:${zoom};
  font-family:${theme.fonts.ui}; color:${theme.ink}; overflow:hidden; }
.bg,.bg-dots { position:absolute; inset:0; }
.top { position:relative; padding:130px 110px 0; text-align:${panel.align ?? "left"}; }
.badge { display:inline-block; font:600 34px/1 ${theme.fonts.mono}; letter-spacing:.14em;
  padding:18px 34px; border:3px solid; border-radius:${theme.radius.badge}px; margin-bottom:44px; }
h1 { font-family:${theme.fonts.display}; font-weight:600; font-size:${panel.headlineSize ?? 148}px;
  line-height:1.04; letter-spacing:-0.015em; text-wrap:balance; }
h1 em { font-style:italic; color:${tint}; }
.sub { font-size:52px; line-height:1.3; color:color-mix(in oklab, ${theme.ink} 62%, transparent);
  margin-top:40px; max-width:1040px; ${panel.align === "center" ? "margin-left:auto;margin-right:auto;" : ""} }
.shot-zone { position:absolute; left:0; right:0; bottom:-90px; display:flex; justify-content:center; }
.frame { position:relative; background:#111; border-radius:${theme.radius.device}px; padding:22px;
  box-shadow:${theme.shadow.device}; }
.screen { display:block; width:100%; border-radius:${theme.radius.device - 24}px; }
img.screen { height:auto; }
.island { position:absolute; top:50px; left:50%; transform:translateX(-50%);
  width:268px; height:80px; background:#000; border-radius:999px; }
.ph { aspect-ratio:1320/2868; padding:200px 70px 0; position:relative; }
.ph-head { height:220px; border-radius:36px; margin-bottom:48px; }
.ph-row { display:flex; align-items:center; gap:30px; margin-bottom:40px; }
.ph-dot { width:64px; height:64px; border-radius:50%; flex:none; }
.ph-bar { height:64px; border-radius:20px; flex:1; }
.ph-note { position:absolute; left:0; right:0; top:46%; text-align:center;
  font:400 44px/1.5 ${theme.fonts.mono}; color:${theme.inkSoft}; }
.card { position:absolute; display:flex; align-items:center; gap:26px; padding:34px 42px;
  background:${theme.white}; border-radius:${theme.radius.card}px; box-shadow:${theme.shadow.card}; }
.card-ic { width:84px; height:84px; border-radius:26px; flex:none; display:flex;
  align-items:center; justify-content:center; font-size:46px; }
.card-tx { display:flex; flex-direction:column; gap:6px; }
.card-tx b { font-size:42px; } .card-tx i { font-style:normal; font-size:34px; color:${theme.inkSoft}; }
.chips { position:absolute; transform:translateX(-50%); display:flex; flex-wrap:wrap; gap:22px; justify-content:center; }
.chip { font:600 38px/1 ${theme.fonts.ui}; padding:20px 36px; border:3px solid; border-radius:999px; }
.founder { position:absolute; left:50%; top:46%; transform:translateX(-50%); width:1020px;
  background:${theme.white}; border-radius:56px; box-shadow:${theme.shadow.card};
  padding:90px 84px; text-align:center; }
.fq { font-family:${theme.fonts.display}; font-style:italic; font-size:64px; line-height:1.35; }
.fn { font-family:${theme.fonts.display}; font-size:48px; margin-top:56px; }
.fr { font:400 36px/1.4 ${theme.fonts.mono}; color:${theme.inkSoft}; margin-top:12px; }
.footnote { position:absolute; bottom:70px; left:0; right:0; text-align:center;
  font:400 36px/1.4 ${theme.fonts.mono}; color:color-mix(in oklab, ${theme.ink} 55%, transparent); }
</style></head><body>
<div class="panel">
  ${background(panel.background)}
  <div class="top">
    ${badge(panel.badge, tint)}
    <h1>${rich(panel.headline)}</h1>
    ${panel.sub ? `<p class="sub">${rich(panel.sub)}</p>` : ""}
  </div>
  ${shot(panel.shot, device, tint)}
  ${chips(panel.chips)}
  ${founder(panel.founder)}
  ${overlays(panel.overlays)}
  ${panel.footnote ? `<p class="footnote">${rich(panel.footnote)}</p>` : ""}
</div>
</body></html>`;
}
