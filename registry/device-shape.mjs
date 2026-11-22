// Draws the canonical devices in registry/device-frames.json as SVG. The one
// implementation every renderer uses: the website scenes (septena-site syncs
// this file) and the App Store panels (appstore/components.mjs). No renderer
// draws device corners with CSS border-radius: Safari has no corner-shape, and
// circular arcs are not Apple's continuous corners.
//
// corner "continuous": Apple's continuous corner, the Bezier construction of
// UIBezierPath(roundedRect:cornerRadius:) since iOS 7. The curve starts 1.528x
// the radius from the corner and eases in, with no sudden change in curvature.
// corner "circular": plain quarter circles.

const RIM = 2;
// One corner as cubic segments in corner coordinates: a = distance back along
// the incoming edge, b = distance along the outgoing edge, in units of the radius.
const CORNERS = {
  continuous: [
    [1.52866483, 0],
    ["C", [1.08849323, 0], [0.86840689, 0], [0.66993427, 0.06549600]],
    ["L", [0.63149399, 0.07491176]],
    ["C", [0.37282392, 0.16906013], [0.16906013, 0.37282392], [0.07491176, 0.63149399]],
    ["L", [0.06549600, 0.66993427]],
    ["C", [0, 0.86840689], [0, 1.08849323], [0, 1.52866483]],
  ],
  circular: [
    [1, 0],
    ["C", [0.44771525, 0], [0, 0.44771525], [0, 1]],
  ],
};
const REACH = { continuous: 1.52866483, circular: 1 };

/**
 * Path of a rounded rectangle with separate top and bottom corner radii, drawn clockwise.
 * @param {number} width @param {number} height
 * @param {{ top: number, bottom?: number }} radius
 * @param {"continuous" | "circular"} corner
 */
export function roundedRectPath(width, height, radius, corner = "circular") {
  const reach = REACH[corner], limit = Math.min(width, height) / 2 / reach;
  const top = Math.max(0, Math.min(radius.top, limit)), bottom = Math.max(0, Math.min(radius.bottom ?? radius.top, limit));
  // Each corner maps (a, b) to page coordinates, walking clockwise from the top edge.
  const maps = [
    [top, (a, b, r) => [width - a * r, b * r]],
    [bottom, (a, b, r) => [width - b * r, height - a * r]],
    [bottom, (a, b, r) => [a * r, height - b * r]],
    [top, (a, b, r) => [b * r, a * r]],
  ];
  const f = n => n.toFixed(2);
  let d = "";
  maps.forEach(([r, map], index) => {
    const [first, ...segments] = CORNERS[corner];
    const start = map(first[0], first[1], r);
    d += `${index === 0 ? "M" : "L"}${f(start[0])} ${f(start[1])}`;
    if (r === 0) return;
    for (const [kind, ...points] of segments) {
      d += kind + points.map(([a, b]) => map(a, b, r)).map(([x, y]) => `${f(x)} ${f(y)}`).join(" ");
    }
  });
  return `${d}Z`;
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

/** A laptop lid: lid size, the lid drawing (rim plus black glass) and the screen mask (the same corner on all four corners, concentric with the lid top). */
export function laptopShape(device) {
  const w = device.screen.width + 2 * (device.bezel + RIM), h = device.screen.height + 2 * (device.bezel + RIM);
  const lid = { top: device.outerRadius, bottom: device.hingeRadius }, glass = { top: device.outerRadius - RIM, bottom: Math.max(0, device.hingeRadius - RIM) };
  return {
    width: w, height: h, rim: RIM,
    lid: svg(w, h, `<defs>${svgGradient(device.finish)}</defs><path d="${roundedRectPath(w, h, lid, device.corner)}" fill="url(#f)"/><path d="${roundedRectPath(w - 2 * RIM, h - 2 * RIM, glass, device.corner)}" transform="translate(${RIM} ${RIM})" fill="${device.finish.glass}"/>`),
    screen: svg(device.screen.width, device.screen.height, `<path d="${roundedRectPath(device.screen.width, device.screen.height, { top: Math.max(0, device.outerRadius - RIM - device.bezel) }, device.corner)}"/>`),
  };
}
