import Foundation

// TaskDateActions — the only way a shell changes a task's date fields.
//
// `docs/TASK_DATES_SPEC.md` §4 defines a closed set of date actions (When,
// deadline, Today pin, time slot). Each one is a single call here, so iOS,
// iPad, Mac and every surface on them (menu, swipe, drag, picker, composer,
// keyboard) produce the same fields for the same gesture. Shells never chain
// `schedule` / `moveToToday` / `setDeadline` / `removeFromToday` themselves;
// that chaining is how the platforms drifted apart (spec §7).
//
// The shared core decides the fields (`task_dates.rs`, D3 #290, ADR 0027);
// `TasksBackend+DateActions.swift` writes its patch in one save. This file
// only maps the Swift action to the core's and keeps the selection rule of
// A4. Undo stays with the caller: record one `TaskUndo` snapshot before the
// action and one entry after it (AGENTS.md, "Undo is ONE shared stack").

/// A date action from `docs/TASK_DATES_SPEC.md` §4. The comment on each case
/// names the spec ID.
enum TaskDateAction: Equatable {
  /// A1. Put the task on Today. Replaces its When date (invariant I1).
  case putOnToday
  /// A2. Plan the task for a day. A day on or before today is A1.
  case scheduleFor(Date)
  /// A3. Take the task off Today: unpin, and clear a When date or deadline
  /// that has arrived (decision Q2), so it cannot bounce straight back.
  case removeFromToday
  /// A5. Clear the When date only. The deadline stays (invariant I5).
  case clearWhenDate
  /// A6. "Clear When" (`task.clearSchedule`): When date, deadline, Today pin
  /// and time slot all go. The task lands in Anytime.
  case clearWhen
  /// A7 / A8. Set or clear the deadline.
  case setDeadline(Date?)
  /// A9. Set or clear the time slot. A time with no day pins to Today.
  case setTimeSlot(startTime: String?, durationMinutes: Int?, timeZone: String?)
}

extension TaskMutator {

  /// Apply one date action to one task. The core also clears the agent cue
  /// (every date action is engagement). `mode` answers the fixed-repeat
  /// question for A1 / A2; callers that show the prompt pass the user's
  /// answer.
  /// Returns nothing: shells call it from `() -> Void` closures.
  func apply(_ action: TaskDateAction, to id: String,
             mode: RecurrenceRescheduleMode = .makeException) {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] apply(date action) called before CK bound — dropping", nil)
      return
    }
    cloudBackend.applyDateAction(id: id, action: action, mode: mode)
  }

  /// A4. Toggle Today for a selection. If every task is on Today (by pin OR
  /// by an arrived date: `isOnToday`, never the raw pin), all leave it (A3).
  /// Otherwise the ones not on Today join it (A1) and the rest stay.
  /// Returns the ids that joined Today, so the caller can play the promote
  /// flash; empty when the selection left Today.
  @discardableResult
  func toggleToday(ids: [String]) -> [String] {
    let tasks = ids.compactMap { taskEntity(id: $0) }
    guard !tasks.isEmpty else { return [] }
    if tasks.allSatisfy(\.isOnToday) {
      for id in ids { apply(.removeFromToday, to: id) }
      return []
    }
    let joining = tasks.filter { !$0.isOnToday }.map(\.id)
    for id in ids {
      if joining.contains(id) {
        apply(.putOnToday, to: id)
      } else {
        acknowledge(id: id)
      }
    }
    return joining
  }
}
