import Foundation
import SwiftData

// MARK: - TaskUndo
//
// ONE undo stack for every task surface: Septena and Septask, iOS and macOS,
// SwiftUI and AppKit.
//
// Why this lives in core rather than in a shell: undo was built first inside
// `SeptaskKitTaskListController`, where it worked well and covered every
// mutator the AppKit shell offers. But that made ⌘Z a property of ONE of four
// surfaces. A user who learns on the Mac that ⌘Z takes back an accidental
// completion loses that on iPhone — and on the SwiftUI surfaces ⌘Z is not even
// inert, it reaches whatever text field holds focus, so the mistake looks
// handled when it wasn't. Undo has to belong to the write boundary, which is
// the mutator layer, not to a view controller.
//
// The mechanism stays `UndoManager` — the platform primitive, not a bespoke
// stack. That buys redo, action names, coalescing, and (on iOS) shake-to-undo
// and the three-finger gesture for free, because UIKit resolves those through
// the responder chain's `undoManager`. Each shell just has to point at this
// one:
//   • AppKit — `SeptaskKitTaskListController.undoManager` returns `TaskUndo.manager`.
//   • UIKit  — the app delegates override `undoManager` (they are the last stop
//     in the responder chain, so a focused text field still wins for typing —
//     which is correct: editing a title should undo text, not tasks).
//   • Menus  — ⌘Z / ⌘⇧Z in the Edit menu, both shells.
//
// RECORDING IS EXPLICIT, never automatic inside `TaskMutator`. That is
// deliberate: the mutators are also driven by CloudKit applies, the 30-day
// auto-purge, recurrence spawning a next occurrence, and the watch. Recording
// inside them would put sync traffic on the user's undo stack and let ⌘Z
// "undo" a change another device made. Callers say what the user did.
//
// The same reasoning makes these recorders the fade clock's stamp sites
// (docs/TASK_FADE_SPEC.md §3): schedule, move, Today, complete, cancel and
// title / notes edits call `TaskMutator.touch` here, because a recorder only
// runs for a user gesture. Undo / redo replays do not re-stamp.
@MainActor
enum TaskUndo {
  /// The process-wide manager. One instance: a second would split the stack
  /// and make ⌘Z depend on which surface had focus.
  static let manager: UndoManager = {
    let m = UndoManager()
    // Group by event, the standard interactive setting: one gesture is one
    // undo step even when it fans out to several mutator calls.
    m.groupsByEvent = true
    return m
  }()

  /// Posted after any registration, undo, or redo, so a surface can refresh an
  /// "Undo" affordance (the iOS toast) without polling.
  static let changed = Notification.Name("septena.taskUndo.changed")

  static var canUndo: Bool { manager.canUndo }
  static var canRedo: Bool { manager.canRedo }
  static var undoActionName: String { manager.undoActionName }

  static func undo() {
    guard manager.canUndo else { return }
    manager.undo()
    NotificationCenter.default.post(name: changed, object: nil)
  }

  static func redo() {
    guard manager.canRedo else { return }
    manager.redo()
    NotificationCenter.default.post(name: changed, object: nil)
  }

  /// Drop everything. Call when the underlying data is no longer the data the
  /// stack's closures were written against — a full re-import, or a sign-out.
  /// NOT on ordinary sync: a remote edit doesn't invalidate a local inverse,
  /// it just means undo may land on a changed row, which is the same risk any
  /// undo carries.
  static func removeAll() {
    manager.removeAllActions()
    NotificationCenter.default.post(name: changed, object: nil)
  }

  // MARK: - Registration

  /// Register `undoAction` as the inverse of a mutation just made. Performing
  /// it re-registers `redoAction` as ITS inverse, which is what gives redo for
  /// free — the standard symmetric-registration idiom.
  ///
  /// Both closures must be idempotent enough to survive the row having moved
  /// or changed underneath them; they replay MUTATORS, never raw writes, so
  /// the CloudKit queue and the notifications behave exactly as they would for
  /// a hand-made edit.
  static func record(name: String,
                     undo undoAction: @escaping @MainActor () -> Void,
                     redo redoAction: @escaping @MainActor () -> Void) {
    manager.setActionName(name)
    manager.registerUndo(withTarget: Token.shared) { _ in
      MainActor.assumeIsolated {
        undoAction()
        record(name: name, undo: redoAction, redo: undoAction)
        NotificationCenter.default.post(name: changed, object: nil)
      }
    }
    NotificationCenter.default.post(name: changed, object: nil)
  }

  /// `registerUndo(withTarget:)` requires an object to key the registration on,
  /// and holds it unowned. A process-lived token keeps that contract honest
  /// without tying the stack to any view's lifetime.
  private final class Token { @MainActor static let shared = Token() }

  // MARK: - Scheduling fields

  /// The scheduling fields the date / Today / repeat commands touch, captured
  /// before a change so undo can put them back. Hoisted verbatim from the
  /// AppKit shell — there is no second write path, `restore` replays the SAME
  /// mutators the forward commands use.
  struct ScheduleSnapshot {
    let id: String
    let scheduled: Date?
    let startTime: String?
    let durationMinutes: Int?
    let timeZone: String?
    let today: Bool
    let starred: Bool
    let deadline: Date?
    let deferredDeadline: String?
    /// The wait (docs/REVIEW_SPEC.md §6): Waiting On… changes it with When.
    let waitingOn: String?
    let waitingSince: String?
    let assignedTo: String?
    let recurrence: Recurrence?
    let recurrencePaused: Bool
    let reminder: TaskReminder?

