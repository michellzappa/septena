// Component library for App Store marketing panels.
// Pure functions: panel config (panels.config.mjs) + theme (theme.mjs) → HTML.
// Panels are authored in the device's `designWidth` coordinate space (portrait
// devices share 1320 so the type scale is identical; render.mjs scales to exact
// ASC pixels via `zoom`). Two layouts: portrait (phone/pad, text over a framed
// device shot) and landscape (mac, text column beside a windowed shot).
//
// Component vocabulary (all optional per panel):
//   background — solid / wash / split, with optional dot grid
//   badge      — small pill above the headline
//   headline   — Fraunces display; *stars* mark accent spans
//   sub        — supporting line, system font
//   shot       — real capture in a device frame (placeholder if missing)
//   overlays   — floating annotation cards, positioned in panel fractions
//   chips      — colored section pills
//   founder    — quote card
//   footnote   — small print at the bottom

import { theme } from "./theme.mjs";

const esc = (s = "") =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

// "*one private app*" → accent-colored span.
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
// Per-device frame geometry. `pad` is the bezel thickness; `radius` is the
// OUTER bezel radius. The screen is clipped at `radius − pad` so the corners
// are concentric (a uniform-width bezel all the way around the curve). Radii
// are tuned to real device proportions (~14% of width for iPhone). The frame's
// `overflow:hidden` guarantees the screenshot is actually clipped to the curve.
const FRAME = {
  phone: { pad: 24, radius: 158, island: true },
  pad:   { pad: 30, radius: 92,  island: false },
  mac:   { pad: 0,  radius: 28,  island: false }, // window chrome added separately
  none:  { pad: 0,  radius: 40,  island: false },
};

function shot(s, device, tint) {
  if (!s) return "";
  const dw = device.designWidth;
  const f = FRAME[device.frame] ?? FRAME.phone;
  const w = Math.round(dw * (s.width ?? 0.74));
  const screenR = Math.max(0, f.radius - f.pad);
  const screen = s.img
    ? `<img class="screen" src="${s.img}" alt="" style="border-radius:${screenR}px;">`
    : placeholderScreen(s.src, tint, device.screenAspect ?? 0.46, screenR);
  // Real captures already include the device's Dynamic Island/status bar — only
  // draw a synthetic island on the (content-free) placeholder.
  const island = f.island && !s.img ? `<div class="island"></div>` : "";
  return `
  <div class="shot-zone" style="transform: translateY(${Math.round((s.offsetY ?? 0) * 100)}%);">
    <div class="frame" style="width:${w}px; padding:${f.pad}px; border-radius:${f.radius}px; transform: rotate(${s.rotate ?? 0}deg);">
      ${screen}${island}
    </div>
  </div>`;
}

// Quiet, honest placeholder — neutral screen with the expected capture name.
function placeholderScreen(src, tint, aspect, radius = 0) {
  return `<div class="screen ph" style="background:${theme.paper}; aspect-ratio:${aspect}; border-radius:${radius}px;">
    <div class="ph-center">
      <svg viewBox="0 0 24 24" width="120" height="120" style="color:${tint};opacity:.5">
        <rect x="3" y="3" width="18" height="18" rx="4" fill="none" stroke="currentColor" stroke-width="1.4"/>
        <circle cx="9" cy="9.5" r="2" fill="currentColor"/>
        <path d="M4 18l5-5 4 3 3.5-4L20 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/>
      </svg>
      <div class="ph-name">${esc(src ?? "?")}</div>
    </div>
  </div>`;
}

// A Mac window: traffic lights + the screenshot. Used by the landscape layout.
function macWindow(s, tint) {
  const inner = s?.img
    ? `<img class="mac-screen" src="${s.img}" alt="">`
    : placeholderScreen(s?.src, tint, 1.6);
  return `
  <div class="mac-win" style="transform: rotate(${s?.rotate ?? 0}deg);">
    <div class="mac-bar"><span style="background:#ff5f57"></span><span style="background:#febc2e"></span><span style="background:#28c840"></span></div>
    ${inner}
  </div>`;
}

// ------------------------------------------------------------------ overlays
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

