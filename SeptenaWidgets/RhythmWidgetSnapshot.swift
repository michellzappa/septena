import CloudKit
import SwiftUI

/// Reads the iPhone-published rhythm snapshot for the time-wheel widget.
///
/// It's the **same** `WatchSnapshot` record the Next widget reads — the rhythm
/// blob rides along in the additive `rhythmPayload` field (see
/// `WatchSnapshotPublisher`). One O(1) `record(for:)`, no zone replay; the
/// wire's color tokens are re-resolved through `AdaptiveColor` here so the
/// dots stay appearance-adaptive at render time.
enum RhythmWidgetSnapshot {
  private static let containerID = "iCloud.com.septena.cloud"
  private static let recordID    = CKRecord.ID(recordName: "watch-next-snapshot")

  /// Render-ready rhythm: wheel marks + a color legend, mapped off the wire.
  struct Content {
    var events: [TimeOfDayWheel.Event] = []
    var bands: [TimeOfDayWheel.Band] = []
    var legend: [LegendItem] = []
    var windowDays: Int = 7
    var isEmpty: Bool { events.isEmpty && bands.isEmpty }
  }

  struct LegendItem: Identifiable {
    let key: String
    let label: String
    let color: Color
    var id: String { key }
  }

  /// Resolved content, or an empty snapshot whenever iCloud is unavailable,
  /// nothing is published yet, or the read stalls — the widget never spins.
  static func load() async -> Content {
    let container = CKContainer(identifier: containerID)
    guard (try? await container.accountStatus()) == .available else { return Content() }

    let db = container.privateCloudDatabase
    guard
      let record = try? await withTimeout(seconds: 10, { try await db.record(for: recordID) }),
      let data   = record["rhythmPayload"] as? Data,
      let wire   = try? JSONDecoder().decode(RhythmWire.self, from: data)
    else { return Content() }

    return map(wire)
  }

  /// Wire → render-ready, re-resolving color tokens via `AdaptiveColor`.
  static func map(_ wire: RhythmWire) -> Content {
    Content(
      events: wire.events.map {
        TimeOfDayWheel.Event(id: $0.id, fraction: $0.fraction, daysAgo: $0.daysAgo,
                             color: $0.colorHex.flatMap(AdaptiveColor.adaptive))
      },
      bands: wire.bands.map {
        TimeOfDayWheel.Band(id: $0.id, start: $0.start, end: $0.end, daysAgo: $0.daysAgo,
                            color: $0.colorHex.flatMap(AdaptiveColor.adaptive),
                            thin: $0.thin, opaque: $0.opaque)
      },
      legend: wire.legend.map {
        LegendItem(key: $0.key, label: $0.label,
                   color: AdaptiveColor.adaptive($0.colorHex) ?? .secondary)
      },
      windowDays: wire.windowDays
    )
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
