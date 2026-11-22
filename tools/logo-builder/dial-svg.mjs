// Parametric SVG generator for the canonical Septena Upright Compass App Icon:
// - Upright North pointer (-90°) in the active exotic-fruit accent
// - 6 clean machined dial ticks at the remaining 7-way bearings
// - Checkmark mathematically aligned to the 2nd tick (-38.57°)
// - Bold recessed ring separating outside housing & inside dial (mild warm-stone on White shell)
// - Automatic contrast rule:
//     * Outside = Black or White -> Checkmark is ACCENTED (active exotic fruit)
//     * Outside = Accented Color -> Checkmark is BLACK ink on White inside (crisp white on Black inside)

const r = (n) => Number(n.toFixed(2));

export function squirclePath(size = 1024, pad = 0, radiusRatio = 0.285) {
  const x0 = pad, y0 = pad, w = size - pad * 2, h = size - pad * 2;
  const x1 = x0 + w, y1 = y0 + h, ext = w * radiusRatio, k = ext * 0.36;
  return `M ${r(x0 + ext)} ${r(y0)} L ${r(x1 - ext)} ${r(y0)} C ${r(x1 - k)} ${r(y0)}, ${r(x1)} ${r(y0 + k)}, ${r(x1)} ${r(y0 + ext)} L ${r(x1)} ${r(y1 - ext)} C ${r(x1)} ${r(y1 - k)}, ${r(x1 - k)} ${r(y1)}, ${r(x1 - ext)} ${r(y1)} L ${r(x0 + ext)} ${r(y1)} C ${r(x0 + k)} ${r(y1)}, ${r(x0)} ${r(y1 - k)}, ${r(x0)} ${r(y1 - ext)} L ${r(x0)} ${r(y0 + ext)} C ${r(x0)} ${r(y0 + k)}, ${r(x0 + k)} ${r(y0)}, ${r(x0 + ext)} ${r(y0)} Z`;
}

function northPointerPath(cx, cy, rBase = 238, rTip = 336, halfSpanDeg = 11.2, notchDepth = 22) {
  const deg = -90;
  const a0 = (deg * Math.PI) / 180;
  const aL = ((deg - halfSpanDeg) * Math.PI) / 180;
  const aR = ((deg + halfSpanDeg) * Math.PI) / 180;
  const tx = cx + Math.cos(a0) * rTip, ty = cy + Math.sin(a0) * rTip;
  const lx = cx + Math.cos(aL) * rBase, ly = cy + Math.sin(aL) * rBase;
  const rx = cx + Math.cos(aR) * rBase, ry = cy + Math.sin(aR) * rBase;
  const nx = cx + Math.cos(a0) * (rBase + notchDepth), ny = cy + Math.sin(a0) * (rBase + notchDepth);
  return `M ${r(tx)} ${r(ty)} L ${r(rx)} ${r(ry)} L ${r(nx)} ${r(ny)} L ${r(lx)} ${r(ly)} Z`;
}

export function hexToHsl(hex) {
  const c = (hex || '#27272E').replace('#', '').trim();
  const f = c.length === 3 ? c.split('').map(x => x + x).join('') : c.padEnd(6, '0').slice(0, 6);
  const rv = parseInt(f.slice(0, 2), 16) / 255;
  const gv = parseInt(f.slice(2, 4), 16) / 255;
  const bv = parseInt(f.slice(4, 6), 16) / 255;
  const max = Math.max(rv, gv, bv), min = Math.min(rv, gv, bv);
  let h = 0, s = 0, l = (max + min) / 2;
  if (max !== min) {
    const d = max - min;
    s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
    if (max === rv) h = ((gv - bv) / d + (gv < bv ? 6 : 0)) / 6;
    else if (max === gv) h = ((bv - rv) / d + 2) / 6;
    else h = ((rv - gv) / d + 4) / 6;
  }
  return { h: h * 360, s: s * 100, l: l * 100 };
}

