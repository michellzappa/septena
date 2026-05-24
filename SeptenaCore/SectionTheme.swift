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

  public init(key: String, label: String, color: String) {
    self.key = key
    self.label = label
    self.color = color
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
    .init(key: "air",         label: "Air",         color: "#14b8a6"),
    .init(key: "groceries",   label: "Groceries",   color: "#84cc16"),
    .init(key: "caffeine",    label: "Caffeine",    color: "#92400e"),
    .init(key: "cannabis",    label: "Cannabis",    color: "#65a30d"),
    .init(key: "body",        label: "Body",        color: "#ec4899"),
    .init(key: "gut",         label: "Gut",         color: "#b45309"),
    .init(key: "activity",    label: "Activity",    color: "#06b6d4"),
    .init(key: "goals",       label: "Goals",       color: "#8b5cf6"),
    .init(key: "insights",    label: "Insights",    color: "#0ea5e9"),
  ]

  /// Neutral fallback — inherits from the asset catalog's AccentColor.
  static let fallback = Color.accentColor

  /// Primary accent for the app — equals the user's Septena Tasks-section color.
  var accent: Color = SectionTheme.fallback
  /// Soft / strong derivatives recomputed whenever `accent` changes.
  private(set) var accentSoft: Color = Color.accentColor.opacity(0.14)
  /// All section accents keyed by Septena section id (`tasks`, `habits`,
  /// `chores`, `supplements`, ...). Populated by `refresh()`.
  private(set) var accentByKey: [String: Color] = [:]

  /// Resolve any section's accent — falls back to `inkSecondary` for
  /// sections we don't know about (or before the first refresh completes).
  func color(for sectionKey: String) -> Color {
    accentByKey[sectionKey] ?? Color(red: 0.541, green: 0.514, blue: 0.471)
  }

  /// Placeholder glyph for any "this is the X section" chrome that still
  /// needs an icon slot filled (e.g. SwiftUI's `ContentUnavailableView`).
  /// Deliberately section-agnostic — Septena doesn't lean on per-section
  /// SF Symbols, and "when in doubt, a dot" beats picking a glyph that
  /// ends up feeling arbitrary.
  func icon(for sectionKey: String) -> String { "circle.fill" }

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

  /// Accept "#rrggbb", "rgb(r, g, b)", or "hsl(h, s%, l%)".
  private func parseColor(_ raw: String) -> Color? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if s.hasPrefix("#") { return colorFromHex(s) }
    if s.hasPrefix("hsl") { return colorFromHSL(s) }
    if s.hasPrefix("rgb") { return colorFromRGB(s) }
    return colorFromHex("#" + s)   // bare 6-char hex
  }

  private func colorFromHex(_ s: String) -> Color? {
    let hex = s.replacingOccurrences(of: "#", with: "")
    guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
    return Color(
      red:   Double((v >> 16) & 0xff) / 255,
      green: Double((v >> 8)  & 0xff) / 255,
      blue:  Double(v         & 0xff) / 255
    )
  }

  private func colorFromHSL(_ s: String) -> Color? {
    // Match h, s%, l% — accepting commas or spaces between values.
    let nums = s
      .replacingOccurrences(of: "hsl", with: "")
      .replacingOccurrences(of: "(", with: "")
      .replacingOccurrences(of: ")", with: "")
      .replacingOccurrences(of: "%", with: "")
      .split(whereSeparator: { ", ".contains($0) })
      .compactMap { Double($0) }
    guard nums.count >= 3 else { return nil }
    return hslToColor(h: nums[0], s: nums[1] / 100, l: nums[2] / 100)
  }

  private func colorFromRGB(_ s: String) -> Color? {
    let nums = s
      .replacingOccurrences(of: "rgba", with: "")
      .replacingOccurrences(of: "rgb", with: "")
      .replacingOccurrences(of: "(", with: "")
      .replacingOccurrences(of: ")", with: "")
      .split(whereSeparator: { ", ".contains($0) })
      .compactMap { Double($0) }
    guard nums.count >= 3 else { return nil }
    return Color(red: nums[0] / 255, green: nums[1] / 255, blue: nums[2] / 255)
  }

  /// Standard HSL → RGB.
  private func hslToColor(h: Double, s: Double, l: Double) -> Color {
    let c = (1 - abs(2 * l - 1)) * s
    let hPrime = h.truncatingRemainder(dividingBy: 360) / 60
    let x = c * (1 - abs(hPrime.truncatingRemainder(dividingBy: 2) - 1))
    let m = l - c / 2
    let (r1, g1, b1): (Double, Double, Double)
    switch hPrime {
    case 0..<1: (r1, g1, b1) = (c, x, 0)
    case 1..<2: (r1, g1, b1) = (x, c, 0)
    case 2..<3: (r1, g1, b1) = (0, c, x)
    case 3..<4: (r1, g1, b1) = (0, x, c)
    case 4..<5: (r1, g1, b1) = (x, 0, c)
    default:    (r1, g1, b1) = (c, 0, x)
    }
    return Color(red: r1 + m, green: g1 + m, blue: b1 + m)
  }
}
