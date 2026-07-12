import CloudKit
import SwiftData
import WidgetKit

/// Publishes a single CloudKit record holding Septask's Today task list so the
/// watch can do one O(1) read. Written to the **default** private zone (same
/// pattern as `WatchSnapshotPublisher`) with a distinct record name so it never
/// collides with Septena's Next snapshot.
enum TasksWatchSnapshotPublisher {
  /// Reuse the deployed `WatchSnapshot` type — distinct `recordName` only.
  static let recordType = TasksWatchSnapshot.recordType
  static let recordName = TasksWatchSnapshot.recordName
  private static let containerID = "iCloud.com.septena.cloud"

  @MainActor private static var pending: Task<Void, Never>?
  @MainActor private static var observers: [NSObjectProtocol]?

  @MainActor
  static func schedule(context: ModelContext, date: String) {
    pending?.cancel()
    pending = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(800))
      guard !Task.isCancelled else { return }
      pending = nil
      publish(context: context, date: date)
    }
  }

  @MainActor
  static func install(context: ModelContext) {
    #if !os(iOS)
    return
    #else
    guard observers == nil else { return }
    let center = NotificationCenter.default
    let tasks = center.addObserver(
      forName: .septenaTasksChanged, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { schedule(context: context, date: SeptenaDate.today) }
    }
    let dayChange = center.addObserver(
      forName: .NSCalendarDayChanged, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { schedule(context: context, date: SeptenaDate.today) }
    }
    observers = [tasks, dayChange]
    schedule(context: context, date: SeptenaDate.today)
    #endif
  }

  @MainActor
  static func publish(context: ModelContext, date: String) {
    let wire = TasksWatchBuilder.buildSnapshot(context: context)
    guard let payload = try? JSONEncoder().encode(wire) else { return }

    Task.detached(priority: .utility) {
      await save(payload: payload, date: date)
    }
  }

  private static func save(payload: Data, date: String) async {
    #if !os(iOS)
    return
    #else
    let db = CKContainer(identifier: containerID).privateCloudDatabase
    let id = CKRecord.ID(recordName: recordName)
    do {
      let record = (try? await db.record(for: id))
        ?? CKRecord(recordType: recordType, recordID: id)
      record["payload"] = payload as CKRecordValue
      record["date"] = date as CKRecordValue
      record["updatedAt"] = Date() as CKRecordValue
      try await db.save(record)
    } catch {
      // Best-effort — the next publish reconciles.
    }
    #endif
  }
}
