import Foundation

enum TasksWidgetSnapshotStore {
  static let userDefaultsKey = "septena.widget.tasksToday"
  static let appGroupSuite = "group.com.septena.cloud"

  static func load() -> TasksWidgetWire? {
    guard
      let defaults = UserDefaults(suiteName: appGroupSuite),
      let data = defaults.data(forKey: userDefaultsKey),
      let decoded = try? JSONDecoder().decode(TasksWidgetWire.self, from: data)
    else {
      return nil
    }
    return decoded
  }

  static func save(_ wire: TasksWidgetWire) {
    guard
      let defaults = UserDefaults(suiteName: appGroupSuite),
      let data = try? JSONEncoder().encode(wire)
    else { return }
    defaults.set(data, forKey: userDefaultsKey)
  }

  @discardableResult
  static func saveIfChanged(_ wire: TasksWidgetWire) -> Bool {
    guard load().map({ !wire.hasSameContent(as: $0) }) ?? true else { return false }
    save(wire)
    return true
  }
}
