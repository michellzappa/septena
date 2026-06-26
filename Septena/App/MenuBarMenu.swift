#if os(macOS)
import AppKit
import SwiftUI

/// Lightweight Today loader for the menu bar. Fetches via the existing
/// `client.list(view: "today")` API and re-runs whenever a task mutation
/// posts `.septenaTasksChanged`, so the dropdown reflects the same state
/// as the main window without any custom sync.
@MainActor
@Observable
private final class MenuBarTodayLoader {
  var items: [SeptenaTask] = []
  @ObservationIgnored private var observer: NSObjectProtocol?

  init() {
    // First fetch happens when the menu is opened for the first time
    // (which is when @State instantiates this loader).
    Task { await refresh() }
    // Stay in sync with the rest of the app — every mutation posts this.
    observer = NotificationCenter.default.addObserver(
      forName: .septenaTasksChanged, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in await self?.refresh() }
    }
  }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  func refresh() async {
    let resp = await TaskReads.list(
      view: "today",
      context: LocalStore.shared.container.mainContext
    )
    // Mirror the Today screen: pinned-today (`items`) plus scheduled/due
    // rolling in (`review`). Completed-today rows live in `done` and stay
    // out of the menu bar.
    items = (resp.items + (resp.review ?? [])).filter { $0.status == .open }
  }
}

/// Standard NSMenu-style dropdown for the menu bar item. Only Button,
/// Divider, and Text are guaranteed to render with `.menuBarExtraStyle(.menu)`
/// — anything else (TextField, ScrollView, custom Views) gets dropped or
/// breaks the menu layout. Quick capture lives in the main app instead,
/// reached via "New To-Do" which activates the window into draft mode.
struct MenuBarMenu: View {
  @State private var loader = MenuBarTodayLoader()
  @AppStorage(MCPDefaultsKey.enabled) private var mcpEnabled = false
  @AppStorage(MCPDefaultsKey.keepAlive) private var mcpKeepAlive = false
  @Environment(\.openWindow) private var openWindow

  /// ⌘Q soft-quits to the menu bar only when the server is on *and* "keep
  /// serving after quit" is opted in; otherwise it quits normally.
  private var softQuit: Bool { mcpEnabled && mcpKeepAlive }

  var body: some View {
    Button("New To-Do") { startQuickAdd() }
      .keyboardShortcut("n")

    Divider()

    if loader.items.isEmpty {
      Text("Nothing on Today")
    } else {
      Text("Today")
      ForEach(loader.items) { task in
        Button(task.title) { activateMainWindow() }
      }
    }

    // Live MCP server state, shown only while the server is enabled. Reading
    // `LocalMCPStatus.shared` properties here registers Observation tracking,
    // so the line updates when the server starts/stops or serves a request.
    if mcpEnabled {
      Divider()
      Text(mcpStatusText)
    }

    Divider()

    Button("Open Septena") { activateMainWindow() }
    // ⌘Q soft-quits to the menu bar only when soft-quit is on (NSApp.terminate
    // routes through MacAppDelegate.applicationShouldTerminate); otherwise it
    // quits normally. "Quit Completely" always exits.
    Button(softQuit ? "Hide Septena" : "Quit Septena") { NSApp.terminate(nil) }
      .keyboardShortcut("q")
    if softQuit {
      Button("Quit Completely") { MacAppLifecycle.quitCompletely() }
        .keyboardShortcut("q", modifiers: [.command, .option])
    }
  }

  private var mcpStatusText: String {
    let status = LocalMCPStatus.shared
    if !status.isRunning { return "MCP server off" }
    if status.isActive(within: 120) { return "MCP · active just now" }
    return "MCP · listening on :\(LocalMCPServer.shared.port)"
  }

  private func startQuickAdd() {
    activateMainWindow()
    OpenNewTaskRouting.dispatch()
  }

  private func activateMainWindow() {
    // Unhide first (soft-quit hides the app ⌘H-style), then front the existing
    // window — or recreate it if a red-button close fully released it while the
    // server kept the app alive.
    NSApp.unhide(nil)
    NSApp.activate(ignoringOtherApps: true)
    if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
      window.makeKeyAndOrderFront(nil)
    } else {
      openWindow(id: "main")
    }
    Task { await loader.refresh() }
  }
}
#endif
