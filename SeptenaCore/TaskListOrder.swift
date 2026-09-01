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
  static func byList(_ pool: [SeptenaTask], areas: [Area], projects: [Project]) -> [SeptenaTask] {
    let byProject = Dictionary(grouping: pool.filter { $0.project != nil },
                               by: { $0.project! })
    let byArea = Dictionary(grouping: pool.filter { $0.project == nil && $0.area != nil },
                            by: { $0.area! })
    var result = pool.filter { $0.project == nil && $0.area == nil }
    for area in areas {
      result.append(contentsOf: byArea[area.id] ?? [])
      for project in projects where project.area == area.id {
        result.append(contentsOf: byProject[project.id] ?? [])
      }
    }
    for project in projects where project.area == nil {
      result.append(contentsOf: byProject[project.id] ?? [])
    }
    return result
  }
}
