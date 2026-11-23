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
  enum Fallback { case press, commit, success }
  var beats: [HapticBeat]
  var fallback: Fallback
}

// MARK: - The haptic vocabulary (docs/HAPTICS_SPEC.md)
//
// Every imperative haptic in the app goes through one of these seven verbs.
// Pick the verb by what the gesture MEANS, never by how strong it should
// feel; the feel is decided here, once. Haptics that follow LOCAL view state
// (a filter chip, a toolbar toggle) use SwiftUI's `.sensoryFeedback(_:trigger:)`
// at the view instead, with the same meaning-to-feedback table. Never use
// `.sensoryFeedback` for task data: sync and undo change task data too, and
// the phone must not buzz for a write the user did not make.
//
//   press      touch-down that starts something: lift a drag, open a sheet,
//              open the composer                       → soft impact
//   selection  choose among options, move between drop targets, fold or
//              unfold, change page                     → selection
//   commit     a write landed: rename, schedule, move, reorder, star, add
//                                                      → light impact
//   threshold  a gesture crossed its commit point: full swipe armed, pull
//              armed, spring-load fired                → medium impact
//   success    something finished: a project done, a review accepted
//                                                      → success notification
//   warning    a destructive or cancelling write: delete, cancel, let go
//                                                      → warning notification
//   play(_:)   a composed CoreHaptics pattern (task completion, flourishes)

#if canImport(UIKit)
import CoreHaptics
import UIKit

@MainActor
enum Haptics {

  static func press()     { bank()?.soft.fire() }
  static func selection() { bank()?.selection.fire() }
  static func commit()    { bank()?.light.fire() }
  static func threshold() { bank()?.medium.fire() }
  static func success()   { bank()?.notify(.success) }
  static func warning()   { bank()?.notify(.warning) }

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
      try player.start(atTime: CHHapticTimeImmediate)
    } catch {
      runFallback(spec.fallback)
    }
  }

  private static func runFallback(_ fallback: HapticPatternSpec.Fallback) {
    switch fallback {
    case .press:   press()
    case .commit:  commit()
    case .success: success()
    }
  }

  // MARK: Generators, attached to the key window
  //
  // Since iOS 17.5 a feedback generator belongs to a view (`init(view:)`;
  // the view-less initializers are marked to-be-deprecated). The system uses
  // the view to decide where and whether to play, which matters on iPad with
  // a trackpad or Apple Pencil. The verbs above carry no view, so the bank
  // attaches to the key window and moves when another window becomes key.
  // No foreground window (an App Intent in the background) means no haptic.

  private final class Bank {
    weak var window: UIWindow?
    let soft: UIImpactFeedbackGenerator
    let light: UIImpactFeedbackGenerator
    let medium: UIImpactFeedbackGenerator
    let selection: UISelectionFeedbackGenerator
    let notification: UINotificationFeedbackGenerator

    init(window: UIWindow) {
      self.window = window
      soft = UIImpactFeedbackGenerator(style: .soft, view: window)
      light = UIImpactFeedbackGenerator(style: .light, view: window)
      medium = UIImpactFeedbackGenerator(style: .medium, view: window)
      selection = UISelectionFeedbackGenerator(view: window)
      notification = UINotificationFeedbackGenerator(view: window)
    }

    func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
      notification.notificationOccurred(type)
      notification.prepare()
    }

    /// The generators attach themselves to the window as interactions;
    /// detach them when the bank moves to another window.
    func detach() {
      guard let window else { return }
      for generator: UIFeedbackGenerator in [soft, light, medium, selection, notification] {
        window.removeInteraction(generator)
      }
    }
  }

  private static var current: Bank?

  private static func bank() -> Bank? {
    guard let window = keyWindow() else { return nil }
    if let current, current.window === window { return current }
    current?.detach()
    let bank = Bank(window: window)
    current = bank
    return bank
  }

  private static func keyWindow() -> UIWindow? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .filter { $0.activationState == .foregroundActive }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)
  }

  // MARK: CoreHaptics engine (composed patterns only)

  private static var coreEngine: CHHapticEngine?

  private static func coreHapticEngine() throws -> CHHapticEngine {
    if let coreEngine { return coreEngine }
    let engine = try CHHapticEngine()
    // Haptics only: no audio session work. Auto-shutdown lets the engine
    // power the Taptic Engine down between commits; it starts again on play.
    engine.playsHapticsOnly = true
    engine.isAutoShutdownEnabled = true
    // Both handlers run on an engine queue. Hop to the main actor, where the
    // cached engine lives; the next play rebuilds it when it is gone.
    engine.resetHandler = {
      Task { @MainActor in coreEngine = nil }
    }
    engine.stoppedHandler = { _ in
      Task { @MainActor in coreEngine = nil }
    }
    try engine.start()
    coreEngine = engine
    return engine
  }
}

private extension UIImpactFeedbackGenerator {
  func fire() { impactOccurred(); prepare() }
}

private extension UISelectionFeedbackGenerator {
  func fire() { selectionChanged(); prepare() }
}

#else

// macOS: no haptics on purpose. The Mac HIG keeps haptics for force clicks
// and for dragging onto alignment guides, and the Force Touch trackpad
// already answers every click. Septena has neither guides nor force-click
// actions, so a haptic on a click or a keyboard shortcut would be noise.
// The verbs stay so shared call sites compile unchanged.
@MainActor
enum Haptics {
  static func press() {}
  static func selection() {}
  static func commit() {}
  static func threshold() {}
  static func success() {}
  static func warning() {}
  static func play(_ spec: HapticPatternSpec) {}
}

#endif

extension Haptics {
  /// A project status change: done is a success, cancelled a warning,
  /// reopened a plain commit.
  static func projectStatusChanged(to status: ProjectStatus) {
    switch status {
    case .done: success()
    case .cancelled: warning()
    case .active: commit()
    }
  }
}
