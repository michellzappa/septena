import Foundation
import SwiftData
import SeptenaSharedCore

// The write half of the date actions (D3, #290, ADR 0027).
//
// The shared core (`task_dates.rs`) decides every date field for a date
// action: When date, deadline, Today pin and its stamp, time slot, the
// reminder that follows a moved When date, the fixed-repeat slot and the
// agent cue. This file reads the row into a core snapshot, asks the core for
// the patch and writes the changed fields in one save. No date rule lives
// here. A rule change goes into the core and its fixture
// (`registry/conformance/task-dates.json`), never into Swift.

extension CloudKitTasksBackend {

  /// Apply one date action to one row. `updatesSeries` is the user's
  /// "the whole series" answer for a fixed repeat: after the core moved the
  /// row's slot, the other open copies of the series move with it. Returns
  /// false when the row is missing, the core rejected the input, or the
  /// save rolled back.
  @discardableResult
  func applyDateAction(id: String, action: TaskDateAction,
                       mode: RecurrenceRescheduleMode) -> Bool {
    guard let entity = fetch(id: id) else { return false }
    let updatesSeries = mode == .updateRule
    let now = Date()
    let patch: SeptenaSharedCore.TaskDatePatch
    do {
      patch = try SeptenaSharedCore.applyDateAction(
        task: entity.coreSnapshot, action: action.coreAction(mode: mode),
        today: SeptenaDate.today, now: SharedCoreValues.instant(now))
    } catch {
      SeptenaLog.error("[TasksBackend] date action rejected id=\(id) action=\(action)", error)
      return false
    }
    guard !patch.changed.isEmpty else { return true }
    entity.write(patch, acknowledgedAt: now)
    entity.pendingSync = true
    let landed = commitAndPush(entity, op: "dateAction(\(patch.changed.joined(separator: ",")))")
    if landed, updatesSeries,
       patch.changed.contains("recurrenceAnchorDate"),
       let rule = entity.recurrence, !rule.afterCompletion,
       let anchor = entity.recurrenceAnchorDate {
      rebaseFixedSeries(from: entity, rule: rule, anchor: anchor, displayed: entity.scheduled)
    }
    return landed
  }
}

extension ChecklistItem {

  /// Deterministic ID for a checklist item copied onto a spawned recurring
  /// occurrence, so phone and agent completions converge. The shared core's
  /// rule (`checklist_occurrence_id`, the same code the backend runs).
  static func occurrenceItemID(newTaskID: String, index: Int, sourceItemID: String) -> String {
    SeptenaSharedCore.checklistOccurrenceId(newTaskId: newTaskID, index: UInt32(clamping: index),
                                            sourceItemId: sourceItemID)
  }
}

extension TaskDateAction {

  /// The core's form of the action. Days go as `YYYY-MM-DD` in the app's
  /// calendar.
  func coreAction(mode: RecurrenceRescheduleMode) -> SeptenaSharedCore.DateAction {
    let coreMode: SeptenaSharedCore.RescheduleMode = mode == .updateRule ? .updateRule : .makeException
    switch self {
    case .putOnToday:
      return .putOnToday(mode: coreMode)
    case .scheduleFor(let day):
      return .scheduleFor(day: SeptenaDate.format(day) ?? "", mode: coreMode)
    case .removeFromToday:
      return .removeFromToday
    case .clearWhenDate:
      return .clearWhenDate
    case .clearWhen:
      return .clearWhen
    case .setDeadline(let day):
      return .setDeadline(day: day.flatMap { SeptenaDate.format($0) })
    case .setTimeSlot(let start, let minutes, let zone):
      return .setTimeSlot(startTime: start, durationMinutes: minutes.map { Int32(clamping: $0) },
                          timeZone: zone)
    }
  }
}

extension TaskEntity {

  /// The row as the core reads it. Instants are ISO-8601 strings.
  var coreSnapshot: SeptenaSharedCore.TaskSnapshot {
    SeptenaSharedCore.TaskSnapshot(
      id: id,
      title: title,
      status: statusRaw,
      kind: kind.isEmpty ? nil : kind,
      area: area,
      project: project,
      created: created,
      createdAt: createdAt == .distantPast ? nil : SharedCoreValues.instant(createdAt),
      scheduled: scheduled,
      deadline: deadline,
      deferredDeadline: deferredDeadline,
      today: today,
      todaySetOn: todaySetOn,
      source: source,
      acknowledgedAt: acknowledgedAt.map(SharedCoreValues.instant),
      starred: starred,
      recurrenceUnit: recurrence?.unit.rawValue,
      deletedAt: deletedAt,
      fadedAt: fadedAt.map(SharedCoreValues.instant),
      startTime: startTime,
      durationMinutes: durationMinutes.map { Int32(clamping: $0) },
      timeZone: timeZone,
      reminderAt: reminderAt,
      reminderSnoozedUntil: reminderSnoozedUntil,
      reminderDismissedAt: reminderDismissedAt,
      recurrenceAfterCompletion: recurrence?.afterCompletion,
      recurrenceAnchorDate: recurrenceAnchorDate,
      assignedToOther: isAssignedToOther)
  }

  /// Write the fields the core changed. The core stamps the agent cue with
  /// the `now` the caller passed, so the row keeps that `Date` exactly.
  fileprivate func write(_ patch: SeptenaSharedCore.TaskDatePatch, acknowledgedAt now: Date) {
    let f = patch.fields
    for name in patch.changed {
      switch name {
      case "scheduled": scheduled = f.scheduled
      case "deadline": deadline = f.deadline
      case "deferredDeadline": deferredDeadline = f.deferredDeadline
      case "today": today = f.today
      case "todaySetOn": todaySetOn = f.todaySetOn
      case "startTime": startTime = f.startTime
      case "durationMinutes": durationMinutes = f.durationMinutes.map(Int.init)
      case "timeZone": timeZone = f.timeZone
      case "reminderAt": reminderAt = f.reminderAt
      case "reminderSnoozedUntil": reminderSnoozedUntil = f.reminderSnoozedUntil
      case "reminderDismissedAt": reminderDismissedAt = f.reminderDismissedAt
      case "recurrenceAnchorDate": recurrenceAnchorDate = f.recurrenceAnchorDate
      case "acknowledgedAt": acknowledgedAt = f.acknowledgedAt == nil ? nil : now
      default:
        SeptenaLog.error("[TasksBackend] date patch has an unknown field \(name)", nil)
      }
    }
  }
}