    init(_ task: SeptenaTask) {
      id = task.id
      scheduled = SeptenaDate.parse(task.scheduled)
      startTime = task.startTime
      durationMinutes = task.durationMinutes
      timeZone = task.timeZone
      today = task.today
      starred = task.starred
      deadline = SeptenaDate.parse(task.deadline)
      deferredDeadline = task.deferredDeadline
      waitingOn = task.waitingOn
      waitingSince = task.waitingSince
      assignedTo = task.assignedTo
      recurrence = task.recurrence
      recurrencePaused = task.recurrencePaused
      reminder = task.reminder
    }
  }

  /// Put the captured fields back.
  ///
  /// ORDER IS LOAD-BEARING. `schedule` and `setDeadline` each carry their own
  /// Today side effects (a deadline that has landed can drop a row off Today),
  /// so the explicit Today flag is written LAST and wins. It goes through
  /// `moveToToday(id:today:)` rather than `removeFromToday` — the latter also
  /// clears an already-landed scheduled or deadline date, which would undo
  /// more than the command did.
  ///
  /// One known fidelity limit, same as the AppKit original: when the command
  /// took a row OFF Today, undo re-pins it and `todaySetOn` re-stamps to the
  /// current day, so undo restores Today MEMBERSHIP but not the row's original
  /// tenure age (the gold dial resets). A row whose Today flag the command did
  /// not change keeps its tenure: `moveToToday` is a no-op then.
  static func restore(_ snapshots: [ScheduleSnapshot],
                      using mutator: TaskMutator) {
    for snapshot in snapshots {
      mutator.schedule(id: snapshot.id, date: snapshot.scheduled)
      mutator.setTimeSlot(id: snapshot.id,
                          startTime: snapshot.startTime,
                          durationMinutes: snapshot.durationMinutes,
                          timeZone: snapshot.timeZone)
      mutator.setDeadline(id: snapshot.id, date: snapshot.deadline)
      mutator.setDeferredDeadline(id: snapshot.id, day: snapshot.deferredDeadline)
      mutator.restoreWaiting(id: snapshot.id, on: snapshot.waitingOn, since: snapshot.waitingSince)
      mutator.setAssignee(id: snapshot.id, memberID: snapshot.assignedTo)
      mutator.setRecurrence(id: snapshot.id, recurrence: snapshot.recurrence)
      if snapshot.recurrence != nil {
        mutator.setRecurrencePaused(id: snapshot.id, paused: snapshot.recurrencePaused)
      }
      mutator.setReminder(id: snapshot.id, reminder: snapshot.reminder)
      mutator.setStarred(id: snapshot.id, starred: snapshot.starred)
      mutator.moveToToday(id: snapshot.id, today: snapshot.today)
    }
  }

  /// Register undo for a change to the scheduling fields. Call AFTER the
  /// change, with `before` captured by the caller beforehand.
  ///
  /// The redo side is re-READ from the store rather than predicted, because
  /// `schedule` / `setDeadline` / `removeFromToday` each carry their own Today
  /// side effects and modelling them here would be a second copy of that logic.
  static func recordScheduleChange(name: String,
                                   before: [ScheduleSnapshot],
                                   context: ModelContext,
                                   mutator: TaskMutator) {
    guard !before.isEmpty else { return }
    let wanted = Set(before.map(\.id))
    let after = LocalCache.liveTasks(ids: wanted, in: context)
      .map(ScheduleSnapshot.init)
    guard !after.isEmpty else { return }
    let beforeByID = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let deferred = Set(after.compactMap { a -> String? in
      guard let b = beforeByID[a.id] else { return nil }
      return isDefer(from: b, to: a) ? a.id : nil
    })
    mutator.touch(ids: after.map(\.id), deferredIDs: deferred)
    record(name: name,
           undo: { restore(before, using: mutator) },
           redo: { restore(after, using: mutator) })
  }

  /// A defer (docs/TASK_FADE_SPEC.md §3): the task left Today, or its
  /// scheduled day moved later than it was. Scheduling an unscheduled task is
  /// not a defer.
  private static func isDefer(from b: ScheduleSnapshot, to a: ScheduleSnapshot) -> Bool {
    if b.today && !a.today { return true }
    if let deferred = a.deferredDeadline, deferred != b.deferredDeadline { return true }
    if let was = b.scheduled, let now = a.scheduled,
       Calendar.current.startOfDay(for: now) > Calendar.current.startOfDay(for: was) {
      return true
    }
    return false
  }

  // MARK: - Creation

  /// Undo for freshly created tasks.
  ///
  /// Redo has to RE-create rather than restore: `purge` is a real SwiftData
  /// delete, so there is no row left to bring back. Re-creating mints NEW ids,
  /// which is why both closures read the same mutable box.
  static func recordCreate(name: String,
                           ids: [String],
                           mutator: TaskMutator,
                           rebuild: @escaping @MainActor () -> [String]) {
    var current = ids
    record(name: name,
           undo: { for id in current { mutator.purge(id: id) } },
           redo: { current = rebuild() })
  }

