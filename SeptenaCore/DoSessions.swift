import Foundation
import Observation
import SeptenaSharedCore
import SwiftData

// Do: one task now (docs/DO_SPEC.md, ADR 0041). The rules live in the shared
// core (`do_session.rs`); this file holds the rows, the one seam to the core
// and the state every surface reads.

// MARK: - Rows

@Model
final class DoSessionEntity {
  @Attribute(.unique) var id: String
  var taskID: String
  /// Stamps are kept as the text that syncs, so a pull and a push of the same
  /// instant compare equal.
  var startedAt: String
  var plannedMinutes: Int? = nil
  var confirmedAt: String? = nil
  var endedAt: String? = nil
  var exit: String? = nil
  /// The length is unknown.
  var lapsed: Bool = false
  /// Where the user stopped.
  var note: String? = nil
  var sourceClient: String? = nil

  init(id: String, taskID: String, startedAt: String) {
    self.id = id
    self.taskID = taskID
    self.startedAt = startedAt
  }
}

/// One Do, as a value.
struct DoSession: Identifiable, Hashable, Sendable {
  let id: String
  let taskID: String
  let startedAt: Date
  let plannedMinutes: Int?
  let endedAt: Date?
  let exit: DoExit?
  let lapsed: Bool
  let note: String?

  @MainActor
  init?(_ entity: DoSessionEntity) {
    guard let started = DoStamp.date(entity.startedAt) else { return nil }
    id = entity.id
    taskID = entity.taskID
    startedAt = started
    plannedMinutes = entity.plannedMinutes
    endedAt = entity.endedAt.flatMap(DoStamp.date)
    exit = entity.exit.flatMap(DoExit.init(rawValue:))
    lapsed = entity.lapsed
    note = entity.note
  }

  /// Nil while it is open, and when the length is unknown.
  var length: TimeInterval? {
    guard let endedAt, !lapsed else { return nil }
    return max(0, endedAt.timeIntervalSince(startedAt))
  }
}

/// How a Do ended (`doExit` in `registry/entities.json`).
enum DoExit: String, Sendable, CaseIterable {
  case done, stopped, later, replaced, closed
}

enum DoStamp {
  static func text(_ date: Date) -> String { SharedCoreValues.instant(date) }

  static func date(_ text: String) -> Date? {
    (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
      ?? (try? Date(text, strategy: .iso8601))
  }
}

// MARK: - The core

/// The one seam to the core's Do rules. They are JSON only: typed bindings do
/// not fit the core's size budget.
enum DoCore {
  struct Row: Encodable {
    let id: String
    let startedAt: String
    let plannedMinutes: Int?
    let confirmedAt: String?
    let endedAt: String?
    let taskStatus: String?
  }

  struct End: Decodable {
    let id: String
    let endedAt: String
    let exit: String
    let lapsed: Bool
  }

  struct Current: Decodable {
    let id: String
    let startedMs: Int64
    let plannedEndMs: Int64?
    let staleAtMs: Int64
    let isStale: Bool
  }

  struct Resolution: Decodable {
    let ends: [End]
    let current: Current?
  }

  private struct Input: Encodable {
    let sessions: [Row]
    let now: String
  }

  static func resolve(_ rows: [Row], now: Date) -> Resolution? {
    let input = Input(sessions: rows, now: DoStamp.text(now))
    guard let data = try? JSONEncoder().encode(input), let json = String(data: data, encoding: .utf8) else { return nil }
    do {
      let out = try invokeJson(function: "resolveDoSessions", inputJson: json)
      return try JSONDecoder().decode(Resolution.self, from: Data(out.utf8))
    } catch {
      SeptenaLog.error("[Do] resolve failed", error)
      return nil
    }
  }
}

// MARK: - State

/// What the user does now. `task…` fields are a copy, so a surface can draw
/// the notice without a fetch.
struct DoState: Equatable, Sendable {
  let sessionID: String
  let taskID: String
  let title: String
  let startedAt: Date
  let plannedMinutes: Int?
  let plannedEnd: Date?
  let staleAt: Date
  let isStale: Bool

