import Foundation

/// What the watch complications draw. The watch app writes it after every
/// fetch and change; the widget extension only reads. Shared through the app
/// group (both targets' entitlements carry it).
struct TasksTodayComplicationData: Codable {
  var remaining: Int
  var firstTitle: String?
  var secondTitle: String?
  /// The day the count is for (YYYY-MM-DD). A count from yesterday is stale.
  var day: String?
  var connected: Bool = true
  var updatedAt: Date

  static let userDefaultsKey = "septask.complication.today"
  static let appGroupSuite = "group.com.septena.cloud"
  static let widgetKind = "SeptaskToday"

  static let placeholder = TasksTodayComplicationData(
    remaining: 4, firstTitle: "Book dentist", secondTitle: "Send invoice", day: nil, updatedAt: .now)

  static func load() -> TasksTodayComplicationData {
    guard
      let defaults = UserDefaults(suiteName: appGroupSuite),
      let data = defaults.data(forKey: userDefaultsKey),
      let decoded = try? JSONDecoder().decode(TasksTodayComplicationData.self, from: data)
    else {
      return TasksTodayComplicationData(remaining: 0, firstTitle: nil, day: nil, connected: false, updatedAt: .distantPast)
    }
    return decoded
  }

  func save() {
    guard
      let defaults = UserDefaults(suiteName: Self.appGroupSuite),
      let data = try? JSONEncoder().encode(self)
    else { return }
    defaults.set(data, forKey: Self.userDefaultsKey)
  }
}
