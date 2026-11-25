import SwiftUI
import SwiftData
import Foundation

// The editable shape of a task, shared by every create/edit surface (the
// floating composer, the row editor, the drawer). One struct so the
// Things-style save mapping — scheduling *today* pins the `today` flag and
// clears the planning date; a project derives its area — lives in exactly one
// place instead of being re-derived in each sheet.

struct TaskDraft: Equatable {
  var title: String = ""
  var notes: String = ""
  var onToday: Bool = false
  var starred: Bool = false
  var scheduled: Date? = nil
  var startTime: String? = nil
  var durationMinutes: Int? = nil
  var deadline: Date? = nil
  var reminder: TaskReminder? = nil
  var recurrence: Recurrence? = nil
  var areaId: String? = nil
  var projectId: String? = nil

  var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
  var trimmedNotes: String { notes.trimmingCharacters(in: .whitespacesAndNewlines) }
  var canSave: Bool { !trimmedTitle.isEmpty }

  init() {}

  /// Seed defaults from the list you're composing in: Today pins today,
  /// Upcoming schedules tomorrow, a Project / Area files it there, everything
  /// else lands in the Inbox.
  @MainActor
  init(filter: TaskFilter) {
    switch filter {
    case .today:           onToday = true
    // `DayClock.appNow`, not `.now`: a debug time-travel offset must move
    // the "tomorrow" default too, like every other day read.
    case .upcoming:        scheduled = Calendar.current.date(byAdding: .day, value: 1, to: DayClock.appNow)
    case .project(let id): projectId = id
    case .area(let id):    areaId = id
    case .starred:         starred = true
    case .triage, .agent, .unscheduled, .repeating, .logbook, .faded, .recentlyDeleted: break
    }
  }

  /// Seed from an existing task for editing.
  init(task: SeptenaTask) {
    title = task.title
    notes = task.notes ?? ""
    onToday = task.today
    starred = task.starred
    scheduled = SeptenaDate.parse(task.scheduled)
    startTime = task.startTime
    durationMinutes = task.durationMinutes
    deadline = SeptenaDate.parse(task.deadline)
    reminder = task.reminder
    recurrence = task.recurrence
    areaId = task.area
    projectId = task.project
  }

  // MARK: - When mutations (mutually exclusive)

