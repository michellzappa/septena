import SwiftUI

// Top-level shell for Septena — three peer tabs, each a self-contained
// module. Week is the synthesizing dashboard, Next is the merged daily
// checklist, Tasks is the existing iOS task app embedded verbatim.
// Septena-app's `ContentView` (sidebar + task list) lives inside the Tasks
// tab unchanged so we can iterate on the new tabs without breaking the
// daily-driver UX.

enum SeptenaTab: Hashable {
  case week, next, tasks, goals

  /// Stable, low-cardinality screen name for telemetry. Kept here so the
  /// dashboard's labels match the enum even if the tab's display title
  /// changes.
  var analyticsName: String {
    switch self {
    case .week:  return "week"
    case .next:  return "next"
    case .tasks: return "tasks"
    case .goals: return "goals"
    }
  }
}

// Shared selection so tiles deep inside the Week dashboard can switch tabs
// (e.g. Tasks tile → Tasks tab). Injected via .environment on the TabView.
@Observable final class TabSelection {
  var current: SeptenaTab = .week
}

struct RootTabView: View {
  @Environment(NavigationState.self) private var nav
  @Environment(SectionTheme.self) private var theme
  // Tasks is the one tab gated on section enabled-state. `SettingsStore` is
  // `@Observable`; reading `sections` in `body` re-renders the bar live when
  // the user toggles the Tasks section in Settings. Week, Next, and Coach are
  // always present — Week/Next are aggregate surfaces with no 1:1 section, and
  // Coach is left always-on deliberately: the `goals` section is an
  // `.appFunction` whose only Enabled toggle is reached *through* the Coach
  // tab, so gating the tab on it would strand the user with no way back.
  @Environment(SettingsStore.self) private var settingsStore
  // Gates the in-flight training pill below the tab bar. Read here (not
  // just inside the accessory) so the `.tabViewBottomAccessory` modifier
  // is attached only mid-workout — an empty accessory content still draws
  // a blank bar, so the bar has to be absent, not just empty.
  @Environment(TrainingDraftStore.self) private var draftStore
  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var hSize
  #endif
  #if os(macOS)
  @Environment(\.openWindow) private var openWindow
  #endif
  @State private var tabSelection = TabSelection()
  #if os(iOS)
  @State private var homeToolbarExtras = HomeToolbarExtras()
  // Chrome hoisted from the current `SeptenaPage` (iPad regular). Nil for tabs
  // still on the legacy `homeToolbar`/`HomeToolbarExtras` path. Self-clears when
  // the page leaves the tree (preference reverts to its nil default).
  @State private var hoistedChrome: PageChromeBox?
  #endif

  // "What's New" gate. We show the sheet once when the app's marketing version
  // climbs past the last release the user saw — but never on a fresh install
  // (empty marker → adopt the current version silently; the welcome covers
  // first run) and never until the welcome is done.
  @AppStorage(SettingsKey.welcomeCompleted) private var welcomeCompleted = false
  @AppStorage(SettingsKey.lastSeenChangelogVersion) private var lastSeenChangelog = ""
  @State private var showWhatsNew = false

  // Default to shown when a section row hasn't loaded yet, so a tab never
  // flickers out during launch. Keyed by the manifest `key`, not the tab enum.
  private var tasksEnabled: Bool {
    settingsStore.sections.first { $0.key == "tasks" }?.isEnabled ?? true
  }

