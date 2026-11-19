#if os(macOS)
import AppKit
import SwiftUI

/// Standard NSMenu-style dropdown for the menu bar item. Only Button,
/// Divider, and Text are guaranteed to render with `.menuBarExtraStyle(.menu)`
/// — anything else (TextField, ScrollView, custom Views) gets dropped or
/// breaks the menu layout. Septena Life no longer shows tasks (ADR 0007), so
/// the menu carries no "New To-Do" or Today list: only the MCP server state,
/// Open and Quit.
struct MenuBarMenu: View {
  @AppStorage(MCPDefaultsKey.enabled) private var mcpEnabled = false
  @AppStorage(MCPDefaultsKey.keepAlive) private var mcpKeepAlive = false
  @Environment(\.openWindow) private var openWindow

  /// ⌘Q soft-quits to the menu bar only when the server is on *and* "keep
  /// serving after quit" is opted in; otherwise it quits normally.
  private var softQuit: Bool { mcpEnabled && mcpKeepAlive }

  var body: some View {
    Group {
      // Live MCP server state, shown only while the server is enabled. Reading
      // `LocalMCPStatus.shared` properties here registers Observation tracking,
      // so the line updates when the server starts/stops or serves a request.
      if mcpEnabled {
        Text(mcpStatusText)
        Divider()
      }

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
  }

  private var mcpStatusText: String {
    let status = LocalMCPStatus.shared
    if !status.isRunning { return "MCP server off" }
    if status.isActive(within: 120) { return "MCP · active just now" }
    return "MCP · listening on :\(LocalMCPServer.shared.port)"
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
  }
}
#endif
