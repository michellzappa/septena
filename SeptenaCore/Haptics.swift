import UIKit

// Native UIKit haptics. Lightweight helpers — generators are pre-prepared so
// the first fire isn't laggy. Call from any thread; UIKit dispatches.

enum Haptics {

  // Pre-prepared generators. Calling .prepare() right after .impactOccurred()
  // primes the engine for the next tap, so subsequent fires are instant.
  private static let lightImpact = UIImpactFeedbackGenerator(style: .light)
  private static let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
  private static let selection = UISelectionFeedbackGenerator()
  private static let notification = UINotificationFeedbackGenerator()

  /// Generic light tap — Magic Plus, button presses, swipe-revealed action.
  static func tap() {
    lightImpact.impactOccurred()
    lightImpact.prepare()
  }

  /// Slightly firmer thump — committed write (rename, save, schedule).
  static func tick() {
    mediumImpact.impactOccurred()
    mediumImpact.prepare()
  }

  /// Picker / menu choice — non-destructive selection change.
  static func pick() {
    selection.selectionChanged()
    selection.prepare()
  }

  /// Positive completion — task checked off, project marked done.
  static func success() {
    notification.notificationOccurred(.success)
    notification.prepare()
  }

  /// Destructive / cancelling — delete, cancel, error.
  static func warning() {
    notification.notificationOccurred(.warning)
    notification.prepare()
  }
}
