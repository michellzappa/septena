import Foundation
import SwiftData

// Launch-time one-shot data migrators for the task store.

// MARK: - Someday → Anytime status migration

/// One-shot migration that retires the legacy `someday` task status. The
/// "Someday" bucket merged into "Anytime" — a parked task is now just an open,
/// dateless task. `TaskStatus(rawValue:)` already coerces an unknown
/// `"someday"` string to `.open` on read, so display and filtering are already
/// correct without this; but the *stored* value would stay stale until the row
/// was next edited. Idempotent; gated once-per-device.
@MainActor
enum SomedayStatusMigrator {
  private static let versionKey = "tasks.somedayMerge.v1"

  @discardableResult
  static func runIfNeeded(context: ModelContext, engine: CKEngine,
                          defaults: UserDefaults = .standard) -> Int {
    guard !defaults.bool(forKey: versionKey) else { return 0 }
    guard let rows = try? context.fetch(FetchDescriptor<TaskEntity>()) else { return 0 }

    var changedIDs: [String] = []
    for row in rows where row.statusRaw == "someday" {
      row.statusRaw = TaskStatus.open.rawValue
      row.pendingSync = true
      changedIDs.append(row.id)
    }
    guard !changedIDs.isEmpty else {
      defaults.set(true, forKey: versionKey)
      return 0
    }
    do {
      try StoreHealth.saveOrThrow(context, op: "Migration.runIfNeeded")
    } catch {
      // Leave the gate unset so a later launch retries the rewrite.
      SeptenaLog.error("SomedayStatusMigrator.save", error)
      return 0
    }
    for id in changedIDs { engine.noteTaskChange(id: id) }
    NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    SeptenaLog.info("SomedayStatusMigrator: rewrote \(changedIDs.count) someday tasks → open")
    defaults.set(true, forKey: versionKey)
    return changedIDs.count
  }
}

// MARK: - Peek-ack proposal recovery

/// One-shot: restore MCP proposals that Septena peek/select accidentally
/// acknowledged (cleared the glow and, under the old band predicate, yanked
/// them out of Inbox into Anytime). Birth-acked committed creates
/// (`acknowledgedAt ≈ createdAt`) are left alone — those were intentional.
/// Targets undated, unfiled, open mcp rows whose ack lagged create by >30s.
@MainActor
enum PeekAckProposalRecovery {
  private static let versionKey = "tasks.peekAckRecovery.v1"
  private static let minLag: TimeInterval = 30

  @discardableResult
  static func runIfNeeded(context: ModelContext, mutator: TaskMutator,
                          defaults: UserDefaults = .standard) -> Int {
    guard !defaults.bool(forKey: versionKey) else { return 0 }
    guard let rows = try? context.fetch(FetchDescriptor<TaskEntity>()) else { return 0 }

    var restored: [String] = []
    for row in rows {
      guard row.source == TaskSource.mcp,
            row.isInInbox,
            !row.today, row.scheduled == nil, row.deadline == nil,
            let acked = row.acknowledgedAt,
            row.createdAt != .distantPast
      else { continue }
      let lag = acked.timeIntervalSince(row.createdAt)
      guard lag > minLag else { continue }
      mutator.unacknowledge(id: row.id)
      restored.append(row.id)
    }
    defaults.set(true, forKey: versionKey)
    if !restored.isEmpty {
      SeptenaLog.info(
        "PeekAckProposalRecovery: restored \(restored.count) proposals → Inbox "
        + "(\(restored.joined(separator: ", ")))")
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    }
    return restored.count
  }
}