export function hslToHex(h, s, l) {
  const hh = ((h % 360) + 360) % 360;
  const ss = Math.max(0, Math.min(100, s)) / 100;
  const ll = Math.max(0, Math.min(100, l)) / 100;
  const c = (1 - Math.abs(2 * ll - 1)) * ss;
  const x = c * (1 - Math.abs(((hh / 60) % 2) - 1));
  const m = ll - c / 2;
  let r1 = 0, g1 = 0, b1 = 0;
  if (hh < 60) { r1 = c; g1 = x; }
  else if (hh < 120) { r1 = x; g1 = c; }
  else if (hh < 180) { g1 = c; b1 = x; }
  else if (hh < 240) { g1 = x; b1 = c; }
  else if (hh < 300) { r1 = x; b1 = c; }
  else { r1 = c; b1 = x; }
  const t = v => Math.round((v + m) * 255).toString(16).padStart(2, '0');
  return `#${t(r1)}${t(g1)}${t(b1)}`.toUpperCase();
}

export const FRUIT_PALETTES = [
  { id: 'jabuticaba', name: 'Jabuticaba', origin: 'Brazil · Obsidian & orange north', base: '#27272E', dark: '#FF7738', accent: '#E05212', paper: '#FAF9F6', ink: '#27272E', isObsidian: true },
  { id: 'tamarillo',  name: 'Tamarillo',  origin: 'Andes · Ruby crimson',             base: '#D6333F', dark: '#FF5C67', accent: '#D6333F', paper: '#FFFDF9', ink: '#27272E' },
  { id: 'persimmon',  name: 'Persimmon',  origin: 'East Asia · Burnt vermilion',      base: '#E05212', dark: '#FF7738', accent: '#E05212', paper: '#FFFDF8', ink: '#27272E' },
  { id: 'yuzu',       name: 'Yuzu',       origin: 'Japan · Sunlit citrus gold',       base: '#C28500', dark: '#F2BF2C', accent: '#C28500', paper: '#FFFDF6', ink: '#27272E' },
  { id: 'carambola',  name: 'Carambola',  origin: 'SE Asia · Starfruit lime',         base: '#5B8C00', dark: '#9EE034', accent: '#5B8C00', paper: '#FCFDF8', ink: '#22291E' },
  { id: 'haskap',     name: 'Haskap',     origin: 'Hokkaido · Deep cobalt blue',      base: '#1D63DC', dark: '#4E94FF', accent: '#1D63DC', paper: '#FBFDFE', ink: '#1D2533' },
  { id: 'acai',       name: 'Açaí',       origin: 'Amazon · Royal indigo',            base: '#6544D6', dark: '#9B82FF', accent: '#6544D6', paper: '#FDFCFF', ink: '#232030' },
  { id: 'pitaya',     name: 'Pitaya',     origin: 'Mesoamerica · Dragonfruit',        base: '#D4266C', dark: '#FF5C9B', accent: '#D4266C', paper: '#FFFBFD', ink: '#2A2128' },
];

export const DIAL_PALETTES = FRUIT_PALETTES;

export const DIAL_PROPOSALS = [
  {
    id: 'septena-compass',
    name: 'Septena Compass',
    shortName: 'Septena Compass',
    rationale: 'Canonical upright compass: vivid North pointer UP, 6 machined ticks, checkmark aligned to the 2nd tick (accented on Black/White shells; black ink on colored shells).',
  },
];

