import SwiftUI

// Shared "home-landing" chrome for the top-level dashboard tabs
// (Week / Next / Coach). Every landing shows the same top-left "…" menu —
// same glyph, same placement, same Settings row — so the tab peers read as
// one family and the structure lives in exactly one place. Tabs inject their
// own rows above the shared Settings item (Week adds the dashboard-layout
// switcher + Insights); tabs with nothing extra get just Settings.
//
// Tasks is the deliberate exception: it keeps its sidebar, so it doesn't adopt
// the `homeChrome` modifier — but its phone "…" menu still reuses `HomeMenu`
// (see SidebarView.phoneMoreMenu) so the glyph stays in the family.
//
// On iPad regular width the tab bar is a top toolbar row — per-tab
// `NavigationStack` toolbars land one row *below* it. `HomeToolbarExtras`
// lifts the menu (and tab-specific trailing actions like Tasks "+") to
// `RootTabView`'s `TabView` toolbar so chrome sits in the tab-bar band.

/// Tab-specific rows for the shared home "…" menu while a tab is visible.
/// `RootTabView` reads `content` from the TabView toolbar on iPad regular;
/// each home tab registers on appear and clears on disappear.
@Observable
@MainActor
final class HomeToolbarExtras {
  private(set) var content: AnyView = AnyView(EmptyView())
  private(set) var trailingContent: AnyView = AnyView(EmptyView())
  private(set) var hasTrailing = false

  func setContent(@ViewBuilder _ builder: () -> some View) {
    content = AnyView(builder())
  }

  func clearContent() {
    content = AnyView(EmptyView())
  }

  func setTrailing(@ViewBuilder _ builder: () -> some View) {
    trailingContent = AnyView(builder())
    hasTrailing = true
  }

  func clearTrailing() {
    trailingContent = AnyView(EmptyView())
    hasTrailing = false
  }
}

/// The standard toolbar overflow ("…") menu. Owns the glyph and the "More"
/// accessibility label so every overflow menu across the app reads the same and
/// the glyph lives in exactly one place. `systemImage` only varies for menus
/// that show a transient state in the slot (e.g. an hourglass while busy).
struct OverflowMenu<Content: View>: View {
  private let systemImage: String
  private let content: Content

  init(systemImage: String = "ellipsis", @ViewBuilder content: () -> Content) {
    self.systemImage = systemImage
    self.content = content()
  }

  var body: some View {
    Menu {
      content
    } label: {
      // Bare glyph (not `ellipsis.circle`) so it sits on the system's glass
      // toolbar circle without doubling the ring on iOS 26.
      Image(systemName: systemImage)
    }
    .accessibilityLabel("More")
  }
}

/// The top-left "…" menu for the home tabs. `extra` renders above the shared
/// Settings row, so a caller stacks its own rows (plus any `Divider`) on top.
struct HomeMenu<Extra: View>: View {
  @Environment(NavigationState.self) private var nav
  private let extra: Extra

  init(@ViewBuilder extra: () -> Extra) { self.extra = extra() }

  var body: some View {
    OverflowMenu {
      extra
      Button { nav.showSettings = true } label: {
        Label("Settings", systemImage: "gearshape")
      }
    }
  }
}

extension View {
  /// Attaches the shared home-landing chrome — the top-left "…" menu — to a
  /// tab's content inside its `NavigationStack`. `extra` injects tab-specific
  /// rows above the shared Settings item. One choke point so the glyph,
  /// placement, and Settings row can't drift between Week / Next / Coach.
  func homeChrome<Extra: View>(@ViewBuilder extra: @escaping () -> Extra) -> some View {
    toolbar {
      #if os(iOS)
      ToolbarItem(placement: .topBarLeading) { HomeMenu(extra: extra) }
      #else
      ToolbarItem(placement: .primaryAction) { HomeMenu(extra: extra) }
      #endif
    }
  }

  /// Home chrome with no tab-specific rows — just the "…" → Settings menu.
  func homeChrome() -> some View {
    homeChrome { EmptyView() }
  }

  /// Home "…" menu with tab-specific rows. iPad regular registers `extra` with
  /// `HomeToolbarExtras` so `RootTabView` can render the menu in the TabView
  /// toolbar (tab-bar height). iPhone compact and macOS keep `homeChrome`.
  func homeToolbar<Extra: View>(@ViewBuilder extra: @escaping () -> Extra) -> some View {
    modifier(HomeToolbarModifier(extra: extra))
  }

  func homeToolbar() -> some View {
    homeToolbar { EmptyView() }
  }

  /// Tab-specific trailing toolbar (e.g. Tasks "+"). iPad regular registers
  /// with `HomeToolbarExtras` so `RootTabView` renders it at tab-bar height.
  func homeToolbarTrailing<Trailing: View>(
    when show: Bool = true,
    @ViewBuilder trailing: @escaping () -> Trailing
  ) -> some View {
    modifier(HomeToolbarTrailingModifier(show: show, trailing: trailing))
  }
}

private struct HomeToolbarModifier<Extra: View>: ViewModifier {
  @Environment(\.horizontalSizeClass) private var hSize
  @Environment(HomeToolbarExtras.self) private var homeToolbarExtras
  @ViewBuilder let extra: () -> Extra

  func body(content: Content) -> some View {
    #if os(iOS)
    if hSize == .regular {
      content
        .onAppear { homeToolbarExtras.setContent(extra) }
        .onDisappear { homeToolbarExtras.clearContent() }
    } else {
      content.homeChrome(extra: extra)
    }
    #else
    content.homeChrome(extra: extra)
    #endif
  }
}

private struct HomeToolbarTrailingModifier<Trailing: View>: ViewModifier {
  @Environment(\.horizontalSizeClass) private var hSize
  @Environment(HomeToolbarExtras.self) private var homeToolbarExtras
  let show: Bool
  @ViewBuilder let trailing: () -> Trailing

  func body(content: Content) -> some View {
    #if os(iOS)
    if hSize == .regular {
      content
        .onAppear { syncTrailing() }
        .onDisappear { homeToolbarExtras.clearTrailing() }
        .onChange(of: show) { _, _ in syncTrailing() }
    } else {
      content
    }
    #else
    content
    #endif
  }

  private func syncTrailing() {
    if show { homeToolbarExtras.setTrailing(trailing) }
    else { homeToolbarExtras.clearTrailing() }
  }
}
