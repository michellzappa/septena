import Foundation

/// App-group mirror of dashboard tile snapshots for the Section Tile widget.
enum TileWidgetSnapshotStore {
  static let userDefaultsKey = "septena.widget.sectionTiles"
  static let appGroupSuite = "group.com.septena.cloud"

  static func load() -> TileWidgetCatalog {
    guard
      let defaults = UserDefaults(suiteName: appGroupSuite),
      let data = defaults.data(forKey: userDefaultsKey),
      let decoded = try? JSONDecoder().decode(TileWidgetCatalog.self, from: data)
    else {
      return .empty
    }
    return decoded
  }

  static func save(_ catalog: TileWidgetCatalog) {
    guard
      let defaults = UserDefaults(suiteName: appGroupSuite),
      let data = try? JSONEncoder().encode(catalog)
    else { return }
    defaults.set(data, forKey: userDefaultsKey)
  }

  /// Avoid app-group writes and timeline reloads when only `updatedAt` moved.
  @discardableResult
  static func saveIfChanged(_ catalog: TileWidgetCatalog) -> Bool {
    guard !catalog.hasSameContent(as: load()) else { return false }
    save(catalog)
    return true
  }
}