  /// Undo for a freshly created project heading (section divider, #209).
  /// Undo purges the heading (dissolving any members); redo re-creates it in
  /// the same project at its manual position so it lands back in place.
  static func recordHeadingCreate(id: String,
                                  title: String,
                                  project: String,
                                  position: Double? = nil,
                                  mutator: TaskMutator) {
    recordCreate(
      name: RegistryActions.title(.sectionNew),
      ids: [id],
      mutator: mutator,
      rebuild: { [mutator] in
        guard let recreated = mutator.createHeading(title: title, project: project) else { return [] }
        if let position, position != 0 {
          mutator.reorder(id: recreated.id, toPosition: position)
        }
        return [recreated.id]
      })
  }

  // MARK: - Common single-value changes
  //
  // The three every surface needs. Each is a thin wrapper over `record` — the
  // point is that four shells can't each invent their own inverse for the same
  // gesture and then disagree about what ⌘Z means.

  @discardableResult
  static func toggleProjectChecklist(id: String, mutator: TaskMutator) -> Bool {
    guard let change = mutator.toggleProjectChecklist(id: id) else { return false }
    record(name: String(localized: "Check Checklist Item", comment: "Undo action name"),
           undo: { mutator.restoreChecklistFields(id: id, from: change.after, to: change.before) },
           redo: { mutator.restoreChecklistFields(id: id, from: change.before, to: change.after) })
    return true
  }

  /// Complete / uncomplete. The inverse of completing is uncompleting, which
  /// restores the row to its list; the inverse of uncompleting is completing.
  static func recordCompletion(ids: [String],
                               wasDone: Bool,
                               mutator: TaskMutator) {
    guard !ids.isEmpty else { return }
    mutator.touch(ids: ids)
    let name = wasDone
      ? String(localized: "Reopen Task", comment: "Undo action name")
      : String(localized: "Complete Task", comment: "Undo action name")
    // A plain completion of a task in Review is an Accept (docs/REVIEW_SPEC.md §4).
    let fromReview = wasDone ? [] : ids.filter(mutator.completedFromReview)
    record(name: name,
           undo: {
             for id in ids { wasDone ? mutator.complete(id: id) : mutator.uncomplete(id: id) }
             for id in fromReview {
               mutator.setConvoEndState(id: id, .needsVerify, note: mutator.conversation(id: id)?.endStateNote)
             }
           },
           redo: {
             for id in ids { wasDone ? mutator.uncomplete(id: id) : mutator.complete(id: id) }
           })
  }

  /// Accepts a task in Review (docs/REVIEW_SPEC.md §4), the one path every
  /// Accept control calls: done + `agent_assisted_done`, acknowledged, touched.
  /// Undoing reopens the task AND puts it back in Review with its check note.
  static func acceptReview(id: String, mutator: TaskMutator) {
    let previousNote = mutator.conversation(id: id)?.endStateNote
    mutator.complete(id: id)
    let acknowledged = mutator.acknowledge(id: id)
    mutator.touch(id: id)
    record(name: String(localized: "Accept Review", comment: "Undo action name"),
           undo: {
             mutator.uncomplete(id: id)
             mutator.setConvoEndState(id: id, .needsVerify, note: previousNote)
             if acknowledged { mutator.unacknowledge(id: id) }
           },
           redo: {
             mutator.complete(id: id)
             mutator.acknowledge(id: id)
           })
  }

  /// Waiting On… (docs/REVIEW_SPEC.md §6), the one path every Save calls:
  /// writes the wait and, when `scheduled` is set, the check-back When date.
  /// One undo step puts back both.
  static func setWaiting(id: String, on name: String?, scheduled: Date??,
                         context: ModelContext, mutator: TaskMutator) {
    let before = LocalCache.liveTasks(ids: [id], in: context).map(ScheduleSnapshot.init)
    mutator.setWaiting(id: id, on: name, scheduled: scheduled)
    recordScheduleChange(name: RegistryWaiting.sheetTitle,
                         before: before, context: context, mutator: mutator)
  }

  /// Got It Back (docs/REVIEW_SPEC.md §6): ends the wait on every waiting task
  /// in `ids`; the tasks stay open where they are. On a shared task you
  /// assigned to another member, takes ownership back (`assignedTo = me`).
  static func gotItBack(ids: [String], context: ModelContext, mutator: TaskMutator) {
    let tasks = LocalCache.liveTasks(ids: Set(ids), in: context).filter(\.isWaiting)
    let before = tasks.map(ScheduleSnapshot.init)
    guard !before.isEmpty else { return }
    for task in tasks {
      if TaskWaiting.isWaiting(task.waitingOn) {
        mutator.setWaiting(id: task.id, on: nil)
      }
      if task.sharedWaitingTarget != nil, let me = task.projectShare?.me {
        mutator.setAssignee(id: task.id, memberID: me)
      }
    }
    recordScheduleChange(name: RegistryActions.title(.taskGotItBack),
                         before: before, context: context, mutator: mutator)
  }

