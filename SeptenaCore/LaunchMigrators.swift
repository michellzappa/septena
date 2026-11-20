import Foundation
import SwiftData

// Shared launch-time helpers, split out of CloudKit/Migration.swift
// (#42, docs/SEPTASK_BACKEND.md §9 phase 4) so both apps compile them
// without the CloudKit task migrator: `EventTimestamp` (event mutators) and
// the once-per-device launch migrators `SeptenaServices.start()` runs.

// MARK: - Event timestamp

/// Combines a `yyyy-MM-dd` date string with an optional `HH:mm[:ss]` time
/// string into a `Date` in the current time zone. Used by the event mutators
/// so `occurredAt` is derived identically for every write.
enum EventTimestamp {
  private static func formatter(_ format: String) -> DateFormatter {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .iso8601)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = format
    return f
  }
  private static let withSeconds = formatter("yyyy-MM-dd HH:mm:ss")
  private static let withMinutes = formatter("yyyy-MM-dd HH:mm")
  private static let dayOnly = formatter("yyyy-MM-dd")

  /// Best-effort instant for a logged event:
  /// - `time` "HH:mm:ss" or "HH:mm" → combined with `date`.
  /// - `time` nil/empty → local noon of `date` (day-granular rows have no real
  ///   moment; noon keeps them in the correct local day under TZ shifts).
  /// - unparseable → local start-of-day of `date`, else `.now`.
  static func from(date: String, time: String?) -> Date {
    let t = time?.trimmingCharacters(in: .whitespaces) ?? ""
    if !t.isEmpty {
      let stamp = "\(date) \(t)"
      if let d = withSeconds.date(from: stamp) { return d }
      if let d = withMinutes.date(from: stamp) { return d }
    } else if let day = dayOnly.date(from: date) {
      return Calendar.current.date(byAdding: .hour, value: 12, to: day) ?? day
    }
    return dayOnly.date(from: date) ?? .now
  }

  /// Local "HH:mm" of an instant — the inverse of `from` for the update path:
  /// when only the day changes we preserve the existing time-of-day by deriving
  /// it from `occurredAt`, now that the legacy `time` STRING field is retired.
  static func hhmm(from instant: Date) -> String {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .iso8601)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "HH:mm"
    return f.string(from: instant)
  }

  /// Local wall-clock ISO8601 without zone suffix — matches `concludedAt` /
  /// `endedAt` on exercise entries (`YYYY-MM-DDTHH:mm:ss`).
  static func localISO(from instant: Date) -> String {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .iso8601)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return f.string(from: instant)
  }

  /// Parse a local ISO stamp written by `localISO(from:)`.
  static func fromLocalISO(_ stamp: String) -> Date? {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .iso8601)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return f.date(from: stamp)
  }
}

/// Event entities whose `occurredAt` can be repaired from their `date` string.
/// Empty conformances — the stored properties already exist; this just gives
/// `OccurredAtBackfill` a uniform handle to fix them.
protocol OccurredAtRepairable: AnyObject {
  var date: String { get }
  var occurredAt: Date { get set }
}

extension GutEventEntity: OccurredAtRepairable {}
extension MoodEventEntity: OccurredAtRepairable {}
extension ChoreEventEntity: OccurredAtRepairable {}
extension HabitDayStateEntity: OccurredAtRepairable {}
extension SupplementDayStateEntity: OccurredAtRepairable {}
extension ExerciseEntryEntity: OccurredAtRepairable {}

/// One-shot, local-only repair for event rows created before the `occurredAt`
/// migration: their instant is the `.distantPast` sentinel, which sorts them to
/// the dawn of time and pins hour-of-day at 00:00 — skewing learned-time
/// medians and the unified timeline. The legacy `time` STRING is gone, so the
/// best recoverable instant is local noon of the row's `date`, exactly what
/// `EventTimestamp.from(date:, time: nil)` yields.
///
/// Not pushed to CloudKit: legacy records carry no `occurredAt` value, so a
/// re-fetch can't clobber the local fix, and the only consumers (learned-time
/// suggestions, the timeline) are local. Gated by a UserDefaults version flag
/// so it runs once per device; runs after the initial CloudKit fetch so rows
/// synced on a fresh install are present. (Nutrition/hydration are excluded —
/// they key on `loggedAt`, which is always populated, never `.distantPast`.)
@MainActor
enum OccurredAtBackfill {
  private static let versionKey = "events.occurredAtBackfill.v2"

  static func runIfNeeded(context: ModelContext, defaults: UserDefaults = .standard) {
    guard !defaults.bool(forKey: versionKey) else { return }
    var fixed = 0
    fixed += repair(GutEventEntity.self, context: context)
    fixed += repair(MoodEventEntity.self, context: context)
    fixed += repair(ChoreEventEntity.self, context: context)
    fixed += repair(HabitDayStateEntity.self, context: context)
    fixed += repair(SupplementDayStateEntity.self, context: context)
    fixed += repair(ExerciseEntryEntity.self, context: context)
    if fixed > 0 {
      do {
        try StoreHealth.saveOrThrow(context, op: "Migration.runIfNeeded")
      } catch {
        // Leave the gate unset so a later launch retries the repair.
        SeptenaLog.error("OccurredAtBackfill.save", error)
        return
      }
    }
    defaults.set(true, forKey: versionKey)
  }

