import SwiftUI

// Top-level shell for Septena — three peer tabs, each a self-contained
// module. Week is the synthesizing dashboard, Next is the merged daily
// checklist, Tasks is the existing iOS task app embedded verbatim.
// Septena-app's `ContentView` (sidebar + task list) lives inside the Tasks
// tab unchanged so we can iterate on the new tabs without breaking the
// daily-driver UX.

enum SeptenaTab: Hashable {
  case week, next, tasks, goals

  /// Stable, low-cardinality screen name for Plausible. Kept here so the
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
  // Gates the in-flight training pill below the tab bar. Read here (not
  // just inside the accessory) so the `.tabViewBottomAccessory` modifier
  // is attached only mid-workout — an empty accessory content still draws
  // a blank bar, so the bar has to be absent, not just empty.
  @Environment(TrainingDraftStore.self) private var draftStore
  #if os(macOS)
  @Environment(\.openWindow) private var openWindow
  #endif
  @State private var tabSelection = TabSelection()

  var body: some View {
    @Bindable var nav = nav
    rootTabView
      .tint(theme.accent)
      // Resolve the push-vs-sheet rule once, here at the shell root, and
      // publish it to every tab via `\.usesPushNavigation`. The Week
      // dashboard, Coach tab, and section-drawer inspector all read that one
      // value instead of each recomputing from the size class.
      .resolvesAdaptiveNavigation()
      .environment(tabSelection)
      // Anonymous aggregate analytics — one event when the user lands on
      // a tab. `.task(id:)` re-runs only when the value changes and is
      // cancelled on disappear, so back-nav within a tab doesn't double
      // count. The actor is fire-and-forget; this never blocks UI.
      .task(id: tabSelection.current) {
        await PlausibleClient.shared.track(screen: tabSelection.current.analyticsName)
      }
      // App-global Settings. Lives at the TabView level so the top-left
      // "…" menu on every home view opens it, and so the sidebar row in
      // Tasks does too. On iOS it's a sheet; on macOS the same `showSettings`
      // flag opens the dedicated `"settings"` Window (declared in App.swift)
      // so the surface carries real traffic lights and closes like a window.
      #if os(iOS)
      .sheet(isPresented: $nav.showSettings) {
        SettingsView()
      }
      #else
      .onChange(of: nav.showSettings) { _, open in
        guard open else { return }
        openWindow(id: "settings")
        nav.showSettings = false
      }
      #endif
      // App-global Quick Find palette. Mounted here so the magnifyingglass
      // button in every home view's top-right opens it, regardless of tab.
      .sheet(isPresented: $nav.showQuickFind) {
        QuickFindView()
          #if os(iOS)
          .presentationDetents([.medium, .large])
          .presentationDragIndicator(.visible)
          #else
          .frame(width: 560, height: 420)
          #endif
      }
      // App-global Add Info palette. Still triggered by ⌘K (menu bar /
      // keyboard); the floating + bubble that used to sit beside the tab
      // bar has been removed.
      .sheet(isPresented: $nav.showAddInfo) {
        AddInfoSheet(initialSection: nav.addInfoRequestedSection)
          #if os(iOS)
          .presentationDetents([.medium, .large])
          .presentationDragIndicator(.visible)
          #else
          .frame(width: 560, height: 520)
          #endif
      }
      .onChange(of: nav.showAddInfo) { _, open in
        if !open { nav.addInfoRequestedSection = nil }
      }
      // Home Screen Quick Action routing. Mounted at the tab-root so it
      // fires regardless of which tab is selected — ContentView (the
      // previous host) is only mounted while the Tasks tab is visible.
      // We deliberately do NOT switch tabs; the sheet attached below
      // covers the current tab and dismissing returns the user there.
      .onChange(of: nav.pendingShortcut) { _, action in
        guard let action else { return }
        switch action {
        case .openSection(let key):
          nav.pendingSection = PendingSection(key: key)
        }
        nav.pendingShortcut = nil
      }
      // Deep-link tab switch (e.g. the Next widget's `septena://next`).
      .onChange(of: nav.pendingTab) { _, tab in
        guard let tab else { return }
        tabSelection.current = tab
        nav.pendingTab = nil
      }
      // The section sheet for Home Screen Quick Actions. Hosted here so
      // it works regardless of which tab is selected. Renders the
      // plugin's destinationView() inside a NavigationStack so titles +
      // toolbars present cleanly.
      .sheet(item: $nav.pendingSection) { pending in
        NavigationStack {
          if let view = SectionRegistry.plugin(forKey: pending.key)?.destinationView() {
            view
          } else {
            Text("Section unavailable.")
              .padding()
          }
        }
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 560, height: 600)
        #endif
      }
      // Training session sheet — mounted at the tab root so ⌘K's "Start
      // training" rows present cleanly from any tab, and so the Start
      // button inside the Week tab's Training destination can stack a
      // second sheet on top without dismissing the dashboard.
      .sheet(isPresented: $nav.showTrainingSession) {
        TrainingSessionView()
          #if os(iOS)
          .presentationDetents([.large])
          .presentationDragIndicator(.visible)
          #else
          .frame(minWidth: 560, minHeight: 600)
          #endif
      }
      // Mood check-in sheet — mounted at the tab root so the Next feed's
      // "How are you feeling?" daypart suggestion presents the two-step
      // quadrant picker from any tab. AddMoodPage owns its own
      // NavigationStack and dismisses itself after logging; the mutator
      // posts `.septenaDataChanged`, which the Next feed listens for to
      // clear the suggestion for the now-logged bucket.
      .sheet(isPresented: $nav.showMoodCheckin) {
        AddMoodPage()
          #if os(iOS)
          .presentationDetents([.large])
          .presentationDragIndicator(.visible)
          #else
          .frame(minWidth: 560, minHeight: 600)
          #endif
      }
      // (Insights destination removed — the Correlations homepage
      // layout now hosts the trusted + exploratory grids inline, with
      // per-pair DetailSheet drill-in on tap.)
      // App-global keyboard-shortcuts cheat-sheet (⌘?). Mounted here so it
      // opens over any tab.
      .sheet(isPresented: $nav.showKeyboardShortcuts) {
        KeyboardShortcutsView()
          #if os(iOS)
          .presentationDetents([.medium, .large])
          .presentationDragIndicator(.visible)
          #else
          .frame(width: 480, height: 560)
          #endif
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
          Label("Week", image: "DiscsMark")
        }
        .tag(SeptenaTab.week)

      NextDashboardView()
        .tabItem { Label("Next", systemImage: "arrow.right") }
        .tag(SeptenaTab.next)

      ContentView()
        .tabItem { Label("Tasks", systemImage: "checkmark") }
        .tag(SeptenaTab.tasks)

      CoachView()
        .tabItem {
          Label("Coach", systemImage: "smallcircle.filled.circle")
            .environment(\.symbolVariants, .none)
        }
        .tag(SeptenaTab.goals)
    }
    #if os(iOS)
    let bar = tv.tabBarMinimizeBehavior(.onScrollDown)
    // In-flight training session lives here as a Music-style pill above the
    // tab bar (collapses inline when the bar minimizes) — twin of the Live
    // Activity. Attach the accessory only while a session is active; an
    // empty accessory still draws a blank bar, so it must be absent
    // otherwise. `@Observable` draftStore re-renders this on start/end.
    if let draft = draftStore.draft, draft.totalCount > 0 {
      bar.tabViewBottomAccessory {
        TrainingTabAccessory()
      }
    } else {
      bar
    }
    #else
    tv
    #endif
  }
}
