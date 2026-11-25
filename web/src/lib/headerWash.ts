// Procedural Header Wash renderer for Web (exact port of SeptenaCore/HeaderWashEngine.swift,
// ADR 0019 / docs/CUSTOMIZATION_SPEC.md).
//
// Renders the 5 locked procedural surfaces from a deterministic Mulberry32 PRNG +
// 3D value-noise fBm volume so every platform produces the exact same daily/project
// texture with zero network sync:
//   - topography   (marching-squares elevation contours, 3D morphing in place)
//   - fieldMatrix  (elevation-modulated precision micro-dot grid)
//   - stippleDrift (fixed-anchor elevation-gated stipple dither, zero flicker)
//   - ridges       (tapered horizontal elevation profiles)
//   - washiPaper   (laid sugeta screen lines + sinuous kozo/unryu mulberry fibers)

export type HeaderTextureStyle =
  | "none"
  | "topography"
  | "fieldMatrix"
  | "stippleDrift"
  | "ridges"
  | "washiPaper";

export interface RGBTriple {
  r: number; // 0..1
  g: number; // 0..1
  b: number; // 0..1
}

export interface HeaderWashParams {
  style: HeaderTextureStyle;
  isDark: boolean;
  accent: RGBTriple;
  /** 15..100 */
  intensity: number;
  seed: number;
  /** Continuous seconds for 3D slice morphing (0 when still). */
  phase: number;
  /** Height (CSS px) over which the wash fades cleanly to transparent. */
  fadeHeight: number;
  /** Compact thumbnail mode (denser frequency for Settings preview cards). */
  mini: boolean;
  /** Reduced contrast / high contrast halves effective intensity (cap 30%). */
  increaseContrast: boolean;
}