  mutating func setToday() { onToday = true; scheduled = nil }
  mutating func setScheduled(_ date: Date) {
    let day = Calendar.current.startOfDay(for: date)
    if Calendar.current.isDateInToday(day) { setToday() }
    else { onToday = false; scheduled = day }
  }
  mutating func clearWhen() {
    onToday = false
    scheduled = nil
    startTime = nil
    durationMinutes = nil
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
  func create(via mutator: TaskMutator, deferPush: Bool = false, atBottom: Bool = false) -> SeptenaTask {
    let task = mutator.create(
      title: trimmedTitle,
      area: areaId,
      project: projectId,
      scheduled: storedScheduled,
      deadline: deadline,
      today: pinToday,
      notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
      deferPush: deferPush,
      atBottom: atBottom
    )
    if let recurrence { mutator.setRecurrence(id: task.id, recurrence: recurrence) }
    if let reminder {
      mutator.setReminder(id: task.id, reminder: reminder)
      Task { await TaskReminderScheduler.shared.requestAuthorizationIfNeeded() }
    }
    if starred {
      mutator.setStarred(id: task.id, starred: true)
    }
    if let startTime {
      mutator.apply(.setTimeSlot(startTime: startTime, durationMinutes: durationMinutes,
                                 timeZone: nil), to: task.id)
    }
    return task
  }

  /// Apply edits to an existing task: only fire the mutations whose value
  /// actually changed (the Things-style save the composer commits on Done).
  ///
  /// With `undoContext`, the save also lands on the shared `TaskUndo` stack:
  /// title/notes as one edit, the When / Deadline / Repeat fields as one
  /// schedule change, project / area as one move. `groupsByEvent` folds them
  /// into one ⌘Z step. Pass nil for saves that are not a user edit of an
  /// existing task (the inline-create placeholder's first title).
  ///
  /// Returns false when the title/notes write was attempted and did NOT land
  /// (rolled-back save, or the row has gone from the store). The composer uses
  /// it to decide whether the draft may be marked as persisted — marking a
  /// failed write as saved is what let a typed title be dropped and the row
  /// then purged as untitled. The placement writes below are not part of the
  /// result: losing one of those leaves a visible, re-editable row.
  @MainActor
  @discardableResult
  func update(_ original: SeptenaTask, via mutator: TaskMutator,
              undoContext: ModelContext? = nil) -> Bool {
    let id = original.id
    var titleWriteLanded = true
    // Compare against the original run through the SAME normalization (a draft
    // seeded from it), so every field is normalized-vs-normalized. The When /
    // Today writes used to be unconditional, which — because `storedScheduled`
    // collapses a "scheduled today" date into the pin — silently rewrote a
    // planned-today task into a pinned-today one (and churned CloudKit) every
    // time you merely opened and closed the editor. Now a true no-op peek
    // writes nothing.
    let prior = TaskDraft(task: original)
    // Compare trimmed-vs-trimmed. Comparing the trimmed draft against the RAW
    // stored value meant a task whose title or notes carried stray leading /
    // trailing whitespace read as changed on every save — an endless no-op
    // write that churned CloudKit each time the editor merely opened and closed.
    //
    // Title and notes are written independently: the draft was seeded when the
    // editor opened, so writing the UNCHANGED field too would overwrite an edit
    // another device made to it in the meantime.
    let titleChanged = trimmedTitle != prior.trimmedTitle
    let notesChanged = trimmedNotes != prior.trimmedNotes
    if titleChanged || notesChanged {
      titleWriteLanded = mutator.update(id: id,
                                        title: titleChanged ? trimmedTitle : nil,
                                        notes: notesChanged ? trimmedNotes : nil)
      // The undo entry describes a write that happened: skip it when the
      // write did not land.
      if undoContext != nil, titleWriteLanded {
        TaskUndo.recordEdit(id: id,
                            beforeTitle: original.title,
                            afterTitle: titleChanged ? trimmedTitle : original.title,
                            beforeNotes: original.notes,
                            afterNotes: notesChanged ? trimmedNotes : original.notes,
                            mutator: mutator)
      }
    }

    // Snapshots for undo, taken from the task as it stood when the editor
    // opened (the same baseline the change detection above uses).
    let scheduleBefore = TaskUndo.ScheduleSnapshot(original)
    let filingBefore = TaskUndo.FilingSnapshot(original)
    let scheduleChanged = storedScheduled != prior.storedScheduled
      || startTime != prior.startTime
      || durationMinutes != prior.durationMinutes
      || pinToday != prior.pinToday
      || starred != prior.starred
      || deadline != prior.deadline
      || reminder != prior.reminder
      || recurrence != prior.recurrence
    let filingChanged = projectId != prior.projectId
      || (projectId == nil && areaId != prior.areaId)

    // Date fields go through the spec §4 actions (`TaskDateActions`), in
    // When → deadline → time slot order, so each sees the fields before it.
    // Turning Today off here is "clear the When date" (A5), not Remove from
    // Today (A3): the deadline is its own field in this editor, and A3 would
    // delete an overdue one behind the user's back.
    if storedScheduled != prior.storedScheduled || pinToday != prior.pinToday {
      if pinToday {
        mutator.apply(.putOnToday, to: id)
      } else if let storedScheduled {
        mutator.apply(.scheduleFor(storedScheduled), to: id)
      } else {
        mutator.apply(.clearWhenDate, to: id)
      }
    }
    if deadline != prior.deadline {
      mutator.apply(.setDeadline(deadline), to: id)
    }
    if reminder != prior.reminder {
      mutator.setReminder(id: id, reminder: reminder)
      if reminder != nil {
        Task { await TaskReminderScheduler.shared.requestAuthorizationIfNeeded() }
      }
    }
    if recurrence != prior.recurrence {
      mutator.setRecurrence(id: id, recurrence: recurrence)
    }
    if starred != prior.starred {
      mutator.setStarred(id: id, starred: starred)
    }
    if startTime != prior.startTime || durationMinutes != prior.durationMinutes {
      mutator.apply(.setTimeSlot(startTime: startTime, durationMinutes: durationMinutes,
                                 timeZone: nil), to: id)
    }
    // Project and area are mutually exclusive: a project owns its area, and the
    // backend's `moveToProject` clears area (create() does the same via
    // `effectiveArea = project != nil ? nil : area`). The composer's list picker
    // carries the project's *parent-area* id for its breadcrumb, so when a
    // project is chosen we must NOT also fire `moveToArea` — it would run after
    // `moveToProject` and clobber the just-set project back to its parent area.
    // (Invisible for area-less projects, whose pick carries a nil areaId — which
    // is why this only bit nested projects.)
    if projectId != prior.projectId { mutator.moveToProject(id: id, project: projectId) }
    if projectId == nil, areaId != prior.areaId { mutator.moveToArea(id: id, area: areaId) }

    guard let undoContext else { return titleWriteLanded }
    if scheduleChanged {
      TaskUndo.recordScheduleChange(
        name: String(localized: "Change Schedule", comment: "Undo action name"),
        before: [scheduleBefore], context: undoContext, mutator: mutator)
    }
    if filingChanged {
      TaskUndo.recordMove(before: [filingBefore], context: undoContext, mutator: mutator)
    }
    return titleWriteLanded
  }

  /// Did this edit change a *placement* field — project, area, scheduled, due,
  /// or Today? These are exactly the fields that take a row out of the triage
  /// band (`isInTriageBand`), so a change here is a ratification (the editor
  /// uses it to decide whether saving should clear an agent proposal from the
  /// Inbox). A pure title / notes edit returns false: editing the text of a
  /// loose capture isn't filing it.
  func placementChanged(from original: SeptenaTask) -> Bool {
    // Normalize the original through the same mapping before comparing —
    // otherwise the lossy `pinToday` / `storedScheduled` collapse makes a
    // "scheduled today" task look changed on a bare peek, which would ratify an
    // agent proposal (acknowledge → leave the Inbox) with no decision made.
    let prior = TaskDraft(task: original)
    return pinToday != prior.pinToday
      || storedScheduled != prior.storedScheduled
      || deadline != prior.deadline
      || projectId != prior.projectId
      || areaId != prior.areaId
  }

  // MARK: - Dirty tracking (drives the editor's Cancel / discard guard)

  /// Dirty tracking for BOTH create and edit: has the user changed anything from
  /// the snapshot taken right after seeding (the list defaults for create, the
  /// task for edit)? A whole-struct `Equatable` compare — no field-by-field
  /// normalization to get subtly wrong — so an untouched composer just closes and
  /// only a real change prompts "Discard…". (An earlier `differs(from: task)`
  /// that rebuilt a normalized baseline kept reading an untouched edit as dirty.)
  func differs(fromSeed seed: TaskDraft) -> Bool { self != seed }

  // MARK: - Pill value labels

  /// Resolve the "List" label (project wins, else area, else Inbox).
  func listLabel(areas: [Area], projects: [Project]) -> String {
    if let projectId, let p = projects.first(where: { $0.id == projectId }) { return p.title }
    if let areaId, let a = areas.first(where: { $0.id == areaId }) { return a.title }
    return TaskFilter.triage.title
  }
}

// MARK: - Quick-entry parsing

/// One thing detected in a freeform task title — a date phrase or a
/// `#project` / `@area` / `!today` token — paired with the exact substring to
/// strip from the title once it's applied. Powers the composer's quick-entry
/// suggestion chips.
struct DetectedToken: Identifiable {
  enum Kind {
    case today
    case date(Date)
    case project(id: String, title: String)
    case area(id: String, title: String)
  }
  let id = UUID()
  let kind: Kind
  /// The matched text to remove from the title when this token is applied.
  let phrase: String

