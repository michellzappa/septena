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

    Divider()

    Button("Open Septena") { activateMainWindow() }
    Button("Quit Septena") { NSApp.terminate(nil) }
      .keyboardShortcut("q")
  }

  private func startQuickAdd() {
    activateMainWindow()
    // Posted notification is observed in ContentView — sets path to Inbox
    // and flips `shouldStartCreating`, same as Command-N / iOS quick action.
    NotificationCenter.default.post(name: .septenaOpenQuickAdd, object: nil)
  }

  private func activateMainWindow() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.windows
      .first { $0.canBecomeMain }?
      .makeKeyAndOrderFront(nil)
    Task { await loader.refresh() }
  }
}
#endif
