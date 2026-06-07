import SwiftUI

// The editable shape of a task, shared by every create/edit surface (the
// floating composer, the row editor, the drawer). One struct so the
// Things-style save mapping — scheduling *today* pins the `today` flag and
// clears the planning date; a project derives its area — lives in exactly one
// place instead of being re-derived in each sheet.

struct TaskDraft {
  var title: String = ""
  var notes: String = ""
  var onToday: Bool = false
  var scheduled: Date? = nil
  var deadline: Date? = nil
  var recurrence: Recurrence? = nil
  var areaId: String? = nil
  var projectId: String? = nil
  /// Create-time status seed (e.g. "someday" when composing from the Someday
  /// list). Ignored on update — status changes there go through dedicated
  /// actions (Someday / Cancel).
  var initialStatus: String? = nil

  var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
  var trimmedNotes: String { notes.trimmingCharacters(in: .whitespacesAndNewlines) }
  var canSave: Bool { !trimmedTitle.isEmpty }

  init() {}

  /// Seed defaults from the list you're composing in: Today pins today,
  /// Upcoming schedules tomorrow, Someday demotes, a Project / Area files it
  /// there, everything else lands in the Inbox.
  init(filter: TaskFilter) {
    switch filter {
    case .today:           onToday = true
    case .upcoming:        scheduled = Calendar.current.date(byAdding: .day, value: 1, to: .now)
    case .someday:         initialStatus = "someday"
    case .project(let id): projectId = id
    case .area(let id):    areaId = id
    case .inbox, .unscheduled, .logbook: break
    }
  }

  /// Seed from an existing task for editing.
  init(task: SeptenaTask) {
    title = task.title
    notes = task.notes ?? ""
    onToday = task.today
    scheduled = SeptenaDate.parse(task.scheduled)
    deadline = SeptenaDate.parse(task.deadline)
    recurrence = task.recurrence
    areaId = task.area
    projectId = task.project
  }

  // MARK: - Things-style scheduled mapping

  /// Scheduling for *today* (or flipping the explicit Today toggle) pins the
  /// `today` flag and clears the stored planning date; a future date stores
  /// the date with today=false.
  private var schedIsToday: Bool {
    scheduled.map { Calendar.current.isDateInToday($0) } ?? false
  }
  var pinToday: Bool { onToday || schedIsToday }
  private var storedScheduled: Date? { schedIsToday ? nil : scheduled }

  // MARK: - Commit

  /// Create a brand-new task. Recurrence isn't a `create` parameter, so it's
  /// applied as a follow-up when set.
  @MainActor
  @discardableResult
  func create(via mutator: TaskMutator) -> SeptenaTask {
    let task = mutator.create(
      title: trimmedTitle,
      area: areaId,
      project: projectId,
      scheduled: storedScheduled,
      due: deadline,
      today: pinToday,
      notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
      status: initialStatus
    )
    if let recurrence { mutator.setRecurrence(id: task.id, recurrence: recurrence) }
    return task
  }

  /// Apply edits to an existing task, mirroring the original `EditTaskSheet`
  /// save: only fire the mutations whose value actually changed.
  @MainActor
  func update(_ original: SeptenaTask, via mutator: TaskMutator) {
    let id = original.id
    if trimmedTitle != original.title || notes != (original.notes ?? "") {
      mutator.update(id: id, title: trimmedTitle, notes: notes)
    }
    mutator.schedule(id: id, date: storedScheduled)
    mutator.moveToToday(id: id, today: pinToday)
    if deadline != SeptenaDate.parse(original.deadline) {
      mutator.setDue(id: id, date: deadline)
    }
    if recurrence != original.recurrence {
      mutator.setRecurrence(id: id, recurrence: recurrence)
    }
    if projectId != original.project { mutator.moveToProject(id: id, project: projectId) }
    if areaId != original.area { mutator.moveToArea(id: id, area: areaId) }
  }

  // MARK: - Pill value labels

  /// Resolve the "List" label (project wins, else area, else Inbox).
  func listLabel(areas: [Area], projects: [Project]) -> String {
    if let projectId, let p = projects.first(where: { $0.id == projectId }) { return p.title }
    if let areaId, let a = areas.first(where: { $0.id == areaId }) { return a.title }
    return "Inbox"
  }
}
