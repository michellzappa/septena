import Foundation
import SwiftData

// The Today launch snapshot (#82, docs/LAUNCH_PERF.md).
//
// A cold launch draws its first Today frame from a small JSON file instead of
// SwiftData fetches. The file holds exactly what `TaskListView` reads before
// its first `load()` on Today: the Today rows, the Inbox rows, and the areas
// and projects their group headers name. So the first frame is the SAME view
// with the SAME data; the swap to the live list is the first `load()`, and
// nothing changes on screen when the data matches.
//
// - Writer: `TodaySnapshotWriter` (iOS task app only). It rewrites the file
//   a short time after every `.septenaTasksChanged` / `.septenaStructureChanged`
//   post and at day rollover.
// - Reader: `TodaySnapshotStore.launchRows(day:)`, used only until the first
//   task list frame is drawn (`LaunchPhase`). After that it returns nil.
// - Invalidation: sign-out, account switch and account delete remove the file
//   (`TaskSyncEngine`). A snapshot from another day is never used: the reader
//   compares its day with `DayClock.today`.
//
// Not shared with the widget snapshot (`TasksWidgetWire`): that is a reduced
// shape for a widget. The first frame needs full row DTOs, so `TaskRow` draws
// the same pixels it draws from the store.

/// The file's shape. Plain Codable, versioned: a decode failure or another
/// version means "no snapshot", never an error.
struct TodaySnapshot: Codable {
  static let currentVersion = 1

  var version: Int = currentVersion
  /// `SeptenaDate` day the rows were read on (YYYY-MM-DD).
  var day: String
  /// `LocalCache.tasks(filter: .today)`, in that order.
  var today: [Row]
  /// `LocalCache.tasks(filter: .triage)`, in that order.
  var inbox: [Row]
  /// `StructureCache` order (sidebar order).
  var areas: [AreaRow]
  var projects: [ProjectRow]

  /// Size guard, not a layout cut: real Today lists stay well under it, so
  /// the first two screens always match the live list.
  static let rowCap = 150
  /// Notes only decide whether a row shows its notes glyph.
  static let notesPrefix = 80

  /// A task row. `SeptenaTask`'s wire `CodingKeys` leave out the fields that
  /// ride alongside the entity (provenance, order, kind, conversation), and
  /// the row draws some of them, so they are stored here next to it.
  struct Row: Codable {
    var task: SeptenaTask
    var source: String?
    var sourceClient: String?
    var acknowledgedAt: Date?
    var createdAt: Date
    var position: Double
    var kind: String
    var heading: String?
    /// Only for a task whose conversation has started (the row badge).
    var conversation: TaskConvo?

    init(_ t: SeptenaTask) {
      var wire = t
      if let notes = wire.notes { wire.notes = String(notes.prefix(TodaySnapshot.notesPrefix)) }
      task = wire
      source = t.source
      sourceClient = t.sourceClient
      acknowledgedAt = t.acknowledgedAt
      createdAt = t.createdAt
      position = t.position
      kind = t.kind
      heading = t.heading
      conversation = t.conversation.hasStarted ? t.conversation : nil
    }

    var materialized: SeptenaTask {
      var t = task
      t.source = source
      t.sourceClient = sourceClient
      t.acknowledgedAt = acknowledgedAt
      t.createdAt = createdAt
      t.position = position
      t.kind = kind
      t.heading = heading
      t.conversation = conversation ?? TaskConvo()
      return t
    }
  }

  /// `Area`'s wire keys leave out `position`.
  struct AreaRow: Codable {
    var area: Area
    var position: Int
    var materialized: Area { var a = area; a.position = position; return a }
  }

  /// `Project`'s wire keys leave out `position`.
  struct ProjectRow: Codable {
    var project: Project
    var position: Int
    var materialized: Project { var p = project; p.position = position; return p }
  }
}

/// Reads and removes the snapshot file. The read is synchronous and happens
/// once per process, on the first Today body of a cold launch.
@MainActor
enum TodaySnapshotStore {
  struct Rows {
    let today: [SeptenaTask]
    let inbox: [SeptenaTask]
    let areas: [Area]
    let projects: [Project]
  }

