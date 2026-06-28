import SwiftUI

// One page scaffold for every Septena surface — the 4 tab landings (Today,
// Next, Tasks, Coach) and (eventually) every section destination. It owns the
// three-slot chrome so a glyph never means two things:
//
//   [ ⚙ global ]            Title            [ ··· page ] [ + add ]
//     LEADING                                 TRAILING cluster
//
//   • global (gear)  — constant on every page; the ONLY chrome path to Settings.
//   • ··· (overflow) — page-local actions only; hidden when empty; never Settings.
//   • + (add)        — adds to *this* context (time-views → Add-Info picker,
//                      domain-views → create that domain's object).
//
// These live in the page's NAVIGATION BAR (its `NavigationStack` toolbar), NOT
// the tab bar. Per Apple's HIG, "tab bars are for moving between major areas of
// the app, not for triggering one-off actions," and iPadOS 26 exposes no API to
// place buttons in the tab bar (its only accessory slot is the bottom shelf,
// `tabViewBottomAccessory`). An earlier attempt to "lift" this chrome into the
// iPad tab bar — via a `.toolbar` on the `TabView`, fed by either a preference
// or a shared object — simply never rendered on iPad. So the chrome is a plain
// navigation-bar toolbar on every platform and size class.
//
// See docs/PAGE_CHROME_SPEC.md.

/// What the page's "+" adds. Time-views log into any section via the Add-Info
/// picker; domain-views run their own create action.
enum PageAdd {
  case addInfo
  case action(() -> Void)
}

enum PageChromeMetrics {
  /// Height reserved at the top of each iPad page so content rests below the
  /// floating chrome bar (gear/switcher/+). Matches the bar's rendered height
  /// (≈60pt circles + 8pt top padding) with a little breathing room.
  static let iPadBarHeight: CGFloat = 74
}

extension SeptenaTab {
  /// The `pageChrome` id each tab writes its chrome under (matches the `id:`
  /// each tab passes to `.pageChrome(...)`). `goals` → "coach".
  var chromeID: String {
    switch self {
    case .week:  return "week"
    case .next:  return "next"
    case .tasks: return "tasks"
    case .goals: return "coach"
    }
  }
}

/// Per-tab "···" rows + "+" that the iPad top-bar overlay renders. On iPad each
/// page writes its entry via `.pageChrome` (instead of nav-bar toolbar items),
/// and `RootTabView`'s overlay reads the current tab's. This is what lets the
/// chrome align to `Theme.pageGutter` (like content) and stay put when the Tasks
/// sidebar opens — the system glass toolbar items are edge-anchored and can't be
/// inset. The gear and switcher are global, drawn by the overlay directly.
@MainActor
@Observable
final class IPadChromeModel {
  struct Entry { var localActions: AnyView?; var add: PageAdd? }
  private var entries: [String: Entry] = [:]
  func set(_ id: String, localActions: AnyView?, add: PageAdd?) {
    entries[id] = Entry(localActions: localActions, add: add)
  }
  func entry(_ id: String) -> Entry? { entries[id] }
}

/// The trailing "+" — same spot on every page. The caller decides what it adds.
struct PageAddButton: View {
  let perform: () -> Void
  var body: some View {
    Button(action: perform) {
      Image(systemName: "plus")
    }
    .accessibilityLabel("Add")
  }
}

/// The section switcher as a centered segmented control — the Calendar pattern.
/// On iPad the `TabView`'s own tab bar is hidden and this rides the navigation
/// bar's `principal` slot, so the switcher sits on ONE row flanked by the gear
/// (leading) and ···/+ (trailing), instead of the tab pill floating on a
/// separate row above the actions. Bound to the shared `TabSelection`, so it
/// drives the same content the (now hidden) tab bar would.
struct TabSwitcher: View {
  @Environment(TabSelection.self) private var tabSelection
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(SectionTheme.self) private var theme
  /// Drives the sliding active-tab bubble between segments.
  @Namespace private var bubble

  private var tasksEnabled: Bool {
    settingsStore.sections.first { $0.key == "tasks" }?.isEnabled ?? true
  }

  private var tabs: [(tab: SeptenaTab, title: String)] {
    var t: [(SeptenaTab, String)] = [(.week, "Today"), (.next, "Next")]
    if tasksEnabled { t.append((.tasks, "Tasks")) }
    t.append((.goals, "Coach"))
    return t
  }

