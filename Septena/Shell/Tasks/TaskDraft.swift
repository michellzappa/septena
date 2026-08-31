import SwiftUI
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
  var scheduled: Date? = nil
  var deadline: Date? = nil
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
  init(filter: TaskFilter) {
    switch filter {
    case .today:           onToday = true
    case .upcoming:        scheduled = Calendar.current.date(byAdding: .day, value: 1, to: .now)
    case .project(let id): projectId = id
    case .area(let id):    areaId = id
    case .triage, .unscheduled, .repeating, .logbook, .recentlyDeleted: break
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

  // MARK: - When mutations (mutually exclusive)

  mutating func setToday() { onToday = true; scheduled = nil }
  mutating func setScheduled(_ date: Date) {
    let day = Calendar.current.startOfDay(for: date)
    if Calendar.current.isDateInToday(day) { setToday() }
    else { onToday = false; scheduled = day }
  }
  mutating func clearWhen() { onToday = false; scheduled = nil }

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
    return task
  }

  /// Apply edits to an existing task: only fire the mutations whose value
  /// actually changed (the Things-style save the composer commits on Done).
  @MainActor
  func update(_ original: SeptenaTask, via mutator: TaskMutator) {
    let id = original.id
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
    if trimmedTitle != prior.trimmedTitle || trimmedNotes != prior.trimmedNotes {
      mutator.update(id: id, title: trimmedTitle, notes: trimmedNotes)
    }

    if storedScheduled != prior.storedScheduled {
      mutator.schedule(id: id, date: storedScheduled)
    }
    if pinToday != prior.pinToday {
      if pinToday { mutator.moveToToday(id: id, today: true) }
      else { mutator.removeFromToday(id: id) }
    }
    if deadline != prior.deadline {
      mutator.setDeadline(id: id, date: deadline)
    }
    if recurrence != prior.recurrence {
      mutator.setRecurrence(id: id, recurrence: recurrence)
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
    return "Inbox"
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
    if cal.isDateInTomorrow(d) { return "Tomorrow" }
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
