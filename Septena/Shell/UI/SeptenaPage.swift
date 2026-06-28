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
// Platform handling lives here, in one place, instead of per-tab `onAppear`
// bookkeeping. On iPhone compact and macOS the chrome is a normal toolbar on the
// page's own `NavigationStack`. On iPad regular the tab bar is a top toolbar
// row, so a per-page `NavigationStack` toolbar would land one row *below* it;
// the page therefore publishes its chrome up to `RootTabView` via
// `PageChromeKey` (a SwiftUI preference), and `RootTabView` renders it in the
// `TabView` toolbar at tab-bar height. A preference is recomputed from the live
// view tree every pass, so it **self-clears** when the page leaves — there is no
// manual "clear" step that can race a sibling's "set" and blank the bar.
//
// See docs/PAGE_CHROME_SPEC.md.

/// What the page's "+" adds. Time-views log into any section via the Add-Info
/// picker; domain-views run their own create action.
enum PageAdd {
  case addInfo
  case action(() -> Void)
}

/// Chrome a page publishes to the tab-bar toolbar on iPad regular. Carries the
/// live "···" rows and "+" action; the gear is constant so `RootTabView` draws
/// it unconditionally and it is not carried here. Equatable **by `id` only** so
/// a page re-rendering with unchanged chrome doesn't churn the toolbar (a fresh
/// box with the same `id` compares equal → no `onPreferenceChange` refire). The
/// closures are `@MainActor`; the box is `@unchecked Sendable` solely to satisfy
/// the preference machinery — it is only ever read on the main actor.
@MainActor
final class PageChromeBox: Equatable, @unchecked Sendable {
  let id: String
  let localActions: AnyView?
  let add: (() -> Void)?

  init(id: String, localActions: AnyView?, add: (() -> Void)?) {
    self.id = id
    self.localActions = localActions
    self.add = add
  }

  nonisolated static func == (lhs: PageChromeBox, rhs: PageChromeBox) -> Bool {
    lhs.id == rhs.id
  }
}

struct PageChromeKey: PreferenceKey {
  static let defaultValue: PageChromeBox? = nil
  static func reduce(value: inout PageChromeBox?, nextValue: () -> PageChromeBox?) {
    // Deepest/last published page wins; absence reverts to `nil` (self-clear).
    if let next = nextValue() { value = next }
  }
}

/// The fixed leading "global" slot — identical on every page, the only chrome
/// route to Settings. Supplied by the scaffold, never by the caller, so it
/// can't drift or pick up page-local rows.
struct PageGlobalButton: View {
  @Environment(NavigationState.self) private var nav
  var body: some View {
    Button { nav.showSettings = true } label: {
      Image(systemName: "gearshape")
    }
    .accessibilityLabel("Settings")
  }
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

struct SeptenaPage<Content: View>: View {
  @Environment(NavigationState.self) private var nav
  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var hSize
  #endif

  /// Stable page identity used to diff the hoisted chrome (the tab/section key).
  let id: String
  let title: String
  let localActions: () -> AnyView?
  let add: PageAdd?
  let content: Content

  init(
    id: String,
    title: String,
    localActions: @escaping () -> AnyView? = { nil },
    add: PageAdd? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.id = id
    self.title = title
    self.localActions = localActions
    self.add = add
    self.content = content()
  }

  /// Resolve `PageAdd` to a concrete closure (the Add-Info picker needs `nav`).
  private var addClosure: (() -> Void)? {
    guard let add else { return nil }
    switch add {
    case .addInfo:          return { nav.presentAddInfo() }
    case .action(let run):  return run
    }
  }

  var body: some View {
    #if os(iOS)
    if hSize == .regular {
      // iPad regular: hoist to the TabView toolbar via a self-clearing
      // preference. No local toolbar here — `RootTabView` renders the slots.
      content
        .preference(
          key: PageChromeKey.self,
          value: PageChromeBox(id: id, localActions: localActions(), add: addClosure)
        )
    } else {
      content.toolbar { localToolbar }
    }
    #else
    content.toolbar { localToolbar }
    #endif
  }

  /// The three-slot chrome as a normal toolbar (iPhone compact / macOS).
  @ToolbarContentBuilder
  private var localToolbar: some ToolbarContent {
    #if os(iOS)
    ToolbarItem(placement: .topBarLeading) { PageGlobalButton() }
    if let actions = localActions() {
      ToolbarItem(placement: .topBarTrailing) { OverflowMenu { actions } }
    }
    if let run = addClosure {
      ToolbarItem(placement: .topBarTrailing) { PageAddButton(perform: run) }
    }
    #else
    ToolbarItem(placement: .navigation) { PageGlobalButton() }
    if let actions = localActions() {
      ToolbarItem(placement: .primaryAction) { OverflowMenu { actions } }
    }
    if let run = addClosure {
      ToolbarItem(placement: .primaryAction) { PageAddButton(perform: run) }
    }
    #endif
  }
}
