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
// Find (⌘⇧F); this stays a pure *jump* affordance, so a `Menu` is enough.

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
      ForEach(topLevel) { destButton(.project(id: $0.id), title: $0.title) }
    }

    ForEach(areas) { area in
      let areaProjects = projects.filter { $0.area == area.id && $0.status == .active }
      Divider()
      destButton(.area(id: area.id), title: area.title)
      ForEach(areaProjects) { destButton(.project(id: $0.id), title: $0.title) }
    }

    if !LocalCache.tasks(in: modelContext, filter: .recentlyDeleted).isEmpty {
      Divider()
      destButton(.filter(.recentlyDeleted))
    }
  }

  /// One navigable row. Rendered as a `Toggle` (not a `Button`) so the current
  /// route keeps its own glyph AND gains a checkmark *next to* it: a menu
  /// `Toggle` draws the native selection checkmark in the leading state column,
  /// which coexists with the `Label`'s icon — where a `Button` + `Label` can
  /// only show a checkmark by giving up the icon slot for it. The binding is
  /// navigation, not real two-way state: flipping a row on navigates there;
  /// re-selecting the current (already-on) row is a no-op.
  ///
  /// Every row's label is a `Label(title, systemImage:)` — same structure
  /// throughout, on purpose. Areas use their `folder` SF Symbol here rather than
  /// their user emoji: an emoji has to ride in the title `Text` (SF Symbols
  /// can't render one), but a bare-`Text` row directly followed by `Label` rows
  /// gets promoted to a centered group header by the macOS menu. Uniform
  /// `Label`s keep every destination a normal, left-aligned item. (The sidebar
  /// still shows emoji.)
  @ViewBuilder
  private func destButton(_ route: Route, title: String? = nil) -> some View {
    let isCurrent = nav.path.last?.sameDestination(as: route) == true
    Toggle(isOn: Binding(get: { isCurrent }, set: { if $0 { nav.go(to: route) } })) {
      Label(title ?? route.title, systemImage: route.icon)
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
    //
    // Shares the list's leading grid: the icon rides the same `checkboxTap`
    // column (parked at `headerLeading`, nudged like every row checkbox and
    // section-header glyph) and the title lands one `iconTextGap` past it, so
    // the sun/inbox/emoji/checkbox stack under one X and Today/Inbox/area
    // titles under another.
    HStack(spacing: Theme.iconTextGap) {
      Image(systemName: icon)
        .font(.title2)
        .foregroundStyle(iconTint)
        .frame(width: Theme.checkboxTap, alignment: .center)
        .offset(x: -Theme.checkboxLeadingNudge)
      HStack(spacing: 6) {
        Text(title)
          .font(.septenaScreenTitle)
          .foregroundStyle(.primary)
        Image(systemName: "chevron.down")
          .font(.headline.weight(.semibold))
          .foregroundStyle(.secondary)
      }
    }
    .padding(.leading, TaskCardMetrics.headerLeading)
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