  /// Assign To (docs/PROJECT_SHARING_SPEC.md §8): sets `assignedTo` on `ids`
  /// as one undoable step.
  static func setAssignee(ids: [String], memberID: String?,
                          context: ModelContext, mutator: TaskMutator) {
    let before = LocalCache.liveTasks(ids: Set(ids), in: context).map(ScheduleSnapshot.init)
    guard !before.isEmpty else { return }
    for snapshot in before {
      mutator.setAssignee(id: snapshot.id, memberID: memberID)
    }
    recordScheduleChange(name: SharedProjects.assignTitle,
                         before: before, context: context, mutator: mutator)
  }

  /// Send a task in Review back to the agent with a note. Undoing restores
  /// the pre-send-back conversation snapshot (`needs_verify`).
  static func recordSendBack(id: String,
                             before: TaskConvo,
                             after: TaskConvo,
                             mutator: TaskMutator) {
    mutator.touch(id: id)
    record(name: String(localized: "Send Back", comment: "Undo action name"),
           undo: { mutator.restoreConvo(id: id, before) },
           redo: { mutator.restoreConvo(id: id, after) })
  }

  /// Cancel / reopen. Cancelling parks a task as "won't do" rather than
  /// finishing it, so the inverse is `uncomplete` (status → open) — the same
  /// inverse the AppKit shell already uses, hoisted here so the SwiftUI row
  /// menu can't invent a different one.
  static func recordCancel(ids: [String], mutator: TaskMutator) {
    guard !ids.isEmpty else { return }
    mutator.touch(ids: ids)
    record(name: String(localized: "Cancel Task", comment: "Undo action name"),
           undo: { for id in ids { mutator.uncomplete(id: id) } },
           redo: { for id in ids { mutator.cancel(id: id) } })
  }

  /// Soft-delete → Recently Deleted. Recoverable by design, so the inverse is
  /// simply `restore`. Permanent delete (`purge`) is deliberately NOT undoable
  /// — there is nothing left to restore, and offering ⌘Z there would lie.
  static func recordDelete(ids: [String], mutator: TaskMutator) {
    guard !ids.isEmpty else { return }
    record(name: String(localized: "Delete Task", comment: "Undo action name"),
           undo: { for id in ids { mutator.restore(id: id) } },
           redo: { for id in ids { mutator.delete(id: id) } })
  }

  // MARK: - Task fade (keep / weekly sweep — docs/TASK_FADE_SPEC.md §4 & §5)

  /// Fade & completion state captured before keeping or dropping faded tasks,
  /// so undo puts each task back into the Faded pile with its original stamps.
  struct FadedSnapshot: Equatable {
    let id: String
    let statusRaw: String
    let completedAt: String?
    let dropReason: String?
    let fadedAt: Date?
    let touchedAt: Date?
    let deferCount: Int
    let acknowledgedAt: Date?

    init(_ task: SeptenaTask) {
      id = task.id
      statusRaw = task.status.rawValue
      completedAt = task.completedAt
      dropReason = task.dropReason
      fadedAt = task.fadedAt
      touchedAt = task.touchedAt
      deferCount = task.deferCount
      acknowledgedAt = task.acknowledgedAt
    }
  }

  /// Undo for keeping one or more tasks out of the Faded pile (§4).
  static func recordKeepFaded(before: [FadedSnapshot], mutator: TaskMutator) {
    guard !before.isEmpty else { return }
    let ids = before.map(\.id)
    let name = before.count == 1
      ? String(localized: "Keep Task", comment: "Undo action name: keep faded task")
      : String(localized: "Keep Tasks", comment: "Undo action name: keep faded tasks")
    record(name: name,
           undo: { mutator.restoreFaded(before) },
           redo: { mutator.keepFaded(ids: ids) })
  }

  /// Undo for "Let the rest go" in the weekly sweep (§5) — ONE undo entry
  /// for every dropped task in the sweep.
  static func recordSweepDrop(before: [FadedSnapshot], mutator: TaskMutator) {
    guard !before.isEmpty else { return }
    let ids = before.map(\.id)
    let name = before.count == 1
      ? String(localized: "Let Task Go", comment: "Undo action name: drop faded task")
      : String(localized: "Let Faded Tasks Go", comment: "Undo action name: drop faded tasks in sweep")
    record(name: name,
           undo: { mutator.restoreFaded(before) },
           redo: { mutator.dropFaded(ids: ids) })
  }

  /// Title edit. `before` is the title as it stood when the editor opened.
  static func recordRename(id: String, before: String, after: String,
                           mutator: TaskMutator) {
    guard before != after else { return }
    mutator.touch(id: id)
    record(name: String(localized: "Rename Task", comment: "Undo action name"),
           undo: { mutator.update(id: id, title: before) },
           redo: { mutator.update(id: id, title: after) })
  }

