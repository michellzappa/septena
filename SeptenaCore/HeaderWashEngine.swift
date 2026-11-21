import CoreGraphics
import Foundation

// Shared procedural Header Wash renderer for iOS, iPadOS, and macOS (ADR 0019 /
// docs/CUSTOMIZATION_SPEC.md).
//
// Renders the 6 locked procedural surfaces purely in CoreGraphics from a
// deterministic Mulberry32 PRNG + 3D value-noise fBm volume:
//   • topography   — marching-squares elevation contours (3D morphing in place)
//   • fieldMatrix  — elevation-modulated precision micro-dot grid
//   • stippleDrift — fixed-anchor elevation-gated stipple dither (zero flicker)
//   • causticGlass — pool-floor light: two interfering orbiting Voronoi webs
//   • ridges       — tapered horizontal elevation profiles
//   • washiPaper   — laid sugeta screen lines + sinuous kozo/unryu mulberry fibers
//
// Pure geometry only (no radial gradient blobs or haze): ink harmonizes 58%
// toward the active accent (so Jabuticaba stays monochrome ink), masked cleanly
// from top (100%) to transparent over `fadeHeight`.

struct HeaderWashParams: Sendable, Hashable {
  let style: HeaderTextureStyle
  let isDark: Bool
  let accent: RGBTriple
  /// 15...100
  let intensity: Int
  let seed: UInt32
  /// Continuous seconds for 3D slice morphing (`0` when still).
  let phase: Double
  /// Height (in points) over which the wash fades cleanly to transparent.
  let fadeHeight: CGFloat
  /// Compact thumbnail mode (denser frequency for Settings preview cards).
  let mini: Bool
  /// Accessibility Increase Contrast halves effective intensity (cap 30%).
  let increaseContrast: Bool
}

enum HeaderWashEngine {

  // MARK: - Deterministic Mulberry32 PRNG

  private struct Mulberry32 {
    private var state: UInt32

    init(seed: UInt32) {
      self.state = seed
    }

    mutating func next() -> Double {
      state = state &+ 0x6D2B79F5
      var t = state
      t = (t ^ (t >> 15)) &* (t | 1)
      t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
      return Double(t ^ (t >> 14)) / 4294967296.0
    }
  }

  // MARK: - Cached 3D Value Noise fBm

  private final class NoiseVolume: @unchecked Sendable {
    let perm: [Int]
    let vals: [Double]

    init(seed: UInt32) {
      var rng = Mulberry32(seed: seed &* 9973 &+ 17)
      var p = Array(0..<256)
      var v = [Double](repeating: 0, count: 256)
      for i in 0..<256 { v[i] = rng.next() }
      for i in stride(from: 255, through: 1, by: -1) {
        let j = Int(rng.next() * Double(i + 1))
        p.swapAt(i, j)
      }
      self.perm = p + p
      self.vals = v
    }

    @inline(__always)
    private func fade(_ t: Double) -> Double {
      t * t * t * (t * (t * 6 - 15) + 10)
    }

    @inline(__always)
    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
      a + (b - a) * t
    }

    private func valueNoise3D(_ x: Double, _ y: Double, _ z: Double) -> Double {
      let fx = floor(x), fy = floor(y), fz = floor(z)
      let xi = Int(fx) & 255, yi = Int(fy) & 255, zi = Int(fz) & 255
      let u = fade(x - fx), v = fade(y - fy), w = fade(z - fz)

      let p00 = perm[perm[xi] + yi]
      let p10 = perm[perm[xi + 1] + yi]
      let p01 = perm[perm[xi] + yi + 1]
      let p11 = perm[perm[xi + 1] + yi + 1]

      let n000 = vals[perm[(p00 + zi) & 255]]
      let n100 = vals[perm[(p10 + zi) & 255]]
      let n010 = vals[perm[(p01 + zi) & 255]]
      let n110 = vals[perm[(p11 + zi) & 255]]

      if w == 0 {
        return lerp(lerp(n000, n100, u), lerp(n010, n110, u), v)
      }

      let z1 = (zi + 1) & 255
      let n001 = vals[perm[(p00 + z1) & 255]]
      let n101 = vals[perm[(p10 + z1) & 255]]
      let n011 = vals[perm[(p01 + z1) & 255]]
      let n111 = vals[perm[(p11 + z1) & 255]]

      let nx0 = lerp(lerp(n000, n100, u), lerp(n010, n110, u), v)
      let nx1 = lerp(lerp(n001, n101, u), lerp(n011, n111, u), v)
      return lerp(nx0, nx1, w)
    }

