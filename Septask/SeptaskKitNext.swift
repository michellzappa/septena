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

  /// Where a pick from the page's title dropdown goes. The shell steers its
  /// sidebar, which drives the panes — the same contract the task list's
  /// `onNavigate` uses, so a jump always leaves the two in agreement. Set
  /// before this pane is first displayed.
  var onNavigate: ((Route) -> Void)?

  /// Whether the page's own big title is still on screen. The hosted page
  /// reports it; `syncWindowTitle` applies it.
  private var headerVisible = true

  override func loadView() { view = NSView() }

  /// The hosting controller is added as a CHILD view controller rather than
  /// having its `view` lifted out and used as ours. Taking `host.view` alone
  /// leaves the hosting controller outside the view-controller hierarchy, so
  /// it never receives appearance callbacks and the SwiftUI content's
  /// visibility is tracked only incidentally, by the hosting view noticing it
  /// moved to a window. Settings — the shell's other SwiftUI host — is already
  /// correct (`window.contentViewController = host`); this was the one site
  /// that wasn't.
  override func viewDidLoad() {
    super.viewDidLoad()
    let theme = SeptaskMacRuntime.theme
    let settings = SeptaskMacRuntime.settings
    settings.reloadFromMirror(context: LocalStore.shared.container.mainContext)
    theme.paintFromCache()

    let root = SeptaskNextPage(
      onNavigate: { [weak self] route in self?.onNavigate?(route) },
      onHeaderVisibilityChange: { [weak self] visible in
        guard let self else { return }
        self.headerVisible = visible
        self.syncWindowTitle()
      })
      .septenaSharedEnvironment(navigation: navigation, theme: theme,
                                settings: settings,
                                dayClock: SeptaskMacRuntime.dayClock,
                                logCommit: SeptaskMacRuntime.logCommit,
                                services: SeptenaServices.shared)
      .modelContainer(LocalStore.shared.container)
      .septenaTextSize()

    let host = NSHostingController(rootView: AnyView(root))
    self.host = host
    addChild(host)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.topAnchor.constraint(equalTo: view.topAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
  }

  /// Hide the window title while this page's own big title is on screen, show
  /// it once that title has scrolled away — the identical rule (and identical
  /// name) as `SeptaskKitTaskListController.syncWindowTitle`, so the top of
  /// the window reads the same however you got here. Called by the shell when
  /// it swaps this pane in, ahead of the page's first scroll report.
  func syncWindowTitle() {
    guard let window = view.window else { return }
    let wanted: NSWindow.TitleVisibility = headerVisible ? .hidden : .visible
    if window.titleVisibility != wanted { window.titleVisibility = wanted }
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
