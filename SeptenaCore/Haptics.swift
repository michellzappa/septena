// MARK: - Composable haptic patterns (motion-agnostic)
//
// A `HapticPatternSpec` is a sequence of beats plus a non-CoreHaptics
// fallback. It carries no app-layer concepts (kept that way so this file
// can stay a member of every target — Watch, Widgets — that has no notion
// of CommitMotion). The CommitMotion→spec mapping lives in the app layer.

/// One beat in a composed haptic: a sharp tap (`.transient`) or a swell
/// (`.continuous`, which uses `duration`). Intensity/sharpness are the
/// CoreHaptics 0…1 parameters.
struct HapticBeat {
  enum Kind { case transient, continuous }
  var kind: Kind
  var time: Double          // seconds from the pattern start
  var duration: Double = 0  // continuous only; ignored for transient
  var intensity: Float
  var sharpness: Float
}

/// A composed commit haptic plus the simple generator to fall back to when
/// CoreHaptics is unavailable (older hardware) or fails.
struct HapticPatternSpec {
  enum Fallback { case tap, tick, success }
  var beats: [HapticBeat]
  var fallback: Fallback
}

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

  /// Play a composed pattern. Falls back to the spec's simple generator if
  /// the hardware has no CoreHaptics or pattern playback throws.
  static func play(_ spec: HapticPatternSpec) {
    guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
      runFallback(spec.fallback)
      return
    }
    do {
      let engine = try coreHapticEngine()
      let events = spec.beats.map { beat -> CHHapticEvent in
        let params = [
          CHHapticEventParameter(parameterID: .hapticIntensity, value: beat.intensity),
          CHHapticEventParameter(parameterID: .hapticSharpness, value: beat.sharpness),
        ]
        switch beat.kind {
        case .transient:
          return CHHapticEvent(eventType: .hapticTransient,
                               parameters: params, relativeTime: beat.time)
        case .continuous:
          return CHHapticEvent(eventType: .hapticContinuous,
                               parameters: params, relativeTime: beat.time,
                               duration: beat.duration)
        }
      }
      let pattern = try CHHapticPattern(events: events, parameters: [])
      let player = try engine.makePlayer(with: pattern)
      try player.start(atTime: 0)
    } catch {
      runFallback(spec.fallback)
    }
  }

  private static func runFallback(_ fallback: HapticPatternSpec.Fallback) {
    switch fallback {
    case .tap:     tap()
    case .tick:    tick()
    case .success: success()
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
  static func play(_ spec: HapticPatternSpec) {}
}

#endif
