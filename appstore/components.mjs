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
// The MacBook (registry/device-frames.json): lid rim, glass bezel, screen, base.
const MACBOOK = JSON.parse(readFileSync(new URL("../registry/device-frames.json", import.meta.url), "utf8")).devices.macbook;
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
  if (s.layout === "mac" && s.frame === "laptop") {
    // The window capture on a MacBook screen, drawn from the registry's macbook.
    const w = Math.round(device.designWidth * (s.width ?? 0.9));
    const k = w / (MACBOOK.screen.width + 2 * MACBOOK.bezel);
    const fin = MACBOOK.finish, base = MACBOOK.base;
    const rim = `linear-gradient(${fin.angle}deg, ${fin.stops.map(([p, c]) => `${c} ${p * 100}%`).join(", ")})`;
    const zone = `${s.top != null ? `top:${s.top}px` : `bottom:${s.bottom ?? 110}px`}; transform: translate(${Math.round((s.offsetX ?? 0) * 100)}%, 0);`;
    return `
  <div class="shot-zone" style="${zone}">
    <div style="width:${w}px; filter:drop-shadow(0 40px 60px rgb(0 0 0 / .25));">
      <div style="background:${rim}; padding:${Math.max(2, Math.round(3 * k))}px; border-radius:${Math.round(MACBOOK.outerRadius * k)}px ${Math.round(MACBOOK.outerRadius * k)}px ${Math.round(MACBOOK.hingeRadius * k)}px ${Math.round(MACBOOK.hingeRadius * k)}px;">
        <div style="background:${fin.glass}; padding:${Math.round(MACBOOK.bezel * k)}px; border-radius:${Math.round((MACBOOK.outerRadius - 3) * k)}px ${Math.round((MACBOOK.outerRadius - 3) * k)}px ${Math.round(MACBOOK.hingeRadius * k)}px ${Math.round(MACBOOK.hingeRadius * k)}px;">
          <img src="${s.img}" alt="" style="display:block; width:100%; border-radius:${Math.round(6 * k)}px;">
        </div>
      </div>
      <div style="height:${Math.round(base.height * k)}px; margin:0 -${Math.round(base.overhang * k)}px; background:${base.gradient}; border-radius:0 0 ${Math.round(18 * k)}px ${Math.round(18 * k)}px;"></div>
    </div>
  </div>`;
  }
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
      ${s.img && s.ring?.frame ? ring(s.ring, { w, pad: f.pad }) : ""}
      ${s.img && s.incoming ? incoming(s.incoming, { w, pad: f.pad, tint }) : ""}
    </div>
  </div>`;
}

// --------------------------------------------------------------- incoming
// Tasks arriving from another app: a copy of each row slides in from the
// left, its right end over the phone's edge at the row it lands on, with an
// accent trail behind it. Rows further down sit further out, still on their
// way. Titles and positions come from the screen's .elements.json.
function incoming(inc, { w, pad, tint }) {
  const k = (w - 2 * pad) / (inc.screenWidth ?? 402);
  const ui = String(theme.fonts.ui).replace(/"/g, "'");
  return inc.rows.map((r, i) => {

    // Spaced wider than the rows, so the copies never overlap: they line up
    // with the first row and stream down from there.
    const top = pad + (inc.rows[0].frame[1] + inc.rows[0].frame[3] / 2) * k + i * 150;
    const enter = 40 - i * 90; // how far into the phone the pill's right end reaches
    // Anchored by its right end, so each pill is as wide as its title.
    return `<div style="position:absolute; z-index:4; right:calc(100% - ${enter}px); top:${top}px; transform:translateY(-50%); display:flex; align-items:center; opacity:${1 - i * 0.12};">
      <span style="width:300px; height:10px; border-radius:6px; background:linear-gradient(90deg, transparent, color-mix(in oklab, ${tint} 70%, white));"></span>
      <span style="display:flex; align-items:center; gap:26px; padding:24px 32px; background:#fff; border-radius:28px; box-shadow:0 0 0 4px ${tint}, 0 24px 50px rgb(0 0 0 / .28); font:500 36px/1.2 ${ui}; color:#141518; white-space:nowrap;">
        <span style="flex:none; width:44px; height:44px; border:4px solid #C7C7CC; border-radius:12px;"></span>${esc(r.label)}
      </span>
    </div>`;
  }).join("");
}

// ------------------------------------------------------------------- ring
// A ring around one on-screen element (its frame from the scene's
// .elements.json, resolved in render.mjs), in the ring colour. No card, no line.
function ring(r, { w, pad }) {
  const k = (w - 2 * pad) / (r.screenWidth ?? 402);
  const [x, y, fw, fh] = r.frame;
  const g = 24; // breathing room around the element
  return `<div data-ring="${r.color ?? "#fff"}" style="position:absolute; z-index:2; left:${pad + x * k - g}px; top:${pad + y * k - g}px; width:${fw * k + 2 * g}px; height:${fh * k + 2 * g}px; border:7px solid ${r.color ?? "#fff"}; border-radius:28px; box-shadow:0 0 0 8px color-mix(in oklab, ${r.color ?? "#fff"} 22%, transparent);"></div>`;
}

