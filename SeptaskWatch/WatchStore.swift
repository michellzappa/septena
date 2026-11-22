import Foundation
import WatchKit
import WidgetKit

// The watch's state (docs/WATCH.md): the lists it shows, a disk cache so a
// cold launch draws at once, and a persisted queue of changes so a tap on
// the wrist never waits for the network and is never lost offline.
//
// Every change is applied to the screen first (optimistic), then queued. A
// removal (complete, tomorrow, remove from Today, cancel) waits out a short
// undo window before it is queued at all, so Undo never needs a server
// round trip.

/// One change made on the wrist, waiting to reach the backend.
struct WatchOp: Codable, Identifiable, Equatable {
  enum When: String, Codable, CaseIterable { case inbox, today, tomorrow }

  enum Action: Codable, Equatable {
    case complete(String)
    case moveToToday(String)
    case removeFromToday(String)
    case tomorrow(String)
    case cancel(String)
    case create(title: String, when: When)

    var taskID: String? {
      switch self {
      case .complete(let id), .moveToToday(let id), .removeFromToday(let id), .tomorrow(let id), .cancel(let id):
        return id
      case .create: return nil
      }
    }

    /// The `/v1/tasks/:id/:verb` verb.
    var verb: String? {
      switch self {
      case .complete: return "complete"
      case .moveToToday: return "today"
      case .removeFromToday: return "untoday"
      case .tomorrow: return "tomorrow"
      case .cancel: return "cancel"
      case .create: return nil
      }
    }

    /// True when the row leaves Today.
    var removesFromToday: Bool {
      switch self {
      case .complete, .removeFromToday, .tomorrow, .cancel: return true
      default: return false
      }
    }
  }

  var id = UUID()
  var action: Action
  var createdAt = Date()
  /// Local placeholder row id for a create, so the row shows until the
  /// server list carries the real one.
  var placeholderID: String?
}

enum WatchConnection: Equatable {
  /// No session yet: the phone hasn't handed one over.
  case notConnected
  case connected
}

@MainActor
@Observable
final class WatchStore {
  static let shared = WatchStore()

  // MARK: Shown state

  private(set) var today: WatchTaskList?
  private(set) var upcoming: WatchTaskList?
  private(set) var anytime: WatchTaskList?
  private(set) var connection: WatchConnection = WatchAPI.hasSession ? .connected : .notConnected
  private(set) var isRefreshing = false
  private(set) var lastError: String?
  private(set) var lastSyncedAt: Date?
  private(set) var offline = false
  private(set) var queue: [WatchOp] = []
  /// The removal still inside its undo window.
  private(set) var undoable: Undoable?

  struct Undoable: Equatable {
    let op: WatchOp
    let task: WatchTask
    let message: String
  }

  #if DEBUG
  /// Simulator / screenshot mode: fixed rows, nothing leaves the watch.
  var sampleMode: Bool = UserDefaults.standard.bool(forKey: "septena.watch.sampleMode") {
    didSet {
      UserDefaults.standard.set(sampleMode, forKey: "septena.watch.sampleMode")
      today = nil; upcoming = nil; anytime = nil
      loadCache()
      refresh(.today)
    }
  }
  #else
  let sampleMode = false
  #endif

  // MARK: Derived

  /// Today with every queued / undoable change applied on top.
  var todayRows: [WatchTask] { overlay(today?.tasks ?? [], view: .today) }
  var upcomingRows: [WatchTask] { overlay(upcoming?.tasks ?? [], view: .upcoming) }
  var anytimeRows: [WatchTask] { overlay(anytime?.tasks ?? [], view: .anytime) }
  var todayDay: String { today?.today ?? WatchDay.string(from: .now) }

  private var undoTask: Task<Void, Never>?
  private var flushTask: Task<Void, Never>?
  private var placeholders: [String: WatchTask] = [:]

  private init() {
    queue = Self.read([WatchOp].self, "queue.json") ?? []
    for op in queue {
      if case .create(let title, let when) = op.action, let pid = op.placeholderID, when != .tomorrow {
        placeholders[pid] = WatchTask(id: pid, title: title, inbox: true)
      }
    }
    loadCache()
  }

  // MARK: - Loading

  private func loadCache() {
    if sampleMode {
      today = .sample
      upcoming = WatchTaskList(view: .upcoming, today: WatchTaskList.sample.today, total: 2, tasks: [
        WatchTask(id: "u1", title: "Dentist", scheduled: "2026-11-23", area: "Health"),
        WatchTask(id: "u2", title: "Send invoice", deadline: "2026-11-25", project: "Envisioning"),
      ])
      anytime = WatchTaskList(view: .anytime, today: WatchTaskList.sample.today, total: 1, tasks: [
        WatchTask(id: "a1", title: "Read the bitter lesson again", area: "Envisioning"),
      ])
      return
    }
    today = Self.read(WatchTaskList.self, "today.json")
    upcoming = Self.read(WatchTaskList.self, "upcoming.json")
    anytime = Self.read(WatchTaskList.self, "anytime.json")
    lastSyncedAt = today?.fetchedAt
  }

