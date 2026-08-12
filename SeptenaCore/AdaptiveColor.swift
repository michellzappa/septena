import SwiftUI

// MARK: - AdaptiveColor (global color-token resolver)

/// Single source of truth for turning an authored color token — a hex string
/// (`#rrggbb`), `rgb(...)`, `hsl(...)`, or a packed `UInt32` — into a SwiftUI
/// `Color`. Every section accent, macro tile, fasting band, and Settings
/// swatch flows through here; there is no second hex→Color path.
///
/// Lives in its own file (split out of `SectionTheme.swift`) because it has no
/// dependency on the `SectionTheme` observable — which lets the leaner targets
/// (the widget extension renders the rhythm wheel) compile just this resolver
/// without pulling in the whole theme runtime.
///
/// Authored tokens are *light-mode* values: the Tailwind section palette, the
/// macro catalog, a user's picked swatch. Against the near-black dark-mode
/// canvas, low-lightness tokens — the caffeine/gut browns, a gray fasting
/// band — collapse toward mud. Rather than carry a second value per token,
/// the `adaptive(...)` path derives the dark variant from the color itself:
/// lift anything below `darkFloor` up to it, trimming a little saturation so
/// it reads clean. Bright tokens pass through unchanged, and user-customized
/// darks get the same protection for free.
///
/// Two entry points, one parser:
///   • `adaptive(...)` — appearance-aware. Use for everything that *renders*.
///   • `raw(...)` — the authored color exactly as stored, no lift. Use for
///     editing controls (`ColorPicker`) and anywhere a color round-trips back
///     to a hex string, where an adaptive color would serialize its lifted
///     dark-mode value.
enum AdaptiveColor {

  /// Minimum perceptual lightness a token keeps in dark mode.
  static let darkFloor = 0.50

  // MARK: Entry points

  /// Appearance-adaptive Color from a token string. Nil on unparseable input.
  static func adaptive(_ token: String?) -> Color? {
    guard let rgb = components(token) else { return nil }
    return wrap(rgb)
  }

  /// Appearance-adaptive Color from packed `0xRRGGBB`.
  static func adaptive(hex: UInt32) -> Color { wrap(unpack(hex)) }

  /// Authored Color exactly as stored (no dark-mode lift). Nil on bad input.
  static func raw(_ token: String?) -> Color? {
    guard let c = components(token) else { return nil }
    return Color(red: c.r, green: c.g, blue: c.b)
  }

  /// Authored Color from packed `0xRRGGBB` (no dark-mode lift).
  static func raw(hex: UInt32) -> Color {
    let c = unpack(hex)
    return Color(red: c.r, green: c.g, blue: c.b)
  }

  /// A hand-authored appearance *pair* — the `light` token under a light
  /// appearance, `dark` under a dark one — with NO automatic lift. For
  /// finishes tuned per mode by hand (the membership "metal card", whose dark
  /// plate must sit a touch *lighter* than the near-black canvas to read as
  /// raised, the opposite of what the derived lift would do). Gray on bad input.
  static func dual(light: String, dark: String) -> Color {
    guard let l = components(light), let d = components(dark) else { return .gray }
    #if os(macOS)
    return Color(nsColor: NSColor(name: nil) { appearance in
      let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
      let c = isDark ? d : l
      return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    })
    #else
    return Color(uiColor: UIColor { traits in
      let c = traits.userInterfaceStyle == .dark ? d : l
      return UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
    })
    #endif
  }

  // MARK: - Adaptive wrapping

  /// Wrap base light-mode components in a Color that swaps to the lifted
  /// variant under a dark appearance.
  private static func wrap(_ base: RGB) -> Color {
    let dark = liftedForDark(base)
    #if os(macOS)
    return Color(nsColor: NSColor(name: nil) { appearance in
      let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
      let c = isDark ? dark : base
      return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    })
    #else
    return Color(uiColor: UIColor { traits in
      let c = traits.userInterfaceStyle == .dark ? dark : base
      return UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
    })
    #endif
  }