  private static func repair<E: PersistentModel & OccurredAtRepairable>(
    _ type: E.Type, context: ModelContext) -> Int {
    guard let rows = try? context.fetch(FetchDescriptor<E>()) else { return 0 }
    var n = 0
    for row in rows where row.occurredAt == .distantPast {
      row.occurredAt = EventTimestamp.from(date: row.date, time: nil)
      n += 1
    }
    return n
  }
}

// MARK: - Gut → Symptoms migration (discomfort + blood → symptom events)

/// One-shot, local-only migration that lifts the symptom-shaped fields out of
/// the Gut bowel-movement log (`discomfortLevel`, `blood`) into standalone
/// Symptoms events. The gut rows are left untouched here — stripping those
/// fields is a separate, later step, so this stays lossless and reversible.
/// Deterministic ids (`GutSymptomMap`) make it idempotent; gated by a
/// UserDefaults flag so it runs once per device, after the initial CloudKit
/// fetch so synced gut rows are present. See docs/GUT_SYMPTOMS_MIGRATION_PLAN.
@MainActor
enum GutSymptomMigrator {
  private static let versionKey = "gut.symptomMigration.v1"

  @discardableResult
  static func runIfNeeded(context: ModelContext,
                          mutator: SymptomsMutator,
                          defaults: UserDefaults = .standard) -> Int {
    guard !defaults.bool(forKey: versionKey) else { return 0 }
    guard let rows = try? context.fetch(FetchDescriptor<GutEventEntity>()) else { return 0 }

    // Resolve each target definition lazily and at most once.
    var discomfortDefID: String?
    var bloodDefID: String?
    var created = 0

    for row in rows {
      let hasDiscomfort = GutSymptomMap.discomfortSeverity(row.discomfortLevel) != nil
      let trimmed = row.note?.trimmingCharacters(in: .whitespacesAndNewlines)
      let note = (trimmed?.isEmpty == false) ? trimmed : nil

      if let severity = GutSymptomMap.discomfortSeverity(row.discomfortLevel) {
        let defID = discomfortDefID ?? mutator.ensureDefinition(
          title: GutSymptomMap.discomfortTitle, emoji: "🫄",
          bodySystem: "Digestive", defaultBodyRegion: "Abdomen",
          fallbackID: GutSymptomMap.discomfortDefinitionID)
        discomfortDefID = defID
        mutator.upsertMigratedEvent(
          id: GutSymptomMap.discomfortEventID(gutID: row.id),
          symptomID: defID, date: row.date, occurredAt: row.occurredAt,
          severity: severity,
          durationMinutes: discomfortMinutes(start: row.discomfortStart, end: row.discomfortEnd),
          note: note, source: "migrated-gut")
        created += 1
      }

      if let severity = GutSymptomMap.bloodSeverity(row.blood) {
        let defID = bloodDefID ?? mutator.ensureDefinition(
          title: GutSymptomMap.bloodTitle, emoji: "🩸",
          bodySystem: "Digestive", defaultBodyRegion: "Rectum",
          fallbackID: GutSymptomMap.bloodDefinitionID)
        bloodDefID = defID
        // The free-text note rides the discomfort event when present, so the
        // blood event carries a neutral marker instead of duplicating it.
        let bloodNote = hasDiscomfort ? "with BM" : (note ?? "with BM")
        mutator.upsertMigratedEvent(
          id: GutSymptomMap.bloodEventID(gutID: row.id),
          symptomID: defID, date: row.date, occurredAt: row.occurredAt,
          severity: severity, durationMinutes: nil,
          note: bloodNote, source: "migrated-gut")
        created += 1
      }
    }

    SeptenaLog.info("GutSymptomMigrator: upserted \(created) symptom events from \(rows.count) gut rows")
    defaults.set(true, forKey: versionKey)
    return created
  }

  /// Minutes between the ISO discomfort-window bounds, when both parse.
  private static func discomfortMinutes(start: String?, end: String?) -> Int? {
    guard let start, let end else { return nil }
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var s = fmt.date(from: start); var e = fmt.date(from: end)
    if s == nil || e == nil {
      let alt = ISO8601DateFormatter(); alt.formatOptions = [.withInternetDateTime]
      s = s ?? alt.date(from: start); e = e ?? alt.date(from: end)
    }
    guard let s, let e, e > s else { return nil }
    return Int((e.timeIntervalSince(s) / 60).rounded())
  }
}

// MARK: - Someday → Anytime status migration

/// One-shot migration that retires the legacy `someday` task status. The
/// "Someday" bucket merged into "Anytime" — a parked task is now just an open,
/// dateless task. `TaskStatus(rawValue:)` already coerces an unknown
/// `"someday"` string to `.open` on read, so display and filtering are already
/// correct without this; but the *stored* value (locally and in CloudKit)
/// would stay stale until the row was next edited. This rewrites `statusRaw`
/// to `"open"` and pushes the fix so the data model stays honest. Idempotent
/// (re-running finds nothing); gated once-per-device; runs after the initial
/// CloudKit fetch so synced someday rows are present.
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

/// One-shot: restore MCP proposals that Septask peek/select accidentally
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
