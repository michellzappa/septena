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
    let today: Bool
    let deadline: Date?
    let recurrence: Recurrence?
    let recurrencePaused: Bool

    init(_ task: SeptenaTask) {
      id = task.id
      scheduled = SeptenaDate.parse(task.scheduled)
      today = task.today
      deadline = SeptenaDate.parse(task.deadline)
      recurrence = task.recurrence
      recurrencePaused = task.recurrencePaused
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
  /// One known fidelity limit, same as the AppKit original: `todaySetOn`
  /// re-stamps to the current day, so undo restores Today MEMBERSHIP but not
  /// the row's original tenure age (the gold dial resets).
  static func restore(_ snapshots: [ScheduleSnapshot],
                      using mutator: TaskMutator) {
    for snapshot in snapshots {
      mutator.schedule(id: snapshot.id, date: snapshot.scheduled)
      mutator.setDeadline(id: snapshot.id, date: snapshot.deadline)
      mutator.setRecurrence(id: snapshot.id, recurrence: snapshot.recurrence)
      if snapshot.recurrence != nil {
        mutator.setRecurrencePaused(id: snapshot.id, paused: snapshot.recurrencePaused)
      }
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
    let after = LocalCache.allTasks(in: context)
      .filter { wanted.contains($0.id) }
      .map(ScheduleSnapshot.init)
    guard !after.isEmpty else { return }
    record(name: name,
           undo: { restore(before, using: mutator) },
           redo: { restore(after, using: mutator) })
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

  // MARK: - Common single-value changes
  //
  // The three every surface needs. Each is a thin wrapper over `record` — the
  // point is that four shells can't each invent their own inverse for the same
  // gesture and then disagree about what ⌘Z means.

  /// Complete / uncomplete. The inverse of completing is uncompleting, which
  /// restores the row to its list; the inverse of uncompleting is completing.
  static func recordCompletion(ids: [String],
                               wasDone: Bool,
                               mutator: TaskMutator) {
    guard !ids.isEmpty else { return }
    let name = wasDone
      ? String(localized: "Reopen Task", comment: "Undo action name")
      : String(localized: "Complete Task", comment: "Undo action name")
    record(name: name,
           undo: {
             for id in ids { wasDone ? mutator.complete(id: id) : mutator.uncomplete(id: id) }
           },
           redo: {
             for id in ids { wasDone ? mutator.uncomplete(id: id) : mutator.complete(id: id) }
           })
  }

  /// Cancel / reopen. Cancelling parks a task as "won't do" rather than
  /// finishing it, so the inverse is `uncomplete` (status → open) — the same
  /// inverse the AppKit shell already uses, hoisted here so the SwiftUI row
  /// menu can't invent a different one.
  static func recordCancel(ids: [String], mutator: TaskMutator) {
    guard !ids.isEmpty else { return }
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

  /// Title edit. `before` is the title as it stood when the editor opened.
  static func recordRename(id: String, before: String, after: String,
                           mutator: TaskMutator) {
    guard before != after else { return }
    record(name: String(localized: "Rename Task", comment: "Undo action name"),
           undo: { mutator.update(id: id, title: before) },
           redo: { mutator.update(id: id, title: after) })
  }

  /// Move between area / project / heading. Captured as a triple because the
  /// three fields are one filing decision — restoring them separately would
  /// leave a row in a half-moved state on the way through.
  struct FilingSnapshot {
    let id: String
    let area: String?
    let project: String?
    let heading: String?

    init(_ task: SeptenaTask) {
      id = task.id
      area = task.area
      project = task.project
      heading = task.heading
    }
  }

  static func restore(_ snapshots: [FilingSnapshot], using mutator: TaskMutator) {
    for snapshot in snapshots {
      mutator.moveToArea(id: snapshot.id, area: snapshot.area)
      mutator.moveToProject(id: snapshot.id, project: snapshot.project)
      mutator.setHeading(id: snapshot.id, heading: snapshot.heading)
    }
  }

  static func recordMove(before: [FilingSnapshot],
                         context: ModelContext,
                         mutator: TaskMutator) {
    guard !before.isEmpty else { return }
    let wanted = Set(before.map(\.id))
    let after = LocalCache.allTasks(in: context)
      .filter { wanted.contains($0.id) }
      .map(FilingSnapshot.init)
    guard !after.isEmpty else { return }
    record(name: String(localized: "Move Task", comment: "Undo action name"),
           undo: { restore(before, using: mutator) },
           redo: { restore(after, using: mutator) })
  }
}