  var body: some View {
    @Bindable var nav = nav
    rootTabView
      // If the user disables Tasks while sitting on its tab, that tab vanishes
      // from the bar — fall the selection back to Week so we never sit on a tag
      // with no matching tab. Week/Next/Coach are always present.
      .onChange(of: tasksEnabled) { _, on in
        if !on, tabSelection.current == .tasks { tabSelection.current = .week }
      }
      .tint(theme.accent)
      // Resolve the push-vs-sheet rule once, here at the shell root, and
      // publish it to every tab via `\.usesPushNavigation`. The Week
      // dashboard, Coach tab, and section-drawer inspector all read that one
      // value instead of each recomputing from the size class.
      .resolvesAdaptiveNavigation()
      .environment(tabSelection)
      // Anonymous aggregate telemetry — one event when the user lands on
      // a tab. `.task(id:)` re-runs only when the value changes and is
      // cancelled on disappear, so back-nav within a tab doesn't double
      // count. The actor is fire-and-forget; this never blocks UI.
      .task(id: tabSelection.current) {
        await TelemetryClient.shared.track(screen: tabSelection.current.analyticsName)
      }
      // App-global Settings. Lives at the TabView level so the top-left
      // "…" menu on every home view opens it, and so the sidebar row in
      // Tasks does too. On iOS it's a sheet; on macOS the same `showSettings`
      // flag opens the dedicated `"settings"` Window (declared in App.swift)
      // so the surface carries real traffic lights and closes like a window.
      #if os(iOS)
      // Forward the optional deep-link target so a contextual entry point
      // (e.g. a home "…" menu's "Next Settings" row) can open Settings already
      // pushed to its pane — matching the macOS window path below. Cleared on
      // dismiss so the next plain open lands on the root.
      .sheet(isPresented: $nav.showSettings, onDismiss: { nav.settingsDestination = nil }) {
        SettingsView(initialDestination: nav.settingsDestination)
      }
      #else
      .onChange(of: nav.showSettings) { _, open in
        guard open else { return }
        openWindow(id: "settings")
        nav.showSettings = false
      }
      #endif
      // Every app-global modal — Quick Find, Add Info, the Quick-Action section
      // sheet, the Training logger, the Mood check-in, the keyboard cheat-sheet
      // — routes through one `presentedModal` + this single `.sheet(item:)`,
      // so each surface works regardless of the selected tab without its own
      // boolean + onChange/onDismiss cleanup. Sizing is the shared
      // `septenaModalSheet` (iOS detents / macOS frame). (Insights destination
      // removed — Correlations now hosts its grids inline.)
      .sheet(item: $nav.presentedModal) { modal in
        modalSheet(modal)
      }
      // Home Screen Quick Action routing. Mounted at the tab-root so it
      // fires regardless of which tab is selected — ContentView (the
      // previous host) is only mounted while the Tasks tab is visible.
      // We deliberately do NOT switch tabs; the sheet covers the current
      // tab and dismissing returns the user there.
      .onChange(of: nav.pendingShortcut) { _, action in
        guard let action else { return }
        switch action {
        case .openSection(let key):
          nav.presentSection(key: key)
        }
        nav.pendingShortcut = nil
      }
      // Deep-link tab switch (e.g. the Next widget's `septena://next`).
      .onChange(of: nav.pendingTab) { _, tab in
        guard let tab else { return }
        tabSelection.current = tab
        nav.pendingTab = nil
      }
      // "What's New" after an update — see the gate notes on `showWhatsNew`.
      .task(id: welcomeCompleted) {
        guard welcomeCompleted, let latest = Changelog.latestReleased?.version else { return }
        if lastSeenChangelog.isEmpty {
          lastSeenChangelog = latest            // fresh install: adopt silently
        } else if !Changelog.unseen(since: lastSeenChangelog).isEmpty {
          showWhatsNew = true
        }
      }
      .sheet(isPresented: $showWhatsNew, onDismiss: {
        if let latest = Changelog.latestReleased?.version { lastSeenChangelog = latest }
      }) {
        WhatsNewSheet(since: lastSeenChangelog)
          #if os(iOS)
          .presentationDetents([.large])
          .presentationDragIndicator(.visible)
          #endif
      }
  }

