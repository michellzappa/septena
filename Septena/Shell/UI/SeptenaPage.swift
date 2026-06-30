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
  struct Entry {
    var localActions: AnyView?
    var add: PageAdd?
    /// When false the overlay hides the "···" control entirely (Tasks subpages).
    var showsOverflowMenu: Bool = true
  }
  private var entries: [String: Entry] = [:]
  /// Per-tab navigation depth — true when the tab's stack is at its root.
  /// `RootTabView` hides the window-level chrome overlay when false.
  private var atRootByID: [String: Bool] = [:]

  func set(_ id: String, localActions: AnyView?, add: PageAdd?,
           showsOverflowMenu: Bool = true) {
    entries[id] = Entry(localActions: localActions, add: add,
                        showsOverflowMenu: showsOverflowMenu)
  }
  func entry(_ id: String) -> Entry? { entries[id] }

  func setAtRoot(_ id: String, atRoot: Bool) { atRootByID[id] = atRoot }
  /// Defaults true so tabs that haven't reported yet keep the overlay visible.
  func atRoot(for id: String) -> Bool { atRootByID[id] ?? true }
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
    #if os(iOS)
    // iOS 26 Liquid Glass segmented bar: one `GlassEffectContainer` + track
    // `.glassEffect`, per-segment `glassEffectID` for morphing, and a tinted
    // underlay (not an opaque fill) for the sliding selection.
    GlassEffectContainer {
      segmentButtons
        .padding(4)
        .glassSegmentTrack()
    }
    #else
    segmentButtons
      .padding(4)
      .glassSegmentTrack()
    #endif
  }

  private var segmentButtons: some View {
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
            .glassSegmentSelectionUnderlay(isSelected: selected, tint: theme.accent, in: bubble)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .glassEffectID(item.tab, in: bubble)
        #endif
      }
    }
  }
}

// MARK: - Tab scroll insets (top chrome + wide horizontal)

private struct TabScrollContentWidthKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = nextValue()
  }
}

/// One `contentMargins(.all, EdgeInsets, for: .scrollContent)` call for the
/// home-tab scroll surfaces. Apple documents that multiple `.scrollContent`
/// margin modifiers override each other — separate top vs horizontal calls
/// were wiping each other out, and `.frame(maxWidth:)` doesn't inset `List`
/// content. See `contentMargins(_:_:for:)` EdgeInsets overload.
private struct TabScrollContentInsetsModifier: ViewModifier {
  @Environment(\.usesPushNavigation) private var usesPushNavigation
  let top: CGFloat
  let contentGutter: CGFloat
  @State private var containerWidth: CGFloat = 0

  private var appliesWideHorizontal: Bool {
    #if os(macOS)
    true
    #else
    usesPushNavigation
    #endif
  }

  private var scrollInsets: EdgeInsets {
    let horizontal: CGFloat
    if appliesWideHorizontal, containerWidth > 0 {
      horizontal = WideContentMetrics.horizontalContentMargin(
        containerWidth: containerWidth, contentGutter: contentGutter)
    } else {
      horizontal = 0
    }
    let topInset = appliesWideHorizontal ? top : 0
    return EdgeInsets(top: topInset, leading: horizontal, bottom: 0, trailing: horizontal)
  }

  func body(content: Content) -> some View {
    if appliesWideHorizontal || top > 0 {
      content
        .background {
          GeometryReader { geo in
            Color.clear.preference(key: TabScrollContentWidthKey.self,
                                   value: geo.size.width)
          }
        }
        .onPreferenceChange(TabScrollContentWidthKey.self) { width in
          guard width > 0, abs(containerWidth - width) > 0.5 else { return }
          containerWidth = width
        }
        .contentMargins(.all, scrollInsets, for: .scrollContent)
    } else {
      content
    }
  }
}

extension View {
  /// Top chrome + wide horizontal breathing room on the scroll view / list itself.
  /// Pass `contentGutter` when rows already carry an outer margin (Tasks cards).
  func septenaTabScrollInsets(top: CGFloat, contentGutter: CGFloat = 0) -> some View {
    modifier(TabScrollContentInsetsModifier(top: top, contentGutter: contentGutter))
  }

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
    showsGlobal: Bool = true,
    scrollTopInset: CGFloat? = nil,
    wideContentGutter: CGFloat = 0
  ) -> some View {
    modifier(PageChromeModifier(id: id, title: title,
                                localActions: localActions, add: add,
                                showsGlobal: showsGlobal,
                                scrollTopInset: scrollTopInset,
                                wideContentGutter: wideContentGutter))
  }

  /// Standard treatment for a top-level tab page's scroll view: nav title,
  /// scroll surface, soft top edge, and the unified chrome (`.pageChrome`, which
  /// also reserves the iPad bar inset via contentMargins). Apply to the page's
  /// OWN List/ScrollView so the scroll modifiers land on it. Page-specific bits
  /// (Today's sky background, Next's list selection) stay on the page.
  func septenaTabPage(
    id: String, title: String,
    localActions: @escaping () -> AnyView? = { nil },
    add: PageAdd? = nil,
    showsGlobal: Bool = true,
    scrollTopInset: CGFloat? = nil,
    wideContentGutter: CGFloat = 0
  ) -> some View {
    self
      .scrollContentBackground(.hidden)
      .homeTabScrollSurface()
      .scrollEdgeEffectStyle(.soft, for: .top)
      .navigationTitle("")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .pageChrome(id: id, title: title, localActions: localActions,
                  add: add, showsGlobal: showsGlobal,
                  scrollTopInset: scrollTopInset,
                  wideContentGutter: wideContentGutter)
  }

  /// iPad floating-bar top inset for scroll surfaces that don't publish chrome
  /// themselves (e.g. Tasks split detail). Prefer `.septenaTabScrollInsets` when
  /// both top and wide horizontal margins are needed.
  func septenaTabInset(ownTopPadding: CGFloat = 0) -> some View {
    #if os(iOS)
    septenaTabScrollInsets(
      top: max(0, PageChromeMetrics.iPadBarHeight - ownTopPadding))
    #else
    self
    #endif
  }

  /// Reports whether this tab is at its navigation root so `RootTabView` can
  /// hide the window-level chrome overlay when a section/detail is pushed.
  /// No-op off iOS.
  func iPadReportsNavDepth(id: String, atRoot: Bool) -> some View {
    #if os(iOS)
    modifier(IPadNavDepthReporter(tabID: id, atRoot: atRoot))
    #else
    self
    #endif
  }
}