  /// Fetches a view. Silent: the cached rows stay on screen meanwhile.
  func refresh(_ view: WatchTaskList.View = .today) {
    Task { await refreshNow(view) }
  }

  func refreshNow(_ view: WatchTaskList.View = .today) async {
    guard !sampleMode else { return }
    guard WatchAPI.hasSession else {
      connection = .notConnected
      WatchPhoneLink.shared.requestSession()
      return
    }
    await flush()
    isRefreshing = true
    defer { isRefreshing = false }
    do {
      let list = try await WatchAPI.shared.list(view)
      apply(list)
      connection = .connected
      offline = false
      lastError = nil
    } catch let error as WatchAPIError {
      handle(error)
    } catch {}
  }

  private func apply(_ list: WatchTaskList) {
    switch list.view {
    case .today:
      today = list
      lastSyncedAt = list.fetchedAt
      // A placeholder whose create already landed is now a real row.
      if queue.allSatisfy({ if case .create = $0.action { return false } else { return true } }) {
        placeholders.removeAll()
      }
      Self.write(list, "today.json")
      updateComplication()
    case .upcoming:
      upcoming = list
      Self.write(list, "upcoming.json")
    case .anytime:
      anytime = list
      Self.write(list, "anytime.json")
    case .inbox:
      break
    }
  }

  /// The phone's application context: newer than the cache, older than a
  /// fetch the watch made itself a moment ago.
  func adoptPhoneSnapshot(_ list: WatchTaskList) {
    guard !sampleMode else { return }
    if let mine = today?.fetchedAt, let theirs = list.fetchedAt, mine > theirs { return }
    apply(list)
  }

  // MARK: - Session

  func adopt(_ handoff: WatchSessionHandoff) async {
    await WatchAPI.shared.adopt(handoff)
    connection = .connected
    lastError = nil
    await refreshNow(.today)
  }

  func signedOutOnPhone() async {
    await WatchAPI.shared.signOut()
    connection = .notConnected
    today = nil; upcoming = nil; anytime = nil
    queue = []; placeholders = [:]
    Self.write(queue, "queue.json")
    for name in ["today.json", "upcoming.json", "anytime.json"] { Self.remove(name) }
    updateComplication()
  }

  // MARK: - Changes

  func complete(_ task: WatchTask) {
    WKInterfaceDevice.current().play(.success)
    removeWithUndo(task, .complete(task.id), message: String(localized: "Completed"))
  }

  func tomorrow(_ task: WatchTask) {
    WKInterfaceDevice.current().play(.click)
    removeWithUndo(task, .tomorrow(task.id), message: String(localized: "Moved to Tomorrow"))
  }

  func removeFromToday(_ task: WatchTask) {
    WKInterfaceDevice.current().play(.click)
    removeWithUndo(task, .removeFromToday(task.id), message: String(localized: "Removed from Today"))
  }

  func cancel(_ task: WatchTask) {
    WKInterfaceDevice.current().play(.click)
    removeWithUndo(task, .cancel(task.id), message: String(localized: "Task cancelled"))
  }

  func moveToToday(_ task: WatchTask) {
    WKInterfaceDevice.current().play(.success)
    enqueue(WatchOp(action: .moveToToday(task.id)))
    // Show it on Today at once, at the end, until the next fetch orders it.
    if var list = today, !list.tasks.contains(where: { $0.id == task.id }) {
      list.tasks.append(task)
      list.total += 1
      today = list
      updateComplication()
    }
  }

  func create(title: String, when: WatchOp.When) {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    WKInterfaceDevice.current().play(.success)
    let pid = "local-\(UUID().uuidString.prefix(8))"
    if when != .tomorrow {
      // A watch capture lands in Today's Inbox section (unfiled), same as
      // the phone draws it.
      placeholders[pid] = WatchTask(id: pid, title: trimmed, inbox: true)
    }
    enqueue(WatchOp(action: .create(title: trimmed, when: when), placeholderID: pid))
    updateComplication()
  }

  func undo() {
    guard undoable != nil else { return }
    undoTask?.cancel()
    undoable = nil
    WKInterfaceDevice.current().play(.retry)
    updateComplication()
  }