// ----- shared CSS (authored in design space; render.mjs zooms to ASC px) -----
function css(panel, device, tint, fontFace) {
  const zoom = device.width / device.designWidth;
  return `
${fontFace}
* { margin:0; padding:0; box-sizing:border-box; }
html,body { width:${device.width}px; height:${device.height}px; overflow:hidden; }
.panel { position:relative; width:${device.designWidth}px; height:${Math.round(device.height / zoom)}px; zoom:${zoom};
  font-family:${theme.fonts.ui}; color:${theme.ink}; overflow:hidden; }
.bg,.bg-dots { position:absolute; inset:0; }
.badge { display:inline-block; font:600 34px/1 ${theme.fonts.mono}; letter-spacing:.14em;
  padding:18px 34px; border:3px solid; border-radius:${theme.radius.badge}px; margin-bottom:44px; }
h1 { font-family:${theme.fonts.display}; font-weight:600; font-size:${panel.headlineSize ?? 168}px;
  font-variation-settings:"opsz" 9, "wght" 600, "SOFT" 0, "WONK" 0;  /* matches app: Fraunces-9ptSemiBold */
  line-height:1.06; letter-spacing:-0.01em; text-wrap:balance; }
h1 em { font-style:normal; color:${tint}; font-variation-settings:"opsz" 9, "wght" 600, "SOFT" 0, "WONK" 0; }
.sub { font-size:62px; line-height:1.32; color:color-mix(in oklab, ${theme.ink} 64%, transparent);
  margin-top:44px; max-width:1080px; }
.frame { position:relative; background:#0b0b0c; box-shadow:${theme.shadow.device}; overflow:hidden; }
.screen { display:block; width:100%; }
img.screen { height:auto; }
.island { position:absolute; top:50px; left:50%; transform:translateX(-50%);
  width:268px; height:80px; background:#000; border-radius:999px; }
.ph { position:relative; }
.ph-center { position:absolute; inset:0; display:flex; flex-direction:column;
  align-items:center; justify-content:center; gap:40px; }
.ph-name { font:400 42px/1 ${theme.fonts.mono}; color:${theme.inkSoft}; }
.card { position:absolute; display:flex; align-items:center; gap:26px; padding:34px 42px;
  background:${theme.white}; border-radius:${theme.radius.card}px; box-shadow:${theme.shadow.card}; }
.card-ic { width:84px; height:84px; border-radius:26px; flex:none; display:flex;
  align-items:center; justify-content:center; font-size:46px; }
.card-tx { display:flex; flex-direction:column; gap:6px; }
.card-tx b { font-size:42px; } .card-tx i { font-style:normal; font-size:34px; color:${theme.inkSoft}; }
.chips { position:absolute; transform:translateX(-50%); display:flex; flex-wrap:wrap; gap:22px; justify-content:center; }
.chip { font:600 38px/1 ${theme.fonts.ui}; padding:20px 36px; border:3px solid; border-radius:999px; }
.founder { background:${theme.white}; border-radius:56px; box-shadow:${theme.shadow.card};
  padding:90px 84px; text-align:center; }
.fq { font-family:${theme.fonts.display}; font-style:normal; font-size:64px; line-height:1.35;
  font-variation-settings:"opsz" 9, "wght" 500, "SOFT" 0, "WONK" 0; }
.fn { font-family:${theme.fonts.display}; font-size:48px; margin-top:56px;
  font-variation-settings:"opsz" 9, "wght" 600; }
.fr { font:400 36px/1.4 ${theme.fonts.mono}; color:${theme.inkSoft}; margin-top:12px; }
.footnote { position:absolute; bottom:70px; left:0; right:0; text-align:center;
  font:400 36px/1.4 ${theme.fonts.mono}; color:color-mix(in oklab, ${theme.ink} 55%, transparent); }`;
}

// ---------------------------------------------------------- portrait layout
function portrait(panel, device, tint) {
  return `
<div class="panel">
  ${background(panel.background)}
  <div class="top" style="position:relative; padding:130px 110px 0; text-align:${panel.align ?? "left"};">
    ${badge(panel.badge, tint)}
    <h1>${rich(panel.headline)}</h1>
    ${panel.sub ? `<p class="sub" style="${panel.align === "center" ? "margin-left:auto;margin-right:auto;" : ""}">${rich(panel.sub)}</p>` : ""}
  </div>
  <style>
    .shot-zone { position:absolute; left:0; right:0; bottom:-90px; display:flex; justify-content:center; }
    .founder { position:absolute; left:50%; top:46%; transform:translateX(-50%); width:1020px; }
  </style>
  ${shot(panel.shot, device, tint)}
  ${chips(panel.chips)}
  ${founder(panel.founder)}
  ${overlays(panel.overlays)}
  ${panel.footnote ? `<p class="footnote">${rich(panel.footnote)}</p>` : ""}
</div>`;
}

// --------------------------------------------------------- landscape layout
// Mac: text column on the left, a windowed screenshot bleeding off the right.
function landscape(panel, device, tint) {
  return `
<div class="panel">
  ${background(panel.background)}
  <div style="position:absolute; inset:0; display:flex; align-items:center;">
    <div style="flex:0 0 46%; padding:0 70px 0 180px;">
      ${badge(panel.badge, tint)}
      <h1 style="font-size:${panel.headlineSize ?? 120}px;">${rich(panel.headline)}</h1>
      ${panel.sub ? `<p class="sub" style="font-size:48px; margin-top:36px; max-width:980px;">${rich(panel.sub)}</p>` : ""}
    </div>
    <div style="flex:1; position:relative; height:100%; overflow:visible;">
      <div style="position:absolute; top:50%; left:0; transform:translateY(-50%); width:128%;">
        ${macWindow(panel.shot, tint)}
      </div>
    </div>
  </div>
  <style>
    .mac-win { position:relative; width:100%; background:#1b1b1d; border-radius:36px;
      box-shadow:${theme.shadow.device}; padding-top:90px; overflow:hidden; }
    .mac-bar { position:absolute; top:0; left:0; right:0; height:90px; display:flex; align-items:center;
      gap:24px; padding:0 44px; background:#2a2a2d; }
    .mac-bar span { width:34px; height:34px; border-radius:50%; display:block; }
    .mac-screen { display:block; width:100%; }
    .ph { border-radius:0; }
  </style>
  ${founder(panel.founder)}
  ${overlays(panel.overlays)}
  ${panel.footnote ? `<p class="footnote">${rich(panel.footnote)}</p>` : ""}
</div>`;
}

// ---------------------------------------------------------------- the panel
export function renderPanelHTML(panel, device, { fontFace = "", appearance = "light" } = {}) {
  const tint = panel.background?.tint ?? theme.accent;
  const body = device.landscape ? landscape(panel, device, tint) : portrait(panel, device, tint);
  return `<!doctype html><html><head><meta charset="utf-8"><style>${css(panel, device, tint, fontFace)}</style></head><body>${body}</body></html>`;
}