  /// Lift a dark token up to `darkFloor`, trimming a little saturation so the
  /// brighter swatch reads clean rather than neon. No-op at/above the floor.
  private static func liftedForDark(_ base: RGB) -> RGB {
    var hsl = rgbToHSL(base)
    guard hsl.l < darkFloor else { return base }
    let lift = darkFloor - hsl.l
    hsl.l = darkFloor
    hsl.s = max(0, hsl.s - lift * 0.35)
    return hslToRGB(hsl)
  }

  // MARK: - Solid-fill contrast (accent CTAs)

  /// Near-black label on a light solid fill. Matches the light-mode side of
  /// `Theme.listSelectedInk` — full white fails on yellow/lime/amber slabs
  /// (e.g. `#d6f249` ≈ 1.3:1, `#aacc00` ≈ 1.9:1, palette lime `#84cc16` ≈ 2.0:1).
  static let solidFillDarkInk = Color.black.opacity(0.88)

  /// Minimum WCAG contrast for white ink on a solid button fill. 3:1 is large-
  /// text / UI-component AA — prominent button labels qualify; body AA (4.5:1)
  /// would force yellows into olive and erase section identity.
  static let whiteInkMinContrast = 3.0

  /// Label ink that contrasts against a solid `fill`. Prefer this over hard-
  /// coded `.white` on hand-rolled accent CTAs — light yellows/limes need
  /// dark ink; deep earth tones keep white.
  static func inkOnSolidFill(_ fill: Color) -> Color {
    prefersDarkInk(on: fill) ? solidFillDarkInk : .white
  }

  /// `true` when black ink contrasts better than white against `fill`.
  static func prefersDarkInk(on fill: Color) -> Bool {
    guard let rgb = resolve(fill) else { return false }
    let l = relativeLuminance(rgb)
    let whiteContrast = (1.0 + 0.05) / (l + 0.05)
    let blackContrast = (l + 0.05) / 0.05
    return blackContrast > whiteContrast
  }

  /// Darken `fill` (preserving hue) until white ink clears `whiteInkMinContrast`.
  /// Use as `.tint(...)` on `.glassProminent` / `.borderedProminent`, which force
  /// white labels and cannot pick dark ink. No-op when the fill already passes.
  /// Remapping every light accent to a fixed chartreuse (`#aacc00`) is wrong —
  /// that swatch still fails white ink; darken in-place instead.
  static func fillForWhiteInk(_ fill: Color) -> Color {
    guard let rgb = resolve(fill) else { return fill }
    if contrastAgainstWhite(rgb) >= whiteInkMinContrast { return fill }
    let darkened = darkenedForWhiteInk(rgb, minContrast: whiteInkMinContrast)
    return Color(red: darkened.r, green: darkened.g, blue: darkened.b)
  }

  // MARK: - Token parsing

  private static func unpack(_ hex: UInt32) -> RGB {
    RGB(r: Double((hex >> 16) & 0xff) / 255,
        g: Double((hex >> 8)  & 0xff) / 255,
        b: Double( hex        & 0xff) / 255)
  }

  /// Parse `#rrggbb`, `rgb(r, g, b)`, `hsl(h, s%, l%)`, or bare 6-char hex.
  private static func components(_ token: String?) -> RGB? {
    guard let raw = token else { return nil }
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if s.hasPrefix("#")   { return hexComponents(s) }
    if s.hasPrefix("hsl") { return hslComponents(s) }
    if s.hasPrefix("rgb") { return rgbComponents(s) }
    return hexComponents("#" + s)   // bare 6-char hex
  }

  private static func hexComponents(_ s: String) -> RGB? {
    let hex = s.replacingOccurrences(of: "#", with: "")
    guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
    return unpack(v)
  }

  private static func hslComponents(_ s: String) -> RGB? {
    // Match h, s%, l% — accepting commas or spaces between values.
    let nums = s
      .replacingOccurrences(of: "hsl", with: "")
      .replacingOccurrences(of: "(", with: "")
      .replacingOccurrences(of: ")", with: "")
      .replacingOccurrences(of: "%", with: "")
      .split(whereSeparator: { ", ".contains($0) })
      .compactMap { Double($0) }
    guard nums.count >= 3 else { return nil }
    return hslToRGB(HSL(h: nums[0], s: nums[1] / 100, l: nums[2] / 100))
  }