  /// The time a surface shows: up from the start, or down to the planned end,
  /// then up again past it. Whole minutes.
  func minutes(at now: Date) -> Int {
    if let plannedEnd, now < plannedEnd {
      return Int((plannedEnd.timeIntervalSince(now) / 60).rounded(.up))
    }
    return max(0, Int(now.timeIntervalSince(startedAt) / 60))
  }

  /// `12 min`, in the user's language.
  func timeText(at now: Date) -> String { DoState.lengthText(TimeInterval(minutes(at: now) * 60)) }

  /// The same words for a closed Do in the history.
  static func lengthText(_ length: TimeInterval) -> String {
    let minutes = Int(length / 60)
    let units: Set<Duration.UnitsFormatStyle.Unit> = minutes >= 60 ? [.hours, .minutes] : [.minutes]
    return Duration.seconds(minutes * 60).formatted(.units(allowed: units, width: .abbreviated))
  }
}

/// The current Do, and every gesture on it. Reads rows; writes them through
/// the mutator's engine, like every other synced row.
@MainActor
@Observable
final class DoStore {
  static let shared = DoStore()

  /// Nil when nothing is done now. A stale Do is here too: its surface asks
  /// (§2.2).
  private(set) var current: DoState?

  /// The Do this device shows in full. Local, never synced (ADR 0041).
  private var fullSessionID: String? = UserDefaults.standard.string(forKey: fullKey) {
    didSet { UserDefaults.standard.set(fullSessionID, forKey: Self.fullKey) }
  }

  /// The Do that just stopped here: its surface offers "Where did you stop?".
  private(set) var justStoppedSessionID: String?

  /// Posted when a planned length ends on the device that shows the Do.
  static let plannedEndReached = Notification.Name("septena.do.plannedEnd")

  private static let fullKey = "septena.do.fullSession"
  @ObservationIgnored private var observer: NSObjectProtocol?
  @ObservationIgnored private var wake: Task<Void, Never>?
  @ObservationIgnored private var signalled: Set<String> = []

  private init() {}

  /// This device shows the Do screen.
  var isFullHere: Bool { current.map { !$0.isStale && $0.sessionID == fullSessionID } ?? false }

  /// Another device, or this one after Show List, shows the notice.
  var showsNotice: Bool { current.map { $0.isStale || $0.sessionID != fullSessionID } ?? false }

  func isDoing(_ taskID: String) -> Bool { current?.taskID == taskID && current?.isStale == false }

