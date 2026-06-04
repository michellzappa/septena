import SwiftUI

// MARK: - SectionConfig (value type for palette plumbing)

/// In-memory shape for a single section's accent. Lives here (not in
/// SeptenaClient) because it has no FastAPI dependency anymore — the
/// SectionTheme palette and CloudKit SectionEntity mirror both produce
/// and consume values of this type.
public struct SectionConfig: Codable, Hashable {
  public let key: String
  public let label: String
  public let color: String          // hex (e.g. "#ef4444") or "hsl(...)"
  /// Whether the section is visible in the dashboard / sidebar. Disabled
  /// rows still exist in the central store so their color / label
  /// customizations survive a toggle.
  public let isEnabled: Bool
  /// Whether this section contributes to the Today log. Only meaningful
  /// for sections the manifest flags as `appearsInToday`.
  public let showInToday: Bool
  /// True once the section's first-time onboarding has completed (or
  /// been skipped). Distinguishes "first ever enable" from a later
  /// toggle off → on. Stays true forever once set.
  public let hasOnboarded: Bool

  public init(key: String,
              label: String,
              color: String,
              isEnabled: Bool = true,
              showInToday: Bool = true,
              hasOnboarded: Bool = false) {
    self.key = key
    self.label = label
    self.color = color
    self.isEnabled = isEnabled
    self.showInToday = showInToday
    self.hasOnboarded = hasOnboarded
  }

  // Custom decode so older ResponseCache blobs (pre-isEnabled /
  // pre-showInToday / pre-hasOnboarded) decode cleanly with sensible
  // defaults.
  private enum CodingKeys: String, CodingKey {
    case key, label, color, isEnabled, showInToday, hasOnboarded
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.key = try c.decode(String.self, forKey: .key)
    self.label = try c.decode(String.self, forKey: .label)
    self.color = try c.decode(String.self, forKey: .color)
    self.isEnabled = (try? c.decode(Bool.self, forKey: .isEnabled)) ?? true
    self.showInToday = (try? c.decode(Bool.self, forKey: .showInToday)) ?? true
    self.hasOnboarded = (try? c.decode(Bool.self, forKey: .hasOnboarded)) ?? false
  }
}

// Live mirror of Septena's section accents. Sources, in order of preference:
//   1. CloudKit-backed `SectionEntity` (user-customized colors).
//   2. ResponseCache disk blob (last-known state, primes cold launch).
//   3. Hardcoded `defaultPalette` below (fresh install with no CK records).
// No FastAPI involvement.

@MainActor
@Observable
final class SectionTheme {
  /// Baseline palette used when neither the CloudKit mirror nor the on-
  /// disk cache has anything to offer (first-launch state). Keys match
  /// `HomepageDomain.rawValue` so every tile renders with a sensible color
  /// before the user touches Settings. Edits in Settings overwrite the
  /// SectionEntity records and CK syncs the change to other devices.
  static let defaultPalette: [SectionConfig] = [
    .init(key: "tasks",       label: "Tasks",       color: "#ef4444"),
    .init(key: "habits",      label: "Habits",      color: "#22c55e"),
    .init(key: "training",    label: "Training",    color: "#f97316"),
    .init(key: "chores",      label: "Chores",      color: "#a855f7"),
    .init(key: "supplements", label: "Supplements", color: "#3b82f6"),
    .init(key: "sleep",       label: "Sleep",       color: "#6366f1"),
    .init(key: "nutrition",   label: "Nutrition",   color: "#f59e0b"),
    .init(key: "groceries",   label: "Groceries",   color: "#84cc16"),
    .init(key: "caffeine",    label: "Caffeine",    color: "#92400e"),
    .init(key: "cannabis",    label: "Cannabis",    color: "#65a30d"),
    .init(key: "body",        label: "Body",        color: "#ec4899"),
    .init(key: "gut",         label: "Gut",         color: "#b45309"),
    .init(key: "activity",    label: "Activity",    color: "#06b6d4"),
    .init(key: "goals",       label: "Goals",       color: "#8b5cf6"),
  ]

  /// Neutral fallback — inherits from the asset catalog's AccentColor.
  static let fallback = Color.accentColor

