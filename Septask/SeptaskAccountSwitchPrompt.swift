import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The question before a sign-in with another account replaces the tasks on
/// this device (#575). `TaskSyncEngine.signIn` asks it through
/// `TaskSyncEngine.confirmAccountSwitch`, which `install()` sets at launch.
///
/// The question is a system alert on both platforms, presented from the app
/// rather than from one view: a sign-in starts on the welcome, on Today, in
/// Settings and from a device code, and every path must stop here. Copy comes
/// from `registry/surfaces.json` `accountSwitch`.
@MainActor
enum SeptaskAccountSwitchPrompt {
  static func install() {
    TaskSyncEngine.confirmAccountSwitch = { summary in
      let choice = await ask(summary)
      if choice == .exportFirst { openExport() }
      return choice
    }
  }

  /// The alert's message: what goes, then how much of it.
  static func message(_ summary: TaskSyncEngine.AccountSwitchSummary) -> String {
    var lines = [RegistryAccountSwitch.body]
    lines.append(summary.tasks == 1
                 ? RegistryAccountSwitch.tasksOne
                 : RegistryAccountSwitch.tasksOther.replacingOccurrences(of: "{count}", with: "\(summary.tasks)"))
    if summary.unsent > 0 {
      lines.append(summary.unsent == 1
                   ? RegistryAccountSwitch.unsentOne
                   : RegistryAccountSwitch.unsentOther.replacingOccurrences(of: "{count}", with: "\(summary.unsent)"))
    }
    return lines.joined(separator: "\n\n")
  }

  /// Settings ▸ Import & Export, where the backup is saved.
  private static func openExport() {
    SeptaskSettingsLink.request(RegistrySettings.PageID.importExport)
    #if os(macOS)
    SeptaskKitSettingsWindow.show()
    #endif
  }

  #if os(macOS)
  private static func ask(_ summary: TaskSyncEngine.AccountSwitchSummary) async -> TaskSyncEngine.AccountSwitchChoice {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = RegistryAccountSwitch.title
    alert.informativeText = message(summary)
    alert.addButton(withTitle: RegistryAccountSwitch.cancel)
    alert.addButton(withTitle: RegistryAccountSwitch.export)
    let replace = alert.addButton(withTitle: RegistryAccountSwitch.replace)
    replace.hasDestructiveAction = true
    switch alert.runModal() {
    case .alertFirstButtonReturn: return .cancel
    case .alertSecondButtonReturn: return .exportFirst
    default: return .replace
    }
  }
  #else
  private static func ask(_ summary: TaskSyncEngine.AccountSwitchSummary) async -> TaskSyncEngine.AccountSwitchChoice {
    guard let scene = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive })
      ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
      var top = scene.keyWindow?.rootViewController else { return .cancel }
    while let presented = top.presentedViewController { top = presented }
    let presenter = top
    return await withCheckedContinuation { continuation in
      let alert = UIAlertController(title: RegistryAccountSwitch.title,
                                    message: message(summary),
                                    preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: RegistryAccountSwitch.export, style: .default) { _ in
        continuation.resume(returning: .exportFirst)
      })
      alert.addAction(UIAlertAction(title: RegistryAccountSwitch.replace, style: .destructive) { _ in
        continuation.resume(returning: .replace)
      })
      alert.addAction(UIAlertAction(title: RegistryAccountSwitch.cancel, style: .cancel) { _ in
        continuation.resume(returning: .cancel)
      })
      presenter.present(alert, animated: true)
    }
  }
  #endif
}