// A card that zooms in on a ringed element wears the ring's outline, and a
// thin line in the same accent joins the two (mz, 2026-11-23), so the eye
// reads the card as the ringed element, larger. The line is drawn after
// layout (LAYOUT_CALLOUTS), when both boxes are known.
function linkedEdge(tint) {
  return tint
    ? `box-shadow:0 0 0 7px ${tint}, 0 0 0 15px color-mix(in oklab, ${tint} 22%, transparent), 0 50px 100px rgb(0 0 0 / .28);`
    : "box-shadow:0 50px 100px rgb(0 0 0 / .28);";
}

// ------------------------------------------------------------------ claims
// A grid of short claims, each with a symbol, for a panel that states facts
// instead of showing a screen (the "open" panel). Two columns of white tiles.
function claims(list, tint) {
  if (!list?.length) return "";
  const ui = String(theme.fonts.ui).replace(/"/g, "'");
  const color = list.tint ?? tint;
  const svg = (node, stroke = color, size = 132) => `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="${stroke}" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${node.map(([tag, attrs]) => `<${tag} ${Object.entries(attrs).filter(([k]) => k !== "key").map(([k, v]) => `${k}="${esc(String(v))}"`).join(" ")}/>`).join("")}</svg>`;
  // A bento: a wide dark tile first, then white tiles. Each tile has a
  // symbol, a short promise and one plain sentence that explains it.
  const tile = (c) => {
    const ink = c.dark ? "#fff" : "#141518", sub = c.dark ? "rgb(255 255 255 / .72)" : "#6E6E73";
    return `<div style="grid-column:${c.wide ? "1 / -1" : "auto"}; background:${c.dark ? "#141518" : "#fff"}; border-radius:56px; padding:${c.wide ? "64px 64px" : "56px 52px"}; min-height:${c.wide ? 460 : 660}px; display:flex; flex-direction:${c.wide ? "row" : "column"}; ${c.wide ? "align-items:center; gap:56px;" : "justify-content:space-between;"} box-shadow:0 40px 80px rgb(0 0 0 / .18);">
      <span style="flex:none; display:inline-flex; align-items:center; justify-content:center; width:${c.wide ? 200 : 150}px; height:${c.wide ? 200 : 150}px; border-radius:${c.wide ? 52 : 42}px; background:${c.dark ? color : `color-mix(in oklab, ${color} 13%, white)`};">${svg(c.node, c.dark ? "#fff" : color, c.wide ? 116 : 88)}</span>
      <div>
        <div style="font:700 ${c.wide ? 72 : 60}px/1.1 ${ui}; color:${ink}; letter-spacing:-0.015em;">${esc(c.title)}</div>
        <div style="font:400 ${c.wide ? 44 : 42}px/1.3 ${ui}; color:${sub}; margin-top:18px;">${esc(c.body)}</div>
      </div>
    </div>`;
  };
  return `
  <div style="position:absolute; z-index:3; left:100px; right:100px; top:${list.top ?? 860}px; display:grid; grid-template-columns:1fr 1fr; gap:40px;">
    ${list.map(tile).join("")}
  </div>`;
}

// -------------------------------------------------------------- chat card
// A message from your agent, as a floating card (not a phone screen, not a
// vendor's app): your words, then the agent's reply next to its face (the
// site's avatar crew). Text comes from panels.septask.mjs; left/top/width in
// design px.
function chat(c) {
  if (!c) return "";
  const ui = String(theme.fonts.ui).replace(/"/g, "'");
  const bubble = (text, mine) => `<div style="max-width:${mine ? 82 : 78}%; ${mine ? "margin-left:auto;" : ""} padding:30px 38px; border-radius:40px; ${mine ? "border-bottom-right-radius:12px;" : "border-bottom-left-radius:12px;"} background:${mine ? (c.tint ?? "#1D63DC") : "#F2F2F7"}; color:${mine ? "#fff" : "#141518"}; font:500 46px/1.25 ${ui};">${esc(text)}</div>`;
  const face = c.face ? `<svg width="96" height="96" viewBox="-120 -120 240 240" style="flex:none; overflow:visible;"><path d="${esc(c.face.body)}" fill="${esc(c.face.color)}"/><path d="${esc(c.face.eyes)}" fill="#fff"/></svg>` : "";
  return `
  <div data-linked style="position:absolute; z-index:5; left:${c.left ?? 110}px; right:${c.right ?? 110}px; top:${c.top}px; padding:40px; background:#fff; border-radius:56px; ${linkedEdge(c.tint)} display:flex; flex-direction:column; gap:26px;">
    ${bubble(c.you, true)}
    <div style="display:flex; align-items:flex-end; gap:20px;">${face}${bubble(c.agent, false)}</div>
  </div>`;
}

// ------------------------------------------------------------------- card
// One floating card, drawn like an iOS sheet: an avatar and a title, then a
// question with answer buttons, action buttons, a switch, or a short list.
// No eyebrows, no capitals: system type, system grey, the panel's tint for
// actions. Every word comes from the scene's .elements.json or the app's
// registry (render.mjs resolves it), so the card says what the app says.
function card(c) {
  if (!c) return "";
  const ui = String(theme.fonts.ui).replace(/"/g, "'");
  const tint = c.tint ?? "#007AFF";
  const avatar = (f, size) => f ? `<svg width="${size}" height="${size}" viewBox="-120 -120 240 240" style="flex:none; overflow:visible;"><path d="${esc(f.body)}" fill="${esc(f.color)}"/><path d="${esc(f.eyes)}" fill="#fff"/></svg>` : "";
  const button = (label, kind) => {
    const style = kind === "primary" ? `background:${tint}; color:#fff;`
      : kind === "destructive" ? "background:rgb(255 59 48 / .12); color:#FF3B30;"
      : kind === "muted" ? "background:#F2F2F7; color:#8E8E93;"
      : `background:color-mix(in oklab, ${tint} 13%, white); color:${tint};`;
    return `<span style="padding:24px 40px; border-radius:999px; font:600 42px/1 ${ui}; ${style}">${esc(label)}</span>`;
  };
  const head = c.title ? `
    <div style="display:flex; align-items:center; gap:26px;">
      ${avatar(c.face, 104)}
      <div style="min-width:0;">
        <div style="font:600 46px/1.2 ${ui}; color:#141518;">${esc(c.title)}</div>
        ${c.subtitle ? `<div style="font:400 38px/1.3 ${ui}; color:#8E8E93; margin-top:6px;">${esc(c.subtitle)}</div>` : ""}
      </div>
    </div>` : "";
  const question = c.question ? `<div style="font:700 62px/1.18 ${ui}; color:#141518; margin-top:40px;">${esc(c.question)}</div>` : "";
  const chips = c.chips?.length ? `<div style="display:flex; flex-wrap:wrap; gap:20px; margin-top:40px;">${c.chips.map((x) => button(x, /…$/.test(x) ? "muted" : "tinted")).join("")}</div>` : "";
  const artifact = c.artifact ? `<div style="display:inline-flex; align-items:center; gap:14px; margin-top:30px; padding:18px 28px; border-radius:22px; background:#F2F2F7; font:500 38px/1 ${ui}; color:#3A3A3C;">${esc(c.artifact)}</div>` : "";
  const actions = c.actions?.length ? `<div style="display:flex; flex-wrap:wrap; gap:20px; margin-top:40px;">${c.actions.map((x) => button(x.label, x.kind)).join("")}</div>` : "";
  const toggle = c.toggle ? `
    <div style="display:flex; align-items:center; justify-content:space-between; gap:30px; margin-top:40px; padding-top:34px; border-top:2px solid #E5E5EA;">
      <span style="font:500 44px/1.2 ${ui}; color:#141518;">${esc(c.toggle)}</span>
      <span style="flex:none; width:128px; height:78px; border-radius:999px; background:#E9E9EB; position:relative;"><span style="position:absolute; left:6px; top:6px; width:66px; height:66px; border-radius:50%; background:#fff; box-shadow:0 3px 8px rgb(0 0 0 / .2);"></span></span>
    </div>` : "";
  const rows = c.rows?.length ? `<div style="margin-top:${c.title ? 30 : 0}px;">${c.rows.map((r, i) => `
    <div style="display:flex; align-items:center; gap:26px; padding:28px 0; ${i ? "border-top:2px solid #E5E5EA;" : ""}">
      <span style="flex:none; width:50px; height:50px; border-radius:14px; border:4px ${r.proposal ? "dashed" : "solid"} #C7C7CC;"></span>
      <span style="flex:1; min-width:0; font:500 46px/1.2 ${ui}; color:#141518;">${esc(r.title)}</span>
      ${r.face ? avatar(r.face, 64) : ""}${r.meta ? `<span style="font:400 36px/1 ${ui}; color:#8E8E93;">${esc(r.meta)}</span>` : ""}
    </div>`).join("")}</div>` : "";
  return `
  <div data-linked style="position:absolute; z-index:5; left:${c.left ?? 90}px; right:${c.right ?? 90}px; top:${c.top}px; padding:52px 56px; background:#fff; border-radius:56px; ${linkedEdge(c.tint)}">
    ${head}${question}${chips}${artifact}${actions}${toggle}${rows}
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
  // Short straps that start behind the case's curve (the case paints over
  // them), darkening toward their far end, so they read as curving down and
  // away from the face.
  const tuck = Math.round(r * 0.7);
  const band = (top) => `<div style="position:absolute; left:${Math.round(width * 0.17)}px; right:${Math.round(width * 0.17)}px; ${top ? `bottom:calc(100% - ${tuck}px)` : `top:calc(100% - ${tuck}px)`}; height:${Math.round(h * 0.26) + tuck}px; background:linear-gradient(${top ? "to top" : "to bottom"}, #38383b 0%, #2a2a2d 45%, #0c0c0e 100%); border-radius:${top ? "22px 22px 0 0" : "0 0 22px 22px"};"></div>`;
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
  // Join a ring to its zoomed-in card: a thin accent line from the ring's
  // nearer edge to the card's nearer edge, a dot at each end. Skipped when
  // the two touch or overlap.
  const panelEl = document.querySelector(".panel");
  const ringEl = document.querySelector("[data-ring]");
  const linked = document.querySelector("[data-linked]");
  if (panelEl && ringEl && linked) {
    const P = panelEl.getBoundingClientRect(), s = panelEl.offsetWidth / P.width;
    const box = (el) => { const b = el.getBoundingClientRect(); return { l: (b.left - P.left) * s, t: (b.top - P.top) * s, r: (b.right - P.left) * s, b: (b.bottom - P.top) * s }; };
    const R = box(ringEl), C = box(linked), gap = 22;
    const below = C.t > R.b + gap, above = C.b < R.t - gap;
    if (below || above) {
      const x = Math.max(Math.max(R.l, C.l) + 80, Math.min(Math.min(R.r, C.r) - 80, (R.l + R.r) / 2));
      const y1 = below ? R.b + 8 : R.t - 8, y2 = below ? C.t - 14 : C.b + 14;
      const color = ringEl.dataset.ring;
      const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
      svg.setAttribute("width", panelEl.offsetWidth); svg.setAttribute("height", panelEl.offsetHeight);
      svg.style.cssText = "position:absolute; left:0; top:0; z-index:4; pointer-events:none; overflow:visible;";
      svg.innerHTML = '<line x1="' + x + '" y1="' + y1 + '" x2="' + x + '" y2="' + y2 + '" stroke="' + color + '" stroke-width="7" stroke-linecap="round" stroke-dasharray="2 18"/>'
        + '<circle cx="' + x + '" cy="' + y1 + '" r="13" fill="' + color + '"/><circle cx="' + x + '" cy="' + y2 + '" r="13" fill="' + color + '"/>';
      panelEl.appendChild(svg);
    }
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
    <h1${panel.headline.includes(". ") ? ' class="lead"' : ""}>${panel.splitTitle ? `<strong>${rich(panel.headline.slice(0, panel.headline.indexOf(". ") + 1))}</strong>` : lead(panel.headline)}</h1>
    ${panel.sub ? `<p class="sub" style="${panel.align === "center" ? "margin-left:auto;margin-right:auto;" : ""}">${rich(panel.sub)}</p>` : ""}
  </div>
  <style>
    .shot-zone { position:absolute; left:0; right:0; display:flex; justify-content:center; }
    .founder { position:absolute; left:50%; top:46%; transform:translateX(-50%); width:1020px; }
  </style>
  ${panel.photo ? `<div class="photo" style="position:absolute; inset:0; background:url(${panel.photo.img}) ${panel.photo.focus ?? "50% 40%"}/auto ${Math.round((panel.photo.zoom ?? 1.15) * 100)}% no-repeat;"></div>
  <div style="position:absolute; inset:0; background:linear-gradient(to bottom, rgb(11 11 12 / ${panel.photo.shade ?? 0.9}) 0, rgb(11 11 12 / 0) ${panel.photo.fade ?? 1100}px, rgb(11 11 12 / 0) calc(100% - ${panel.photo.fade ?? 1100}px), rgb(11 11 12 / ${panel.photo.shade ?? 0.9}) 100%);"></div>` : ""}
  ${(panel.shots ?? []).map((s) => shot(s, device, tint)).join("")}
  ${shot(panel.shot, device, tint)}
  ${watch(panel.watch)}
  ${chat(panel.chat)}
  ${card(panel.card)}
  ${claims(panel.claims, tint)}
  ${chips(panel.chips)}
  ${founder(panel.founder)}
  ${overlays(panel.overlays)}
  ${panel.footnote ? `<p class="footnote">${rich(panel.footnote)}</p>` : ""}
  ${panel.splitTitle ? `<h1 class="lead" style="position:absolute; z-index:3; left:110px; right:110px; bottom:150px; margin:0;"><span class="light" style="opacity:1;">${rich(panel.headline.slice(panel.headline.indexOf(". ") + 2))}</span></h1>` : ""}
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
