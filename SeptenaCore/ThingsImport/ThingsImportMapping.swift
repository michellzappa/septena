import Foundation

/// Persists Things uuid → Septena id mappings for idempotent re-import.
enum ThingsImportMapping {
  private static let suite = "group.com.septena.cloud"
  private static let areasKey = "septena.thingsImport.areas"
  private static let projectsKey = "septena.thingsImport.projects"
  private static let tasksKey = "septena.thingsImport.tasks"

  private static var defaults: UserDefaults {
    UserDefaults(suiteName: suite) ?? .standard
  }

  static func areaSeptenaID(for thingsID: String) -> String? {
    table(areasKey)[thingsID]
  }

  static func projectSeptenaID(for thingsID: String) -> String? {
    table(projectsKey)[thingsID]
  }

  static func taskSeptenaID(for thingsID: String) -> String? {
    table(tasksKey)[thingsID]
  }

  static func setArea(thingsID: String, septenaID: String) {
    var t = table(areasKey)
    t[thingsID] = septenaID
    save(t, key: areasKey)
  }

  static func setProject(thingsID: String, septenaID: String) {
    var t = table(projectsKey)
    t[thingsID] = septenaID
    save(t, key: projectsKey)
  }

  static func setTask(thingsID: String, septenaID: String) {
    var t = table(tasksKey)
    t[thingsID] = septenaID
    save(t, key: tasksKey)
  }

  static func allMappedTaskThingsIDs() -> [String] {
    Array(table(tasksKey).keys)
  }

  /// Clears import mappings (tests only).
  static func resetAll() {
    defaults.removeObject(forKey: areasKey)
    defaults.removeObject(forKey: projectsKey)
    defaults.removeObject(forKey: tasksKey)
  }

  private static func table(_ key: String) -> [String: String] {
    defaults.dictionary(forKey: key) as? [String: String] ?? [:]
  }

  private static func save(_ table: [String: String], key: String) {
    defaults.set(table, forKey: key)
  }
}