  var body: some View {
    HStack(spacing: 2) {
      ForEach(tabs, id: \.tab) { item in
        let selected = tabSelection.current == item.tab
        Button {
          if !selected { withAnimation(.snappy(duration: 0.28)) { tabSelection.current = item.tab } }
        } label: {
          Text(item.title)
            .font(.body.weight(.semibold))
            .foregroundStyle(selected ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background {
              if selected {
                // The active-tab "bubble": a raised capsule that slides between
                // segments (matchedGeometry), mirroring the system tab bar's
                // selection indicator. Opaque so it reads clearly over the glass
                // bar; the soft shadow lifts it.
                Capsule()
                  .fill(.background)
                  .shadow(color: .black.opacity(0.16), radius: 4, y: 1)
                  .matchedGeometryEffect(id: "activeBubble", in: bubble)
              }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(4)
    // Real Liquid Glass on iOS / thin material on macOS — the same floating
    // capsule the system tab bar used, so the switcher reads as the tab bar it
    // replaces, just on the actions row.
    .glassCapsule()
  }
}

extension View {
  /// Attach the unified three-slot page chrome to this page's navigation bar.
  /// Drop-in replacement for the old `homeToolbar`: it owns the constant gear
  /// (global → Settings), the page-local "···" (hidden when `localActions` is
  /// nil), and the "+" (`add`).
  ///
  /// - Parameters:
  ///   - id: Stable page identity (tab/section key); used for accessibility/debug.
  ///   - title: Page identity for accessibility (content still owns its visible title).
  ///   - localActions: The "···" menu rows. Return nil → no "···" at all.
  ///   - add: What "+" adds. nil → no "+".
  ///   - showsGlobal: Whether to draw the leading gear. Default true. Set false on
  ///     a split-view *detail* whose sidebar column already shows the gear, so the
  ///     two columns don't each draw one (see Tasks).
  ///
  /// The section switcher is NOT here — on iPad it's a screen-centered overlay
  /// (`RootTabView.iPadTabless`) so the Tasks sidebar opening/closing can't shift
  /// it. This modifier only owns the per-page gear / ··· / +.
  func pageChrome(
    id: String,
    title: String,
    localActions: @escaping () -> AnyView? = { nil },
    add: PageAdd? = nil,
    showsGlobal: Bool = true
  ) -> some View {
    modifier(PageChromeModifier(id: id, title: title,
                                localActions: localActions, add: add,
                                showsGlobal: showsGlobal))
  }
}

private struct PageChromeModifier: ViewModifier {
  @Environment(NavigationState.self) private var nav
  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var hSize
  @Environment(IPadChromeModel.self) private var iPadChrome
  #endif

  let id: String
  let title: String
  let localActions: () -> AnyView?
  let add: PageAdd?
  let showsGlobal: Bool

  /// Resolve `PageAdd` to a concrete closure (the Add-Info picker needs `nav`).
  private var addClosure: (() -> Void)? {
    guard let add else { return nil }
    switch add {
    case .addInfo:          return { nav.presentAddInfo() }
    case .action(let run):  return run
    }
  }

  func body(content: Content) -> some View {
    #if os(iOS)
    if hSize == .regular {
      // iPad: chrome is the window-level overlay bar (RootTabView.iPadTabless),
      // not nav-bar toolbar items — so it aligns to the content gutter and the
      // Tasks sidebar can't shift it. Publish this page's "···"/"+" for the
      // overlay to render; draw nothing in the (transparent) nav bar here.
      content
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        // Reserve the floating bar's height here (inside the page's own
        // NavigationStack) so content rests below it; scroll content still
        // scrolls *under* it. A container-level inset wouldn't reach here.
        .safeAreaInset(edge: .top, spacing: 0) {
          Color.clear.frame(height: PageChromeMetrics.iPadBarHeight)
        }
        .onAppear { iPadChrome.set(id, localActions: localActions(), add: add) }
    } else {
      // iPhone: gear/···/+ live in the page's own nav bar (bottom tab bar stays).
      content
        .toolbar { chromeToolbar }
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
    }
    #else
    content.toolbar { chromeToolbar }
    #endif
  }

  @ToolbarContentBuilder
  private var chromeToolbar: some ToolbarContent {
    #if os(iOS)
    if showsGlobal {
      ToolbarItem(placement: .topBarLeading) { overflowMenu }
    }
    if let run = addClosure {
      ToolbarItem(placement: .topBarTrailing) { PageAddButton(perform: run) }
    }
    #else
    if showsGlobal {
      ToolbarItem(placement: .navigation) { overflowMenu }
    }
    if let run = addClosure {
      ToolbarItem(placement: .primaryAction) { PageAddButton(perform: run) }
    }
    #endif
  }

  /// The leading "···" menu: the page's own actions, then Settings (always last).
  private var overflowMenu: some View {
    OverflowMenu {
      if let actions = localActions() {
        actions
        Divider()
      }
      Button { nav.showSettings = true } label: {
        Label("Settings", systemImage: "gearshape")
      }
    }
  }
}