  static var fileURL: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("TodaySnapshot.json")
  }

  /// nil until the first read; `.some(nil)` = no usable file.
  private static var launch: Rows??
  private static var launchDay: String?

  /// The launch snapshot for `day`, or nil when there is none, it is from
  /// another day, or the first task list frame is already on screen (from
  /// then on the live list owns Today).
  static func launchRows(day: String) -> Rows? {
    guard !LaunchPhase.shared.firstFrameDrawn else { return nil }
    if launch == nil { launch = .some(read()) }
    guard let rows = launch ?? nil, launchDay == day else { return nil }
    LaunchTrace.milestone("launch.snapshotUsed")
    return rows
  }

  private static func read() -> Rows? {
    guard let url = fileURL,
          let data = try? Data(contentsOf: url),
          let snap = try? JSONDecoder.taskConvo.decode(TodaySnapshot.self, from: data),
          snap.version == TodaySnapshot.currentVersion
    else { return nil }
    launchDay = snap.day
    return Rows(today: snap.today.map(\.materialized),
                inbox: snap.inbox.map(\.materialized),
                areas: snap.areas.map(\.materialized),
                projects: snap.projects.map(\.materialized))
  }

  /// Sign-out, account switch, account delete: the rows belong to an account
  /// that is no longer here.
  static func invalidate() {
    launch = .some(nil)
    TodaySnapshotWriter.shared.cancelPending()
    guard let url = fileURL else { return }
    TodaySnapshotWriter.io.async { try? FileManager.default.removeItem(at: url) }
  }
}

/// Keeps the snapshot file current. iOS task app only (`SeptaskLaunch`);
/// it compiles everywhere.
@MainActor
final class TodaySnapshotWriter {
  static let shared = TodaySnapshotWriter()

  /// Changes arrive in bursts (local save, sync batch, Spotlight); one write
  /// per burst is enough, and it never runs on the launch path.
  private static let debounce: Duration = .seconds(2)

  /// Writes and removals run in order on one queue, so a removal is never
  /// overtaken by a write that started before it.
  nonisolated static let io = DispatchQueue(label: "com.septena.todaySnapshot", qos: .utility)

  private var started = false
  private var pending: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []

  private init() {}

  /// Idempotent. Writes once now, then after every Today-affecting change.
  func start() {
    guard !started else { return }
    started = true
    let names: [Notification.Name] = [
      .septenaTasksChanged, .septenaStructureChanged, .NSCalendarDayChanged,
    ]
    for name in names {
      observers.append(NotificationCenter.default.addObserver(
        forName: name, object: nil, queue: .main
      ) { _ in
        MainActor.assumeIsolated { TodaySnapshotWriter.shared.schedule() }
      })
    }
    schedule()
  }

  func cancelPending() {
    pending?.cancel()
    pending = nil
  }

  private func schedule() {
    pending?.cancel()
    pending = Task { @MainActor in
      try? await Task.sleep(for: Self.debounce)
      guard !Task.isCancelled else { return }
      self.writeNow()
    }
  }

  private func writeNow() {
    guard let url = TodaySnapshotStore.fileURL else { return }
    let context = LocalStore.shared.container.mainContext
    let today = LocalCache.tasks(in: context, filter: .today)
    let inbox = LocalCache.tasks(in: context, filter: .triage)
    // An empty Today has nothing to draw early: the live read is just as fast.
    guard !(today.isEmpty && inbox.isEmpty) else {
      Self.io.async { try? FileManager.default.removeItem(at: url) }
      return
    }
    let structure = StructureCache.snapshot(in: context)
    let inboxRows = inbox.prefix(TodaySnapshot.rowCap).map(TodaySnapshot.Row.init)
    let todayRows = today.prefix(max(0, TodaySnapshot.rowCap - inboxRows.count))
      .map(TodaySnapshot.Row.init)
    let snapshot = TodaySnapshot(
      day: SeptenaDate.today,
      today: Array(todayRows),
      inbox: Array(inboxRows),
      areas: structure.areas.map { .init(area: $0, position: $0.position) },
      projects: structure.projects.map { .init(project: $0, position: $0.position) })
    guard let data = try? JSONEncoder.taskConvo.encode(snapshot) else { return }
    Self.io.async { Self.write(data, to: url) }
  }

  nonisolated private static func write(_ data: Data, to url: URL) {
    let fm = FileManager.default
    try? fm.createDirectory(at: url.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
    do {
      try data.write(to: url, options: [.atomic])
      var target = url
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try? target.setResourceValues(values)
    } catch {
      SeptenaLog.error("[TodaySnapshot] write failed", error)
    }
  }
}
