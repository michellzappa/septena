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
//   headline   — New York display; *stars* mark accent spans
//   sub        — supporting line, system font
//   shot       — real capture in a device frame (placeholder if missing)
//   overlays   — floating annotation cards, positioned in panel fractions
//   chips      — colored section pills
//   founder    — quote card
//   footnote   — small print at the bottom

import { readFileSync } from "node:fs";
import { theme } from "./theme.mjs";
import { phoneShape } from "../registry/device-shape.mjs";

// The one iPhone shape (registry/device-frames.json), shared with the website scenes.
const IPHONE = JSON.parse(readFileSync(new URL("../registry/device-frames.json", import.meta.url), "utf8")).devices.iphone;
const IPHONE_CASE_WIDTH = IPHONE.screen.width + 2 * IPHONE.bezel;
// Case drawing and screen mask from registry/device-shape.mjs (continuous corners).
// phoneShape returns CSS url("…") values; they go inside double-quoted style
// attributes here, so escape the quotes or the attribute ends early.
const PHONE = Object.fromEntries(Object.entries(phoneShape(IPHONE)).map(([k, v]) => [k, typeof v === "string" ? v.replaceAll('"', "&quot;") : v]));

const esc = (s = "") =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

// "*one private app*" → accent-colored span.
const rich = (s = "") =>
  esc(s).replace(/\*([^*]+)\*/g, `<em>$1</em>`);
// A two-part title, "Claim. How it works.": the first sentence bold, the rest
// light, at one size (after Things' listing). A one-sentence title renders as is.
const lead = (s = "") => {
  const i = s.indexOf(". ");
  return i < 0 ? rich(s) : `<strong>${rich(s.slice(0, i + 1))}</strong> <span class="light">${rich(s.slice(i + 2))}</span>`;
};

// ---------------------------------------------------------------- background
function background(bg = {}) {
  const tint = bg.tint ?? theme.accent;
  // The app's own canvas with one of its header textures, drawn in the page
  // by WASH_SCRIPT (render.mjs passes the drawing code).
  if (bg.style === "texture") {
    // bg.fill: a solid accent field with the texture drawn in white on it
    // (the wash code's dark-appearance ink, mixed with white).
    const fill = bg.fill ? `linear-gradient(180deg, ${bg.fill} 0%, color-mix(in oklab, ${bg.fill} 82%, black) 100%)` : (bg.canvas ?? theme.app.canvas);
    const ink = bg.fill ? "#FFFFFF" : (bg.accent ?? theme.app.accent);
    return `<div class="bg" style="background:${fill};"><canvas class="bg-wash" data-texture="${esc(bg.texture)}" data-accent="${ink}" data-dark="${bg.fill ? 1 : 0}" data-intensity="${bg.intensity ?? 62}" data-seed="${bg.seed ?? 42}" data-fade="${bg.fade ?? 0.62}"></canvas></div>`;
  }
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
  pad:   { pad: 30, radius: 92,  island: false },
  mac:   { pad: 0,  radius: 28,  island: false }, // window chrome added separately
  none:  { pad: 0,  radius: 40,  island: false },
};