  // The content + sizing for each app-global modal. One switch instead of one
  // `.sheet` modifier per case; sizing shares `septenaModalSheet`.
  @ViewBuilder
  private func modalSheet(_ modal: AppModal) -> some View {
    switch modal {
    case .quickFind:
      QuickFindView()
        .septenaModalSheet(detents: [.medium, .large], macWidth: 560, macHeight: 420)
    case .addInfo(let section):
      AddInfoSheet(initialSection: section)
        .septenaModalSheet(detents: [.medium, .large], macWidth: 560, macHeight: 520)
    case .section(let key):
      // Quick-Action section sheet — the plugin's destination in a
      // NavigationStack so its title + toolbar present cleanly.
      NavigationStack {
        if let view = SectionRegistry.plugin(forKey: key)?.destinationView() {
          view
        } else {
          Text("Section unavailable.").padding()
        }
      }
      .septenaModalSheet(macWidth: 560, macHeight: 600)
    case .trainingSession:
      TrainingSessionView()
        .septenaModalSheet(macWidth: 560, macHeight: 600)
    case .moodCheckin:
      AddMoodPage()
        .septenaModalSheet(macWidth: 560, macHeight: 600)
    case .keyboardShortcuts:
      KeyboardShortcutsView()
        .septenaModalSheet(detents: [.medium, .large], macWidth: 480, macHeight: 560)
    }
  }

  // Standard iOS 26 TabView with the system tab-bar minimize behavior
  // (Music's collapse-on-scroll pattern). The floating "+" bubble that
  // used to ride beside the bar was removed — it crowded the tab bar
  // on iPhone and overlapped tab labels. Add Info still triggers from
  // ⌘K (menu bar) and each destination's own "+" button.
  @ViewBuilder
  private var rootTabView: some View {
    let tv = TabView(selection: Binding(get: { tabSelection.current },
                                        set: { tabSelection.current = $0 })) {
      WeekDashboardView()
        .tabItem {
          // `DiscsMark` is a custom SF Symbol (Septena's seven-disc mark);
          // the system tab bar sizes it like any built-in SF Symbol.
          Label("Today", image: "DiscsMark")
        }
        .tag(SeptenaTab.week)

      NextDashboardView()
        .tabItem { Label("Next", systemImage: "arrow.right") }
        .tag(SeptenaTab.next)

      if tasksEnabled {
        ContentView()
          .tabItem {
            Label("Tasks", systemImage: "checkmark")
          }
          .tag(SeptenaTab.tasks)
      }

      CoachView()
        .tabItem {
          Label("Coach", systemImage: "smallcircle.filled.circle")
            .environment(\.symbolVariants, .none)
        }
        .tag(SeptenaTab.goals)
    }
    #if os(iOS)
    Group {
      if hSize == .regular {
        tv
          .environment(homeToolbarExtras)
          .tabBarMinimizeBehavior(.onScrollDown)
          // A `SeptenaPage` publishes its chrome here; `RootTabView` renders it
          // at tab-bar height. Self-clearing — when the page leaves, the
          // preference reverts to nil and we fall back to the legacy path for
          // tabs not yet migrated to `SeptenaPage`.
          .onPreferenceChange(PageChromeKey.self) { hoistedChrome = $0 }
          .toolbar {
            if let chrome = hoistedChrome {
              ToolbarItem(placement: .topBarLeading) { PageGlobalButton() }
              if let actions = chrome.localActions {
                ToolbarItem(placement: .topBarTrailing) { OverflowMenu { actions } }
              }
              if let add = chrome.add {
                ToolbarItem(placement: .topBarTrailing) { PageAddButton(perform: add) }
              }
            } else {
              ToolbarItem(placement: .topBarLeading) {
                HomeMenu { homeToolbarExtras.content }
              }
              if homeToolbarExtras.hasTrailing {
                ToolbarItem(placement: .topBarTrailing) {
                  homeToolbarExtras.trailingContent
                }
              }
            }
          }
          .trainingTabAccessory(when: draftStore)
      } else {
        tv
          .environment(homeToolbarExtras)
          .tabBarMinimizeBehavior(.onScrollDown)
          .trainingTabAccessory(when: draftStore)
      }
    }
    #else
    tv
    #endif
  }
}

#if os(iOS)
private extension View {
  @ViewBuilder
  func trainingTabAccessory(when draftStore: TrainingDraftStore) -> some View {
    if let draft = draftStore.draft, draft.totalCount > 0 {
      tabViewBottomAccessory { TrainingTabAccessory() }
    } else {
      self
    }
  }
}
#endif