export function deriveDialTokens(pal, opts = {}) {
  const shellMode = opts.shellMode || (pal.isObsidian ? 'black' : 'color');
  const isStealth = shellMode === 'stealth';
  // Stealth is always dark-on-dark (black shell + smoked matte-black dial), even in Light OS
  const faceMode = isStealth ? 'black' : (opts.faceMode || 'white');
  const isWhiteShell = shellMode === 'white';
  const isBlackShell = isStealth || shellMode === 'black' || (shellMode === 'color' && Boolean(pal.isObsidian));
  const isColoredShell = !isWhiteShell && !isBlackShell;
  const isDarkFace = faceMode === 'black';
  const isMono = Boolean(opts.mono || pal.isMono);
  // Automatic contrast rule: Black/White/Stealth outside -> accented check (or mono titanium/charcoal);
  // Colored outside -> 90% black ink check (crisp white on black inside)
  const accentCheck = !isColoredShell && !isMono;

  const shellBase = isWhiteShell ? '#EFECE6' : (isBlackShell ? '#27272E' : pal.base);
  const b = hexToHsl(shellBase);
  const accBase = pal.accent || '#E05212';
  const a = hexToHsl(accBase);
  const p = hexToHsl(pal.paper || '#FAF9F6');

  let shellTop, shellMid, shellBot, shellRim, wellTop, wellMid, wellBot, shadow;
  if (isWhiteShell) {
    shellTop = '#FFFFFF'; shellMid = '#F4F2ED'; shellBot = '#E4E1D9'; shellRim = '#FFFFFF';
    wellTop = isDarkFace ? '#AEABA2' : '#B9B5AC';
    wellMid = isDarkFace ? '#C2BFB7' : '#CBC7BE';
    wellBot = isDarkFace ? '#D4D1C9' : '#DBD8D0';
    shadow = '#6E6A61';
  } else if (isStealth) {
    // Deep satin PVD obsidian shell + pitch-dark groove + smoked graphite dial
    shellTop = '#26272E'; shellMid = '#17181D'; shellBot = '#0C0D10'; shellRim = '#4C4F5C';
    wellTop = '#040406'; wellMid = '#08090C'; wellBot = '#0F1015';
    shadow = '#020204';
  } else if (isBlackShell) {
    shellTop = '#3B3C46'; shellMid = '#27272E'; shellBot = '#15151A'; shellRim = '#686A78';
    wellTop = '#07070A'; wellMid = '#0F1015'; wellBot = '#181920';
    shadow = '#040407';
  } else {
    shellTop = hslToHex(b.h + 4, Math.min(100, b.s + 2), Math.min(82, b.l + 11));
    shellMid = shellBase;
    shellBot = hslToHex(b.h - 4, Math.min(100, b.s + 6), Math.max(6, b.l - 13));
    shellRim = pal.dark || hslToHex(b.h + 6, Math.max(12, b.s - 6), Math.min(94, b.l + 28));
    wellTop = hslToHex(b.h - 4, Math.min(100, b.s + 14), Math.max(11, Math.min(20, b.l - 28)));
    wellMid = hslToHex(b.h - 2, Math.min(100, b.s + 12), Math.max(15, Math.min(25, b.l - 23)));
    wellBot = hslToHex(b.h - 1, Math.min(100, b.s + 10), Math.max(20, Math.min(31, b.l - 17)));
    shadow = hslToHex(b.h - 6, Math.min(100, b.s + 12), Math.max(3, b.l - 36));
  }

  // Mono accent (Jabuticaba): brushed titanium on dark/stealth dial, 90% charcoal on white dial
  const accLight = isMono
    ? (isDarkFace ? (isStealth ? '#C9CDD6' : '#EFEFF4') : '#525660')
    : (pal.dark ? pal.dark : hslToHex(a.h + 6, Math.min(100, a.s + 4), Math.min(82, a.l + 16)));
  const accMid = isMono
    ? (isDarkFace ? (isStealth ? '#9DA2AE' : '#D5D7E0') : '#434750')
    : accBase;
  const accDeep = isMono
    ? (isDarkFace ? (isStealth ? '#777C88' : '#B4B7C2') : '#32353C')
    : hslToHex(a.h - 6, Math.min(100, a.s + 10), Math.max(12, a.l - 15));

  return {
    isWhiteShell, isBlackShell, isStealth, isColoredShell, isDarkFace, isMono, accentCheck: accentCheck || isMono,
    shellTop, shellMid, shellBot, shellRim, wellTop, wellMid, wellBot, shadow,
    faceTop: isStealth ? '#212229' : (isDarkFace ? '#2E2F38' : hslToHex(p.h, p.s, Math.min(100, p.l + 1))),
    faceMid: isStealth ? '#16171C' : (isDarkFace ? '#22232B' : (pal.paper || '#FAF9F6')),
    faceBot: isStealth ? '#0E0F13' : (isDarkFace ? '#17181E' : hslToHex(p.h - 2, Math.min(36, p.s + 8), Math.max(86, p.l - 5))),
    faceRimOp: isStealth ? 0.14 : (isDarkFace ? 0.18 : 0.94),
    accLight,
    accMid,
    accDeep,
    // 90% dark charcoal-graphite ink matching Things 3's calm checkmark tone (white on dark face)
    checkInkTop: isDarkFace ? '#F6F6F8' : '#4C5058',
    checkInkBot: isDarkFace ? '#DFDFE5' : '#363940',
    checkInk: isDarkFace ? '#F4F4F6' : '#3F424A',
    mutedGlyph: isStealth ? '#9A9EA9' : (isDarkFace ? '#C7C9D4' : '#6A6770'),
    tickMutedOp: isStealth ? 0.28 : (isDarkFace ? 0.34 : 0.28),
  };
}

