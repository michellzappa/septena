// Septena Brand Studio — Shared Canonical Icon, Color & Surface Identity State
// Zero-dependency browser script (works identically over file:// and http://).
// Canonical Septena Upright Compass:
//   - Outside (`black` | `white` | `color`) × Inside (`white` | `black`) × 8 Exotic Fruits
//   - Auto contrast rule: Black/White outside -> accented check; Colored outside -> black ink check
(function (global) {
  const STORAGE_KEY = 'septena.brand.identity.v1';
  const r = (n) => Number(n.toFixed(2));

  function squirclePath(size = 1024, pad = 0, radiusRatio = 0.285) {
    const x0 = pad, y0 = pad, w = size - pad * 2, h = size - pad * 2;
    const x1 = x0 + w, y1 = y0 + h, ext = w * radiusRatio, k = ext * 0.36;
    return `M ${r(x0 + ext)} ${r(y0)} L ${r(x1 - ext)} ${r(y0)} C ${r(x1 - k)} ${r(y0)}, ${r(x1)} ${r(y0 + k)}, ${r(x1)} ${r(y0 + ext)} L ${r(x1)} ${r(y1 - ext)} C ${r(x1)} ${r(y1 - k)}, ${r(x1 - k)} ${r(y1)}, ${r(x1 - ext)} ${r(y1)} L ${r(x0 + ext)} ${r(y1)} C ${r(x0 + k)} ${r(y1)}, ${r(x0)} ${r(y1 - k)}, ${r(x0)} ${r(y1 - ext)} L ${r(x0)} ${r(y0 + ext)} C ${r(x0)} ${r(y0 + k)}, ${r(x0 + k)} ${r(y0)}, ${r(x0 + ext)} ${r(y0)} Z`;
  }

  function northPointerPath(cx, cy, rBase = 238, rTip = 336, halfSpanDeg = 11.2, notchDepth = 22) {
    const deg = -90, a0 = (deg * Math.PI) / 180, aL = ((deg - halfSpanDeg) * Math.PI) / 180, aR = ((deg + halfSpanDeg) * Math.PI) / 180;
    const tx = cx + Math.cos(a0) * rTip, ty = cy + Math.sin(a0) * rTip;
    const lx = cx + Math.cos(aL) * rBase, ly = cy + Math.sin(aL) * rBase;
    const rx = cx + Math.cos(aR) * rBase, ry = cy + Math.sin(aR) * rBase;
    const nx = cx + Math.cos(a0) * (rBase + notchDepth), ny = cy + Math.sin(a0) * (rBase + notchDepth);
    return `M ${r(tx)} ${r(ty)} L ${r(rx)} ${r(ry)} L ${r(nx)} ${r(ny)} L ${r(lx)} ${r(ly)} Z`;
  }

  function hexToHsl(hex) {
    const c = (hex || '#27272E').replace('#', '').trim();
    const f = c.length === 3 ? c.split('').map(x => x + x).join('') : c.padEnd(6, '0').slice(0, 6);
    const rv = parseInt(f.slice(0, 2), 16) / 255, gv = parseInt(f.slice(2, 4), 16) / 255, bv = parseInt(f.slice(4, 6), 16) / 255;
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

  function hslToHex(h, s, l) {
    const hh = ((h % 360) + 360) % 360, ss = Math.max(0, Math.min(100, s)) / 100, ll = Math.max(0, Math.min(100, l)) / 100;
    const c = (1 - Math.abs(2 * ll - 1)) * ss, x = c * (1 - Math.abs(((hh / 60) % 2) - 1)), m = ll - c / 2;
    let r1 = 0, g1 = 0, b1 = 0;
    if (hh < 60) { r1 = c; g1 = x; } else if (hh < 120) { r1 = x; g1 = c; } else if (hh < 180) { g1 = c; b1 = x; }
    else if (hh < 240) { g1 = x; b1 = c; } else if (hh < 300) { r1 = x; b1 = c; } else { r1 = c; b1 = x; }
    const t = v => Math.round((v + m) * 255).toString(16).padStart(2, '0');
    return `#${t(r1)}${t(g1)}${t(b1)}`.toUpperCase();
  }

  const FRUIT_SEEDS = [
    { id: 'jabuticaba', name: 'Jabuticaba', origin: 'Brazil · Obsidian & orange north', base: '#27272E', dark: '#FF7738', accent: '#E05212', paper: '#FAF9F6', ink: '#27272E', isObsidian: true },
    { id: 'tamarillo',  name: 'Tamarillo',  origin: 'Andes · Ruby crimson',             base: '#D6333F', dark: '#FF5C67', accent: '#D6333F', paper: '#FFFDF9', ink: '#27272E' },
    { id: 'persimmon',  name: 'Persimmon',  origin: 'East Asia · Burnt vermilion',      base: '#E05212', dark: '#FF7738', accent: '#E05212', paper: '#FFFDF8', ink: '#27272E' },
    { id: 'yuzu',       name: 'Yuzu',       origin: 'Japan · Sunlit citrus gold',       base: '#C28500', dark: '#F2BF2C', accent: '#C28500', paper: '#FFFDF6', ink: '#27272E' },
    { id: 'carambola',  name: 'Carambola',  origin: 'SE Asia · Starfruit lime',         base: '#5B8C00', dark: '#9EE034', accent: '#5B8C00', paper: '#FCFDF8', ink: '#22291E' },
    { id: 'haskap',     name: 'Haskap',     origin: 'Hokkaido · Deep cobalt blue',      base: '#1D63DC', dark: '#4E94FF', accent: '#1D63DC', paper: '#FBFDFE', ink: '#1D2533' },
    { id: 'acai',       name: 'Açaí',       origin: 'Amazon · Royal indigo',            base: '#6544D6', dark: '#9B82FF', accent: '#6544D6', paper: '#FDFCFF', ink: '#232030' },
    { id: 'pitaya',     name: 'Pitaya',     origin: 'Mesoamerica · Dragonfruit',        base: '#D4266C', dark: '#FF5C9B', accent: '#D4266C', paper: '#FFFBFD', ink: '#2A2128' },
  ];

  function buildFruitPalette(seed) {
    const b = hexToHsl(seed.base);
    const isObsidian = Boolean(seed.isObsidian) || (b.l < 22 && b.s < 18);
    const accHex = seed.accent || (isObsidian ? '#E05212' : seed.base);
    const a = hexToHsl(accHex);
    return {
      ...seed,
      baseHex: seed.base,
      isObsidian,
      lightBg: false,
      bezelTop: hslToHex(b.h + 4, Math.min(100, b.s + (isObsidian ? 0 : 2)), Math.min(82, b.l + 10)),
      bezelBot: hslToHex(b.h - 4, Math.min(100, b.s + (isObsidian ? 2 : 6)), Math.max(6, b.l - 13)),
      bezelRim: seed.dark && !isObsidian ? seed.dark : hslToHex(b.h + 6, Math.max(12, b.s - 6), Math.min(94, b.l + 28)),
      wellTop: hslToHex(b.h - 4, Math.min(100, b.s + (isObsidian ? 2 : 14)), isObsidian ? 5 : Math.max(11, Math.min(20, b.l - 28))),
      wellBot: hslToHex(b.h - 1, Math.min(100, b.s + (isObsidian ? 2 : 10)), isObsidian ? 12 : Math.max(20, Math.min(31, b.l - 17))),
      surfaceTop: isObsidian ? '#2E2F38' : (seed.paper || '#FFFDF8'),
      surfaceBot: isObsidian ? '#191A20' : '#EFECE4',
      surfaceBack: isObsidian ? '#14151B' : '#E2DDD2',
      accentLight: seed.dark ? seed.dark : hslToHex(a.h + 6, Math.min(100, a.s + 4), Math.min(82, a.l + 16)),
      accentMid: accHex,
      accentDeep: hslToHex(a.h - 6, Math.min(100, a.s + 10), Math.max(12, a.l - 15)),
      shadow: hslToHex(b.h - 6, Math.min(100, b.s + 12), Math.max(3, b.l - 36)),
      bgBase: isObsidian ? '#1B1C22' : hslToHex(b.h, Math.min(86, b.s), Math.max(18, b.l - 8)),
      bgDeep: isObsidian ? '#0C0D11' : hslToHex(b.h - 5, Math.min(90, b.s + 6), Math.max(7, b.l - 24)),
      bgGlow: seed.dark ? seed.dark : '#FF7738',
      bgInk: '#F6F7FA',
    };
  }

  const FRUIT_PALETTES = FRUIT_SEEDS.map(buildFruitPalette);
  const PALETTES = FRUIT_PALETTES;
  const MONOLITH_PALETTES = FRUIT_PALETTES;

  // 6 quick-pick finish presets of the ONE canonical Septena Upright Compass
  const DIAL_PROPOSALS = [
    { id: 'compass-black-white', family: 'dial', shell: 'black', face: 'white', name: 'Black · White Inside',  shortName: 'Black / White', defaultPalette: 'jabuticaba', defaultBgStyle: 'rings' },
    { id: 'compass-black-black', family: 'dial', shell: 'black', face: 'black', name: 'Black · Black Inside',  shortName: 'Black / Black', defaultPalette: 'jabuticaba', defaultBgStyle: 'rings' },
    { id: 'compass-white-white', family: 'dial', shell: 'white', face: 'white', name: 'White · White Inside',  shortName: 'White / White', defaultPalette: 'jabuticaba', defaultBgStyle: 'linen' },
    { id: 'compass-white-black', family: 'dial', shell: 'white', face: 'black', name: 'White · Black Inside',  shortName: 'White / Black', defaultPalette: 'jabuticaba', defaultBgStyle: 'grid'  },
    { id: 'compass-color-white', family: 'dial', shell: 'color', face: 'white', name: 'Color · White Inside',  shortName: 'Color / White', defaultPalette: 'persimmon',  defaultBgStyle: 'rings' },
    { id: 'compass-color-black', family: 'dial', shell: 'color', face: 'black', name: 'Color · Black Inside',  shortName: 'Color / Black', defaultPalette: 'persimmon',  defaultBgStyle: 'rings' },
  ];

  const ALL_PROPOSALS = [...DIAL_PROPOSALS];

  function deriveCustomPalette({ housing, surface, accent }) {
    return buildFruitPalette({
      id: 'custom', name: 'Custom Brand', origin: 'Custom',
      base: housing || '#27272E', dark: accent || '#FF7738',
      accent: accent || '#E05212', paper: surface || '#FAF9F6', ink: '#27272E',
    });
  }

  function renderDialSVG(proposalId, c, options = {}) {
    const size = options.size ?? 1024;
    const p = options.idPrefix ? `${options.idPrefix}_` : '';
    const preset = DIAL_PROPOSALS.find(x => x.id === proposalId);
    const shellMode = options.shellMode || (preset && preset.shell) || c.shellMode || 'black';
    const faceMode = options.faceMode || (preset && preset.face) || c.faceMode || 'white';
    const isWhiteShell = shellMode === 'white';
    const isBlackShell = shellMode === 'black' || (shellMode === 'color' && Boolean(c.isObsidian));
    const isColoredShell = !isWhiteShell && !isBlackShell;
    const isDarkFace = faceMode === 'black';
    // Auto contrast rule: Black/White outside -> accented check; Colored outside -> black ink check (white on black inside)
    const accentCheck = !isColoredShell;

    const shellBaseHex = isWhiteShell ? '#EFECE6' : (isBlackShell ? '#27272E' : (c.base || c.baseHex || c.bezelTop || '#E05212'));
    const b = hexToHsl(shellBaseHex);
    const accHex = c.accent || c.accentMid || '#E05212';
    const a = hexToHsl(accHex);
    const paperHex = c.paper || '#FAF9F6';
    const ph = hexToHsl(paperHex);

    let shellTop, shellMid, shellBot, shellRim, wellTop, wellMid, wellBot, shadow;
    if (isWhiteShell) {
      shellTop = '#FFFFFF'; shellMid = '#F4F2ED'; shellBot = '#E4E1D9'; shellRim = '#FFFFFF';
      wellTop = isDarkFace ? '#AEABA2' : '#B9B5AC';
      wellMid = isDarkFace ? '#C2BFB7' : '#CBC7BE';
      wellBot = isDarkFace ? '#D4D1C9' : '#DBD8D0';
      shadow = '#6E6A61';
    } else if (isBlackShell) {
      shellTop = '#3B3C46'; shellMid = '#27272E'; shellBot = '#15151A'; shellRim = '#686A78';
      wellTop = '#07070A'; wellMid = '#0F1015'; wellBot = '#181920';
      shadow = '#040407';
    } else {
      shellTop = hslToHex(b.h + 4, Math.min(100, b.s + 2), Math.min(82, b.l + 11));
      shellMid = shellBaseHex;
      shellBot = hslToHex(b.h - 4, Math.min(100, b.s + 6), Math.max(6, b.l - 13));
      shellRim = c.dark || hslToHex(b.h + 6, Math.max(12, b.s - 6), Math.min(94, b.l + 28));
      wellTop = hslToHex(b.h - 4, Math.min(100, b.s + 14), Math.max(11, Math.min(20, b.l - 28)));
      wellMid = hslToHex(b.h - 2, Math.min(100, b.s + 12), Math.max(15, Math.min(25, b.l - 23)));
      wellBot = hslToHex(b.h - 1, Math.min(100, b.s + 10), Math.max(20, Math.min(31, b.l - 17)));
      shadow = hslToHex(b.h - 6, Math.min(100, b.s + 12), Math.max(3, b.l - 36));
    }

    const faceTop = isDarkFace ? '#2E2F38' : hslToHex(ph.h, ph.s, Math.min(100, ph.l + 1));
    const faceMid = isDarkFace ? '#22232B' : paperHex;
    const faceBot = isDarkFace ? '#17181E' : hslToHex(ph.h - 2, Math.min(36, ph.s + 8), Math.max(86, ph.l - 5));
    const faceRimOp = isDarkFace ? 0.18 : 0.94;
    const accLight = c.dark ? c.dark : hslToHex(a.h + 6, Math.min(100, a.s + 4), Math.min(82, a.l + 16));
    const accDeep = hslToHex(a.h - 6, Math.min(100, a.s + 10), Math.max(12, a.l - 15));
    const checkInkTop = isDarkFace ? '#F6F6F8' : '#4C5058';
    const checkInkBot = isDarkFace ? '#DFDFE5' : '#363940';
    const mutedGlyph = isDarkFace ? '#C7C9D4' : '#6A6770';
    const sq = squirclePath(1024, 0), rimSq = squirclePath(1024, 8, 0.282);
    const cx = 512, cy = 512, step = 360 / 7, checkMain = 'M 377 511 L 460 598 L 639 426';
    const accMidStop = isDarkFace ? '68%' : '52%';

    const northArrow = northPointerPath(cx, cy, 238, 336, 11.2, 22);
    const ticks = [];
    for (let i = 1; i < 7; i++) {
      const rad = ((-90 + i * step) * Math.PI) / 180;
      ticks.push(`<line x1="${r(cx + Math.cos(rad) * 260)}" y1="${r(cy + Math.sin(rad) * 260)}" x2="${r(cx + Math.cos(rad) * 310)}" y2="${r(cy + Math.sin(rad) * 310)}" stroke="${mutedGlyph}" stroke-width="24" stroke-linecap="round" opacity="${isDarkFace ? 0.34 : 0.28}"/>`);
    }
    const checkMarkup = accentCheck
      ? `<g filter="url(#${p}sD)"><path d="${checkMain}" fill="none" stroke="url(#${p}aG)" stroke-width="64" stroke-linecap="round" stroke-linejoin="round"/></g>`
      : `${isDarkFace ? '' : `<path d="${checkMain}" fill="none" stroke="#FFFFFF" stroke-opacity="0.65" stroke-width="66" stroke-linecap="round" stroke-linejoin="round" transform="translate(0, 5)"/>`}<path d="${checkMain}" fill="none" stroke="url(#${p}iG)" stroke-width="64" stroke-linecap="round" stroke-linejoin="round"/>`;

    const defs = `<clipPath id="${p}sq"><path d="${sq}"/></clipPath><linearGradient id="${p}sG" x1="16%" y1="2%" x2="84%" y2="100%"><stop offset="0%" stop-color="${shellTop}"/><stop offset="48%" stop-color="${shellMid}"/><stop offset="100%" stop-color="${shellBot}"/></linearGradient><radialGradient id="${p}sS" cx="28%" cy="12%" r="72%"><stop offset="0%" stop-color="#FFFFFF" stop-opacity="${isWhiteShell ? 0.45 : (isBlackShell ? 0.16 : 0.24)}"/><stop offset="55%" stop-color="#FFFFFF" stop-opacity="0.03"/><stop offset="100%" stop-color="#000000" stop-opacity="${isWhiteShell ? 0.06 : 0.12}"/></radialGradient><linearGradient id="${p}wG" x1="20%" y1="0%" x2="80%" y2="100%"><stop offset="0%" stop-color="${wellTop}"/><stop offset="55%" stop-color="${wellMid}"/><stop offset="100%" stop-color="${wellBot}"/></linearGradient><radialGradient id="${p}fG" cx="42%" cy="30%" r="72%"><stop offset="0%" stop-color="${faceTop}"/><stop offset="62%" stop-color="${faceMid}"/><stop offset="100%" stop-color="${faceBot}"/></radialGradient><linearGradient id="${p}aG" x1="18%" y1="0%" x2="82%" y2="100%"><stop offset="0%" stop-color="${accLight}"/><stop offset="${accMidStop}" stop-color="${accHex}"/><stop offset="100%" stop-color="${accDeep}"/></linearGradient><linearGradient id="${p}iG" x1="25%" y1="0%" x2="75%" y2="100%"><stop offset="0%" stop-color="${checkInkTop}"/><stop offset="100%" stop-color="${checkInkBot}"/></linearGradient><filter id="${p}dD" x="-16%" y="-14%" width="132%" height="136%"><feDropShadow dx="0" dy="14" stdDeviation="14" flood-color="${shadow}" flood-opacity="${isWhiteShell ? 0.30 : 0.44}"/><feDropShadow dx="0" dy="3" stdDeviation="4" flood-color="${shadow}" flood-opacity="0.26"/></filter><filter id="${p}sD" x="-22%" y="-22%" width="144%" height="148%"><feDropShadow dx="0" dy="6" stdDeviation="6" flood-color="${shadow}" flood-opacity="0.30"/></filter>`;
    const clipAttr = options.fullBleed ? '' : ` clip-path="url(#${p}sq)"`;
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="${size}" height="${size}"><defs>${defs}</defs><g${clipAttr}><rect x="0" y="0" width="1024" height="1024" fill="url(#${p}sG)"/><rect x="0" y="0" width="1024" height="1024" fill="url(#${p}sS)"/>${options.fullBleed ? '' : `<path d="${rimSq}" fill="none" stroke="${isWhiteShell ? '#000000' : shellRim}" stroke-opacity="${isWhiteShell ? 0.08 : 0.32}" stroke-width="5"/>`}<circle cx="${cx}" cy="${cy}" r="416" fill="url(#${p}wG)"/><circle cx="${cx}" cy="${cy}" r="412" fill="none" stroke="${shadow}" stroke-opacity="${isWhiteShell ? 0.28 : 0.55}" stroke-width="8"/><circle cx="${cx}" cy="${cy + 3}" r="415" fill="none" stroke="#FFFFFF" stroke-opacity="${isWhiteShell ? 0.85 : 0.20}" stroke-width="4"/><g filter="url(#${p}dD)"><circle cx="${cx}" cy="${cy}" r="354" fill="url(#${p}fG)"/><circle cx="${cx}" cy="${cy}" r="351" fill="none" stroke="#FFFFFF" stroke-opacity="${faceRimOp}" stroke-width="5"/></g><g>${ticks.join('')}</g><path d="${northArrow}" fill="url(#${p}aG)" stroke="${accDeep}" stroke-opacity="0.24" stroke-width="2" filter="url(#${p}sD)"/>${checkMarkup}</g></svg>`;
  }

  function renderProposalSVG(proposalId, c, options = {}) {
    return renderDialSVG(proposalId, c, options);
  }

  const LEGACY_PALETTE_ALIASES = {
    'mono-terracotta': 'persimmon', 'terracotta-warm': 'persimmon',
    'mono-vermilion': 'tamarillo', 'mono-forest': 'carambola', 'forest-linen': 'carambola',
    'mono-cobalt': 'haskap', 'cobalt-things': 'haskap',
    'mono-black': 'jabuticaba', 'mono-obsidian': 'jabuticaba', 'obsidian-brass': 'jabuticaba', 'mono-white': 'jabuticaba',
    'mono-stone': 'yuzu', 'linen-ink': 'yuzu', 'slate-amber': 'yuzu',
  };

  function findProposal(id) {
    return ALL_PROPOSALS.find(p => p.id === id) || ALL_PROPOSALS[0];
  }

  function loadState() {
    const defaults = {
      activeProposal: 'compass-black-white',
      paletteMode: 'jabuticaba',
      shellMode: 'black',
      faceMode: 'white',
      inlayMode: 'auto',
      customSeeds: { housing: '#27272E', surface: '#FAF9F6', accent: '#E05212' },
      cavityTint: false,
      cavityHex: '#E05212',
    };
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) return defaults;
      const parsed = JSON.parse(raw);
      const validProp = ALL_PROPOSALS.some(p => p.id === parsed.activeProposal) ? parsed.activeProposal : defaults.activeProposal;
      const rawPal = parsed.paletteMode || defaults.paletteMode;
      const mappedPal = LEGACY_PALETTE_ALIASES[rawPal] || rawPal;
      const validPal = (mappedPal === 'native' || mappedPal === 'custom' || FRUIT_PALETTES.some(f => f.id === mappedPal)) ? mappedPal : defaults.paletteMode;
      const validShell = ['black', 'white', 'color'].includes(parsed.shellMode) ? parsed.shellMode : defaults.shellMode;
      const validFace = ['white', 'black'].includes(parsed.faceMode) ? parsed.faceMode : defaults.faceMode;
      return {
        activeProposal: validProp,
        paletteMode: validPal,
        shellMode: validShell,
        faceMode: validFace,
        inlayMode: parsed.inlayMode || defaults.inlayMode,
        customSeeds: { ...defaults.customSeeds, ...(parsed.customSeeds || {}) },
        cavityTint: Boolean(parsed.cavityTint),
        cavityHex: parsed.cavityHex || defaults.cavityHex,
      };
    } catch {
      return defaults;
    }
  }

  function saveState(next) {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
      global.dispatchEvent(new CustomEvent('septena-brand-change', { detail: next }));
    } catch {}
  }

  function resolvePalette(brandState, proposalOverride) {
    const prop = proposalOverride || findProposal(brandState.activeProposal);
    let basePal;
    if (brandState.paletteMode === 'custom') {
      basePal = deriveCustomPalette(brandState.customSeeds || {});
    } else {
      const mapped = LEGACY_PALETTE_ALIASES[brandState.paletteMode] || brandState.paletteMode;
      basePal = FRUIT_PALETTES.find(f => f.id === mapped) || FRUIT_PALETTES.find(f => f.id === prop.defaultPalette) || FRUIT_PALETTES[0];
    }
    // If rendering a Color-shell preset while Jabuticaba is active, showcase its Persimmon orange shell
    if (prop.shell === 'color' && basePal.isObsidian) {
      basePal = FRUIT_PALETTES.find(f => f.id === 'persimmon') || basePal;
    }
    return { ...basePal, shellMode: prop.shell, faceMode: prop.face };
  }

  global.SeptenaBrand = {
    FRUIT_PALETTES,
    PALETTES,
    MONOLITH_PALETTES,
    DIAL_PROPOSALS,
    ALL_PROPOSALS,
    squirclePath,
    deriveCustomPalette,
    renderDialSVG,
    renderProposalSVG,
    findProposal,
    loadState,
    saveState,
    resolvePalette,
  };
})(window);
