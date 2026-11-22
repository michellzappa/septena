// Draws the canonical devices in registry/device-frames.json as SVG. The one
// implementation every renderer uses: the website scenes (septena-site syncs
// this file) and the App Store panels (appstore/components.mjs). No renderer
// draws device corners with CSS border-radius: Safari has no corner-shape, and
// circular arcs are not Apple's continuous corners.
//
// corner "continuous": a superellipse that eases into the edge, reaching 1.528x
// the nominal radius along each edge (Apple's continuous corner).
// corner "circular": plain arcs (exponent 2 is a circle).

const CURVES = { continuous: { exponent: 5, reach: 1.528 }, circular: { exponent: 2, reach: 1 } };
const RIM = 2;

/**
 * Path of a rounded rectangle with separate top and bottom corner radii.
 * @param {number} width @param {number} height
 * @param {{ top: number, bottom?: number }} radius
 * @param {"continuous" | "circular"} corner
 */
export function roundedRectPath(width, height, radius, corner = "circular", steps = 18) {
  const { exponent, reach } = CURVES[corner];
  const limit = Math.min(width, height) / 2;
  const top = Math.min(radius.top * reach, limit), bottom = Math.min((radius.bottom ?? radius.top) * reach, limit);
  const corners = [[width - bottom, height - bottom, bottom], [bottom, height - bottom, bottom], [top, top, top], [width - top, top, top]];
  const points = [];
  corners.forEach(([cx, cy, r], quadrant) => {
    for (let i = 0; i <= steps; i++) {
      const t = (quadrant + i / steps) * (Math.PI / 2), c = Math.cos(t), s = Math.sin(t);
      points.push(`${(cx + r * Math.sign(c) * Math.abs(c) ** (2 / exponent)).toFixed(2)} ${(cy + r * Math.sign(s) * Math.abs(s) ** (2 / exponent)).toFixed(2)}`);
    }
  });
  return `M${points.join("L")}Z`;
}

/** CSS linear-gradient for a finish ({ angle, stops }). */
export function cssGradient(finish) {
  return `linear-gradient(${finish.angle}deg,${finish.stops.map(([at, color]) => `${color} ${Math.round(at * 100)}%`).join(",")})`;
}

const uri = svg => `url("data:image/svg+xml,${encodeURIComponent(svg)}")`;
function svgGradient(finish) {
  const a = (finish.angle * Math.PI) / 180, x = Math.sin(a) / 2, y = -Math.cos(a) / 2;
  const stops = finish.stops.map(([at, color]) => `<stop offset="${at}" stop-color="${color}"/>`).join("");
  return `<linearGradient id="f" x1="${(0.5 - x).toFixed(3)}" y1="${(0.5 - y).toFixed(3)}" x2="${(0.5 + x).toFixed(3)}" y2="${(0.5 + y).toFixed(3)}">${stops}</linearGradient>`;
}
const svg = (w, h, body) => uri(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">${body}</svg>`);

/** A phone: case size, the case drawing (CSS background) and the screen mask (CSS mask). */
export function phoneShape(device) {
  const w = device.screen.width + 2 * device.bezel, h = device.screen.height + 2 * device.bezel;
  const outer = { top: device.outerRadius }, inner = { top: device.outerRadius - device.bezel };
  return {
    width: w, height: h,
    case: svg(w, h, `<defs>${svgGradient(device.finish)}</defs><path d="${roundedRectPath(w, h, outer, device.corner)}" fill="url(#f)"/><path d="${roundedRectPath(w - 1, h - 1, { top: device.outerRadius - 0.5 }, device.corner)}" transform="translate(.5 .5)" fill="none" stroke="${device.finish.highlight}"/>`),
    screen: svg(device.screen.width, device.screen.height, `<path d="${roundedRectPath(device.screen.width, device.screen.height, inner, device.corner)}"/>`),
  };
}

/** A laptop lid: lid size, the lid drawing (rim plus black glass) and the screen mask (rounded top corners only). */
export function laptopShape(device) {
  const w = device.screen.width + 2 * (device.bezel + RIM), h = device.screen.height + 2 * (device.bezel + RIM);
  const lid = { top: device.outerRadius, bottom: device.hingeRadius }, glass = { top: device.outerRadius - RIM, bottom: Math.max(0, device.hingeRadius - RIM) };
  return {
    width: w, height: h, rim: RIM,
    lid: svg(w, h, `<defs>${svgGradient(device.finish)}</defs><path d="${roundedRectPath(w, h, lid, device.corner)}" fill="url(#f)"/><path d="${roundedRectPath(w - 2 * RIM, h - 2 * RIM, glass, device.corner)}" transform="translate(${RIM} ${RIM})" fill="${device.finish.glass}"/>`),
    screen: svg(device.screen.width, device.screen.height, `<path d="${roundedRectPath(device.screen.width, device.screen.height, { top: Math.max(0, device.outerRadius - RIM - device.bezel), bottom: 0 }, device.corner)}"/>`),
  };
}
