import WatchKit

// MARK: - Watch completion feel
//
// The wrist counterpart of the phone's `CheckFeel`. Completing something on
// the watch used to fire one flat `.success` for every kind; this gives each
// Next section its own *rhythm* so a finished habit reads differently from a
// taken supplement, even eyes-off.
//
// The phone differentiates with CoreHaptics (precisely-timed transients +
// swells). watchOS has no CoreHaptics — `WKInterfaceDevice` only plays the
// fixed `WKHapticType` set — so we reproduce the *signature* of each feel
// (its beat count and spacing) by sequencing taps, not their texture:
//
//   • .stamp (tasks)        — one beat. The crisp "done".
//   • .echo  (habits)       — two spaced beats: today, answered by the streak.
//   • .drop  (supplements)  — a soft beat then a landing: one more capsule down.
//   • .tuck  (chores)       — a beat then a later, softer close: filed away.
//   • .logged (suggestions) — a single quiet click: the wrist cousin of the
//     phone's quiet tick. Everyday quick-logs are acknowledged, not
//     celebrated (the celebration-budget rule); `.success` stays reserved
//     for the check-feels above.
//
// Kind → feel mirrors the phone's `CheckFeel` assignment and routes off the
// shared `NextBlocks` kinds (`task` / `habit` / `supplement` / `chore`), so
// adding a Next member there picks up `.logged` until given a feel here.
enum WatchCompletionFeel {
  case stamp
  case echo
  case drop
  case tuck
  case logged

  /// Map a `NextItem.kind` to its feel. Unknown kinds fall back to `.logged`
  /// so a new completable member is never silent — just not yet bespoke.
  static func forItemKind(_ kind: String) -> WatchCompletionFeel {
    switch kind {
    case "task":       return .stamp
    case "habit":      return .echo
    case "supplement": return .drop
    case "chore":      return .tuck
    default:           return .logged
    }
  }

  /// Play the feel's rhythm. Single-beat feels fire immediately; the two-beat
  /// feels schedule the second tap after a gap wide enough to register as a
  /// distinct beat on the wrist (back-to-back plays merge into one buzz).
  func play() {
    let device = WKInterfaceDevice.current()
    switch self {
    case .stamp:
      device.play(.success)                          // one crisp beat — done
    case .logged:
      device.play(.click)                            // quiet acknowledgment
    case .echo:
      device.play(.click)                            // today's mark…
      Self.after(0.18) { $0.play(.click) }           // …echoed by the streak
    case .drop:
      device.play(.click)                            // the soft fall…
      Self.after(0.15) { $0.play(.success) }         // …then it lands
    case .tuck:
      device.play(.success)                          // the thud…
      Self.after(0.22) { $0.play(.click) }           // …then the drawer eases shut
    }
  }

  /// Schedule a second beat. Re-fetches the device inside the hop rather than
  /// capturing it, so nothing non-`Sendable` crosses the `Task` boundary.
  private static func after(_ seconds: Double, _ play: @escaping @Sendable (WKInterfaceDevice) -> Void) {
    Task {
      try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      play(WKInterfaceDevice.current())
    }
  }
}