#if os(iOS)
private struct IPadNavDepthReporter: ViewModifier {
  @Environment(\.usesPushNavigation) private var usesPushNavigation
  @Environment(IPadChromeModel.self) private var iPadChrome
  let tabID: String
  let atRoot: Bool

  func body(content: Content) -> some View {
    content
      .onChange(of: atRoot, initial: true) { _, root in
        guard usesPushNavigation else { return }
        iPadChrome.setAtRoot(tabID, atRoot: root)
      }
  }
}
#endif

private struct PageChromeModifier: ViewModifier {
  @Environment(NavigationState.self) private var nav
  #if os(iOS)
  @Environment(\.usesPushNavigation) private var usesPushNavigation
  @Environment(IPadChromeModel.self) private var iPadChrome
  #endif

  let id: String
  let title: String
  let localActions: () -> AnyView?
  let add: PageAdd?
  let showsGlobal: Bool
  let scrollTopInset: CGFloat?
  let wideContentGutter: CGFloat

  /// Resolve `PageAdd` to a concrete closure (the Add-Info picker needs `nav`).
  private var addClosure: (() -> Void)? {
    guard let add else { return nil }
    switch add {
    case .addInfo:          return { nav.presentAddInfo() }
    case .action(let run):  return run
    }
  }

  #if os(iOS)
  /// Tasks "···" (New Area / Project) vs detail surfaces — see `NavigationState`.
  private var tasksShowsIndexOverflow: Bool {
    id == "tasks" && nav.tasksShowsIndexOverflow(usesPushNavigation: usesPushNavigation)
  }

  private func publishIPadChrome() {
    let showOverflow = id != "tasks" || tasksShowsIndexOverflow
    iPadChrome.set(
      id,
      localActions: showOverflow ? localActions() : nil,
      add: add,
      showsOverflowMenu: showOverflow
    )
  }
  #endif

  func body(content: Content) -> some View {
    #if os(iOS)
    // `usesPushNavigation` (resolved once at the app root), NOT the local
    // `hSize`: inside the Tasks SIDEBAR column the size class is `.compact`
    // (narrow column), which would wrongly route its chrome to the nav bar
    // instead of the window overlay. `usesPushNavigation` is true on iPad
    // regular regardless of column width.
    if usesPushNavigation {
      // iPad: chrome is the window-level overlay bar (RootTabView.iPadTabless),
      // not nav-bar toolbar items — so it aligns to the content gutter and the
      // Tasks sidebar can't shift it. Publish this page's "···"/"+" for the
      // overlay to render; draw nothing in the (transparent) nav bar here.
      content
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .septenaTabScrollInsets(
          top: scrollTopInset ?? PageChromeMetrics.iPadBarHeight,
          contentGutter: wideContentGutter)
        .onAppear { publishIPadChrome() }
        .onChange(of: nav.path.last?.id) { _, _ in publishIPadChrome() }
    } else {
      // iPhone: ···/+ live in the page's own nav bar (bottom tab bar stays).
      content
        .toolbar { chromeToolbar }
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
    }
    #else
    content
      .toolbar { chromeToolbar }
      .septenaTabScrollInsets(top: 0, contentGutter: wideContentGutter)
    #endif
  }

  @ToolbarContentBuilder
  private var chromeToolbar: some ToolbarContent {
    #if os(iOS)
    if showsGlobal || id == "tasks" {
      ToolbarItem(placement: .topBarLeading) { iosLeadingChrome }
    }
    if let run = addClosure {
      ToolbarItem(placement: .topBarTrailing) { PageAddButton(perform: run) }
    }
    #else
    if id == "tasks" {
      ToolbarItem(placement: .navigation) { macTasksLeadingChrome }
    } else if showsGlobal {
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

  /// iPhone Tasks: Quick Find beside "···" on the index; search-only on subpages.
  /// Other tabs: overflow menu only.
  #if os(iOS)
  @ViewBuilder
  private var iosLeadingChrome: some View {
    if id == "tasks" {
      HStack(spacing: 16) {
        QuickFindToolbarButton()
        if tasksShowsIndexOverflow {
          overflowMenu
        }
      }
    } else if showsGlobal {
      overflowMenu
    }
  }
  #endif

  #if os(macOS)
  /// macOS Tasks: sidebar publishes "···" only; detail adds Quick Find beside
  /// Settings (or beside index "···" when `localActions` is set).
  @ViewBuilder
  private var macTasksLeadingChrome: some View {
    HStack(spacing: 12) {
      if localActions() == nil {
        QuickFindToolbarButton()
          .help("Quick Find (⌘K)")
      }
      if localActions() != nil {
        overflowMenu
      } else if showsGlobal {
        overflowMenu
      }
    }
  }
  #endif
}
