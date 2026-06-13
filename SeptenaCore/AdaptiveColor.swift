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