  /// Called once the local store is open.
  func start() {
    guard observer == nil else { refresh(); return }
    observer = NotificationCenter.default.addObserver(
      forName: .septenaTasksChanged, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
    refresh()
  }

  // MARK: Reads

  private var context: ModelContext { LocalStore.shared.container.mainContext }

  func refresh() {
    let resolution = resolve()
    let next = resolution?.current.flatMap(state(of:))
    if next != current { current = next }
    if let fullSessionID, next?.sessionID != fullSessionID { self.fullSessionID = nil }
    scheduleWake()
    DoEndAlert.update(for: isFullHere ? current : nil)
    #if os(iOS)
    DoActivity.update(for: isFullHere ? current : nil)
    #endif
  }

  /// A task's Do history, newest first.
  func history(taskID: String) -> [DoSession] {
    StoreHealth.fetch(context, FetchDescriptor<DoSessionEntity>(predicate: #Predicate { $0.taskID == taskID }))
      .compactMap(DoSession.init)
      .sorted { $0.startedAt > $1.startedAt }
  }

  /// Where the user stopped last, or nil.
  func lastNote(taskID: String) -> String? {
    history(taskID: taskID).first { $0.note?.isEmpty == false }?.note
  }

  private func state(of current: DoCore.Current) -> DoState? {
    guard let row = entity(current.id), let task = task(row.taskID) else { return nil }
    return DoState(
      sessionID: row.id, taskID: row.taskID, title: task.title,
      startedAt: Date(timeIntervalSince1970: Double(current.startedMs) / 1000),
      plannedMinutes: row.plannedMinutes,
      plannedEnd: current.plannedEndMs.map { Date(timeIntervalSince1970: Double($0) / 1000) },
      staleAt: Date(timeIntervalSince1970: Double(current.staleAtMs) / 1000),
      isStale: current.isStale)
  }

  /// The core's answer over the rows of this device. Never writes.
  private func resolve() -> DoCore.Resolution? {
    let open = StoreHealth.fetch(context, FetchDescriptor<DoSessionEntity>(predicate: #Predicate { $0.endedAt == nil }))
    guard let oldest = open.compactMap({ DoStamp.date($0.startedAt) }).min() else { return nil }
    let all = StoreHealth.fetch(context, FetchDescriptor<DoSessionEntity>())
      .filter { (DoStamp.date($0.startedAt) ?? .distantPast) >= oldest }
    return DoCore.resolve(all.map { row in
      DoCore.Row(id: row.id, startedAt: row.startedAt, plannedMinutes: row.plannedMinutes,
                 confirmedAt: row.confirmedAt, endedAt: row.endedAt, taskStatus: taskStatus(row.taskID))
    }, now: DayClock.appNow)
  }

  /// A task that is not here may still be on its way in a pull: it counts as
  /// open, and the store ends the Do when the task is really gone.
  private func taskStatus(_ id: String) -> String? {
    guard let task = task(id) else { return TaskStatus.open.rawValue }
    return task.deletedAt != nil || task.isFaded ? nil : task.statusRaw
  }

  private func entity(_ id: String) -> DoSessionEntity? {
    var d = FetchDescriptor<DoSessionEntity>(predicate: #Predicate { $0.id == id })
    d.fetchLimit = 1
    return try? context.fetch(d).first
  }

  private func task(_ id: String) -> TaskEntity? {
    var d = FetchDescriptor<TaskEntity>(predicate: #Predicate { $0.id == id })
    d.fetchLimit = 1
    return try? context.fetch(d).first
  }

  // MARK: Gestures

  /// Starts a Do of an open task and shows it here. A Do that was open ends.
  func begin(taskID: String, plannedMinutes: Int? = nil) {
    guard let task = task(taskID), task.status == .open, !task.isHeading, task.deletedAt == nil else { return }
    guard !isDoing(taskID) else { showHere(); return }
    // The start is engagement: it resets the fade and keeps a faded task.
    SeptenaServices.shared.taskMutator.touch(id: taskID)
    let row = DoSessionEntity(id: "do-\(UUID().uuidString.lowercased())", taskID: taskID,
                              startedAt: DoStamp.text(Date()))
    row.plannedMinutes = plannedMinutes.map(clampedLength)
    row.sourceClient = TaskBackendClient.clientName
    context.insert(row)
    var changed = [row.id]
    for end in resolve()?.ends ?? [] where end.id != row.id {
      guard let older = entity(end.id) else { continue }
      older.endedAt = end.endedAt
      older.exit = end.exit
      older.lapsed = end.lapsed
      changed.append(older.id)
    }
    guard commit(changed, op: "doSession.begin") else { return }
    justStoppedSessionID = nil
    fullSessionID = row.id
    refresh()
  }

  /// Stop for now. Ends one Do by its id, never "whatever is open".
  func stop(sessionID: String) {
    guard end(sessionID, exit: .stopped) else { return }
    justStoppedSessionID = sessionID
  }

  /// Later saved a date for the task: the Do ends.
  func endForLater(sessionID: String) { end(sessionID, exit: .later) }

  /// The stale question's Still On It.
  func confirm(sessionID: String) {
    guard let row = entity(sessionID), row.endedAt == nil else { return }
    row.confirmedAt = DoStamp.text(Date())
    commit([sessionID], op: "doSession.confirm")
    refresh()
  }

  /// nil counts up.
  func setLength(sessionID: String, minutes: Int?) {
    guard let row = entity(sessionID), row.endedAt == nil else { return }
    row.plannedMinutes = minutes.map(clampedLength)
    signalled.remove(sessionID)
    commit([sessionID], op: "doSession.length")
    refresh()
  }

  /// The answer to "Where did you stop?". Empty clears nothing and writes
  /// nothing.
  func setNote(sessionID: String, _ note: String) {
    let text = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(RegistryEntityLimits.doNoteMax))
    if justStoppedSessionID == sessionID { justStoppedSessionID = nil }
    guard !text.isEmpty, let row = entity(sessionID) else { return }
    row.note = text
    commit([sessionID], op: "doSession.note")
  }

  func dismissStopNote() { justStoppedSessionID = nil }

  /// Do here: this device becomes the full one.
  func showHere() {
    guard let current, !current.isStale else { return }
    fullSessionID = current.sessionID
    refresh()
  }

  /// Show the list. The Do goes on, and this device shows the notice.
  func showList() {
    fullSessionID = nil
    refresh()
  }

  // MARK: Writes

  @discardableResult
  private func end(_ sessionID: String, exit: DoExit) -> Bool {
    guard let row = entity(sessionID), row.endedAt == nil else { return false }
    row.lapsed = current?.sessionID == sessionID && current?.isStale == true
    row.endedAt = DoStamp.text(Date())
    row.exit = exit.rawValue
    let ok = commit([sessionID], op: "doSession.end")
    refresh()
    return ok
  }

  /// A mutator closed, deleted or faded these tasks: their open Do ends at
  /// once (§2.1 rule 5). The store applies the same rule for every other
  /// client. Called by the task write path, never by a sync apply.
  func noteTasksClosed(_ ids: [String]) {
    let set = Set(ids)
    let open = StoreHealth.fetch(context, FetchDescriptor<DoSessionEntity>(predicate: #Predicate { $0.endedAt == nil }))
      .filter { set.contains($0.taskID) }
    guard !open.isEmpty else { return }
    var changed: [String] = []
    for row in open {
      let task = task(row.taskID)
      if let task, task.status == .open, task.deletedAt == nil, !task.isFaded { continue }
      row.lapsed = current?.sessionID == row.id && current?.isStale == true
      row.endedAt = DoStamp.text(Date())
      row.exit = (task?.status == .done && task?.deletedAt == nil ? DoExit.done : .closed).rawValue
      changed.append(row.id)
    }
    guard !changed.isEmpty, commit(changed, op: "doSession.taskClosed") else { return }
    refresh()
  }

  /// A purged task takes its Do history with it.
  func purge(taskID: String) {
    let rows = StoreHealth.fetch(context, FetchDescriptor<DoSessionEntity>(predicate: #Predicate { $0.taskID == taskID }))
    for row in rows {
      context.delete(row)
      SeptenaServices.shared.ckEngine.noteDoSessionDeletion(id: row.id)
    }
  }

  @discardableResult
  private func commit(_ ids: [String], op: String) -> Bool {
    guard StoreHealth.save(context, op: op) else { return false }
    for id in ids { SeptenaServices.shared.ckEngine.noteDoSessionChange(id: id) }
    return true
  }

  private func clampedLength(_ minutes: Int) -> Int {
    min(max(minutes, 1), RegistryEntityLimits.doPlannedMinutesMax)
  }

  // MARK: Clock

  /// One wake at the next instant that changes the state: the planned end or
  /// the stale limit.
  private func scheduleWake() {
    wake?.cancel()
    guard let current, !current.isStale else { return }
    let now = Date()
    let planned = current.plannedEnd.flatMap { $0 > now ? $0 : nil }
    let next = min(planned ?? .distantFuture, current.staleAt)
    wake = Task { [weak self] in
      try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow) + 0.2))
      guard !Task.isCancelled, let self else { return }
      if planned == next, self.isFullHere, self.signalled.insert(current.sessionID).inserted {
        NotificationCenter.default.post(name: Self.plannedEndReached, object: nil)
      }
      self.refresh()
    }
  }
}