  private func removeWithUndo(_ task: WatchTask, _ action: WatchOp.Action, message: String) {
    // A second removal inside the window commits the first at once.
    commitUndoable()
    let op = WatchOp(action: action)
    undoable = Undoable(op: op, task: task, message: message)
    updateComplication()
    undoTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(3.5))
      guard !Task.isCancelled else { return }
      self.commitUndoable()
    }
  }

  private func commitUndoable() {
    undoTask?.cancel()
    guard let u = undoable else { return }
    undoable = nil
    enqueue(u.op)
  }

  private func enqueue(_ op: WatchOp) {
    if sampleMode {
      applyLocally(op)
      return
    }
    queue.append(op)
    Self.write(queue, "queue.json")
    scheduleFlush()
  }

  /// Sample mode: make the change stick in the fixed rows.
  private func applyLocally(_ op: WatchOp) {
    if let pid = op.placeholderID, let row = placeholders.removeValue(forKey: pid) {
      today?.tasks.insert(row, at: 0)
    }
    guard let id = op.action.taskID else { return }
    if op.action.removesFromToday { today?.tasks.removeAll { $0.id == id } }
    upcoming?.tasks.removeAll { $0.id == id }
    anytime?.tasks.removeAll { $0.id == id }
  }

  private func scheduleFlush() {
    flushTask?.cancel()
    flushTask = Task { @MainActor in
      await self.flush()
      // One quiet refresh after a burst of changes, so ordering and any
      // spawned repeat show up.
      try? await Task.sleep(for: .seconds(1.5))
      guard !Task.isCancelled else { return }
      await self.refreshNow(.today)
      WatchPhoneLink.shared.notifyChanged()
    }
  }

  /// Sends queued changes in order. Stops at the first retryable failure.
  func flush() async {
    while let op = queue.first {
      do {
        try await WatchAPI.shared.send(op)
        drop(op)
      } catch let error as WatchAPIError {
        switch error {
        case .notFound:
          drop(op)
        case .rejected(let why):
          drop(op)
          lastError = why
        default:
          handle(error)
          return
        }
      } catch {
        return
      }
    }
  }

  private func drop(_ op: WatchOp) {
    queue.removeAll { $0.id == op.id }
    Self.write(queue, "queue.json")
  }

  private func handle(_ error: WatchAPIError) {
    switch error {
    case .notConnected:
      connection = .notConnected
      WatchPhoneLink.shared.requestSession()
    case .network:
      offline = true
    case .server(let code):
      lastError = String(localized: "Server error \(code)")
    case .rejected(let why):
      lastError = why
    case .badResponse:
      lastError = String(localized: "Unexpected reply from the server")
    case .notFound:
      break
    }
  }

  // MARK: - Overlay

  private func overlay(_ rows: [WatchTask], view: WatchTaskList.View) -> [WatchTask] {
    var hidden = Set<String>()
    var pending = queue.map(\.action)
    if let u = undoable { pending.append(u.op.action) }
    for action in pending {
      guard let id = action.taskID else { continue }
      switch view {
      case .today:
        if action.removesFromToday { hidden.insert(id) }
      case .upcoming:
        // Tomorrow keeps a row in Upcoming (it only changes day).
        if action != .tomorrow(id) { hidden.insert(id) }
      case .anytime, .inbox:
        hidden.insert(id)
      }
    }
    var out = rows.filter { !hidden.contains($0.id) }
    if view == .today {
      let fresh = placeholders.values.filter { p in !out.contains { $0.title == p.title && $0.isInbox } }
      out.insert(contentsOf: fresh.sorted { $0.id < $1.id }, at: 0)
    }
    return out
  }

  // MARK: - Complication

  private func updateComplication() {
    let rows = todayRows
    TasksTodayComplicationData(
      remaining: rows.count,
      firstTitle: rows.first?.title,
      secondTitle: rows.dropFirst().first?.title,
      day: todayDay,
      connected: connection == .connected || sampleMode,
      updatedAt: .now
    ).save()
    WidgetCenter.shared.reloadTimelines(ofKind: TasksTodayComplicationData.widgetKind)
  }

  // MARK: - Disk

  private static var directory: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("Watch", isDirectory: true)
  }

  private static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
    guard let url = directory?.appendingPathComponent(name),
          let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder.watchWire.decode(type, from: data)
  }

  private static func write<T: Encodable>(_ value: T, _ name: String) {
    guard let dir = directory, let data = try? JSONEncoder.watchWire.encode(value) else { return }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
  }

  private static func remove(_ name: String) {
    guard let url = directory?.appendingPathComponent(name) else { return }
    try? FileManager.default.removeItem(at: url)
  }
}

/// YYYY-MM-DD in the watch's zone, the wire's day format.
enum WatchDay {
  private static let formatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()

  static func string(from date: Date) -> String { formatter.string(from: date) }
  static func date(from ymd: String) -> Date? { formatter.date(from: ymd) }
}
