#if canImport(UIKit)
import CoreHaptics
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
  private static var coreEngine: CHHapticEngine?

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

  /// AI generation — a short, low continuous pulse borrowed from NavigateWithin.
  static func aiGeneration() {
    guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
      tick()
      return
    }

    do {
      let engine = try coreHapticEngine()
      let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6)
      let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4)
      let event = CHHapticEvent(
        eventType: .hapticContinuous,
        parameters: [intensity, sharpness],
        relativeTime: 0,
        duration: 1.0
      )
      let pattern = try CHHapticPattern(events: [event], parameters: [])
      let player = try engine.makePlayer(with: pattern)
      try player.start(atTime: 0)
    } catch {
      tick()
    }
  }

  private static func coreHapticEngine() throws -> CHHapticEngine {
    if let coreEngine { return coreEngine }

    let engine = try CHHapticEngine()
    engine.resetHandler = {
      try? coreEngine?.start()
    }
    engine.stoppedHandler = { _ in
      coreEngine = nil
    }
    try engine.start()
    coreEngine = engine
    return engine
  }
}

#else

// macOS has no UIKit haptics — Mac trackpads use NSHapticFeedbackManager,
// but for now we no-op so call sites stay platform-agnostic.
enum Haptics {
  static func tap() {}
  static func tick() {}
  static func pick() {}
  static func success() {}
  static func warning() {}
  static func aiGeneration() {}
}

#endif
