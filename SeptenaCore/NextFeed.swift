import SwiftData

/// The single source of truth for the "Next" feed's *membership and order*.
///
/// "Next" was historically just the ritual checklist (chores / habits /
/// supplements — see `ChecklistMirror.loadNextItems`). Tasks and read-only
/// suggestions were folded in later, but the composition + ordering got
/// re-derived independently in every surface (the iOS Next list, the watch
/// CloudKit snapshot), and they drifted. This type is where that logic now
/// lives *once*, so no surface can diverge again.
///
/// Two seams, by consumer need:
///   • `orderedSectionKeys(enabledKeys:)` — the pure ordering rule. The iOS
///     list passes its reactive `SettingsStore` sections; the headless flat
///     builder passes the mirror's. Same rule, different (appropriate) source.
///   • `flat(context:date:)` — the complete feed as a serializable `[NextItem]`
///     (suggestions first, then the ordered section blocks). What the watch
///     and any count consumer should use instead of assembling Next piecemeal.
///
/// Rendering stays per-platform on purpose: the iOS list builds interactive,
/// SwiftData-backed rows from its per-type models, while the watch shows a
/// read-only list off this flat snapshot. Only the *composition* is shared.
enum NextFeed {
  /// The section blocks Next can render, in fallback order. Calendar is
  /// intentionally absent — it no longer surfaces in Next.
  static let sectionKeys = ["tasks", "chores", "habits", "supplements"]

  /// The Next section blocks in the user's saved order, filtered to those the
  /// user has enabled. Falls back to `sectionKeys` when the caller has no
  /// enabled keys yet (cold launch before the settings mirror hydrates), so
  /// Next never paints blank.
  static func orderedSectionKeys(enabledKeys: [String]) -> [String] {
    let ranked = enabledKeys.filter { sectionKeys.contains($0) }
    return ranked.isEmpty ? sectionKeys : ranked
  }

  /// The complete Next feed as a flat, serializable list: read-only
  /// suggestions first, then the ordered section blocks (tasks / chores /
  /// habits / supplements). All habit buckets are included (each tagged in
  /// `subtitle`) so a consumer can filter to the current time-of-day bucket
  /// on-device and the list stays valid all day.
  @MainActor
  static func flat(context: ModelContext, date: String) -> [NextItem] {
    var entries: [NextEntry] = []

    // Suggestions always lead — they're not a section and don't participate
    // in the saved order.
    entries.append(contentsOf:
      NextSuggestionsModel.visibleSuggestions(context: context).map(NextEntry.suggestion))

    // Today's open tasks, tagged with their project/area under the title.
    let areaTitle = Dictionary(LocalCache.areas(in: context).map { ($0.id, $0.title) },
                               uniquingKeysWith: { a, _ in a })
    let projectTitle = Dictionary(LocalCache.projects(in: context).map { ($0.id, $0.title) },
                                  uniquingKeysWith: { a, _ in a })
    let taskEntries: [NextEntry] = LocalCache.tasks(in: context, filter: .today)
      .filter { $0.status == .open }
      .map { task in
        let list = task.project.flatMap { projectTitle[$0] }
          ?? task.area.flatMap { areaTitle[$0] }
        return .task(id: task.id, title: task.title, subtitle: list, overdue: task.isOverdue)
      }

    // Chores / habits (all buckets) / supplements — already formatted by the
    // ritual builder; bucket by kind so they re-emit in section order.
    let ritual = ChecklistMirror.loadNextItems(context: context, date: date, bucket: nil).items
    let blocksByKey: [String: [NextEntry]] = [
      "tasks":       taskEntries,
      "chores":      ritual.filter { $0.kind == "chore" }.map(NextEntry.ritual),
      "habits":      ritual.filter { $0.kind == "habit" }.map(NextEntry.ritual),
      "supplements": ritual.filter { $0.kind == "supplement" }.map(NextEntry.ritual),
    ]

    let enabled = SettingsMirror.loadSections(context: context)
      .filter(\.isEnabled).map(\.key)
    for key in orderedSectionKeys(enabledKeys: enabled) {
      entries.append(contentsOf: blocksByKey[key] ?? [])
    }

    return entries.enumerated().map { index, entry in entry.asNextItem(sortKey: index) }
  }
}

/// One composed Next row, before it's flattened to the `NextItem` wire format.
/// Co-locates the three field mappings (suggestion / task / ritual) that used
/// to be scattered across the watch publisher and `loadNextItems`.
enum NextEntry {
  case suggestion(NextSuggestion)
  case task(id: String, title: String, subtitle: String?, overdue: Bool)
  /// An already-formatted ritual item (chore / habit / supplement) from
  /// `ChecklistMirror.loadNextItems`.
  case ritual(NextItem)

  func asNextItem(sortKey: Int) -> NextItem {
    switch self {
    case .suggestion(let s):
      return NextItem(
        id: s.id,
        kind: "suggestion",
        title: s.emoji.map { "\($0) \(s.title)" } ?? s.title,
        subtitle: s.detail,
        trailing: nil,
        overdue: false,
        sortKey: sortKey)
    case .task(let id, let title, let subtitle, let overdue):
      return NextItem(
        id: id, kind: "task", title: title, subtitle: subtitle,
        trailing: nil, overdue: overdue, sortKey: sortKey)
    case .ritual(let item):
      return NextItem(
        id: item.id, kind: item.kind, title: item.title,
        subtitle: item.subtitle, trailing: item.trailing,
        overdue: item.overdue, sortKey: sortKey)
    }
  }
}
