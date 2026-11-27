import SwiftUI

// The Sort By menu (docs/LIST_SORT_SPEC.md §6). One builder for every place
// the menu shows: the View ▸ Sort By slot (`listSortOptions`), the list
// toolbar / "···" menus in SwiftUI, and the AppKit page menu. The choices,
// titles and symbol come from the registry; `ListSortPreferences` stores the
// pick. Changing the sort is a view change and never goes on the undo stack.

enum ListSortMenuNodes {
  /// The five choices, the current one checked. A list that takes no sort
  /// (or no list in front) gets the same five rows disabled, so the View
  /// menu's Sort By stays where the user expects it.
  @MainActor
  static func nodes(for filter: TaskFilter?) -> [RegistryMenuNode] {
    let prefs = ListSortPreferences.shared
    let target = filter.flatMap { ListSort.key(for: $0) != nil ? $0 : nil }
    let current = target.map { prefs.sort(for: $0) }
    return ListSort.options.map { option in
      RegistryMenuEntry.slot(
        id: "listSort.\(option.value)", title: option.title,
        isOn: option.value == current,
        perform: target.map { list in { prefs.setSort(option.value, for: list) } })
    }
  }

  /// The same rows as one "Sort By" submenu, for a list's own menu.
  @MainActor
  static func submenu(for filter: TaskFilter) -> RegistryMenuNode {
    .submenu(id: "sortBy", title: RegistrySurfaces.listSortMenuTitle,
             sfSymbol: RegistrySurfaces.listSortSymbol, children: nodes(for: filter))
  }
}

/// SwiftUI Sort By submenu for a list's toolbar or "···" menu. Renders
/// nothing for a list that takes no sort.
struct ListSortMenu: View {
  let filter: TaskFilter

  var body: some View {
    // Read so the menu follows a pick made on another device or surface.
    let _ = ListSortPreferences.shared.revision
    if ListSort.key(for: filter) != nil {
      RegistryMenuContent(nodes: [ListSortMenuNodes.submenu(for: filter)])
    }
  }
}

/// The header line of a sorted list: "Sorted by When". Nothing for Manual.
/// Sits on the list's leading grid like `ScreenTitle`: the glyph in the
/// checkbox column, the text where the task titles start.
struct ListSortIndicator: View {
  let filter: TaskFilter

  var body: some View {
    if let line = ListSort.indicator(ListSortPreferences.shared.sort(for: filter)) {
      HStack(spacing: Theme.iconTextGap) {
        Image(systemName: RegistrySurfaces.listSortSymbol)
          .frame(width: Theme.checkboxTap, alignment: .center)
          .offset(x: -Theme.checkboxLeadingNudge)
        Text(line)
      }
      .font(.septenaMeta)
      .foregroundStyle(Theme.inkSecondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.leading, TaskCardMetrics.headerLeading)
      .padding(.trailing, TaskCardMetrics.margin)
      .padding(.bottom, 8)
      .accessibilityElement(children: .combine)
    }
  }
}