  /// The app's primary accent — the asset-catalog `AccentColor`, a standalone
  /// brand tint intentionally independent of any section color. Applied at the
  /// app root via `.tint(theme.accent)`, so `Color.accentColor` inherits it
  /// app-wide. Per-section colors come from `color(for:)`, never this.
  let accent: Color = SectionTheme.fallback
  /// All section accents keyed by Septena section id (`tasks`, `habits`,
  /// `chores`, `supplements`, ...). Populated by `refresh()`.
  private(set) var accentByKey: [String: Color] = [:]

  /// Hydrate from the local mirror / disk cache during construction so the
  /// very first frame the dashboard renders already has the user's accent
  /// colors. Doing this in `.task` instead leaves a half-second flash of
  /// gray placeholders while SwiftUI waits for the task closure to fire.
  init() {
    paintFromCache()
  }

  /// Resolve any section's accent — falls back to `inkSecondary` for
  /// sections we don't know about (or before the first refresh completes).
  func color(for sectionKey: String) -> Color {
    accentByKey[sectionKey] ?? Color(red: 0.541, green: 0.514, blue: 0.471)
  }

  /// Glyph for "this is the X section" chrome (e.g. SwiftUI's
  /// `ContentUnavailableView` empty states). Delegates to the manifest so
  /// there is a single source of truth for section iconography — the same
  /// per-section SF Symbol shown on tiles and in the sidebar. Falls back to
  /// a neutral dot for unknown keys.
  func icon(for sectionKey: String) -> String {
    SectionManifest.byKey[sectionKey]?.iconSymbol ?? "circle.fill"
  }

  /// Synchronous cache prime — reads the last-known `/api/sections`
  /// response out of disk and populates `accentByKey`. Called before
  /// `refresh()` on app launch so tiles render with the right color on
  /// cold launch instead of the fallback gray.
  func paintFromCache() {
    if let sections = loadSectionsForPaint() {
      applySections(sections)
    }
  }

  static let cacheKey = "theme.sections"

  func refresh() async {
    if let sections = loadSectionsForPaint(), !sections.isEmpty {
      applySections(sections)
      ResponseCache.save(sections, forKey: Self.cacheKey)
      return
    }

    // Fresh install with no CK records yet — paint with the hardcoded
    // baseline palette and seed CloudKit so other devices inherit the
    // same starting point. Users can recolor in Settings; that overwrite
    // syncs through SettingsMirror.replaceSections.
    let sections = Self.defaultPalette
    applySections(sections)
    ResponseCache.save(sections, forKey: Self.cacheKey)
    SettingsMirror.replaceSections(sections,
                                   context: LocalStore.shared.container.mainContext,
                                   engine: SeptenaServices.shared.ckEngine)
  }

  private func loadSectionsForPaint() -> [SectionConfig]? {
    let context = LocalStore.shared.container.mainContext
    let mirrored = SettingsMirror.loadSections(context: context)
    if !mirrored.isEmpty { return mirrored }
    return ResponseCache.load([SectionConfig].self,
                              forKey: Self.cacheKey)
  }

  private func applySections(_ sections: [SectionConfig]) {
    var byKey: [String: Color] = [:]
    for s in sections {
      if let c = parseColor(s.color) { byKey[s.key] = c }
    }
    accentByKey = byKey
  }

  // MARK: - Color string parsing

  /// Resolve an authored color token ("#rrggbb", "rgb(...)", or "hsl(...)")
  /// to an appearance-adaptive accent. The dark-mode lift that keeps low-
  /// lightness swatches legible lives in `AdaptiveColor` — the single
  /// resolver every color token in the app flows through (section accents,
  /// macro tiles, the fasting band, and Settings swatches all share it).
  private func parseColor(_ raw: String) -> Color? {
    AdaptiveColor.adaptive(raw)
  }
}

// MARK: - AdaptiveColor (global color-token resolver)

/// Single source of truth for turning an authored color token — a hex string
/// (`#rrggbb`), `rgb(...)`, `hsl(...)`, or a packed `UInt32` — into a SwiftUI
/// `Color`. Every section accent, macro tile, fasting band, and Settings
/// swatch flows through here; there is no second hex→Color path.
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
