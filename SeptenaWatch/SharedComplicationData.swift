import Foundation

struct NextComplicationData: Codable {
  var bucket: String
  var remaining: Int
  var firstTitle: String?
  var updatedAt: Date

  static let userDefaultsKey = "septena.complication.next"
  static let appGroupSuite   = "group.com.septena.cloud"

  static func load() -> NextComplicationData {
    guard
      let defaults = UserDefaults(suiteName: appGroupSuite),
      let data     = defaults.data(forKey: userDefaultsKey),
      let decoded  = try? JSONDecoder().decode(NextComplicationData.self, from: data)
    else {
      return NextComplicationData(bucket: "", remaining: 0, firstTitle: nil, updatedAt: .distantPast)
    }
    return decoded
  }

  func save() {
    guard
      let defaults = UserDefaults(suiteName: Self.appGroupSuite),
      let data     = try? JSONEncoder().encode(self)
    else { return }
    defaults.set(data, forKey: Self.userDefaultsKey)
  }
}