  /// Title and notes edited together (the composer saves both at once). Only
  /// the fields that changed are replayed, so undo never writes back a field
  /// another device edited in the meantime.
  static func recordEdit(id: String,
                         beforeTitle: String, afterTitle: String,
                         beforeNotes: String?, afterNotes: String?,
                         mutator: TaskMutator) {
    let titleChanged = beforeTitle != afterTitle
    let notesChanged = (beforeNotes ?? "") != (afterNotes ?? "")
    guard titleChanged || notesChanged else { return }
    if titleChanged && !notesChanged {
      recordRename(id: id, before: beforeTitle, after: afterTitle, mutator: mutator)
      return
    }
    mutator.touch(id: id)
    func apply(title: String, notes: String?, from: String?) {
      mutator.update(id: id,
                     title: titleChanged ? title : nil,
                     notes: notesChanged ? (notes ?? "") : nil,
                     notesFrom: from ?? "")
    }
    record(name: String(localized: "Edit Task", comment: "Undo action name"),
           undo: { apply(title: beforeTitle, notes: beforeNotes, from: afterNotes) },
           redo: { apply(title: afterTitle, notes: afterNotes, from: beforeNotes) })
  }

  /// Move between area / project / heading. Captured together because the
  /// fields are one filing decision — restoring them separately would leave a
  /// row in a half-moved state on the way through. Today and the manual
  /// position ride along: filing out of the Inbox can pin a row to Today, and
  /// re-homing resets its position, so undo has to put both back too.
  struct FilingSnapshot: Equatable {
    let id: String
    /// `var` so an area-delete undo can re-file under a revived area's new
    /// id (`recordAreaDelete`).
    var area: String?
    /// `var` so a project-delete undo can re-file under a revived project's
    /// new id (`recordProjectDelete`).
    var project: String?
    let heading: String?
    let today: Bool
    let position: Double
    /// Today's own slot (#66). Leaving Today clears it, so a move that drops
    /// the row off Today has to put it back too.
    let todayPosition: Double?

    init(_ task: SeptenaTask) {
      id = task.id
      area = task.area
      project = task.project
      heading = task.heading
      today = task.today
      position = task.position
      todayPosition = task.todayPosition
    }
  }

  /// Order is load-bearing: re-homing resets `position` and filing can set
  /// Today, so both are written after the filing fields.
  static func restore(_ snapshots: [FilingSnapshot], using mutator: TaskMutator) {
    for snapshot in snapshots {
      mutator.moveToArea(id: snapshot.id, area: snapshot.area)
      mutator.moveToProject(id: snapshot.id, project: snapshot.project)
      mutator.setHeading(id: snapshot.id, heading: snapshot.heading)
      mutator.moveToToday(id: snapshot.id, today: snapshot.today)
      mutator.reorder(id: snapshot.id, toPosition: snapshot.position)
      mutator.reorderToday(id: snapshot.id, toPosition: snapshot.todayPosition)
    }
  }

  /// Snapshot of manual positions, keyed by task id. Capture it before a
  /// reorder (drag or keyboard) and pass it to `recordReorder` after.
  static func positions(of ids: some Sequence<String>,
                        in context: ModelContext) -> [String: Double] {
    orderSnapshot(of: ids, in: context, \.position)
  }

  /// Snapshot of Today slots (#66), keyed by task id; nil = never ordered on
  /// Today. Capture it before a Today reorder and pass it to
  /// `recordTodayReorder` after.
  static func todayPositions(of ids: some Sequence<String>,
                             in context: ModelContext) -> [String: Double?] {
    orderSnapshot(of: ids, in: context, \.todayPosition)
  }

  /// Undo for a manual reorder. `before` holds the positions of every row the
  /// reorder may have touched (a renumber rewrites neighbours too); the redo
  /// side is re-read from the store.
  static func recordReorder(before: [String: Double],
                            context: ModelContext,
                            mutator: TaskMutator) {
    recordOrderChange(before: before, after: positions(of: before.keys, in: context)) {
      mutator.reorder(id: $0, toPosition: $1)
    }
  }

  /// Undo for a Today reorder (#66) — `recordReorder` for `todayPosition`.
  /// The list `position` is never touched, so it needs no snapshot.
  static func recordTodayReorder(before: [String: Double?],
                                 context: ModelContext,
                                 mutator: TaskMutator) {
    recordOrderChange(before: before, after: todayPositions(of: before.keys, in: context)) {
      mutator.reorderToday(id: $0, toPosition: $1)
    }
  }

  /// A reorder snapshot for either lane, so a gesture that serves both
  /// (`TaskOrderLane`) captures and records through one call pair.
  struct ReorderSnapshot {
    let lane: TaskOrderLane
    fileprivate let list: [String: Double]
    fileprivate let today: [String: Double?]
  }

  static func reorderSnapshot(of ids: some Sequence<String>, lane: TaskOrderLane,
                              in context: ModelContext) -> ReorderSnapshot {
    switch lane {
    case .list: return ReorderSnapshot(lane: lane, list: positions(of: ids, in: context), today: [:])
    case .today: return ReorderSnapshot(lane: lane, list: [:], today: todayPositions(of: ids, in: context))
    }
  }

  static func recordReorder(_ before: ReorderSnapshot, context: ModelContext, mutator: TaskMutator) {
    switch before.lane {
    case .list: recordReorder(before: before.list, context: context, mutator: mutator)
    case .today: recordTodayReorder(before: before.today, context: context, mutator: mutator)
    }
  }

