import Foundation

struct TasksTodayComplicationData: Codable {
  var remaining: Int
  var firstTitle: String?
  var updatedAt: Date

  static let userDefaultsKey = "septask.complication.today"
  static let appGroupSuite = "group.com.septena.cloud"

  static func load() -> TasksTodayComplicationData {
    guard
      let defaults = UserDefaults(suiteName: appGroupSuite),
      let data = defaults.data(forKey: userDefaultsKey),
      let decoded = try? JSONDecoder().decode(TasksTodayComplicationData.self, from: data)
    else {
      return TasksTodayComplicationData(remaining: 0, firstTitle: nil, updatedAt: .distantPast)
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
