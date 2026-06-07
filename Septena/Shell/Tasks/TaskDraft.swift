import SwiftUI
import Foundation

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
  /// Someday bucket — "I'll get to it eventually," not a calendared commitment.
  /// Stored as `status == .someday`; mutually exclusive with Today / a
  /// scheduled date. Lives in the When control, not a separate menu action.
  var someday: Bool = false

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
    case .someday:         someday = true
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
    someday = task.status == .someday
  }

  // MARK: - When mutations (mutually exclusive)

  mutating func setToday() { onToday = true; scheduled = nil; someday = false }
  mutating func setScheduled(_ date: Date) {
    let day = Calendar.current.startOfDay(for: date)
    if Calendar.current.isDateInToday(day) { setToday() }
    else { onToday = false; scheduled = day; someday = false }
  }
  /// Demote to Someday — clears Today, any planning date, and the deadline
  /// (Someday isn't a commitment), mirroring `TaskMutator.moveToSomeday`.
  mutating func setSomeday() { someday = true; onToday = false; scheduled = nil; deadline = nil }
  mutating func clearWhen() { onToday = false; scheduled = nil; someday = false }

  // MARK: - Things-style scheduled mapping

  /// Scheduling for *today* (or flipping the explicit Today toggle) pins the
  /// `today` flag and clears the stored planning date; a future date stores
  /// the date with today=false.
  private var schedIsToday: Bool {
    scheduled.map { Calendar.current.isDateInToday($0) } ?? false
  }
  var pinToday: Bool { !someday && (onToday || schedIsToday) }
  private var storedScheduled: Date? { someday ? nil : (schedIsToday ? nil : scheduled) }

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
      due: someday ? nil : deadline,
      today: pinToday,
      notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
      status: someday ? "someday" : nil
    )
    if let recurrence { mutator.setRecurrence(id: task.id, recurrence: recurrence) }
    return task
  }

  /// Apply edits to an existing task: only fire the mutations whose value
  /// actually changed (the Things-style save the composer commits on Done).
  @MainActor
  func update(_ original: SeptenaTask, via mutator: TaskMutator) {
    let id = original.id
    if trimmedTitle != original.title || notes != (original.notes ?? "") {
      mutator.update(id: id, title: trimmedTitle, notes: notes)
    }

    let wasSomeday = original.status == .someday
    if someday {
      // Demote — moveToSomeday clears today/scheduled/due, so skip the
      // scheduling calls that would resurrect it.
      if !wasSomeday { mutator.moveToSomeday(id: id) }
    } else {
      // Leaving Someday: re-open (status someday → open) before re-scheduling.
      if wasSomeday { mutator.uncomplete(id: id) }
      mutator.schedule(id: id, date: storedScheduled)
      mutator.moveToToday(id: id, today: pinToday)
      if deadline != SeptenaDate.parse(original.deadline) {
        mutator.setDue(id: id, date: deadline)
      }
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