function shot(s, device, tint) {
  if (!s) return "";
  // A Mac window from the scene builder's mac layout (it carries its own window
  // bar): rounded and shadowed, positioned like a phone.
  if (s.layout === "mac") {
    const w = Math.round(device.designWidth * (s.width ?? 1));
    return `
  <div class="shot-zone"${s.alignTop ? " data-align-top" : ""}${s.alignMiddle != null ? ` data-align-middle="${s.alignMiddle}"` : ""} style="${s.top != null ? `top:${s.top}px` : `bottom:${s.bottom ?? 110}px`}; transform: translate(${Math.round((s.offsetX ?? 0) * 100)}%, ${Math.round((s.offsetY ?? 0) * 100)}%);">
    <div class="shot-wrap" style="width:${w}px;"><img src="${s.img}" alt="" style="display:block; width:100%; border-radius:${Math.round(w * 0.02)}px; border:2px solid rgb(0 0 0 / .18); box-shadow:0 40px 90px rgb(0 0 0 / .32);"></div>
  </div>`;
  }
  const dw = device.designWidth;
  const w = Math.round(dw * (s.width ?? 0.74));
  // Phone: the canonical iPhone (registry/device-frames.json), scaled to this width.
  const k = w / IPHONE_CASE_WIDTH;
  const f = device.frame === "phone"
    ? { pad: Math.round(IPHONE.bezel * k), radius: Math.round(IPHONE.outerRadius * k), island: true, bezel: true }
    : FRAME[device.frame] ?? FRAME.none;
  const screenR = Math.max(0, f.radius - f.pad);
  const clip = f.bezel
    ? `-webkit-mask:${PHONE.screen} center/100% 100% no-repeat; mask:${PHONE.screen} center/100% 100% no-repeat;`
    : `border-radius:${screenR}px;`;
  const screen = s.img
    ? `<img class="screen" src="${s.img}" alt="" style="${clip}">`
    : placeholderScreen(s.src, tint, device.screenAspect ?? 0.46, clip);
  // Real captures already include the device's Dynamic Island/status bar — only
  // draw a synthetic island on the (content-free) placeholder.
  const c = IPHONE.cutout;
  const island = f.island && !s.img ? `<div class="island" style="top:${Math.round((IPHONE.bezel + c.top) * k)}px; width:${Math.round(c.width * k)}px; height:${Math.round(c.height * k)}px;"></div>` : "";
  return `
  <div class="shot-zone"${s.alignTop ? " data-align-top" : ""}${s.alignMiddle != null ? ` data-align-middle="${s.alignMiddle}"` : ""} style="${s.top != null ? `top:${s.top}px` : `bottom:${s.bottom ?? 110}px`}; transform: translate(${Math.round((s.offsetX ?? 0) * 100)}%, ${Math.round((s.offsetY ?? 0) * 100)}%);">
    <div class="shot-wrap" style="width:${w}px; transform: rotate(${s.rotate ?? 0}deg);">
      ${faces(s.faces, w)}
      <div class="frame" style="position:relative; z-index:1; width:${w}px; padding:${f.pad}px;${f.bezel ? ` background:${PHONE.case} center/100% 100% no-repeat; box-shadow:none; overflow:visible; filter:drop-shadow(0 ${Math.round(20 * k)}px ${Math.round(24 * k)}px rgb(0 0 0 / .28));` : ` border-radius:${f.radius}px;`}">
        ${screen}${island}
      </div>
      ${s.img ? callout(s.callout, { w, pad: f.pad, margin: (dw - w) / 2, tint }) : ""}
    </div>
  </div>`;
}

