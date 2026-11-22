#if os(macOS)
import AppKit
import SwiftUI

// The first run on the AppKit shell: the shared SwiftUI `SeptaskFirstRunView`
// (registry-driven, `SeptaskFirstRun.swift`) hosted as a sheet on the main
// window. Same reason as Settings for hosting rather than porting: one
// implementation, and the environment chain is the Settings window's, because
// a hosted shared view reading a missing @Environment crashes at launch.
@MainActor
enum SeptaskKitFirstRunWindow {
  private static var sheet: NSWindow?

  /// Decide once per launch (`SeptaskFirstRunGate.resolve`), then present
  /// when this account still owes a first run.
  static func presentIfNeeded() async {
    let settings = SeptaskMacRuntime.settings
    await SeptaskFirstRunGate.resolve(settings: settings)
    guard SeptaskFirstRunGate.shouldPresent(settings: settings,
                                            context: LocalStore.shared.container.mainContext) else { return }
    present()
  }

  /// Settings ▸ About ▸ Show Welcome Again opens it directly.
  static func present() {
    guard sheet == nil,
          let parent = SeptaskKitWindowController.existing?.window else { return }
    let root = SeptaskKitFirstRunRoot { dismiss() }
    let host = NSHostingController(rootView: root)
    let window = NSWindow(contentViewController: host)
    window.title = String(localized: "Septena", comment: "First-run window title")
    window.styleMask = [.titled, .fullSizeContentView]
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    sheet = window
    parent.beginSheet(window)
  }

  private static func dismiss() {
    guard let window = sheet else { return }
    window.sheetParent?.endSheet(window)
    sheet = nil
  }
}

private struct SeptaskKitFirstRunRoot: View {
  let onFinish: () -> Void
  private let appearance = AppearancePreferences.shared

  var body: some View {
    SeptaskFirstRunView(onFinish: onFinish)
      .septenaSharedEnvironment(navigation: NavigationState(),
                                theme: SeptaskMacRuntime.theme,
                                settings: SeptaskMacRuntime.settings,
                                dayClock: SeptaskMacRuntime.dayClock,
                                logCommit: SeptaskMacRuntime.logCommit,
                                services: SeptenaServices.shared)
      .modelContainer(LocalStore.shared.container)
      .septenaTextSize()
      .tint(appearance.accentSwiftUIColor)
      .preferredColorScheme(appearance.preferredColorScheme)
  }
}
#endif
