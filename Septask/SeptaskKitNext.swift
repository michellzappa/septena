#if os(macOS)
import AppKit
import SwiftUI

// Next page for the AppKit shell: hosts the shared SwiftUI `SeptaskNextPage`
// (same feed body as the iOS Next tab / iPad sidebar destination) in an
// NSHostingController. Next is not a keyboard-latency task surface, so
// porting HabitRow/ChoreRow/… to AppKit would be pure drift; hosting keeps
// the single implementation. Same environment rules as Settings
// (`SeptaskKitSettingsWindow` / `SeptaskMacRuntime`).

@MainActor
final class SeptaskKitNextController: NSViewController {
  /// Per-pane NavigationState — suggestion rows write `presentedModal` here
  /// (mood / nutrition sheets). Not the process-wide runtime; navigation is
  /// window-scoped the same way Settings gets its own.
  private let navigation = NavigationState()
  private var host: NSHostingController<AnyView>?

  override func loadView() {
    let theme = SeptaskMacRuntime.theme
    let settings = SeptaskMacRuntime.settings
    settings.reloadFromMirror(context: LocalStore.shared.container.mainContext)
    theme.paintFromCache()

    let root = SeptaskNextPage()
      .septenaSharedEnvironment(navigation: navigation, theme: theme,
                                settings: settings,
                                dayClock: SeptaskMacRuntime.dayClock,
                                logCommit: SeptaskMacRuntime.logCommit,
                                services: SeptenaServices.shared)
      .modelContainer(LocalStore.shared.container)
      .septenaTextSize()

    let host = NSHostingController(rootView: AnyView(root))
    self.host = host
    view = host.view
  }

  /// Match the task list's subtitle convention when this pane is front.
  func claimWindowSubtitle() {
    view.window?.subtitle = String(localized: "Next", comment: "Smart list title")
  }
}

/// Lightweight open-count for the sidebar badge. Same membership rules as
/// `SeptaskNextFeed.openCount` (suggestions − skips − training, chores, and
/// habits/supplements due now with linger). Sync paint-from-cache only — the
/// sidebar rebuild already runs on the data-changed notifications that would
/// have triggered a full load.
@MainActor
enum KitNextCount {
  static func open() -> Int {
    let clock = SeptaskMacRuntime.dayClock
    return SeptaskNextFeed.openCount(today: clock.today, now: clock.now)
  }
}
#endif
