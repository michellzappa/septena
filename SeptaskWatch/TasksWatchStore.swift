import CloudKit
import WidgetKit
import WatchKit

private let ckContainerID = "iCloud.com.septena.cloud"
private let ckZoneName    = "septena-v1"
private let ckZoneID      = CKRecordZone.ID(
  zoneName: ckZoneName,
  ownerName: CKCurrentUserDefaultName
)

/// CloudKit-backed data source for the Septask watch Today list. Reads one
/// precomputed snapshot (written by the Septask iPhone) and writes task
/// mutations straight to the shared zone.
@Observable
final class TasksWatchStore {
  static let shared = TasksWatchStore()

  var tasks: [TasksWatchTaskWire] = []
  var totalCount = 0
  var accentColor: String?
  var isLoading = false
  /// Human-readable phase while the first fetch is in flight.
  var loadingMessage: String?
  var errorMessage: String?
  var lastFetchedAt: Date?
  var completedIDs: Set<String> = []

  private let db: CKDatabase
  private let snapshotRecordID = CKRecord.ID(recordName: TasksWatchSnapshot.recordName)
  private var snapshotDate: String?
  private var fetchTask: Task<Void, Never>?

  private init() {
    db = CKContainer(identifier: ckContainerID).privateCloudDatabase
  }

  private let doneStore = UserDefaults.standard
  private func localDoneIDs(date: String) -> Set<String> {
    guard doneStore.string(forKey: "septaskDoneLocalDate") == date else { return [] }
    return Set(doneStore.stringArray(forKey: "septaskDoneLocalIDs") ?? [])
  }
  private func markDoneLocally(id: String, date: String) {
    if doneStore.string(forKey: "septaskDoneLocalDate") != date {
      doneStore.set(date, forKey: "septaskDoneLocalDate")
      doneStore.set([String](), forKey: "septaskDoneLocalIDs")
    }
    var ids = doneStore.stringArray(forKey: "septaskDoneLocalIDs") ?? []
    if !ids.contains(id) { ids.append(id) }
    doneStore.set(ids, forKey: "septaskDoneLocalIDs")
  }