  private static func orderSnapshot<Value>(of ids: some Sequence<String>, in context: ModelContext,
                                           _ field: KeyPath<SeptenaTask, Value>) -> [String: Value] {
    let wanted = Set(ids)
    var result: [String: Value] = [:]
    for task in LocalCache.liveTasks(ids: wanted, in: context) {
      result[task.id] = task[keyPath: field]
    }
    return result
  }

  private static func recordOrderChange<Value: Equatable & Sendable>(
    before: [String: Value], after: [String: Value],
    write: @escaping @MainActor (String, Value) -> Void
  ) {
    guard !before.isEmpty, after != before else { return }
    func apply(_ map: [String: Value]) {
      for (id, value) in map { write(id, value) }
    }
    record(name: String(localized: "Reorder Tasks", comment: "Undo action name"),
           undo: { apply(before) },
           redo: { apply(after) })
  }

  static func recordMove(before: [FilingSnapshot],
                         context: ModelContext,
                         mutator: TaskMutator) {
    guard !before.isEmpty else { return }
    let wanted = Set(before.map(\.id))
    let after = LocalCache.liveTasks(ids: wanted, in: context)
      .map(FilingSnapshot.init)
    guard !after.isEmpty else { return }
    // A move into the list the task already lives in changed nothing, so it
    // gets no undo step: ⌘Z must not "undo" a no-op and skip the real action
    // behind it. Compared by id, because the caller's order and the store's
    // order differ.
    let beforeByID = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    guard after.contains(where: { beforeByID[$0.id] != $0 }) else { return }
    mutator.touch(ids: after.map(\.id))
    record(name: String(localized: "Move Task", comment: "Undo action name"),
           undo: { restore(before, using: mutator) },
           redo: { restore(after, using: mutator) })
  }

  // MARK: - Project / area delete

  /// What a project delete takes away: the project row, its section headings
  /// and every task in it (open and done), all of which go to Recently
  /// Deleted. Capture BEFORE the delete.
  struct ProjectDeleteSnapshot {
    var project: ProjectsMutator.DeletedProject
    let headings: [FilingSnapshot]
    let members: [FilingSnapshot]

    /// Live tasks the delete moves to Recently Deleted (headings excluded):
    /// the count the confirmation states.
    var taskCount: Int { members.count }
  }

  static func projectDeleteSnapshot(id: String,
                                    projects: ProjectsMutator,
                                    context: ModelContext) -> ProjectDeleteSnapshot? {
    guard let project = projects.snapshotForDelete(id: id) else { return nil }
    return ProjectDeleteSnapshot(
      project: project,
      headings: LocalCache.headings(inProject: id, in: context).map(FilingSnapshot.init),
      members: LocalCache.allTasks(in: context)
        .filter { $0.project == id }
        .map(FilingSnapshot.init))
  }

  /// Bring one deleted project back with all it held: revive the row (same
  /// id when the sync store allows it, else a new one —
  /// `ProjectsMutator.revive`), restore its headings, then its tasks, from
  /// Recently Deleted, and re-file each exactly as it stood: heading, Today,
  /// list and Today positions included. Returns the id it used.
  @discardableResult
  private static func undoProjectDelete(_ snapshot: ProjectDeleteSnapshot,
                                        projects: ProjectsMutator,
                                        mutator: TaskMutator) -> String? {
    guard let id = projects.revive(snapshot.project) else { return nil }
    // Headings first, so a member's `heading` points at a live row when it
    // comes back (`restore` clears a heading link that dangles).
    for heading in snapshot.headings { mutator.restore(id: heading.id) }
    for member in snapshot.members { mutator.restore(id: member.id) }
    let filings = (snapshot.headings + snapshot.members).map { filing -> FilingSnapshot in
      var refiled = filing
      refiled.project = id
      return refiled
    }
    restore(filings, using: mutator)
    return id
  }

  /// Undo for a project delete (`undoProjectDelete`). Redo deletes again
  /// through the same cascade. Call AFTER starting the delete.
  static func recordProjectDelete(_ snapshot: ProjectDeleteSnapshot,
                                  projects: ProjectsMutator,
                                  mutator: TaskMutator) {
    var currentID = snapshot.project.id
    record(name: String(localized: "Delete Project", comment: "Undo action name"),
           undo: {
             if let id = undoProjectDelete(snapshot, projects: projects, mutator: mutator) {
               currentID = id
             }
           },
           redo: {
             let id = currentID
             Task { @MainActor in try? await projects.delete(id: id) }
           })
  }

  /// Undo for a new project deletes it. Redo re-creates it under the SAME id,
  /// so anything later filed into it (and later undo steps) still resolve.
  /// Call AFTER the create lands, at the user gesture.
  static func recordProjectCreate(_ project: Project, projects: ProjectsMutator) {
    record(name: RegistryActions.title(.sidebarNewProject),
           undo: { Task { @MainActor in try? await projects.delete(id: project.id) } },
           redo: {
             Task { @MainActor in
               _ = try? await projects.createWithExplicitID(id: project.id, title: project.title,
                                                            area: project.area)
               if let mode = project.checklistMode {
                 try? await projects.useAsChecklist(id: project.id, mode: mode)
               }
             }
           })
  }

