import Foundation

/// App-group mirror of today's macro rings for the Macros widget.
enum MacroWidgetSnapshotStore {
  static let userDefaultsKey = "septena.widget.macros"
  static let appGroupSuite = "group.com.septena.cloud"

  static func load() -> MacroWidgetWire? {
    guard
      let defaults = UserDefaults(suiteName: appGroupSuite),
      let data = defaults.data(forKey: userDefaultsKey),
      let decoded = try? JSONDecoder().decode(MacroWidgetWire.self, from: data)
    else {
      return nil
    }
    return decoded
  }

  static func save(_ wire: MacroWidgetWire?) {
    guard let defaults = UserDefaults(suiteName: appGroupSuite) else { return }
    guard let wire else {
      defaults.removeObject(forKey: userDefaultsKey)
      return
    }
    guard let data = try? JSONEncoder().encode(wire) else { return }
    defaults.set(data, forKey: userDefaultsKey)
  }
}