export function renderDialSVG(proposalId, palette, opts = {}) {
  const pal = palette || FRUIT_PALETTES[0];
  const fullBleed = !!opts.fullBleed;
  const size = opts.size ?? 1024;
  const shellMode = opts.shellMode || 'black';
  const faceMode = opts.faceMode || 'white';
  const uid = opts.uid || opts.idPrefix || `sc_${shellMode[0]}${faceMode[0]}_${Math.abs((pal.accent || pal.base || '').split('').reduce((a, c) => ((a << 5) - a + c.charCodeAt(0)) | 0, 0)) % 997}`;
  const t = deriveDialTokens(pal, { shellMode, faceMode, mono: opts.mono });
  const outerClip = squirclePath(1024, 0, 0.285);
  const rimPath = squirclePath(1024, 8, 0.282);
  const cx = 512, cy = 512, step = 360 / 7;
  const checkMain = 'M 377 511 L 460 598 L 639 426';
  const accMidStop = t.isDarkFace ? '68%' : '52%';

  const northArrow = northPointerPath(cx, cy, 238, 336, 11.2, 22);
  const ticks = [];
  for (let i = 1; i < 7; i++) {
    const rad = ((-90 + i * step) * Math.PI) / 180;
    ticks.push(`<line x1="${r(cx + Math.cos(rad) * 260)}" y1="${r(cy + Math.sin(rad) * 260)}" x2="${r(cx + Math.cos(rad) * 310)}" y2="${r(cy + Math.sin(rad) * 310)}" stroke="${t.mutedGlyph}" stroke-width="24" stroke-linecap="round" opacity="${t.tickMutedOp}"/>`);
  }

  const checkMarkup = t.accentCheck
    ? `<g filter="url(#${uid}_shSm)"><path d="${checkMain}" fill="none" stroke="url(#${uid}_acc)" stroke-width="64" stroke-linecap="round" stroke-linejoin="round"/></g>`
    : `${t.isDarkFace ? '' : `<path d="${checkMain}" fill="none" stroke="#FFFFFF" stroke-opacity="0.65" stroke-width="66" stroke-linecap="round" stroke-linejoin="round" transform="translate(0, 5)"/>`}<path d="${checkMain}" fill="none" stroke="url(#${uid}_ink)" stroke-width="64" stroke-linecap="round" stroke-linejoin="round"/>`;

  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="${size}" height="${size}">
  <defs>
    ${fullBleed ? '' : `<clipPath id="${uid}_clip"><path d="${outerClip}"/></clipPath>`}
    <linearGradient id="${uid}_shell" x1="0.16" y1="0.02" x2="0.84" y2="1">
      <stop offset="0%" stop-color="${t.shellTop}"/>
      <stop offset="48%" stop-color="${t.shellMid}"/>
      <stop offset="100%" stop-color="${t.shellBot}"/>
    </linearGradient>
    <radialGradient id="${uid}_sheen" cx="0.28" cy="0.12" r="0.72">
      <stop offset="0%" stop-color="#FFFFFF" stop-opacity="${t.isWhiteShell ? 0.45 : (t.isBlackShell ? 0.16 : 0.24)}"/>
      <stop offset="55%" stop-color="#FFFFFF" stop-opacity="0.03"/>
      <stop offset="100%" stop-color="#000000" stop-opacity="${t.isWhiteShell ? 0.06 : 0.12}"/>
    </radialGradient>
    <linearGradient id="${uid}_well" x1="0.2" y1="0" x2="0.8" y2="1">
      <stop offset="0%" stop-color="${t.wellTop}"/>
      <stop offset="55%" stop-color="${t.wellMid}"/>
      <stop offset="100%" stop-color="${t.wellBot}"/>
    </linearGradient>
    <radialGradient id="${uid}_face" cx="42%" cy="30%" r="72%">
      <stop offset="0%" stop-color="${t.faceTop}"/>
      <stop offset="62%" stop-color="${t.faceMid}"/>
      <stop offset="100%" stop-color="${t.faceBot}"/>
    </radialGradient>
    <linearGradient id="${uid}_acc" x1="0.18" y1="0" x2="0.82" y2="1">
      <stop offset="0%" stop-color="${t.accLight}"/>
      <stop offset="${accMidStop}" stop-color="${t.accMid}"/>
      <stop offset="100%" stop-color="${t.accDeep}"/>
    </linearGradient>
    <linearGradient id="${uid}_ink" x1="0.25" y1="0" x2="0.75" y2="1">
      <stop offset="0%" stop-color="${t.checkInkTop}"/>
      <stop offset="100%" stop-color="${t.checkInkBot}"/>
    </linearGradient>
    <filter id="${uid}_shPlate" x="-16%" y="-14%" width="132%" height="136%">
      <feDropShadow dx="0" dy="14" stdDeviation="14" flood-color="${t.shadow}" flood-opacity="${t.isWhiteShell ? 0.30 : 0.44}"/>
      <feDropShadow dx="0" dy="3" stdDeviation="4" flood-color="${t.shadow}" flood-opacity="0.26"/>
    </filter>
    <filter id="${uid}_shSm" x="-22%" y="-22%" width="144%" height="148%">
      <feDropShadow dx="0" dy="6" stdDeviation="6" flood-color="${t.shadow}" flood-opacity="0.30"/>
    </filter>
  </defs>
  <g${fullBleed ? '' : ` clip-path="url(#${uid}_clip)"`}>
    <rect x="0" y="0" width="1024" height="1024" fill="url(#${uid}_shell)"/>
    <rect x="0" y="0" width="1024" height="1024" fill="url(#${uid}_sheen)"/>
    ${fullBleed ? '' : `<path d="${rimPath}" fill="none" stroke="${t.isWhiteShell ? '#000000' : t.shellRim}" stroke-opacity="${t.isWhiteShell ? 0.08 : 0.32}" stroke-width="5"/>`}
    <circle cx="${cx}" cy="${cy}" r="416" fill="url(#${uid}_well)"/>
    <circle cx="${cx}" cy="${cy}" r="412" fill="none" stroke="${t.shadow}" stroke-opacity="${t.isWhiteShell ? 0.28 : 0.55}" stroke-width="8"/>
    <circle cx="${cx}" cy="${cy + 3}" r="415" fill="none" stroke="#FFFFFF" stroke-opacity="${t.isWhiteShell ? 0.85 : 0.20}" stroke-width="4"/>
    <g filter="url(#${uid}_shPlate)">
      <circle cx="${cx}" cy="${cy}" r="354" fill="url(#${uid}_face)"/>
      <circle cx="${cx}" cy="${cy}" r="351" fill="none" stroke="#FFFFFF" stroke-opacity="${t.faceRimOp}" stroke-width="5"/>
    </g>
    <g>${ticks.join('')}</g>
    <path d="${northArrow}" fill="url(#${uid}_acc)" stroke="${t.accDeep}" stroke-opacity="0.24" stroke-width="2" filter="url(#${uid}_shSm)"/>
    ${checkMarkup}
  </g>
</svg>`;
}