  /// What an area delete takes away: the area row, each of its projects (as
  /// a project delete takes it) and every task filed directly in the area.
  /// Capture BEFORE the delete.
  struct AreaDeleteSnapshot {
    let area: AreasMutator.DeletedArea
    let projects: [ProjectDeleteSnapshot]
    let members: [FilingSnapshot]

    var projectCount: Int { projects.count }
    /// Every task the delete moves to Recently Deleted: the area's own and
    /// its projects'. The count the confirmation states.
    var taskCount: Int { members.count + projects.reduce(0) { $0 + $1.taskCount } }
  }

  static func areaDeleteSnapshot(id: String,
                                 areas: AreasMutator,
                                 projects: ProjectsMutator,
                                 context: ModelContext) -> AreaDeleteSnapshot? {
    guard let area = areas.snapshotForDelete(id: id) else { return nil }
    let projectIDs = ((try? context.fetch(FetchDescriptor<ProjectEntity>(
      predicate: #Predicate { $0.area == id }
    ))) ?? []).map(\.id)
    return AreaDeleteSnapshot(
      area: area,
      projects: projectIDs.compactMap {
        projectDeleteSnapshot(id: $0, projects: projects, context: context)
      },
      members: LocalCache.allTasks(in: context)
        .filter { $0.area == id }
        .map(FilingSnapshot.init))
  }

  /// Undo for an area delete: revive the area (same id when allowed, else a
  /// new one — `AreasMutator.revive`), then each project under it as a
  /// project-delete undo does, then the area's own tasks from Recently
  /// Deleted, re-filed exactly. One step on the stack. Redo deletes again
  /// through the same cascade. Call AFTER starting the delete.
  static func recordAreaDelete(_ snapshot: AreaDeleteSnapshot,
                               areas: AreasMutator,
                               projects: ProjectsMutator,
                               mutator: TaskMutator) {
    var currentID = snapshot.area.id
    record(name: String(localized: "Delete Area", comment: "Undo action name"),
           undo: {
             guard let id = areas.revive(snapshot.area) else { return }
             currentID = id
             for var project in snapshot.projects {
               project.project.area = id
               undoProjectDelete(project, projects: projects, mutator: mutator)
             }
             for member in snapshot.members { mutator.restore(id: member.id) }
             let filings = snapshot.members.map { filing -> FilingSnapshot in
               var refiled = filing
               refiled.area = id
               return refiled
             }
             restore(filings, using: mutator)
           },
           redo: {
             let id = currentID
             Task { @MainActor in try? await areas.delete(id: id) }
           })
  }

  // MARK: - Checklists (1-level subtasks, docs/CHECKLISTS_SPEC.md)

  static func recordChecklistAdd(_ item: ChecklistItem, mutator: TaskMutator) {
    mutator.touch(ids: [item.taskId])
    var live = item
    record(name: String(localized: "Add Checklist Item", comment: "Undo action name"),
           undo: { mutator.deleteChecklistItem(id: live.id) },
           redo: {
             if let restored = mutator.restoreChecklistItem(live) { live = restored }
           })
  }

  static func recordChecklistUpdate(before: ChecklistItem, after: ChecklistItem, mutator: TaskMutator) {
    mutator.touch(ids: [before.taskId])
    record(name: before.checked != after.checked
             ? (after.checked
                ? String(localized: "Check Item", comment: "Undo action name")
                : String(localized: "Uncheck Item", comment: "Undo action name"))
             : String(localized: "Edit Checklist Item", comment: "Undo action name"),
           undo: {
             mutator.updateChecklistItem(id: before.id,
                                         title: before.title,
                                         checked: before.checked,
                                         position: before.position)
           },
           redo: {
             mutator.updateChecklistItem(id: after.id,
                                         title: after.title,
                                         checked: after.checked,
                                         position: after.position)
           })
  }

  static func recordChecklistDelete(_ item: ChecklistItem, mutator: TaskMutator) {
    mutator.touch(ids: [item.taskId])
    var live = item
    record(name: String(localized: "Delete Checklist Item", comment: "Undo action name"),
           undo: {
             if let restored = mutator.restoreChecklistItem(live) { live = restored }
           },
           redo: { mutator.deleteChecklistItem(id: live.id) })
  }

  static func recordChecklistReorder(taskID: String, beforeIDs: [String], afterIDs: [String], mutator: TaskMutator) {
    guard beforeIDs != afterIDs else { return }
    mutator.touch(ids: [taskID])
    record(name: String(localized: "Reorder Checklist", comment: "Undo action name"),
           undo: { mutator.reorderChecklistItems(taskID: taskID, orderedIDs: beforeIDs) },
           redo: { mutator.reorderChecklistItems(taskID: taskID, orderedIDs: afterIDs) })
  }

  // MARK: - References (docs/TASK_REFERENCES_SPEC.md §8)

  static func recordTaskRefAdd(_ ref: TaskRef, mutator: TaskMutator) {
    mutator.touch(ids: [ref.taskId])
    var live = ref
    record(name: String(localized: "Add Reference", comment: "Undo action name"),
           undo: { mutator.removeTaskRef(id: live.id) },
           redo: {
             if let restored = mutator.restoreTaskRef(live) { live = restored }
           })
  }