export function hexToRgbTriple(hex: string): RGBTriple {
  const clean = hex.replace(/^#/, "");
  if (clean.length !== 6) return { r: 0, g: 0.48, b: 1 };
  const n = Number.parseInt(clean, 16);
  if (Number.isNaN(n)) return { r: 0, g: 0.48, b: 1 };
  return {
    r: ((n >> 16) & 255) / 255,
    g: ((n >> 8) & 255) / 255,
    b: (n & 255) / 255,
  };
}

export function hexWithAlpha(hex: string, alpha: number): string {
  const { r, g, b } = hexToRgbTriple(hex);
  const clamped = Math.max(0, Math.min(1, alpha));
  return `rgba(${Math.round(r * 255)}, ${Math.round(g * 255)}, ${Math.round(b * 255)}, ${clamped.toFixed(3)})`;
}

// FNV-1a 32-bit matching AppearancePreferences.swift identically.
function fnv1a(input: string): number {
  let hash = 2166136261 >>> 0;
  const bytes = new TextEncoder().encode(input);
  for (let i = 0; i < bytes.length; i++) {
    hash ^= bytes[i];
    hash = Math.imul(hash, 16777619) >>> 0;
  }
  return hash;
}

export function resolvedWashSeed(dayISO: string, projectId?: string | null): number {
  if (projectId && projectId.length > 0) {
    return Math.max(1, fnv1a(`septena.wash.project:${projectId}`) % 9999);
  }
  return Math.max(1, fnv1a(`septena.wash:${dayISO}`) % 9999);
}

class Mulberry32 {
  private state: number;
  constructor(seed: number) {
    this.state = seed >>> 0;
  }
  next(): number {
    this.state = (this.state + 0x6d2b79f5) >>> 0;
    let t = this.state;
    t = Math.imul(t ^ (t >>> 15), t | 1) >>> 0;
    t = (t ^ ((t + Math.imul(t ^ (t >>> 7), t | 61)) >>> 0)) >>> 0;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296.0;
  }
}

class NoiseVolume {
  readonly perm: Uint8Array;
  readonly vals: Float64Array;

  constructor(seed: number) {
    const rng = new Mulberry32((Math.imul(seed >>> 0, 9973) + 17) >>> 0);
    const p = new Uint8Array(256);
    const v = new Float64Array(256);
    for (let i = 0; i < 256; i++) {
      p[i] = i;
      v[i] = rng.next();
    }
    for (let i = 255; i >= 1; i--) {
      const j = Math.floor(rng.next() * (i + 1));
      const tmp = p[i];
      p[i] = p[j];
      p[j] = tmp;
    }
    const perm = new Uint8Array(512);
    perm.set(p, 0);
    perm.set(p, 256);
    this.perm = perm;
    this.vals = v;
  }

  private fade(t: number): number {
    return t * t * t * (t * (t * 6 - 15) + 10);
  }

  private lerp(a: number, b: number, t: number): number {
    return a + (b - a) * t;
  }

  private valueNoise3D(x: number, y: number, z: number): number {
    const fx = Math.floor(x);
    const fy = Math.floor(y);
    const fz = Math.floor(z);
    const xi = fx & 255;
    const yi = fy & 255;
    const zi = fz & 255;
    const u = this.fade(x - fx);
    const v = this.fade(y - fy);
    const w = this.fade(z - fz);

    const perm = this.perm;
    const vals = this.vals;
    const p00 = perm[perm[xi] + yi];
    const p10 = perm[perm[xi + 1] + yi];
    const p01 = perm[perm[xi] + yi + 1];
    const p11 = perm[perm[xi + 1] + yi + 1];

    const n000 = vals[perm[(p00 + zi) & 255]];
    const n100 = vals[perm[(p10 + zi) & 255]];
    const n010 = vals[perm[(p01 + zi) & 255]];
    const n110 = vals[perm[(p11 + zi) & 255]];

    if (w === 0) {
      return this.lerp(this.lerp(n000, n100, u), this.lerp(n010, n110, u), v);
    }

    const z1 = (zi + 1) & 255;
    const n001 = vals[perm[(p00 + z1) & 255]];
    const n101 = vals[perm[(p10 + z1) & 255]];
    const n011 = vals[perm[(p01 + z1) & 255]];
    const n111 = vals[perm[(p11 + z1) & 255]];

    const nx0 = this.lerp(this.lerp(n000, n100, u), this.lerp(n010, n110, u), v);
    const nx1 = this.lerp(this.lerp(n001, n101, u), this.lerp(n011, n111, u), v);
    return this.lerp(nx0, nx1, w);
  }

  fbm(x: number, y: number, z: number, octaves: number): number {
    let total = 0;
    let amp = 0.5;
    let freq = 1.0;
    let norm = 0;
    for (let o = 0; o < octaves; o++) {
      total += this.valueNoise3D(x * freq, y * freq, z * (1.0 + o * 0.35)) * amp;
      norm += amp;
      amp *= 0.5;
      freq *= 2.02;
    }
    return total / norm;
  }
}

const volumeCache = new Map<number, NoiseVolume>();

function volumeFor(seed: number): NoiseVolume {
  const hit = volumeCache.get(seed);
  if (hit) return hit;
  if (volumeCache.size > 24) volumeCache.clear();
  const vol = new NoiseVolume(seed);
  volumeCache.set(seed, vol);
  return vol;
}

export function drawHeaderWash(
  ctx: CanvasRenderingContext2D,
  width: number,
  height: number,
  params: HeaderWashParams,
): void {
  ctx.clearRect(0, 0, width, height);
  if (params.style === "none" || width <= 1 || height <= 1) return;

  const w = width;
  const h = Math.min(height, params.mini ? height : params.fadeHeight);
  if (h <= 1) return;

  const effectiveInt = params.increaseContrast
    ? Math.min(30, Math.floor(params.intensity / 2))
    : params.intensity;
  const intensity = Math.max(10, Math.min(100, effectiveInt)) / 100.0;

  const neutral: RGBTriple = params.isDark
    ? { r: 235 / 255, g: 240 / 255, b: 248 / 255 }
    : { r: 30 / 255, g: 36 / 255, b: 48 / 255 };
  const inkR = Math.round((neutral.r * 0.42 + params.accent.r * 0.58) * 255);
  const inkG = Math.round((neutral.g * 0.42 + params.accent.g * 0.58) * 255);
  const inkB = Math.round((neutral.b * 0.42 + params.accent.b * 0.58) * 255);

  const vol = volumeFor(params.seed);
  const zSlice = params.phase * 0.036;
  const sample = (x: number, y: number, octaves = 4) => vol.fbm(x, y, zSlice, octaves);

  const setStroke = (alpha: number) => {
    const a = Math.max(0, Math.min(1, alpha));
    ctx.strokeStyle = `rgba(${inkR}, ${inkG}, ${inkB}, ${a.toFixed(4)})`;
  };
  const setFill = (alpha: number) => {
    const a = Math.max(0, Math.min(1, alpha));
    ctx.fillStyle = `rgba(${inkR}, ${inkG}, ${inkB}, ${a.toFixed(4)})`;
  };

  ctx.save();
  ctx.beginPath();
  ctx.rect(0, 0, w, h);
  ctx.clip();

  switch (params.style) {
    case "topography":
      drawTopography(ctx, w, h, params.isDark, intensity, params.mini, sample, setStroke);
      break;
    case "fieldMatrix":
      drawFieldMatrix(ctx, w, h, params.isDark, intensity, params.mini, params.phase, vol, setFill);
      break;
    case "stippleDrift":
      drawStippleDrift(ctx, w, h, params.isDark, intensity, params.seed, params.mini, sample, setFill);
      break;
    case "ridges":
      drawRidges(ctx, w, h, params.isDark, intensity, params.mini, sample, setStroke);
      break;
    case "washiPaper":
      drawWashiPaper(ctx, w, h, params.isDark, intensity, params.seed, params.mini, sample, setStroke);
      break;
  }

  // Soft vertical fade-out mask from top (100%) to transparent over h.
  if (!params.mini) {
    ctx.globalCompositeOperation = "destination-in";
    const grad = ctx.createLinearGradient(0, 0, 0, h);
    grad.addColorStop(0.0, "rgba(0, 0, 0, 1)");
    grad.addColorStop(0.56, "rgba(0, 0, 0, 0.58)");
    grad.addColorStop(1.0, "rgba(0, 0, 0, 0)");
    ctx.fillStyle = grad;
    ctx.fillRect(0, 0, w, h);
    ctx.globalCompositeOperation = "source-over";
  }

  ctx.restore();
}

function drawTopography(
  ctx: CanvasRenderingContext2D,
  w: number,
  h: number,
  isDark: boolean,
  intensity: number,
  mini: boolean,
  sample: (x: number, y: number, octaves?: number) => number,
  setStroke: (a: number) => void,
): void {
  const step = mini ? 5.0 : 8.0;
  const cols = Math.ceil(w / step) + 1;
  const rows = Math.ceil(h / step) + 1;
  const freq = mini ? 0.016 : 0.0055;

  const grid = new Float64Array(cols * rows);
  for (let r = 0; r < rows; r++) {
    const sy = r * step * freq;
    for (let c = 0; c < cols; c++) {
      grid[r * cols + c] = sample(c * step * freq, sy, 4);
    }
  }

  const levels = mini ? 8 : 13;
  for (let l = 0; l < levels; l++) {
    const thresh = 0.22 + (l / (levels - 1)) * 0.56;
    const isIndex = l % 4 === 0;
    ctx.lineWidth = isIndex ? 1.25 : 0.75;
    const baseAlpha = isDark ? (isIndex ? 0.3 : 0.14) : isIndex ? 0.26 : 0.12;
    setStroke(baseAlpha * (0.45 + intensity * 0.95));

    ctx.beginPath();
    for (let r = 0; r < rows - 1; r++) {
      for (let c = 0; c < cols - 1; c++) {
        const v0 = grid[r * cols + c];
        const v1 = grid[r * cols + c + 1];
        const v2 = grid[(r + 1) * cols + c + 1];
        const v3 = grid[(r + 1) * cols + c];
        const idx =
          (v0 > thresh ? 1 : 0) |
          (v1 > thresh ? 2 : 0) |
          (v2 > thresh ? 4 : 0) |
          (v3 > thresh ? 8 : 0);
        if (idx === 0 || idx === 15) continue;

        const x = c * step;
        const y = r * step;
        const interp = (va: number, vb: number) => {
          const d = vb - va;
          return Math.abs(d) < 1e-5 ? 0.5 : (thresh - va) / d;
        };
        const tx = x + interp(v0, v1) * step;
        const ty = y;
        const rx = x + step;
        const ry = y + interp(v1, v2) * step;
        const bx = x + interp(v3, v2) * step;
        const by = y + step;
        const lx = x;
        const ly = y + interp(v0, v3) * step;

        const seg = (ax: number, ay: number, ex: number, ey: number) => {
          ctx.moveTo(ax, ay);
          ctx.lineTo(ex, ey);
        };

        switch (idx) {
          case 1:
          case 14:
            seg(lx, ly, tx, ty);
            break;
          case 2:
          case 13:
            seg(tx, ty, rx, ry);
            break;
          case 3:
          case 12:
            seg(lx, ly, rx, ry);
            break;
          case 4:
          case 11:
            seg(rx, ry, bx, by);
            break;
          case 5:
            seg(lx, ly, bx, by);
            seg(tx, ty, rx, ry);
            break;
          case 6:
          case 9:
            seg(tx, ty, bx, by);
            break;
          case 7:
          case 8:
            seg(lx, ly, bx, by);
            break;
          case 10:
            seg(lx, ly, tx, ty);
            seg(rx, ry, bx, by);
            break;
        }
      }
    }
    ctx.stroke();
  }
}

function drawFieldMatrix(
  ctx: CanvasRenderingContext2D,
  w: number,
  h: number,
  isDark: boolean,
  intensity: number,
  mini: boolean,
  phase: number,
  vol: NoiseVolume,
  setFill: (a: number) => void,
): void {
  const gap = mini ? 8.5 : 14.0;
  const freq = mini ? 0.018 : 0.0065;
  const maxR = (mini ? 2.0 : 2.9) * (0.65 + intensity * 0.55);
  const alphaBase = isDark ? 0.36 : 0.3;
  const z = phase * 0.18;

  for (let y = gap / 2; y < h; y += gap) {
    for (let x = gap / 2; x < w; x += gap) {
      const v = vol.fbm(x * freq, y * freq, z, 3);
      const norm = Math.max(0, Math.min(1, (v - 0.26) / 0.48));
      const r = 0.45 + norm * norm * maxR;
      setFill((0.04 + norm * alphaBase) * (0.4 + intensity * 0.85));
      ctx.beginPath();
      ctx.arc(x, y, r, 0, Math.PI * 2);
      ctx.fill();
    }
  }
}

function drawStippleDrift(
  ctx: CanvasRenderingContext2D,
  w: number,
  h: number,
  isDark: boolean,
  intensity: number,
  seed: number,
  mini: boolean,
  sample: (x: number, y: number, octaves?: number) => number,
  setFill: (a: number) => void,
): void {
  const rng = new Mulberry32((seed + 303) >>> 0);
  const count = Math.floor((w * h) / (mini ? 12.0 : 18.0));
  const freq = mini ? 0.014 : 0.005;
  const base = (isDark ? 0.27 : 0.24) * (0.35 + intensity * 0.85);

  for (let i = 0; i < count; i++) {
    const x = rng.next() * w;
    const y = rng.next() * h;
    const gate = rng.next();
    const isBig = rng.next() > 0.82;
    const wave = Math.sin(sample(x * freq, y * freq, 3) * Math.PI * 6.5) * 0.5 + 0.5;
    if (gate < wave * 0.65) {
      const s = isBig ? 1.5 : 1.0;
      setFill(base * (0.4 + wave * 0.6));
      ctx.fillRect(x, y, s, s);
    }
  }
}

function drawRidges(
  ctx: CanvasRenderingContext2D,
  w: number,
  h: number,
  isDark: boolean,
  intensity: number,
  mini: boolean,
  sample: (x: number, y: number, octaves?: number) => number,
  setStroke: (a: number) => void,
): void {
  const spacing = mini ? 8.5 : 13.5;
  const amp = (mini ? 15.0 : 32.0) * (0.55 + intensity * 0.65);
  const freqX = mini ? 0.015 : 0.0055;
  const freqY = 0.008;
  const stepX = mini ? 4.0 : 6.0;

  ctx.lineWidth = 0.95;
  for (let y = -amp; y < h + amp; y += spacing) {
    const rowNorm = Math.max(0, Math.min(1, y / Math.max(1, h)));
    const alpha =
      (isDark ? 0.24 : 0.21) *
      (0.4 + intensity * 0.85) *
      (0.55 + 0.45 * Math.sin(rowNorm * Math.PI));
    setStroke(alpha);
    ctx.beginPath();
    let first = true;
    for (let x = 0; x <= w + stepX; x += stepX) {
      const py = y + (sample(x * freqX + 1.3, y * freqY + 2.7, 3) - 0.5) * amp * 2.1;
      if (first) {
        ctx.moveTo(x, py);
        first = false;
      } else {
        ctx.lineTo(x, py);
      }
    }
    ctx.stroke();
  }
}

function drawWashiPaper(
  ctx: CanvasRenderingContext2D,
  w: number,
  h: number,
  isDark: boolean,
  intensity: number,
  seed: number,
  mini: boolean,
  sample: (x: number, y: number, octaves?: number) => number,
  setStroke: (a: number) => void,
): void {
  const rng = new Mulberry32((seed + 777) >>> 0);
  const freq = mini ? 0.016 : 0.006;
  const strength = 0.45 + intensity * 0.9;

  const laidStep = mini ? 5.0 : 6.0;
  ctx.lineWidth = 0.6;
  setStroke((isDark ? 0.075 : 0.065) * strength);
  ctx.beginPath();
  for (let y = laidStep / 2; y < h; y += laidStep) {
    ctx.moveTo(0, y);
    ctx.lineTo(w, y);
  }
  const chainStep = mini ? 28.0 : 48.0;
  for (let x = chainStep; x < w; x += chainStep) {
    ctx.moveTo(x, 0);
    ctx.lineTo(x, h);
  }
  ctx.stroke();

  const longCount = Math.max(20, Math.floor((w * h) / (mini ? 380.0 : 1250.0)));
  ctx.lineCap = "round";
  for (let i = 0; i < longCount; i++) {
    const fx = rng.next() * w;
    const fy = rng.next() * h;
    const angle = (rng.next() - 0.5) * Math.PI * 1.4;
    const len = (mini ? 14.0 : 26.0) + rng.next() * (mini ? 22.0 : 46.0);
    const bend = (rng.next() - 0.5) * len * 0.65;
    const mx = fx + Math.cos(angle) * len * 0.5 - Math.sin(angle) * bend;
    const my = fy + Math.sin(angle) * len * 0.5 + Math.cos(angle) * bend;
    const ex = fx + Math.cos(angle) * len;
    const ey = fy + Math.sin(angle) * len;
    const alphaRand = rng.next();
    const thick = rng.next() > 0.72;
    const wave = 0.55 + sample(fx * freq, fy * freq, 2) * 0.75;

    setStroke((isDark ? 0.28 : 0.24) * strength * wave * (0.55 + alphaRand * 0.55));
    ctx.lineWidth = thick ? 1.35 : 0.85;
    ctx.beginPath();
    ctx.moveTo(fx, fy);
    ctx.quadraticCurveTo(mx, my, ex, ey);
    ctx.stroke();
  }

  const shortCount = Math.floor((w * h) / (mini ? 95.0 : 165.0));
  ctx.lineWidth = 0.75;
  for (let i = 0; i < shortCount; i++) {
    const fx = rng.next() * w;
    const fy = rng.next() * h;
    const angle = rng.next() * Math.PI * 2;
    const len = 3.0 + rng.next() * 8.0;
    const alphaRand = rng.next();
    const wave = 0.5 + sample(fx * freq, fy * freq, 2) * 0.8;
    setStroke((isDark ? 0.16 : 0.14) * strength * wave * (0.45 + alphaRand * 0.65));
    ctx.beginPath();
    ctx.moveTo(fx, fy);
    ctx.lineTo(fx + Math.cos(angle) * len, fy + Math.sin(angle) * len);
    ctx.stroke();
  }
}