  var displayText: String {
    switch kind {
    case .today:               return "Today"
    case .date(let d):         return Self.dateLabel(d)
    case .project(_, let t):   return t
    case .area(_, let t):      return t
    }
  }

  var icon: String {
    switch kind {
    case .today:    return "sun.max"
    case .date:     return "calendar"
    case .project:  return "number"
    case .area:     return "folder"
    }
  }

  static func dateLabel(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "Today" }
    if cal.isDateInTomorrow(d) { return RegistrySurfaces.tomorrowLabel }
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("MMMd")
    return f.string(from: d)
  }
}

/// Lightweight natural-language parse of a task title: explicit `#project` /
/// `@area` / `!today` tokens plus a single date phrase (via `NSDataDetector`).
/// Detection only — applying + stripping is the composer's job, so the user
/// stays in control (chips are tap-to-apply, never silent).
enum TaskTitleParser {
  static func detect(in raw: String, projects: [Project], areas: [Area]) -> [DetectedToken] {
    var tokens: [DetectedToken] = []

    // Explicit tokens, one per whitespace-delimited word.
    for word in raw.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init) {
      let lower = word.lowercased()
      if lower == "!today" || lower == "!t" {
        tokens.append(DetectedToken(kind: .today, phrase: word))
      } else if word.hasPrefix("#"), word.count > 1,
                let p = matchProject(String(lower.dropFirst()), projects) {
        tokens.append(DetectedToken(kind: .project(id: p.id, title: p.title), phrase: word))
      } else if word.hasPrefix("@"), word.count > 1,
                let a = matchArea(String(lower.dropFirst()), areas) {
        tokens.append(DetectedToken(kind: .area(id: a.id, title: a.title), phrase: word))
      }
    }

