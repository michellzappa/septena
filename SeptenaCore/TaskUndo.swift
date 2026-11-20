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
  /// One known fidelity limit, same as the AppKit original: when the command
  /// took a row OFF Today, undo re-pins it and `todaySetOn` re-stamps to the
  /// current day, so undo restores Today MEMBERSHIP but not the row's original
  /// tenure age (the gold dial resets). A row whose Today flag the command did
  /// not change keeps its tenure: `moveToToday` is a no-op then.
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
    func apply(title: String, notes: String?) {
      mutator.update(id: id,
                     title: titleChanged ? title : nil,
                     notes: notesChanged ? (notes ?? "") : nil)
    }
    record(name: String(localized: "Edit Task", comment: "Undo action name"),
           undo: { apply(title: beforeTitle, notes: beforeNotes) },
           redo: { apply(title: afterTitle, notes: afterNotes) })
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
    for task in LocalCache.allTasks(in: context) where wanted.contains(task.id) {
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
    let after = LocalCache.allTasks(in: context)
      .filter { wanted.contains($0.id) }
      .map(FilingSnapshot.init)
    guard !after.isEmpty else { return }
    // A move into the list the task already lives in changed nothing, so it
    // gets no undo step: ⌘Z must not "undo" a no-op and skip the real action
    // behind it. Compared by id, because the caller's order and the store's
    // order differ.
    let beforeByID = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    guard after.contains(where: { beforeByID[$0.id] != $0 }) else { return }
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
}

// MARK: - Delete confirmation copy

/// The confirmation every shell shows before an area / project delete: what
/// goes, how many tasks go with it, where they go, and that ⌘Z brings it all
/// back. One wording for the AppKit sheet and the SwiftUI dialogs.
@MainActor
enum ContainerDeleteCopy {
  struct Text {
    let title: String
    let message: String
  }

  static func project(id: String, title: String, context: ModelContext) -> Text {
    let tasks = LocalCache.allTasks(in: context).filter { $0.project == id }.count
    let name = title.isEmpty ? String(localized: "Project", comment: "Delete confirm: untitled project") : title
    let head: String
    if tasks == 0 {
      head = String(localized: "Delete “\(name)”?", comment: "Delete project confirm: no tasks")
    } else {
      head = String(localized: "Delete “\(name)” and its \(taskPhrase(tasks))?",
                    comment: "Delete project confirm. Argument: “3 tasks”")
    }
    return Text(title: head, message: message(tasks: tasks))
  }

  static func area(id: String, title: String, context: ModelContext) -> Text {
    let projectIDs = Set(((try? context.fetch(FetchDescriptor<ProjectEntity>(
      predicate: #Predicate { $0.area == id }
    ))) ?? []).map(\.id))
    let tasks = LocalCache.allTasks(in: context).filter {
      $0.area == id || $0.project.map(projectIDs.contains) == true
    }.count
    let name = title.isEmpty ? String(localized: "Area", comment: "Delete confirm: untitled area") : title
    let head: String
    switch (projectIDs.isEmpty, tasks == 0) {
    case (true, true):
      head = String(localized: "Delete “\(name)”?", comment: "Delete area confirm: empty")
    case (true, false):
      head = String(localized: "Delete “\(name)” and its \(taskPhrase(tasks))?",
                    comment: "Delete area confirm, no projects. Argument: “3 tasks”")
    case (false, true):
      head = String(localized: "Delete “\(name)” and its \(projectPhrase(projectIDs.count))?",
                    comment: "Delete area confirm, no tasks. Argument: “2 projects”")
    case (false, false):
      head = String(localized: "Delete “\(name)”, its \(projectPhrase(projectIDs.count)) and \(taskPhrase(tasks))?",
                    comment: "Delete area confirm. Arguments: “2 projects”, “3 tasks”")
    }
    return Text(title: head, message: message(tasks: tasks))
  }

  private static func message(tasks: Int) -> String {
    tasks == 0
      ? String(localized: "You can undo this.", comment: "Delete area/project confirm body, no tasks")
      : String(localized: "The tasks move to Recently Deleted. You can undo this.",
               comment: "Delete area/project confirm body")
  }

  private static func taskPhrase(_ n: Int) -> String {
    n == 1 ? String(localized: "1 task", comment: "Delete confirm count")
           : String(localized: "\(n) tasks", comment: "Delete confirm count")
  }

  private static func projectPhrase(_ n: Int) -> String {
    n == 1 ? String(localized: "1 project", comment: "Delete confirm count")
           : String(localized: "\(n) projects", comment: "Delete confirm count")
  }
}
