import SwiftUI
import SwiftData

// A bog-standard SwiftUI navigation dropdown for the Tasks domain — the
// Things-style title menu. It lists every sidebar destination (smart lists,
// areas + their projects, top-level projects, Recently Deleted) and routes
// via `NavigationState.go(to:)` on tap, so you can jump anywhere WITHOUT the
// sidebar — collapsed via ⌘/ on macOS, and only a back-tap away on iPhone.
//
// Single-source: destinations come from `TaskDestinations` (the same smart-list
// set and persisted area/project order the sidebar uses), and every label /
// icon / selection check reads off `Route`, so the menu can never disagree
// with the sidebar about what's navigable, in what order, or what's current.
//
// Pure native `Menu` + `Button`s (no popover, no custom focus handling) per
// the "use default SwiftUI, never get creative" rule. Search lives in Quick
// Find (⌘K); this stays a pure *jump* affordance, so a `Menu` is enough.

/// The destination dropdown. The caller supplies the `label` (the visible
/// trigger): the smart-list screens pass a `ScreenTitle`-shaped label, while
/// project / area detail pass a bare chevron so their inline-editable title
/// keeps working untouched.
struct TaskNavMenu<Trigger: View>: View {
  @Environment(NavigationState.self) private var nav
  @Environment(\.modelContext) private var modelContext

  @ViewBuilder var label: () -> Trigger

  var body: some View {
    Menu {
      menuContent
    } label: {
      label()
    }
    // Render the label as plain content (the ScreenTitle / chevron the caller
    // passed), not a bezeled macOS menu button, and hide the system caret
    // since the label draws its own chevron.
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .inlineHover()
  }

  // MARK: - Menu content

  // Built lazily when the menu opens, so the per-render title never pays for a
  // structure read. Groups are separated by explicit `Divider()`s rather than
  // `Section`s: a `Section` whose leading element is a plain-`Text` button (an
  // emoji area) followed by more rows gets that text promoted to a centered,
  // greyed section header on macOS — so every row stays a uniform, left-aligned
  // button this way.
  @ViewBuilder
  private var menuContent: some View {
    let snapshot = StructureCache.snapshot(in: modelContext)
    let areas = TaskDestinations.orderedAreas(snapshot.areas)
    let projects = TaskDestinations.orderedProjects(snapshot.projects)
    let topLevel = projects.filter { $0.area == nil && $0.status == .active }

    ForEach(TaskDestinations.smartListRoutes, id: \.id) { destButton($0) }

    if !topLevel.isEmpty {
      Divider()
      ForEach(topLevel) { destButton(.project($0)) }
    }

    ForEach(areas) { area in
      let areaProjects = projects.filter { $0.area == area.id && $0.status == .active }
      Divider()
      destButton(.area(area))
      ForEach(areaProjects) { destButton(.project($0)) }
    }

    if !LocalCache.tasks(in: modelContext, filter: .recentlyDeleted).isEmpty {
      Divider()
      destButton(.filter(.recentlyDeleted))
    }
  }

  /// One navigable row. The current route shows a leading checkmark in place
  /// of its glyph (the standard "selected item" menu cue).
  ///
  /// Every row is a `Label(title, systemImage:)` — same structure throughout,
  /// on purpose. Areas use their `folder` SF Symbol here rather than their user
  /// emoji: an emoji has to ride in the title `Text` (SF Symbols can't render
  /// one), but a bare-`Text` row directly followed by `Label` rows gets promoted
  /// to a centered group header by the macOS menu. Uniform `Label`s keep every
  /// destination a normal, left-aligned item. (The sidebar still shows emoji.)
  @ViewBuilder
  private func destButton(_ route: Route) -> some View {
    let isCurrent = nav.path.last?.sameDestination(as: route) == true
    Button {
      nav.go(to: route)
    } label: {
      Label(route.title, systemImage: isCurrent ? "checkmark" : route.icon)
    }
  }
}

// MARK: - Title-shaped label

/// The smart-list screens' menu trigger: the existing `ScreenTitle` look
/// (icon + large title) plus a trailing chevron so it reads as a dropdown.
struct ScreenTitleMenuLabel: View {
  let icon: String
  let iconTint: Color
  let title: String

  var body: some View {
    // Intrinsic width (no `maxWidth: .infinity`) so the menu it triggers
    // anchors to the title, not the full row width — the row fills the rest
    // via a trailing Spacer at the call site.
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.title2)
        .foregroundStyle(iconTint)
      HStack(spacing: 6) {
        Text(title)
          .font(.septenaScreenTitle)
          .foregroundStyle(.primary)
        Image(systemName: "chevron.down")
          .font(.headline.weight(.semibold))
          .foregroundStyle(.secondary)
      }
    }
    .padding(.leading, Theme.hPadding)
    .padding(.top, 12)
    .padding(.bottom, 18)
    .contentShape(Rectangle())
  }
}

/// The project / area detail menu trigger: a discreet chevron that sits beside
/// the inline-editable title, so renaming still works and the dropdown is a
/// separate tap target.
struct NavMenuChevron: View {
  var body: some View {
    Image(systemName: "chevron.down")
      .font(.headline.weight(.semibold))
      .foregroundStyle(.secondary)
      .frame(width: 28, height: 28)
      .contentShape(Rectangle())
      .inlineHover(cornerRadius: 8)
      .accessibilityLabel("Go to list")
  }
}