    func fbm(_ x: Double, _ y: Double, z: Double, octaves: Int) -> Double {
      var total = 0.0
      var amp = 0.5
      var freq = 1.0
      var norm = 0.0
      for o in 0..<octaves {
        total += valueNoise3D(x * freq, y * freq, z * (1.0 + Double(o) * 0.35)) * amp
        norm += amp
        amp *= 0.5
        freq *= 2.02
      }
      return total / norm
    }
  }

  private static let cacheLock = NSLock()
  private static var volumeCache: [UInt32: NoiseVolume] = [:]

  private static func volume(for seed: UInt32) -> NoiseVolume {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    if let hit = volumeCache[seed] { return hit }
    if volumeCache.count > 24 { volumeCache.removeAll() }
    let vol = NoiseVolume(seed: seed)
    volumeCache[seed] = vol
    return vol
  }

  // MARK: - Public Entry Point

  /// Draws the procedural Header Wash into `ctx` in top-left origin coordinates
  /// (standard SwiftUI `Canvas` / flipped `NSView` coordinate space).
  static func draw(in ctx: CGContext, size: CGSize, params: HeaderWashParams) {
    guard params.style != .none, size.width > 1, size.height > 1 else { return }

    let w = Double(size.width)
    let h = Double(min(size.height, params.mini ? size.height : params.fadeHeight))
    guard h > 1 else { return }

    let effectiveInt = params.increaseContrast
      ? min(30, params.intensity / 2)
      : params.intensity
    let intensity = Double(max(10, min(100, effectiveInt))) / 100.0

    // Harmonize pure geometry ink 58% toward active accent (zero gradient blobs).
    let neutral: RGBTriple = params.isDark
      ? RGBTriple(r: 235.0 / 255.0, g: 240.0 / 255.0, b: 248.0 / 255.0)
      : RGBTriple(r: 30.0 / 255.0, g: 36.0 / 255.0, b: 48.0 / 255.0)
    let inkRGB = RGBTriple(
      r: neutral.r * 0.42 + params.accent.r * 0.58,
      g: neutral.g * 0.42 + params.accent.g * 0.58,
      b: neutral.b * 0.42 + params.accent.b * 0.58
    )

    let vol = volume(for: params.seed)
    let zSlice = params.phase * 0.036

    // Pure in-place 3D slice morphing: zero X/Y positional shift when animation
    // toggles on or off; elevation contours evolve continuously from z = 0.
    func sample(_ x: Double, _ y: Double, octaves: Int = 4) -> Double {
      vol.fbm(x, y, z: zSlice, octaves: octaves)
    }

    func setStroke(_ alpha: Double) {
      let a = max(0, min(1, alpha))
      ctx.setStrokeColor(red: inkRGB.r, green: inkRGB.g, blue: inkRGB.b, alpha: a)
    }

    func setFill(_ alpha: Double) {
      let a = max(0, min(1, alpha))
      ctx.setFillColor(red: inkRGB.r, green: inkRGB.g, blue: inkRGB.b, alpha: a)
    }

    ctx.saveGState()
    // Render into a transparency layer so we can apply a clean linear fade-out
    // mask from top edge (y = 0) down to `h` without touching the underlying canvas.
    let drawRect = CGRect(x: 0, y: 0, width: w, height: h)
    ctx.clip(to: drawRect)
    ctx.beginTransparencyLayer(in: drawRect, auxiliaryInfo: nil)

    switch params.style {
    case .none:
      break
    case .topography:
      drawTopography(ctx: ctx, w: w, h: h, isDark: params.isDark, intensity: intensity,
                     mini: params.mini, sample: sample, setStroke: setStroke)
    case .fieldMatrix:
      drawFieldMatrix(ctx: ctx, w: w, h: h, isDark: params.isDark, intensity: intensity,
                      mini: params.mini, sample: sample, setFill: setFill)
    case .stippleDrift:
      drawStippleDrift(ctx: ctx, w: w, h: h, isDark: params.isDark, intensity: intensity,
                       seed: params.seed, mini: params.mini, sample: sample, setFill: setFill)
    case .causticGlass:
      drawCausticGlass(ctx: ctx, w: w, h: h, isDark: params.isDark, intensity: intensity,
                       seed: params.seed, mini: params.mini, phase: params.phase,
                       ink: inkRGB, sample: sample)
    case .ridges:
      drawRidges(ctx: ctx, w: w, h: h, isDark: params.isDark, intensity: intensity,
                 mini: params.mini, sample: sample, setStroke: setStroke)
    case .washiPaper:
      drawWashiPaper(ctx: ctx, w: w, h: h, isDark: params.isDark, intensity: intensity,
                     seed: params.seed, mini: params.mini, sample: sample, setStroke: setStroke)
    }

    // Apply soft Header Wash vertical fade-out mask (skipped for tiny picker thumbnails).
    if !params.mini {
      let colorSpace = CGColorSpaceCreateDeviceRGB()
      let colors: [CGColor] = [
        CGColor(colorSpace: colorSpace, components: [0, 0, 0, 1.0])!,
        CGColor(colorSpace: colorSpace, components: [0, 0, 0, 0.58])!,
        CGColor(colorSpace: colorSpace, components: [0, 0, 0, 0.0])!,
      ]
      let locations: [CGFloat] = [0.0, 0.56, 1.0]
      if let grad = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations) {
        ctx.setBlendMode(.destinationIn)
        ctx.drawLinearGradient(
          grad,
          start: CGPoint(x: 0, y: 0),
          end: CGPoint(x: 0, y: h),
          options: []
        )
        ctx.setBlendMode(.normal)
      }
    }

    ctx.endTransparencyLayer()
    ctx.restoreGState()
  }

  // MARK: - 1. Topography (Marching Squares over 3D fBm)

  private static func drawTopography(
    ctx: CGContext, w: Double, h: Double, isDark: Bool, intensity: Double,
    mini: Bool, sample: (Double, Double, Int) -> Double, setStroke: (Double) -> Void
  ) {
    let step = mini ? 5.0 : 8.0
    let cols = Int(ceil(w / step)) + 1
    let rows = Int(ceil(h / step)) + 1
    let freq = mini ? 0.016 : 0.0055

    var grid = [Double](repeating: 0, count: cols * rows)
    for r in 0..<rows {
      let sy = Double(r) * step * freq
      for c in 0..<cols {
        grid[r * cols + c] = sample(Double(c) * step * freq, sy, 4)
      }
    }

    let levels = mini ? 8 : 13
    for l in 0..<levels {
      let thresh = 0.22 + (Double(l) / Double(levels - 1)) * 0.56
      let isIndex = l % 4 == 0
      ctx.setLineWidth(isIndex ? 1.25 : 0.75)
      let baseAlpha = isDark ? (isIndex ? 0.30 : 0.14) : (isIndex ? 0.26 : 0.12)
      setStroke(baseAlpha * (0.45 + intensity * 0.95))

      ctx.beginPath()
      for r in 0..<(rows - 1) {
        for c in 0..<(cols - 1) {
          let v0 = grid[r * cols + c]
          let v1 = grid[r * cols + c + 1]
          let v2 = grid[(r + 1) * cols + c + 1]
          let v3 = grid[(r + 1) * cols + c]
          let idx = (v0 > thresh ? 1 : 0) | (v1 > thresh ? 2 : 0)
                  | (v2 > thresh ? 4 : 0) | (v3 > thresh ? 8 : 0)
          if idx == 0 || idx == 15 { continue }

          let x = Double(c) * step
          let y = Double(r) * step
          @inline(__always) func interp(_ va: Double, _ vb: Double) -> Double {
            let d = vb - va
            return abs(d) < 1e-5 ? 0.5 : (thresh - va) / d
          }
          let top = CGPoint(x: x + interp(v0, v1) * step, y: y)
          let right = CGPoint(x: x + step, y: y + interp(v1, v2) * step)
          let bottom = CGPoint(x: x + interp(v3, v2) * step, y: y + step)
          let left = CGPoint(x: x, y: y + interp(v0, v3) * step)

          @inline(__always) func seg(_ a: CGPoint, _ b: CGPoint) {
            ctx.move(to: a)
            ctx.addLine(to: b)
          }
          switch idx {
          case 1, 14: seg(left, top)
          case 2, 13: seg(top, right)
          case 3, 12: seg(left, right)
          case 4, 11: seg(right, bottom)
          case 5:     seg(left, bottom); seg(top, right)
          case 6, 9:  seg(top, bottom)
          case 7, 8:  seg(left, bottom)
          case 10:    seg(left, top); seg(right, bottom)
          default: break
          }
        }
      }
      ctx.strokePath()
    }
  }

  // MARK: - 2. Field Matrix (Elevation-Modulated Micro-Dots)

  private static func drawFieldMatrix(
    ctx: CGContext, w: Double, h: Double, isDark: Bool, intensity: Double,
    mini: Bool, sample: (Double, Double, Int) -> Double, setFill: (Double) -> Void
  ) {
    let gap = mini ? 8.5 : 14.0
    let freq = mini ? 0.018 : 0.0065
    let maxR = (mini ? 2.0 : 2.9) * (0.65 + intensity * 0.55)
    let alphaBase = isDark ? 0.36 : 0.30

    var y = gap / 2
    while y < h {
      var x = gap / 2
      while x < w {
        let v = sample(x * freq, y * freq, 3)
        let norm = max(0, min(1, (v - 0.26) / 0.48))
        let r = 0.45 + norm * norm * maxR
        setFill((0.04 + norm * alphaBase) * (0.4 + intensity * 0.85))
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        x += gap
      }
      y += gap
    }
  }

  // MARK: - 3. Stipple Drift (Fixed-Anchor Risograph Dither)

  private static func drawStippleDrift(
    ctx: CGContext, w: Double, h: Double, isDark: Bool, intensity: Double,
    seed: UInt32, mini: Bool, sample: (Double, Double, Int) -> Double, setFill: (Double) -> Void
  ) {
    var rng = Mulberry32(seed: seed &+ 303)
    let count = Int((w * h) / (mini ? 12.0 : 18.0))
    let freq = mini ? 0.014 : 0.005
    let base = (isDark ? 0.27 : 0.24) * (0.35 + intensity * 0.85)

    for _ in 0..<count {
      let x = rng.next() * w
      let y = rng.next() * h
      let gate = rng.next()
      let isBig = rng.next() > 0.82
      let wave = sin(sample(x * freq, y * freq, 3) * .pi * 6.5) * 0.5 + 0.5
      if gate < wave * 0.65 {
        let s = isBig ? 1.5 : 1.0
        setFill(base * (0.4 + wave * 0.6))
        ctx.fill(CGRect(x: x, y: y, width: s, height: s))
      }
    }
  }

  // MARK: - 4. Caustic Glass (Pool-Floor Light Network)

  // Light on a pool floor: two interfering Voronoi webs, each a thin bright
  // filament with a soft halo, whose cell centers orbit slowly with `phase`.
  // Filaments get brighter and thinner where a low-frequency "focus" field
  // peaks, and brighter still where the two webs cross (the hot knots).
  private static func drawCausticGlass(
    ctx: CGContext, w: Double, h: Double, isDark: Bool, intensity: Double,
    seed: UInt32, mini: Bool, phase: Double, ink: RGBTriple,
    sample: (Double, Double, Int) -> Double
  ) {
    let div = mini ? 1.3 : 1.6
    let rw = min(320, max(56, Int(w / div)))
    let rh = min(200, max(40, Int(h / div)))
    // Pixel → wash-point scale so cell size is resolution-independent.
    let sx = w / Double(rw)
    let sy = h / Double(rh)

    let cellA = mini ? 0.055 : 0.020
    let cellB = cellA * 1.62
    let warpFreq = cellA * 0.55
    let strength = (0.40 + intensity * 0.90) * (isDark ? 0.95 : 0.72)
    let t = phase * 0.32

    @inline(__always) func cellHash(_ ix: Int, _ iy: Int, _ salt: UInt32) -> Double {
      var n = UInt32(bitPattern: Int32(truncatingIfNeeded: ix)) &* 374761393
      n = n &+ (UInt32(bitPattern: Int32(truncatingIfNeeded: iy)) &* 668265263)
      n = n &+ ((seed &+ salt) &* 1442695041)
      n = (n ^ (n >> 13)) &* 1274126177
      return Double(n ^ (n >> 16)) / 4294967296.0
    }

    // F2 - F1 distance for one web, cell centers orbiting their home point.
    @inline(__always) func web(_ px: Double, _ py: Double, salt: UInt32, speed: Double) -> Double {
      let ix = Int(floor(px))
      let iy = Int(floor(py))
      var d1 = 99.0
      var d2 = 99.0
      for oy in -1...1 {
        for ox in -1...1 {
          let cx = ix + ox
          let cy = iy + oy
          let hA = cellHash(cx, cy, salt)
          let hB = cellHash(cx, cy, salt &+ 17)
          let ang = t * speed * (0.6 + hB * 0.8) + hA * .pi * 2
          let fx = Double(cx) + 0.5 + 0.34 * sin(ang)
          let fy = Double(cy) + 0.5 + 0.34 * cos(ang * 0.83 + hB * 3.1)
          let dx = px - fx
          let dy = py - fy
          let dist = dx * dx + dy * dy
          if dist < d1 {
            d2 = d1; d1 = dist
          } else if dist < d2 {
            d2 = dist
          }
        }
      }
      return d2.squareRoot() - d1.squareRoot()
    }

    // Thin core + soft halo for one filament.
    @inline(__always) func filament(_ gap: Double, width: Double) -> Double {
      let core = max(0.0, 1.0 - gap / width)
      let halo = max(0.0, 1.0 - gap / (width * 3.2))
      return core * core * core + halo * halo * 0.22
    }

    var pixels = [UInt8](repeating: 0, count: rw * rh * 4)
    let rByte = Double(max(0, min(255, Int(round(ink.r * 255)))))
    let gByte = Double(max(0, min(255, Int(round(ink.g * 255)))))
    let bByte = Double(max(0, min(255, Int(round(ink.b * 255)))))

    for y in 0..<rh {
      let yd = Double(y) * sy
      for x in 0..<rw {
        let xd = Double(x) * sx
        // Shared ripple warp bends both webs the same way, like one water surface.
        let wx = (sample(xd * warpFreq + 2.1, yd * warpFreq + 4.3, 2) - 0.5) * 1.6
        let wy = (sample(xd * warpFreq + 9.4, yd * warpFreq + 1.7, 2) - 0.5) * 1.6
        let focus = sample(xd * warpFreq * 0.45 + 5.5, yd * warpFreq * 0.45 + 7.9, 2)
        let focusN = max(0.0, min(1.0, (focus - 0.30) / 0.42))
        let width = 0.11 - focusN * 0.05

        let gA = web(xd * cellA + wx, yd * cellA + wy, salt: 11, speed: 1.0)
        let gB = web(xd * cellB + wx * 1.3 + 3.7, yd * cellB + wy * 1.3 + 1.9, salt: 47, speed: -1.35)
        let fA = filament(gA, width: width)
        let fB = filament(gB, width: width * 1.15) * 0.62
        let knot = fA * fB * 1.6

        let lum = (fA + fB + knot) * (0.55 + focusN * 0.65)
        let a = min(1.0, lum * strength)
        let idx = (y * rw + x) * 4
        // Premultiplied RGBA for CGImage
        pixels[idx]     = UInt8(rByte * a)
        pixels[idx + 1] = UInt8(gByte * a)
        pixels[idx + 2] = UInt8(bByte * a)
        pixels[idx + 3] = UInt8(round(a * 255.0))
      }
    }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    let created: CGImage? = pixels.withUnsafeMutableBytes { buf in
      guard let base = buf.baseAddress else { return nil }
      guard let bmp = CGContext(
        data: base, width: rw, height: rh,
        bitsPerComponent: 8, bytesPerRow: rw * 4,
        space: colorSpace, bitmapInfo: bitmapInfo.rawValue
      ) else { return nil }
      return bmp.makeImage()
    }
    if let img = created {
      ctx.interpolationQuality = .high
      ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
  }

  // MARK: - 5. Ridge Lines (Displaced Elevation Profiles)

  private static func drawRidges(
    ctx: CGContext, w: Double, h: Double, isDark: Bool, intensity: Double,
    mini: Bool, sample: (Double, Double, Int) -> Double, setStroke: (Double) -> Void
  ) {
    let spacing = mini ? 8.5 : 13.5
    let amp = (mini ? 15.0 : 32.0) * (0.55 + intensity * 0.65)
    let freqX = mini ? 0.015 : 0.0055
    let freqY = 0.008
    let stepX = mini ? 4.0 : 6.0

    ctx.setLineWidth(0.95)
    var y = -amp
    while y < h + amp {
      let rowNorm = max(0, min(1, y / max(1, h)))
      let alpha = (isDark ? 0.24 : 0.21) * (0.4 + intensity * 0.85) * (0.55 + 0.45 * sin(rowNorm * .pi))
      setStroke(alpha)
      ctx.beginPath()
      var x = 0.0
      var first = true
      while x <= w + stepX {
        let py = y + (sample(x * freqX + 1.3, y * freqY + 2.7, 3) - 0.5) * amp * 2.1
        if first {
          ctx.move(to: CGPoint(x: x, y: py))
          first = false
        } else {
          ctx.addLine(to: CGPoint(x: x, y: py))
        }
        x += stepX
      }
      ctx.strokePath()
      y += spacing
    }
  }

  // MARK: - 6. Washi Paper (Laid Sugeta Screen + Sinuous Kozo Fibers)

  private static func drawWashiPaper(
    ctx: CGContext, w: Double, h: Double, isDark: Bool, intensity: Double,
    seed: UInt32, mini: Bool, sample: (Double, Double, Int) -> Double, setStroke: (Double) -> Void
  ) {
    var rng = Mulberry32(seed: seed &+ 777)
    let freq = mini ? 0.016 : 0.006
    let strength = 0.45 + intensity * 0.9

    // 1. Subtle laid-paper bamboo screen lines (sugeta)
    let laidStep = mini ? 5.0 : 6.0
    ctx.setLineWidth(0.6)
    setStroke((isDark ? 0.075 : 0.065) * strength)
    ctx.beginPath()
    var y = laidStep / 2
    while y < h {
      ctx.move(to: CGPoint(x: 0, y: y))
      ctx.addLine(to: CGPoint(x: w, y: y))
      y += laidStep
    }
    let chainStep = mini ? 28.0 : 48.0
    var x = chainStep
    while x < w {
      ctx.move(to: CGPoint(x: x, y: 0))
      ctx.addLine(to: CGPoint(x: x, y: h))
      x += chainStep
    }
    ctx.strokePath()

    // 2. Signature sinuous kozo / unryu mulberry fibers
    let longCount = max(20, Int((w * h) / (mini ? 380.0 : 1250.0)))
    ctx.setLineCap(.round)
    for _ in 0..<longCount {
      let fx = rng.next() * w
      let fy = rng.next() * h
      let angle = (rng.next() - 0.5) * .pi * 1.4
      let len = (mini ? 14.0 : 26.0) + rng.next() * (mini ? 22.0 : 46.0)
      let bend = (rng.next() - 0.5) * len * 0.65
      let mx = fx + cos(angle) * len * 0.5 - sin(angle) * bend
      let my = fy + sin(angle) * len * 0.5 + cos(angle) * bend
      let ex = fx + cos(angle) * len
      let ey = fy + sin(angle) * len
      let alphaRand = rng.next()
      let thick = rng.next() > 0.72
      let wave = 0.55 + sample(fx * freq, fy * freq, 2) * 0.75

      setStroke((isDark ? 0.28 : 0.24) * strength * wave * (0.55 + alphaRand * 0.55))
      ctx.setLineWidth(thick ? 1.35 : 0.85)
      ctx.beginPath()
      ctx.move(to: CGPoint(x: fx, y: fy))
      ctx.addQuadCurve(to: CGPoint(x: ex, y: ey), control: CGPoint(x: mx, y: my))
      ctx.strokePath()
    }

    // 3. Short crisp pulp micro-fibers
    let shortCount = Int((w * h) / (mini ? 95.0 : 165.0))
    ctx.setLineWidth(0.75)
    for _ in 0..<shortCount {
      let fx = rng.next() * w
      let fy = rng.next() * h
      let angle = rng.next() * .pi * 2
      let len = 3.0 + rng.next() * 8.0
      let alphaRand = rng.next()
      let wave = 0.5 + sample(fx * freq, fy * freq, 2) * 0.8
      setStroke((isDark ? 0.16 : 0.14) * strength * wave * (0.45 + alphaRand * 0.65))
      ctx.beginPath()
      ctx.move(to: CGPoint(x: fx, y: fy))
      ctx.addLine(to: CGPoint(x: fx + cos(angle) * len, y: fy + sin(angle) * len))
      ctx.strokePath()
    }
  }
}
