import CloudKit

/// Reads the iPhone-published "Next" snapshot for the widget.
///
/// The phone precomputes the whole day's open checklist into one tiny
/// `WatchSnapshot` record in the **default** private zone (see
/// `WatchSnapshotPublisher`). The watch already reads this exact record; the
/// widget does the same — a single O(1) `record(for:)` with no zone replay —
/// and narrows it to the current time-of-day bucket via the shared
/// `NextItemsResponse.itemsForBucket(_:)` helper so the two surfaces can't
/// disagree about what's due now.
enum NextWidgetSnapshot {
  private static let containerID = "iCloud.com.septena.cloud"
  private static let recordID    = CKRecord.ID(recordName: "watch-next-snapshot")

  /// The current bucket's open items. Returns `[]` (→ empty state) whenever
  /// iCloud is unavailable, nothing is published yet, or the read stalls —
  /// the widget never shows a spinner or hangs the timeline reload.
  static func loadItems() async -> [NextItem] {
    let container = CKContainer(identifier: containerID)
    guard (try? await container.accountStatus()) == .available else { return [] }

    let db = container.privateCloudDatabase
    guard
      let record   = try? await withTimeout(seconds: 10, { try await db.record(for: recordID) }),
      let payload  = record["payload"] as? Data,
      let response = try? JSONDecoder().decode(NextItemsResponse.self, from: payload)
    else { return [] }

    return response.itemsForBucket(.current)
  }

  /// Fail a CloudKit read after `seconds` so a stall surfaces as an empty
  /// state rather than blocking the extension's tight refresh budget.
  private static func withTimeout<T: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        throw CancellationError()
      }
      defer { group.cancelAll() }
      return try await group.next()!
    }
  }
}