// ------------------------------------------------------------------ watch
// A small Apple Watch with Today's first tasks (rows come from a scene's
// elements, see render.mjs). Drawn, not captured: the scene builder has no
// watch layout yet. left/top/width in design px; accent: the title colour.
function watch(w) {
  if (!w) return "";
  const width = w.width ?? 300, h = Math.round(width * 1.22), r = Math.round(width * 0.27);
  const ui = String(theme.fonts.ui).replace(/"/g, "'"); // inside style="…" attributes
  const rows = w.rows.map((t) => `<div style="display:flex; align-items:center; gap:${Math.round(width * 0.05)}px; padding:${Math.round(width * 0.035)}px ${Math.round(width * 0.05)}px; background:#1c1c1e; border-radius:${Math.round(width * 0.07)}px; margin-top:${Math.round(width * 0.03)}px;"><span style="flex:none; width:${Math.round(width * 0.08)}px; height:${Math.round(width * 0.08)}px; border:${Math.max(2, Math.round(width * 0.012))}px solid #8e8e93; border-radius:50%;"></span><span style="font:600 ${Math.round(width * 0.08)}px/1.15 ${ui}; color:#fff; white-space:nowrap; overflow:hidden; text-overflow:ellipsis;">${esc(t)}</span></div>`).join("");
  const band = (top) => `<div style="position:absolute; left:${Math.round(width * 0.18)}px; right:${Math.round(width * 0.18)}px; ${top ? "bottom:100%" : "top:100%"}; height:${Math.round(h * 0.42)}px; background:linear-gradient(${top ? "0deg" : "180deg"}, #2c2c2e, #1c1c1e); border-radius:${top ? "30px 30px 0 0" : "0 0 30px 30px"};"></div>`;
  return `
  <div style="position:absolute; z-index:4; left:${w.left}px; top:${w.top}px; width:${width}px; height:${h}px;">
    ${band(true)}${band(false)}
    <div style="position:absolute; inset:0; background:#0b0b0c; border-radius:${r}px; border:${Math.round(width * 0.035)}px solid #3a3a3c; box-shadow:0 30px 60px rgb(0 0 0 / .35); overflow:hidden; padding:${Math.round(width * 0.09)}px ${Math.round(width * 0.07)}px;">
      <div style="font:700 ${Math.round(width * 0.11)}px/1 ${ui}; color:${w.accent ?? "#fff"}; margin-bottom:${Math.round(width * 0.04)}px;">Today</div>
      ${rows}
    </div>
  </div>`;
}

// ------------------------------------------------------------ agent faces
// Agent faces on the phone's edge, in front of the device (mz, 2026-11-23):
// side: "left" | "right"; y: centre as a fraction of the phone's height;
// size in design px; show: the fraction of the face past the edge. Put them
// where the screen is empty.
function faces(list, w) {
  if (!list?.length) return "";
  return list.map((f) => {
    const size = f.size ?? 210, show = f.show ?? 0.55;
    const x = f.side === "left" ? -size * show : w - size * (1 - show);
    return `<svg class="agent-face" width="${size}" height="${size}" viewBox="-120 -120 240 240" style="position:absolute; z-index:2; left:${Math.round(x)}px; top:calc(${(f.y ?? 0.3) * 100}% - ${size / 2}px); overflow:visible; filter:drop-shadow(0 10px 18px rgb(0 0 0 / .22));"><path d="${esc(f.body)}" fill="${esc(f.color)}"/><path d="${esc(f.eyes)}" fill="#fff"/></svg>`;
  }).join("");
}

// --------------------------------------------------------------- callout
// Bipe-style callout: a card that repeats an on-screen element's own text,
// larger, with a curved line down to it and a ring around the element. The
// element's frame and label come from the scene's .elements.json (render.mjs),
// so the card can only say what the screen says. Coordinates are in the
// shot-wrap box (frame width w); the card is placed in the browser after
// layout (layoutCallouts below) so it never runs off the panel.
function callout(c, { w, pad, margin, tint }) {
  if (!c?.frame) return "";
  const k = (w - 2 * pad) / (c.screenWidth ?? 402);
  const [x, y, fw, fh] = c.frame;
  const ex = pad + x * k, ey = pad + y * k, ew = fw * k, eh = fh * k;
  const text = c.label.split("\n").map((l) => l.trim()).filter(Boolean).join(" · ");
  const side = c.side ?? "right";
  const cy = ey + eh / 2 + (c.dy ?? -70) * k;
  return `
      <div class="co-ring" style="left:${ex - 10}px; top:${ey - 10}px; width:${ew + 20}px; height:${eh + 20}px; border-color:${tint};"></div>
      <svg class="co-line" data-co-line width="${w}" height="10" style="color:${tint};"><path fill="none" stroke="currentColor" stroke-width="7" stroke-linecap="round"/><circle r="14" fill="currentColor"/></svg>
      <div class="co-card" data-callout data-ex="${ex}" data-ew="${ew}" data-top="${ey - 10}" data-bottom="${ey + eh + 10}" data-cy="${cy}" data-side="${side}" data-min="${-margin + 50}" data-max="${w + margin - 50}" style="--tint:${tint}; transform: rotate(${side === "left" ? -1.5 : 1.5}deg);">
        <span class="co-dot"></span>${esc(text)}
      </div>`;
}

// Runs in the page after fonts load (render.mjs calls it): places each card
// over its anchor, clamped inside the panel, and draws the connector.
const LAYOUT_CALLOUTS = `window.__layoutCallouts = () => {
  // The main phone sits on the bottom margin (shot.bottom). Phones behind it
  // (data-align-top) share its top line. A phone that reaches into the title
  // marks the page, and render.mjs refuses it.
  const zones = [...document.querySelectorAll(".shot-zone")];
  const main = zones.find((z) => !("alignTop" in z.dataset) && !("alignMiddle" in z.dataset));
  for (const zone of zones) if (main && "alignTop" in zone.dataset) {
    zone.style.top = main.offsetTop + "px"; zone.style.bottom = "auto";
  }
  // data-align-middle: centred on the main phone's midline, then nudged down by its value.
  for (const zone of zones) if (main && "alignMiddle" in zone.dataset) {
    zone.style.top = (main.offsetTop + (main.offsetHeight - zone.offsetHeight) / 2 + (+zone.dataset.alignMiddle || 0)) + "px"; zone.style.bottom = "auto";
  }
  const text = document.querySelector(".panel > .top");
  const phone = main?.querySelector(".frame");
  if (text && phone) {
    const textBottom = text.offsetTop + text.offsetHeight;
    const phoneTop = main.offsetTop + phone.offsetTop;
    if (phoneTop < textBottom + 24) document.documentElement.dataset.overlap = String(textBottom + 24 - phoneTop);
  }
  for (const card of document.querySelectorAll("[data-callout]")) {
    const d = card.dataset, cy = +d.cy;
    const cw = card.offsetWidth, ch = card.offsetHeight;
    // The card sticks out past the phone on its side; the line runs down the
    // panel margin (outside the screen) and enters the element from the side,
    // so it never crosses screen content.
    const left = d.side === "left" ? +d.min : +d.max - cw;
    card.style.left = left + "px";
    card.style.top = (cy - ch / 2) + "px";
    const below = cy > +d.bottom;
    const sx = d.side === "left" ? left + 44 : left + cw - 44;
    const sy = below ? cy - ch / 2 : cy + ch / 2;
    const my = (+d.top + +d.bottom) / 2;
    const ex = d.side === "left" ? +d.ex - 10 : +d.ex + +d.ew + 10;
    const r = Math.min(60, Math.abs(my - sy) / 2), dir = ex > sx ? 1 : -1, vy = my > sy ? 1 : -1;
    const svg = card.parentElement.querySelector("[data-co-line]");
    svg.style.top = "0px"; svg.setAttribute("height", String(Math.max(my, sy) + 40));
    svg.querySelector("path").setAttribute("d",
      "M" + sx + " " + sy + " L" + sx + " " + (my - vy * r) + " Q" + sx + " " + my + " " + (sx + dir * r) + " " + my + " L" + ex + " " + my);
    const dot = svg.querySelector("circle"); dot.setAttribute("cx", ex); dot.setAttribute("cy", my);
  }
};`;

// Quiet, honest placeholder — neutral screen with the expected capture name.
function placeholderScreen(src, tint, aspect, clip = "") {
  return `<div class="screen ph" style="background:${theme.paper}; aspect-ratio:${aspect}; ${clip}">
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
  line-height:1.06; letter-spacing:-0.025em; text-wrap:balance; }
h1 em { font-style:normal; color:${tint}; }
h1.lead { font-size:${panel.leadSize ?? 104}px; line-height:1.12; letter-spacing:-0.015em; text-align:center; text-wrap:balance; }
h1.lead strong { font-weight:800; }
h1.lead .light { font-weight:400; opacity:.86; }
${panel.background?.fill ? `h1, h1 em { color:#fff; } h1 { font-weight:700; text-shadow:0 2px 24px rgb(0 0 0 / 0.12); }
.panel .sub { color:rgb(255 255 255 / 0.94); font-weight:600; font-size:84px; line-height:1.22; margin-top:40px; max-width:1160px; text-wrap:balance; }
.co-line { filter: drop-shadow(0 0 4px rgb(0 0 0 / 0.35)); }` : ""}
.bg-wash { position:absolute; inset:0; width:100%; height:100%; }
.sub { font-size:62px; line-height:1.32; color:${theme.inkSecondary};
  margin-top:44px; max-width:1080px; }
.frame { position:relative; background:#0b0b0c; box-shadow:${theme.shadow.device}; overflow:hidden; }
.shot-wrap { position:relative; }
.co-ring { position:absolute; border:6px solid; border-radius:28px; background:color-mix(in oklab, currentColor 0%, transparent); }
.co-line { position:absolute; left:0; overflow:visible; pointer-events:none; }
.co-card { position:absolute; white-space:nowrap; display:flex; align-items:center; gap:24px;
  padding:34px 48px; background:${theme.white}; border-radius:44px; box-shadow:${theme.shadow.card};
  font:600 54px/1.1 ${theme.fonts.ui}; color:${theme.ink}; }
.co-dot { width:26px; height:26px; border-radius:50%; background:var(--tint); flex:none; }
.screen { display:block; width:100%; }
img.screen { height:auto; }
.island { position:absolute; left:50%; transform:translateX(-50%);
  background:#000; border-radius:999px; }
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
  font-weight:600; }
.fn { font-family:${theme.fonts.display}; font-size:48px; margin-top:56px;
  font-weight:600; }
.fr { font:400 36px/1.4 ${theme.fonts.mono}; color:${theme.inkSoft}; margin-top:12px; }
.footnote { position:absolute; bottom:70px; left:0; right:0; text-align:center;
  font:400 36px/1.4 ${theme.fonts.mono}; color:color-mix(in oklab, ${theme.ink} 55%, transparent); }`;
}

// ---------------------------------------------------------- portrait layout
function portrait(panel, device, tint) {
  return `
<div class="panel">
  ${background(panel.background)}
  <div class="top" style="position:relative; z-index:3; padding:130px 110px 0; text-align:${panel.align ?? "left"};">
    ${badge(panel.badge, tint)}
    <h1${panel.headline.includes(". ") ? ' class="lead"' : ""}>${lead(panel.headline)}</h1>
    ${panel.sub ? `<p class="sub" style="${panel.align === "center" ? "margin-left:auto;margin-right:auto;" : ""}">${rich(panel.sub)}</p>` : ""}
  </div>
  <style>
    .shot-zone { position:absolute; left:0; right:0; display:flex; justify-content:center; }
    .founder { position:absolute; left:50%; top:46%; transform:translateX(-50%); width:1020px; }
  </style>
  ${panel.photo ? `<div class="photo" style="position:absolute; left:0; right:0; bottom:0; top:${panel.photo.top ?? 160}px; background:url(${panel.photo.img}) ${panel.photo.focus ?? "50% 40%"}/auto ${Math.round((panel.photo.zoom ?? 1.15) * 100)}% no-repeat;"></div>
  <div style="position:absolute; inset:0; background:linear-gradient(to bottom, #0B0B0C 0, #0B0B0C ${panel.photo.top ?? 160}px, rgb(11 11 12 / ${panel.photo.shade ?? 0.7}) ${(panel.photo.top ?? 160) + 160}px, rgb(11 11 12 / 0) ${panel.photo.fade ?? 900}px);"></div>` : ""}
  ${(panel.shots ?? []).map((s) => shot(s, device, tint)).join("")}
  ${shot(panel.shot, device, tint)}
  ${watch(panel.watch)}
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
// Draws each texture canvas with the app's header-wash code (washCode defines
// drawHeaderWash). The texture is drawn in points: App Store pixels are 3x, so
// the pattern has the same density as on a phone. drawHeaderWash caps the
// pixel ratio at 2, so it gets a stand-in canvas that reports the point size
// and a context that keeps the 3x transform.
const WASH_SCRIPT = (washCode) => `
${washCode}
document.querySelectorAll("canvas.bg-wash").forEach((real) => {
  const r = real.getBoundingClientRect(), S = 3;
  real.width = Math.round(r.width); real.height = Math.round(r.height);
  const ctx = real.getContext("2d");
  const proxy = new Proxy(ctx, { get(t, p) {
    if (p === "setTransform") return () => t.setTransform(S, 0, 0, S, 0, 0);
    const v = t[p]; return typeof v === "function" ? v.bind(t) : v; },
    set(t, p, v) { t[p] = v; return true; } });
  const w = r.width / S, h = r.height / S, d = real.dataset;
  const stand = { getContext: () => proxy, getBoundingClientRect: () => ({ width: w, height: h }),
    get width() { return Math.round(w * 2); }, set width(_) {}, get height() { return Math.round(h * 2); }, set height(_) {} };
  drawHeaderWash(stand, { texture: d.texture, accentHex: d.accent, isDark: d.dark === "1",
    intensity: Number(d.intensity), seed: Number(d.seed), fadeHeight: h * Number(d.fade) });
});`;

export function renderPanelHTML(panel, device, { fontFace = "", appearance = "light", washCode = null } = {}) {
  const tint = panel.background?.tint ?? theme.accent;
  if (panel.background?.style === "texture" && !washCode) throw new Error(`${panel.id}: texture background needs the header-wash code (render.mjs)`);
  const body = device.landscape ? landscape(panel, device, tint) : portrait(panel, device, tint);
  const wash = washCode ? `<script>${WASH_SCRIPT(washCode)}</script>` : "";
  return `<!doctype html><html><head><meta charset="utf-8"><style>${css(panel, device, tint, fontFace)}</style></head><body>${body}${wash}<script>${LAYOUT_CALLOUTS}</script></body></html>`;
}
