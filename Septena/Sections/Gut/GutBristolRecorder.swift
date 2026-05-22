import Foundation

// Tracks which Bristol types the user has actually committed over the last
// 30 days, persisted in UserDefaults. Called from every commit site
// (QuickAdd, AddGutPage, EditGutEntrySheet). The menu reads `recentTypes`
// to show only numbers the user has genuinely used — if they've never
// logged a 1 or 2, those don't appear.

enum GutBristolRecorder {
  private static let key = "gut.bristolLastUsed"   // [String: Double] (type→timestamp)
  private static let window: TimeInterval = 30 * 24 * 3600

  /// Call after any successful gut entry commit.
  static func record(_ bristol: Int) {
    var map = load()
    map[String(bristol)] = Date().timeIntervalSinceReferenceDate
    save(map)
  }

  /// Distinct Bristol types used within the last 30 days, ascending.
  /// Returns an empty array if no history exists yet (menu shows its own fallback).
  static var recentTypes: [Int] {
    let cutoff = Date().timeIntervalSinceReferenceDate - window
    return load()
      .compactMap { key, ts -> Int? in
        guard ts >= cutoff, let n = Int(key) else { return nil }
        return n
      }
      .sorted()
  }

  private static func load() -> [String: Double] {
    (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
  }

  private static func save(_ map: [String: Double]) {
    UserDefaults.standard.set(map, forKey: key)
  }
}
