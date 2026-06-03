import CloudKit
import SwiftData

/// Publishes a single, tiny CloudKit record holding the watch's entire "Next"
/// payload so the watch can do one O(1) `record(for:)` read instead of replaying
/// the whole zone. Written to the **default** private zone so it stays clear of
/// CKSyncEngine's `septena-v1` zone.
///
/// The payload is the full day's open checklist (`loadNextItems` with no bucket
/// filter) — every habit is tagged with its bucket in `subtitle`, so the watch
/// filters to the current time-of-day bucket itself and the snapshot stays valid
/// all day. It's rewritten on every checklist mutation and on app foreground.
enum WatchSnapshotPublisher {
  static let recordType = "WatchSnapshot"
  static let recordName = "watch-next-snapshot"
  private static let containerID = "iCloud.com.septena.cloud"

  /// Compute on the main actor (SwiftData read), then save off-main. Best-effort:
  /// a failed write is retried by the next mutation / foreground.
  @MainActor
  static func publish(context: ModelContext, date: String = SeptenaDate.today) {
    var items: [NextItem] = []

    // Suggested first — mirrors the app's Next ordering (Suggested → Tasks → …).
    for s in NextSuggestionsModel.visibleSuggestions(context: context) {
      items.append(NextItem(
        id: s.id,
        kind: "suggestion",
        title: s.emoji.map { "\($0) \(s.title)" } ?? s.title,
        subtitle: s.detail,
        trailing: nil,
        overdue: false,
        sortKey: items.count
      ))
    }

    // Today's open tasks next, tagged with their project/area under the title.
    let areaTitle = Dictionary(LocalCache.areas(in: context).map { ($0.id, $0.title) },
                               uniquingKeysWith: { a, _ in a })
    let projectTitle = Dictionary(LocalCache.projects(in: context).map { ($0.id, $0.title) },
                                  uniquingKeysWith: { a, _ in a })
    for task in LocalCache.tasks(in: context, filter: .today) where task.status == .open {
      let list = task.project.flatMap { projectTitle[$0] } ?? task.area.flatMap { areaTitle[$0] }
      items.append(NextItem(
        id: task.id,
        kind: "task",
        title: task.title,
        subtitle: list,
        trailing: nil,
        overdue: task.isOverdue,
        sortKey: items.count
      ))
    }

    // Then chores / habits (all buckets, tagged in subtitle) / supplements.
    for item in ChecklistMirror.loadNextItems(context: context, date: date, bucket: nil).items {
      items.append(NextItem(
        id: item.id, kind: item.kind, title: item.title,
        subtitle: item.subtitle, trailing: item.trailing,
        overdue: item.overdue, sortKey: items.count
      ))
    }

    let response = NextItemsResponse(date: date, bucket: "", items: items)
    guard let payload = try? JSONEncoder().encode(response) else { return }
    Task.detached(priority: .utility) {
      await save(payload: payload, date: date)
    }
  }

  private static func save(payload: Data, date: String) async {
    let db = CKContainer(identifier: containerID).privateCloudDatabase
    let id = CKRecord.ID(recordName: recordName)   // default zone
    do {
      let record = (try? await db.record(for: id))
        ?? CKRecord(recordType: recordType, recordID: id)
      record["payload"]   = payload as CKRecordValue
      record["date"]      = date as CKRecordValue
      record["updatedAt"] = Date() as CKRecordValue
      try await db.save(record)
    } catch {
      // Best-effort — the next publish() call reconciles.
    }
  }
}
