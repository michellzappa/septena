import Foundation

/// Canonical sidebar / picker order for areas and projects. Every surface that
/// lists them for navigation or filing reads through `StructureCache`, which
/// applies this ordering on top of the title-sorted `LocalCache` fetch.
///
/// Priority: synced `position` (CloudKit `reservedInt1`) → legacy device-local
/// `sidebar.*Order` UserDefaults → title order for unset rows. See
/// `docs/DRAG_AND_DROP.md` §5 gap #2.
enum TaskStructureOrder {
  static func orderedAreas(_ loaded: [Area]) -> [Area] {
    positionOrdered(loaded, legacyKey: "sidebar.areaOrder", position: \.position)
  }

  static func orderedProjects(_ loaded: [Project]) -> [Project] {
    positionOrdered(loaded, legacyKey: "sidebar.projectOrder", position: \.position)
  }

  /// Order by the synced `position`. Once anything's been ordered, position
  /// wins: ascending, with unset rows (`position == 0`) sinking to the bottom
  /// in the incoming (title-sorted) order. Before any reorder on this build
  /// (every position still 0), fall back to the legacy device-local order.
  private static func positionOrdered<T: Identifiable>(
    _ loaded: [T], legacyKey: String, position: KeyPath<T, Int>
  ) -> [T] where T.ID == String {
    guard loaded.contains(where: { $0[keyPath: position] != 0 }) else {
      return applyStoredOrder(loaded, key: legacyKey)
    }
    return loaded.enumerated().sorted { a, b in
      let pa = a.element[keyPath: position] == 0 ? Int.max : a.element[keyPath: position]
      let pb = b.element[keyPath: position] == 0 ? Int.max : b.element[keyPath: position]
      return pa != pb ? pa < pb : a.offset < b.offset
    }.map(\.element)
  }

  /// Reorder `loaded` to match a persisted `[id]` order, appending any ids the
  /// stored list hasn't seen yet (new entities) at the end.
  private static func applyStoredOrder<T: Identifiable>(_ loaded: [T],
                                                        key: String) -> [T]
  where T.ID == String {
    guard let data = UserDefaults.standard.data(forKey: key),
          let ids = try? JSONDecoder().decode([String].self, from: data),
          !ids.isEmpty else { return loaded }
    let byId = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
    let ordered = ids.compactMap { byId[$0] }
    let new = loaded.filter { !ids.contains($0.id) }
    return ordered + new
  }
}
