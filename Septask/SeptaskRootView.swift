import SwiftUI

/// Septask's root: the shared `ContentView` (single-stack on iPhone, split
/// view on iPad/Mac) plus a Septask-only bottom tab bar on compact width.
/// Composition only — the bar drives the SAME single `NavigationState` path
/// the stack renders, so every shared behavior (flat-app replace semantics,
/// ⌘N inline create, project drill-in pushes) keeps working unchanged. A
/// native `TabView` with per-tab stacks would fork that one path; this
/// deliberately doesn't.
struct SeptaskRootView: View {
  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var hSize
  #endif

  var body: some View {
    #if os(iOS)
    if hSize == .compact {
      ContentView()
        .safeAreaInset(edge: .bottom, spacing: 0) { SeptaskTabBar() }
    } else {
      ContentView()
    }
    #else
    ContentView()
    #endif
  }
}

#if os(iOS)
/// iPhone bottom bar: Inbox / Today / Upcoming / Browse. Reuses the
/// segmented-glass language of the full app's TabSwitcher (PlatformShims'
/// `glassSegmentTrack` / selection underlay) so the chrome reads native to
/// the family. The smart lists replace the path (the app is conceptually
/// flat); Browse pops to the sidebar root and stays highlighted for
/// everything reached from it (areas, projects).
private struct SeptaskTabBar: View {
  @Environment(NavigationState.self) private var nav
  @Environment(SectionTheme.self) private var theme
  @Namespace private var bubble

  private var tabs: [(route: Route?, title: String, icon: String)] {
    [(Route.filter(.triage),   String(localized: "Inbox"),    "tray.full"),
     (Route.filter(.today),    String(localized: "Today"),    "sun.max.fill"),
     (Route.filter(.upcoming), String(localized: "Upcoming"), "calendar"),
     (nil,                     String(localized: "Browse"),   "list.bullet")]
  }

  private func isSelected(_ route: Route?) -> Bool {
    guard let route else {
      // Browse owns the sidebar root and everything reached from it.
      switch nav.path.last {
      case nil, .project, .area: return true
      default: return false
      }
    }
    return nav.path.last?.sameDestination(as: route) ?? false
  }

  var body: some View {
    GlassEffectContainer {
      HStack(spacing: 2) {
        ForEach(tabs, id: \.title) { tab in
          let selected = isSelected(tab.route)
          Button {
            if let route = tab.route {
              nav.go(to: route)
            } else if !nav.path.isEmpty {
              Haptics.tap()
              nav.path = []
            }
          } label: {
            VStack(spacing: 2) {
              Image(systemName: tab.icon)
                .font(.system(size: 17, weight: .semibold))
              Text(tab.title)
                .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(selected ? AnyShapeStyle(theme.accent)
                                      : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .glassSegmentSelectionUnderlay(isSelected: selected,
                                           tint: theme.accent, in: bubble)
            .contentShape(Capsule())
          }
          .buttonStyle(.plain)
          .glassEffectID(tab.title, in: bubble)
          .accessibilityLabel(tab.title)
          .accessibilityAddTraits(selected ? .isSelected : [])
        }
      }
      .padding(4)
      .glassSegmentTrack()
    }
    .padding(.horizontal, 24)
    .padding(.bottom, 6)
  }
}
#endif
