import SwiftUI
import SwiftData

// A bog-standard SwiftUI navigation dropdown for the Tasks domain — the
// Things-style title menu. It lists every sidebar destination (smart lists,
// areas + their projects, top-level projects) and routes
// via `NavigationState.go(to:)` on tap, so you can jump anywhere WITHOUT the
// sidebar — shown only when the sidebar is hidden or unavailable (compact
// stack on iPhone / narrow iPad, or collapsed via ⌘/ on iPad / macOS — see
// `NavigationState.showsTitleNavMenu(usesPushNavigation:)`). When the sidebar
// is visible, callers render the plain static `ScreenTitle` or omit the
// trailing chevron.
//
// Single-source: destinations come from `StructureCache` (sidebar order via
// `TaskStructureOrder`) and `TaskDestinations.sidebarRoutes`; every label /
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

  /// The destination to draw the checkmark on. Defaults to whatever `nav` is
  /// showing. A host that doesn't drive `nav` names its destination directly
  /// (an AppKit-hosted page whose `NavigationState` stub nothing observes, so
  /// `nav.path` there is always empty). No caller does today: Septask's Next
  /// page, the one such host, was removed on 2026-11-19.
  var current: Route? = nil
  /// Where a pick goes. Defaults to `nav.go(to:)` — the SwiftUI shells' whole
  /// navigation model. The AppKit shell passes a closure that steers its own
  /// sidebar instead, which is what drives its panes.
  var onNavigate: ((Route) -> Void)? = nil
  @ViewBuilder var label: () -> Trigger
  /// Smart lists that hide while empty and currently have rows. Read once per
  /// task change, not per render: iOS builds the `Menu` content on every
  /// body pass, and the read runs five filtered fetches of the whole store.
  @State private var nonEmptyIDs: Set<String> = []

  var body: some View {
    Menu {
      menuContent
    } label: {
      label()
    }
    .onAppear { refreshNonEmptyIDs() }
    .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in
      refreshNonEmptyIDs()
    }
    // Render the label as plain content (the ScreenTitle / chevron the caller
    // passed), not a bezeled macOS menu button, and hide the system caret
    // since the label draws its own chevron.
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .inlineHover()
  }

  private func refreshNonEmptyIDs() {
    let ids = TaskDestinations.nonEmptySmartListIDs(in: modelContext)
    if ids != nonEmptyIDs { nonEmptyIDs = ids }
  }

  // MARK: - Menu content

  // iOS builds this on every body pass, not when the menu opens, so it reads
  // only memoized state (`StructureCache`, `nonEmptyIDs`). Groups are separated by explicit `Divider()`s rather than
  // `Section`s: a `Section` whose leading element is a plain-`Text` button (an
  // emoji area) followed by more rows gets that text promoted to a centered,
  // greyed section header on macOS — so every row stays a uniform, left-aligned
  // button this way.
  @ViewBuilder
  private var menuContent: some View {
    let snapshot = StructureCache.snapshot(in: modelContext)
    let areas = snapshot.areas
    let projects = snapshot.projects
    let topLevel = projects.filter { $0.area == nil && $0.status == .active }

    ForEach(TaskDestinations.sidebarRoutes(in: .top, nonEmptyIDs: nonEmptyIDs), id: \.id) { destButton($0) }

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

    let bottomRoutes = TaskDestinations.sidebarRoutes(in: .bottom, nonEmptyIDs: nonEmptyIDs)
    if !bottomRoutes.isEmpty {
      Divider()
      ForEach(bottomRoutes, id: \.id) { destButton($0) }
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
    let isCurrent = (current ?? nav.path.last)?.sameDestination(as: route) == true
    Toggle(isOn: Binding(get: { isCurrent }, set: { if $0 { navigate(to: route) } })) {
      Label(title ?? route.title, systemImage: route.icon)
    }
  }

  private func navigate(to route: Route) {
    if let onNavigate { onNavigate(route) } else { nav.go(to: route) }
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
