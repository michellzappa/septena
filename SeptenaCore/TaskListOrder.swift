import Foundation

/// The canonical **by list** ordering for task rows: loose work first, then
/// each area (its own direct tasks, then that area's projects in sidebar
/// order), then projects that belong to no area.
///
/// Declared once because three surfaces have to agree on it and each used to
/// spell it out for itself:
///   • Septask's AppKit list — `groupedByList` emits headers in this order,
///     and flat Today now runs its "Lists" block through this;
///   • SwiftUI's `groupedOpenItems` / `ungroupedOpenItems`;
///   • `TaskListView.orderedFromGroupedOpen`, which arrow-key traversal reads
///     — it must match what the eye sees or ↑/↓ jumps around.
/// Same single-source rule as `NextBlocks` / `DayBucket`.
///
/// `areas` and `projects` come in already in sidebar order (`StructureCache`).
enum TaskListOrder {
  ///
  /// A dangling reference (an area or project id with no row — deleted on
  /// another device, or not synced yet) counts as nil, so the row lands with
  /// the loose work instead of dropping out of the list. Same for a project
  /// whose area is gone: it sorts with the area-less projects.
  static func byList(_ pool: [SeptenaTask], areas: [Area], projects: [Project]) -> [SeptenaTask] {
    let areaIDs = Set(areas.map(\.id))
    let projectIDs = Set(projects.map(\.id))
    func knownProject(_ t: SeptenaTask) -> String? {
      guard let p = t.project, projectIDs.contains(p) else { return nil }
      return p
    }
    func knownArea(_ t: SeptenaTask) -> String? {
      guard let a = t.area, areaIDs.contains(a) else { return nil }
      return a
    }
    let byProject = Dictionary(grouping: pool.filter { knownProject($0) != nil },
                               by: { knownProject($0)! })
    let byArea = Dictionary(grouping: pool.filter { knownProject($0) == nil && knownArea($0) != nil },
                            by: { knownArea($0)! })
    var result = pool.filter { knownProject($0) == nil && knownArea($0) == nil }
    for area in areas {
      result.append(contentsOf: byArea[area.id] ?? [])
      for project in projects where project.area == area.id {
        result.append(contentsOf: byProject[project.id] ?? [])
      }
    }
    for project in projects where project.area.map({ !areaIDs.contains($0) }) ?? true {
      result.append(contentsOf: byProject[project.id] ?? [])
    }
    return result
  }
}