  static func recordTaskRefRemove(_ ref: TaskRef, mutator: TaskMutator) {
    mutator.touch(ids: [ref.taskId])
    var live = ref
    record(name: String(localized: "Remove Reference", comment: "Undo action name"),
           undo: {
             if let restored = mutator.restoreTaskRef(live) { live = restored }
           },
           redo: { mutator.removeTaskRef(id: live.id) })
  }

  // MARK: - Tags (docs/TAGS_SPEC.md)

  static func recordTaskTags(name: String = String(localized: "Change Tags", comment: "Undo action name"),
                             before: [String: [String]],
                             after: [String: [String]],
                             mutator: TaskMutator) {
    guard before != after else { return }
    mutator.touch(ids: Array(before.keys))
    record(name: name,
           undo: {
             for (id, tags) in before { mutator.setTaskTags(id: id, tagIDs: tags) }
           },
           redo: {
             for (id, tags) in after { mutator.setTaskTags(id: id, tagIDs: tags) }
           })
  }

  static func recordTagCreate(_ tag: TaskTag, mutator: TaskMutator) {
    var live = tag
    record(name: String(localized: "Create Tag", comment: "Undo action name"),
           undo: { mutator.deleteTag(id: live.id) },
           redo: {
             if let restored = mutator.restoreTag(live) { live = restored }
           })
  }

  static func recordTagUpdate(before: TaskTag, after: TaskTag, mutator: TaskMutator) {
    guard before != after else { return }
    record(name: String(localized: "Edit Tag", comment: "Undo action name"),
           undo: { mutator.updateTag(id: before.id, name: before.name, color: .some(before.color), position: .some(before.position)) },
           redo: { mutator.updateTag(id: after.id, name: after.name, color: .some(after.color), position: .some(after.position)) })
  }

  static func recordTagDelete(_ tag: TaskTag, mutator: TaskMutator) {
    var live = tag
    record(name: String(localized: "Delete Tag", comment: "Undo action name"),
           undo: {
             if let restored = mutator.restoreTag(live) { live = restored }
           },
           redo: { mutator.deleteTag(id: live.id) })
  }

  // MARK: - Attachments (docs/ATTACHMENTS_MAC_PARITY_SPEC.md)

  static func recordAttachmentDelete(_ snapshot: TaskAttachmentSnapshot,
                                     store: TaskAttachmentStore,
                                     mutator: TaskMutator) {
    mutator.touch(ids: [snapshot.taskID])
    var live = snapshot
    record(name: String(localized: "Delete Attachment", comment: "Undo action name"),
           undo: {
             if let restored = store.restore(live) { live = restored }
           },
           redo: {
             if let next = store.removeForUndo(id: live.id) { live = next }
           })
  }

  // MARK: - Project & area notes (proposals & history restore, #123)

  static func recordProjectNotesRestore(id: String,
                                        before: String?,
                                        after: String?,
                                        projects: ProjectsMutator) {
    guard (before ?? "") != (after ?? "") else { return }
    record(name: ContainerNotesCopy.undoRestoreName,
           undo: { Task { @MainActor in try? await projects.setNotes(id: id, notes: before, from: after ?? "") } },
           redo: { Task { @MainActor in try? await projects.setNotes(id: id, notes: after, from: before ?? "") } })
  }

  static func recordAreaNotesRestore(id: String,
                                     before: String?,
                                     after: String?,
                                     areas: AreasMutator) {
    guard (before ?? "") != (after ?? "") else { return }
    record(name: ContainerNotesCopy.undoRestoreName,
           undo: { Task { @MainActor in try? await areas.setContext(id: id, context: before) } },
           redo: { Task { @MainActor in try? await areas.setContext(id: id, context: after) } })
  }

  static func recordProjectProposalDecision(id: String,
                                            accepted: Bool,
                                            beforeNotes: String?,
                                            afterNotes: String?,
                                            proposal: NotesProposal,
                                            projects: ProjectsMutator) {
    let name = accepted ? ContainerNotesCopy.undoAcceptProposalName : ContainerNotesCopy.undoRejectProposalName
    record(name: name,
           undo: {
             Task { @MainActor in
               try? await projects.restoreNotesState(id: id, notes: beforeNotes, proposal: proposal)
             }
           },
           redo: {
             Task { @MainActor in
               try? await projects.restoreNotesState(id: id, notes: afterNotes, proposal: nil)
             }
           })
  }

  static func recordAreaProposalDecision(id: String,
                                         accepted: Bool,
                                         beforeNotes: String?,
                                         afterNotes: String?,
                                         proposal: NotesProposal,
                                         areas: AreasMutator) {
    let name = accepted ? ContainerNotesCopy.undoAcceptProposalName : ContainerNotesCopy.undoRejectProposalName
    record(name: name,
           undo: {
             Task { @MainActor in
               try? await areas.restoreNotesState(id: id, context: beforeNotes, proposal: proposal)
             }
           },
           redo: {
             Task { @MainActor in
               try? await areas.restoreNotesState(id: id, context: afterNotes, proposal: nil)
             }
           })
  }
}
