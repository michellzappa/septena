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
}
