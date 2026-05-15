import SwiftUI

// Live mirror of Septena's Tasks section accent. Refreshed from /api/sections
// at app launch and on settings change. Falls back to the asset-catalog
// AccentColor (neutral blue) if the fetch fails or the server returns no
// `tasks` row — no opinionated default hue baked into code.

@MainActor
@Observable
final class SectionTheme {
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

  func refresh(from client: SeptenaClient) async {
    do {
      let sections = try await client.sections()
      var byKey: [String: Color] = [:]
      for s in sections {
        if let c = parseColor(s.color) { byKey[s.key] = c }
      }
      accentByKey = byKey
      if let tasks = byKey["tasks"] {
        accent = tasks
        accentSoft = tasks.opacity(0.14)
      }
    } catch {
      SeptenaLog.error("section accent refresh failed", error)
    }
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
