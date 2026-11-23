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
// Phase D3 (#290) moves the decisions below into the Rust core
// (`septena-core`, ADR 0027). Until then this file is the one Swift copy.
//
// Undo stays with the caller: record one `TaskUndo` snapshot before the
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

  /// Apply one date action to one task, then clear its agent cue (every
  /// date action is engagement). `mode` answers the fixed-repeat question
  /// for A1 / A2; callers that show the prompt pass the user's answer.
  func apply(_ action: TaskDateAction, to id: String,
             mode: RecurrenceRescheduleMode = .makeException) {
    perform(action, on: id, mode: mode)
    acknowledge(id: id)
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

  // MARK: - The rules (spec §4)

  private func perform(_ action: TaskDateAction, on id: String,
                       mode: RecurrenceRescheduleMode) {
    let today = SeptenaDate.today
    switch action {
    case .putOnToday:
      // Move a dated row's occurrence to today first, so a fixed repeat
      // records its slot and a reminder on the old When day follows it, then
      // drop the date: a pinned row has no When date (I1).
      if taskEntity(id: id)?.scheduled != nil {
        reschedule(id: id, date: SeptenaDate.parse(today), mode: mode)
        schedule(id: id, date: nil)
      }
      moveToToday(id: id, today: true)

    case .scheduleFor(let day):
      guard let iso = SeptenaDate.format(day) else { return }
      if iso <= today {
        perform(.putOnToday, on: id, mode: mode)
        return
      }
      // The deadline stays (decision Q1): a deadline that has arrived keeps
      // the row on Today, red, until the user deals with it.
      reschedule(id: id, date: day, mode: mode)
      moveToToday(id: id, today: false)

    case .removeFromToday:
      removeFromToday(id: id)
      clearTimeSlotIfNoDay(id)

    case .clearWhenDate:
      schedule(id: id, date: nil)
      moveToToday(id: id, today: false)
      clearTimeSlotIfSet(id)

    case .clearWhen:
      // The deadline goes before the unpin: `setDeadline` pins a row that
      // only its old deadline held on Today, and the unpin after it removes
      // that pin, so Clear When always ends in Anytime.
      schedule(id: id, date: nil)
      setDeadline(id: id, date: nil)
      moveToToday(id: id, today: false)
      clearTimeSlotIfSet(id)

    case .setDeadline(let date):
      // `setDeadline` keeps a row on Today that only its old deadline held
      // there (spec §4, the keep-on-Today rule).
      setDeadline(id: id, date: date)

    case .setTimeSlot(let start, let duration, let zone):
      setTimeSlot(id: id, startTime: start, durationMinutes: duration, timeZone: zone)
      guard let start, !start.isEmpty,
            let task = taskEntity(id: id),
            task.scheduled == nil, !task.today else { return }
      moveToToday(id: id, today: true)
    }
  }

  /// Invariant I6: a time slot needs a day. After a row leaves Today with no
  /// When date left, its time slot goes too.
  private func clearTimeSlotIfNoDay(_ id: String) {
    guard let task = taskEntity(id: id), task.scheduled == nil, !task.today else { return }
    clearTimeSlotIfSet(id)
  }

  private func clearTimeSlotIfSet(_ id: String) {
    guard taskEntity(id: id)?.startTime != nil else { return }
    setTimeSlot(id: id, startTime: nil, durationMinutes: nil)
  }
}
