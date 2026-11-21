#if os(macOS)
import AppKit
import SwiftUI

/// Standard NSMenu-style dropdown for the menu bar item. Only Button,
/// Divider, and Text are guaranteed to render with `.menuBarExtraStyle(.menu)`
/// — anything else (TextField, ScrollView, custom Views) gets dropped or
/// breaks the menu layout. Septena Life no longer shows tasks (ADR 0007), so
/// the menu carries Open and Quit.
struct MenuBarMenu: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Group {
      Button("Open Septena Life") { activateMainWindow() }
      Button("Quit Septena Life") { NSApp.terminate(nil) }
        .keyboardShortcut("q")
    }
  }

  private func activateMainWindow() {
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