    // A single date phrase, detected on the title minus any token words so a
    // "#friday-standup" list name can't be mistaken for the day Friday.
    let withoutTokens = tokens.reduce(raw) { strip($1.phrase, from: $0) }
    if let (date, phrase) = detectDate(in: withoutTokens) {
      tokens.append(DetectedToken(kind: .date(date), phrase: phrase))
    }
    return tokens
  }

  /// Remove the first (case-insensitive) occurrence of `phrase`, then tidy
  /// doubled / edge whitespace.
  static func strip(_ phrase: String, from text: String) -> String {
    guard let r = text.range(of: phrase, options: [.caseInsensitive]) else { return text }
    var s = text
    s.removeSubrange(r)
    while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Matching

  private static func matchProject(_ q: String, _ projects: [Project]) -> Project? {
    projects.first { $0.status == .active && titleMatches($0.title, q) }
  }
  private static func matchArea(_ q: String, _ areas: [Area]) -> Area? {
    areas.first { titleMatches($0.title, q) }
  }
  private static func titleMatches(_ title: String, _ q: String) -> Bool {
    let t = title.lowercased()
    return t == q || t.hasPrefix(q) || t.replacingOccurrences(of: " ", with: "").hasPrefix(q)
  }

  private static func detectDate(in text: String) -> (Date, String)? {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    else { return nil }
    let ns = text as NSString
    for m in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
      guard let d = m.date else { continue }
      let phrase = ns.substring(with: m.range)
      // Require a letter so bare numbers ("call 5") aren't read as dates;
      // "tomorrow", "friday", "jun 3", "5pm" all qualify.
      if phrase.rangeOfCharacter(from: .letters) != nil {
        return (d, phrase)
      }
    }
    return nil
  }
}