  private static func rgbComponents(_ s: String) -> RGB? {
    let nums = s
      .replacingOccurrences(of: "rgba", with: "")
      .replacingOccurrences(of: "rgb", with: "")
      .replacingOccurrences(of: "(", with: "")
      .replacingOccurrences(of: ")", with: "")
      .split(whereSeparator: { ", ".contains($0) })
      .compactMap { Double($0) }
    guard nums.count >= 3 else { return nil }
    return RGB(r: nums[0] / 255, g: nums[1] / 255, b: nums[2] / 255)
  }

  // MARK: - Luminance / contrast

  /// Resolve a SwiftUI `Color` to sRGB components in the *current* appearance.
  /// Dynamic/`AdaptiveColor` values evaluate to whichever variant is showing.
  private static func resolve(_ color: Color) -> RGB? {
    #if os(macOS)
    guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
    return RGB(r: srgb.redComponent, g: srgb.greenComponent, b: srgb.blueComponent)
    #else
    let ui = UIColor(color)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    if ui.getRed(&r, green: &g, blue: &b, alpha: &a) {
      return RGB(r: Double(r), g: Double(g), b: Double(b))
    }
    guard let converted = ui.cgColor.converted(
      to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
          let c = converted.components, c.count >= 3
    else { return nil }
    return RGB(r: Double(c[0]), g: Double(c[1]), b: Double(c[2]))
    #endif
  }

  private static func relativeLuminance(_ c: RGB) -> Double {
    func lin(_ v: Double) -> Double {
      v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
  }

  private static func contrastAgainstWhite(_ c: RGB) -> Double {
    (1.0 + 0.05) / (relativeLuminance(c) + 0.05)
  }

  /// Binary-search a scale toward black until white-ink contrast clears the bar.
  private static func darkenedForWhiteInk(_ base: RGB, minContrast: Double) -> RGB {
    // Scale RGB toward black. t=1 is the authored fill; t=0 is black.
    // Keep the lightest t that still clears white-ink contrast.
    var lo = 0.0, hi = 1.0
    var best = RGB(r: 0, g: 0, b: 0)
    for _ in 0..<12 {
      let t = (lo + hi) / 2
      let candidate = RGB(r: base.r * t, g: base.g * t, b: base.b * t)
      if contrastAgainstWhite(candidate) >= minContrast {
        best = candidate
        lo = t
      } else {
        hi = t
      }
    }
    return best
  }

  // MARK: - HSL ⇄ RGB

  private static func rgbToHSL(_ c: RGB) -> HSL {
    let maxV = max(c.r, c.g, c.b)
    let minV = min(c.r, c.g, c.b)
    let l = (maxV + minV) / 2
    let delta = maxV - minV
    guard delta > 0 else { return HSL(h: 0, s: 0, l: l) }
    let s = delta / (1 - abs(2 * l - 1))
    var h: Double
    if maxV == c.r {
      h = ((c.g - c.b) / delta).truncatingRemainder(dividingBy: 6)
    } else if maxV == c.g {
      h = (c.b - c.r) / delta + 2
    } else {
      h = (c.r - c.g) / delta + 4
    }
    h *= 60
    if h < 0 { h += 360 }
    return HSL(h: h, s: s, l: l)
  }

  /// Standard HSL → RGB.
  private static func hslToRGB(_ c: HSL) -> RGB {
    let chroma = (1 - abs(2 * c.l - 1)) * c.s
    let hPrime = c.h.truncatingRemainder(dividingBy: 360) / 60
    let x = chroma * (1 - abs(hPrime.truncatingRemainder(dividingBy: 2) - 1))
    let m = c.l - chroma / 2
    let (r1, g1, b1): (Double, Double, Double)
    switch hPrime {
    case 0..<1: (r1, g1, b1) = (chroma, x, 0)
    case 1..<2: (r1, g1, b1) = (x, chroma, 0)
    case 2..<3: (r1, g1, b1) = (0, chroma, x)
    case 3..<4: (r1, g1, b1) = (0, x, chroma)
    case 4..<5: (r1, g1, b1) = (x, 0, chroma)
    default:    (r1, g1, b1) = (chroma, 0, x)
    }
    return RGB(r: r1 + m, g: g1 + m, b: b1 + m)
  }

  // MARK: - Component value types

  private struct RGB { var r, g, b: Double }
  private struct HSL { var h, s, l: Double }
}
