import Foundation

// The fade cue on a task row (docs/TASK_FADE_SPEC.md §4). A task left on Today
// fades a little each day it carries over; the whole row fades, checkbox
// included and by the same amount (mz, 2026-11-20), so the cue reads as "this
// is slipping away" instead of a tinted control. Today
// it runs on the Today tenure clock (`SeptenaTask.todayTenureFill`); with the
// fade fields (#28) the same curve counts down to the task leaving the list.
//
// One rule for both task lists: the SwiftUI row (`CheckableRow`) and the AppKit
// row (`SeptaskKitTaskCell`) read it, so they cannot drift.

enum TaskFade {
  /// The faintest a fading row gets. Label ink at 0.55 on the light background
  /// stays above a 4.5:1 contrast ratio, so a faded title is still readable.
  static let minOpacity: Double = 0.55

  /// Row content opacity for a tenure fill (0…1, nil = not fading): full at
  /// 0, `minOpacity` at 1. Applied to the checkbox too; it stays tappable.
  static func rowOpacity(_ fill: Double?) -> Double {
    guard let fill, fill.isFinite, fill > 0 else { return 1 }
    return 1 - min(1, fill) * (1 - minOpacity)
  }

  /// Whether a user's schedule / Today change counts as a defer
  /// (`docs/TASK_FADE_SPEC.md` §3): setting `scheduled` to a later day than
  /// its current value, or taking a task off Today.
  static func isDefer(oldScheduled: String?,
                      newScheduled: String?,
                      wasOnToday: Bool,
                      isNowOnToday: Bool) -> Bool {
    if wasOnToday && !isNowOnToday { return true }
    if let old = oldScheduled, let new = newScheduled, new > old { return true }
    return false
  }
}
