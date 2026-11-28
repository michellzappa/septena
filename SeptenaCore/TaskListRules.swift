import Foundation
import SeptenaSharedCore

// List membership on Apple (C4 #250, D3 #290, ADR 0025/0027). Whether a task
// is on Today, in Upcoming, in the triage band, overdue or due today, and how
// many days it has carried over, are the shared core's answers
// (`taskViewMembership`, vectors `registry/conformance/task-views.json`): the
// same code Android and the backend run. `SeptenaTask` and `TaskEntity` read
// these properties; they hold no date rule of their own.

enum TaskListRules {

  /// The core's membership of one task on `today` at `now`. A task the core
  /// refuses (an invalid `today`) is in no list.
  static func membership(_ task: SeptenaSharedCore.TaskSnapshot, today: String,
                         now: Date) -> SeptenaSharedCore.TaskViewMembership? {
    try? taskViewMembership(task: task, today: today, now: SharedCoreValues.instant(now))
  }

  static func deadlineState(_ m: SeptenaSharedCore.TaskViewMembership?, hasDeadline: Bool) -> DeadlineState {
    switch m?.dueState {
    case "overdue": return .overdue
    case "dueToday": return .dueToday
    default:
      // An active task with a deadline and no due state has it in the future.
      return hasDeadline && (m?.matchesUpcoming == true || m?.upcomingDay != nil) ? .later : .none
    }
  }

  static func snapshot(id: String, title: String, status: String, kind: String, area: String?,
                       project: String?, created: String?, createdAt: Date, scheduled: String?,
                       deadline: String?, deferredDeadline: String?, today: Bool, todaySetOn: String?, source: String?,
                       acknowledgedAt: Date?, starred: Bool, recurrence: Recurrence?,
                       deletedAt: String?, fadedAt: Date?, assignedToOther: Bool = false,
                       endState: String? = nil) -> SeptenaSharedCore.TaskSnapshot {
    SeptenaSharedCore.TaskSnapshot(
      id: id, title: title, status: status,
      kind: kind.isEmpty ? nil : kind,
      area: area, project: project, created: created,
      createdAt: createdAt == .distantPast ? nil : SharedCoreValues.instant(createdAt),
      scheduled: scheduled, deadline: deadline, deferredDeadline: deferredDeadline,
      today: today, todaySetOn: todaySetOn,
      source: source, acknowledgedAt: acknowledgedAt.map(SharedCoreValues.instant),
      starred: starred, recurrenceUnit: recurrence?.unit.rawValue,
      deletedAt: deletedAt, fadedAt: fadedAt.map(SharedCoreValues.instant),
      startTime: nil, durationMinutes: nil, timeZone: nil,
      reminderAt: nil, reminderSnoozedUntil: nil, reminderDismissedAt: nil,
      recurrenceAfterCompletion: recurrence?.afterCompletion, recurrenceAnchorDate: nil,
      assignedToOther: assignedToOther, endState: endState)
  }
}

extension SeptenaTask {
  func listMembership(today: String = SeptenaDate.today,
                      now: Date = Date()) -> SeptenaSharedCore.TaskViewMembership? {
    TaskListRules.membership(
      TaskListRules.snapshot(
        id: id, title: title, status: status.rawValue, kind: kind, area: area, project: project,
        created: created, createdAt: createdAt, scheduled: scheduled, deadline: deadline,
        deferredDeadline: deferredDeadline, today: self.today, todaySetOn: todaySetOn, source: source, acknowledgedAt: acknowledgedAt,
        starred: starred, recurrence: recurrence, deletedAt: deletedAt, fadedAt: fadedAt,
        assignedToOther: isAssignedToOther, endState: conversationEndState),
      today: today, now: now)
  }
}

extension TaskEntity {
  func listMembership(today: String = SeptenaDate.today,
                      now: Date = Date()) -> SeptenaSharedCore.TaskViewMembership? {
    TaskListRules.membership(
      TaskListRules.snapshot(
        id: id, title: title, status: statusRaw, kind: kind, area: area, project: project,
        created: created, createdAt: createdAt, scheduled: scheduled, deadline: deadline,
        deferredDeadline: deferredDeadline, today: self.today, todaySetOn: todaySetOn, source: source, acknowledgedAt: acknowledgedAt,
        starred: starred, recurrence: recurrence, deletedAt: deletedAt, fadedAt: fadedAt,
        assignedToOther: isAssignedToOther, endState: conversationEndState),
      today: today, now: now)
  }
}

extension TaskEntity {
  /// The conversation's end state as the core reads it (`decomposed` makes
  /// an open task tracked, ADR 0066). nil when the task has no conversation,
  /// so a row without one never decodes JSON.
  var conversationEndState: String? {
    conversationJSON == nil ? nil : conversation.endState?.rawValue
  }
}

extension SeptenaTask {
  /// The conversation's end state as the core reads it (ADR 0066).
  var conversationEndState: String? { conversation.endState?.rawValue }

  /// The core's answer: an open task whose work goes on elsewhere
  /// (`endState = decomposed`, ADR 0066). It is in Review > Tracked and in no
  /// area or project list.
  /// A task with no end state skips the core call; the answer is the core's.
  var isTracked: Bool {
    conversation.endState != nil && (listMembership()?.isTracked ?? false)
  }
}

extension TaskEntity {
  /// The core's answer: this open task is tracked (ADR 0066). A row with no
  /// conversation skips the core call.
  var isTracked: Bool {
    conversationJSON != nil && (listMembership()?.isTracked ?? false)
  }
}
