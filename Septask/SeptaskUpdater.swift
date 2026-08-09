#if os(macOS)
import AppKit
import Sparkle

/// The one process-wide owner of Septask's Sparkle updater.
///
/// Sparkle owns the update UI, download, signature verification, replacement,
/// and relaunch. Keeping that lifecycle here means the AppKit shell, SwiftUI
/// Settings, and the application menu all use one updater controller.
@MainActor
final class SeptaskUpdater: NSObject {
  static let shared = SeptaskUpdater()

  static var isConfigured: Bool {
    guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
      return false
    }
    let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
    return !value.isEmpty && value != "your-sparkle-public-ed25519-key"
  }

  private let controller: SPUStandardUpdaterController

  private override init() {
    controller = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
    super.init()
  }

  func checkForUpdates() {
    controller.checkForUpdates(nil)
  }
}
#endif