  private static let dateFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    return f
  }()

  private var today: String {
    snapshotDate ?? Self.dateFmt.string(from: Date())
  }

  private var reconcileTask: Task<Void, Never>?

  private enum FetchError: Error {
    case iCloudUnavailable(String)
    case unreadableSnapshot
  }

  func fetchToday(silent: Bool = false) {
    fetchTask?.cancel()
    fetchTask = Task { @MainActor in
      await _fetch(silent: silent)
    }
  }

  func fetchInBackground() async {
    await _fetch(silent: true)
  }

  private func scheduleReconcile() {
    reconcileTask?.cancel()
    reconcileTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 6_000_000_000)
      guard !Task.isCancelled else { return }
      await self?._fetch(silent: true)
    }
  }

  @MainActor
  private func _fetch(silent: Bool = false) async {
    let showSpinner = !silent && tasks.isEmpty
    if showSpinner {
      isLoading = true
      loadingMessage = "Checking iCloud…"
    }
    errorMessage = nil

    defer {
      if showSpinner {
        isLoading = false
        loadingMessage = nil
      }
      lastFetchedAt = Date()
    }

    guard !Task.isCancelled else { return }

    do {
      try await withTimeout(seconds: 20) { @MainActor [self] in
        let container = CKContainer(identifier: ckContainerID)
        loadingMessage = "Checking iCloud…"
        let status = try await container.accountStatus()
        guard status == .available else {
          throw FetchError.iCloudUnavailable(accountStatusLabel(status))
        }

        guard !Task.isCancelled else { throw CancellationError() }

        loadingMessage = "Loading Today…"
        let record = try await db.record(for: snapshotRecordID)
        guard
          let payload = record["payload"] as? Data,
          let wire = try? JSONDecoder().decode(TasksWatchWire.self, from: payload)
        else {
          throw FetchError.unreadableSnapshot
        }

        let doneLocal = localDoneIDs(date: wire.today)
        self.tasks = wire.tasks.filter { !doneLocal.contains($0.id) }
        self.totalCount = wire.totalCount
        self.accentColor = wire.accentColor
        self.snapshotDate = wire.today
        updateComplication()
        TasksWatchRefresh.scheduleNext()
      }
    } catch is CancellationError {
    } catch FetchError.iCloudUnavailable(let label) {
      errorMessage = "iCloud not available on watch (status: \(label))"
    } catch FetchError.unreadableSnapshot {
      errorMessage = "Couldn't read the watch snapshot. Open Septask on your iPhone."
    } catch let ckError as CKError where ckError.code == .operationCancelled {
    } catch let ckError as CKError where ckError.code == .unknownItem {
      errorMessage = "No data yet. Open Septask on your iPhone to sync your watch."
    } catch let ckError as CKError {
      switch ckError.code {
      case .unknownItem:
        errorMessage = "No data yet. Open Septask on your iPhone to sync your watch."
      case .networkUnavailable, .networkFailure, .serviceUnavailable:
        errorMessage = "No network. Try again in a moment."
      case .notAuthenticated, .permissionFailure:
        errorMessage = "Sign in to iCloud on your watch."
      default:
        let msg = ckError.localizedDescription.lowercased()
        if msg.contains("fetch") || msg.contains("unknown") || msg.contains("not found") {
          errorMessage = "No data yet. Open Septask on your iPhone to sync your watch."
        } else {
          errorMessage = ckError.localizedDescription
        }
      }
    } catch let err as NSError where err.domain == "SeptaskWatch" && err.code == -1000 {
      errorMessage = "Timed out — open Septask on your iPhone, then try again."
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func complete(_ task: TasksWatchTaskWire) {
    guard !completedIDs.contains(task.id) else { return }
    let date = today

    WKInterfaceDevice.current().play(.success)
    completedIDs.insert(task.id)
    markDoneLocally(id: task.id, date: date)
    updateComplication()

    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_100_000_000)
      tasks.removeAll { $0.id == task.id }
      completedIDs.remove(task.id)
    }

    Task {
      do {
        try await saveTaskCompletion(taskID: task.id)
        scheduleReconcile()
      } catch { }
    }
  }

  func cancelTask(_ task: TasksWatchTaskWire) {
    Task {
      do {
        try await saveTaskCancel(taskID: task.id)
        await MainActor.run {
          markDoneLocally(id: task.id, date: today)
          tasks.removeAll { $0.id == task.id }
          updateComplication()
        }
        scheduleReconcile()
      } catch { }
    }
  }

  func offTodayTask(_ task: TasksWatchTaskWire) {
    Task {
      do {
        try await saveTaskOffToday(taskID: task.id)
        await MainActor.run {
          markDoneLocally(id: task.id, date: today)
          tasks.removeAll { $0.id == task.id }
          updateComplication()
        }
        scheduleReconcile()
      } catch { }
    }
  }

  func addInboxTask(title: String) {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    WKInterfaceDevice.current().play(.success)
    let date = today
    Task {
      do { try await saveInboxTask(title: trimmed, date: date) }
      catch { }
    }
  }

  private func updateComplication() {
    TasksTodayComplicationData(
      remaining: tasks.count,
      firstTitle: tasks.first?.title,
      updatedAt: Date()
    ).save()
    WidgetCenter.shared.reloadTimelines(ofKind: "SeptaskToday")
  }

  private func accountStatusLabel(_ status: CKAccountStatus) -> String {
    switch status {
    case .available: return "available"
    case .noAccount: return "no iCloud account"
    case .restricted: return "restricted"
    case .couldNotDetermine: return "could not determine"
    case .temporarilyUnavailable: return "temporarily unavailable"
    @unknown default: return "unknown (\(status.rawValue))"
    }
  }

  private func withTimeout(
    seconds: Double,
    _ operation: @escaping @MainActor @Sendable () async throws -> Void
  ) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { @MainActor in try await operation() }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        throw NSError(
          domain: "SeptaskWatch", code: -1000,
          userInfo: [NSLocalizedDescriptionKey:
            "Timed out after \(Int(seconds))s — CloudKit didn't respond"])
      }
      try await group.next()
      group.cancelAll()
    }
  }

  private func saveTaskCompletion(taskID: String) async throws {
    let recordID = CKRecord.ID(recordName: taskID, zoneID: ckZoneID)
    guard let record = try? await db.record(for: recordID) else { return }
    record["status"] = "done"
    record["completedAt"] = Self.tsFmt.string(from: Date())
    record["today"] = 0
    try await db.save(record)
  }

  private func saveTaskCancel(taskID: String) async throws {
    let recordID = CKRecord.ID(recordName: taskID, zoneID: ckZoneID)
    guard let record = try? await db.record(for: recordID) else { return }
    record["status"] = "cancelled"
    record["completedAt"] = Self.tsFmt.string(from: Date())
    record["today"] = 0
    try await db.save(record)
  }

  private func saveTaskOffToday(taskID: String) async throws {
    let recordID = CKRecord.ID(recordName: taskID, zoneID: ckZoneID)
    guard let record = try? await db.record(for: recordID) else { return }
    record["today"] = 0
    record["todaySetOn"] = nil
    if let scheduled = record["scheduled"] as? String, scheduled <= today {
      record["scheduled"] = nil
    }
    try await db.save(record)
  }

  private func saveInboxTask(title: String, date: String) async throws {
    let id = String(UUID().uuidString.lowercased().prefix(8))
    let recordID = CKRecord.ID(recordName: id, zoneID: ckZoneID)
    let record = CKRecord(recordType: "Task", recordID: recordID)
    record["title"] = title
    record["status"] = "open"
    record["created"] = date
    record["today"] = 0
    record["source"] = "app"
    record["sourceClient"] = "watch"
    record["createdAt"] = Date()
    try await db.save(record)
  }

  private static let tsFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()
}
