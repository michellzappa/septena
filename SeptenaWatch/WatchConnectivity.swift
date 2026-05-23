import CloudKit
import WidgetKit

// MARK: - CloudKit constants (must match SeptenaCloudKit in the iOS target)

private let ckContainerID = "iCloud.com.septena.cloud"
private let ckZoneName    = "septena-v1"
private let ckZoneID      = CKRecordZone.ID(
  zoneName: ckZoneName,
  ownerName: CKCurrentUserDefaultName
)

// MARK: - WatchConnectivity

/// CloudKit-backed data source for the watch's Next view.
/// Reads HabitDefinition/Event, SupplementDefinition/Event, and
/// ChoreDefinition/Event directly from the private CK database —
/// no WCSession or FastAPI dependency.
@Observable
final class WatchConnectivity {
  static let shared = WatchConnectivity()

  var items: [NextItem] = []
  var bucket: String = ""
  var isLoading = false
  var errorMessage: String?

  private let db: CKDatabase

  private init() {
    db = CKContainer(identifier: ckContainerID).privateCloudDatabase
  }

  // MARK: - Date helpers

  private static let dateFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    return f
  }()

  private var today: String { Self.dateFmt.string(from: Date()) }

  private func currentBucket() -> String {
    let hour = Calendar.current.component(.hour, from: Date())
    switch hour {
    case 5..<12:  return "morning"
    case 12..<17: return "afternoon"
    default:      return "evening"
    }
  }

  // MARK: - Foreground fetch

  func fetchNext() {
    Task { await _fetch() }
  }

  func fetchInBackground() async {
    await _fetch()
  }

  @MainActor
  private func _fetch() async {
    isLoading = true
    errorMessage = nil

    do {
      let date = today
      let bkt  = currentBucket()

      // Parallel fetch of all six record types.
      async let habitDefsTask   = fetchAll("HabitDefinition")
      async let habitEventsTask = fetchAll("HabitEvent")
      async let suppDefsTask    = fetchAll("SupplementDefinition")
      async let suppEventsTask  = fetchAll("SupplementEvent")
      async let choreDefsTask   = fetchAll("ChoreDefinition")
      async let choreEventsTask = fetchAll("ChoreEvent")

      let (habitDefRecs, habitEventRecs,
           suppDefRecs, suppEventRecs,
           choreDefRecs, choreEventRecs) = try await (
        habitDefsTask, habitEventsTask,
        suppDefsTask,  suppEventsTask,
        choreDefsTask, choreEventsTask
      )

      // Decode into lightweight value types.
      let habitDefs = habitDefRecs.map(HabitDef.init)
        .sorted { $0.sortIndex < $1.sortIndex }
      let doneHabitIDs = Set(
        habitEventRecs
          .compactMap { HabitEventRec($0) }
          .filter { $0.date == date && $0.done }
          .map(\.habitID)
      )

      let suppDefs = suppDefRecs.map(SuppDef.init)
        .sorted { $0.sortIndex < $1.sortIndex }
      let doneSupplementIDs = Set(
        suppEventRecs
          .compactMap { SuppEventRec($0) }
          .filter { $0.date == date && $0.done }
          .map(\.supplementID)
      )

      let choreDefs = choreDefRecs.map(ChoreDef.init)
        .sorted { $0.sortIndex < $1.sortIndex }
      let choreEvents = choreEventRecs.compactMap(ChoreEventRec.init)
        .sorted { $0.sortKey < $1.sortKey }
      let eventsByChore = Dictionary(grouping: choreEvents, by: \.choreID)

      // Build the items list.
      var result: [NextItem] = []
      var sortKey = 0

      // 1. Habits in the current bucket that are not yet done today.
      for h in habitDefs where h.bucket == bkt && !doneHabitIDs.contains(h.id) {
        result.append(NextItem(
          id: h.id, kind: "habit",
          title: [h.emoji, h.title].compactMap { $0 }.joined(separator: " "),
          subtitle: nil, trailing: nil, overdue: false, sortKey: sortKey
        ))
        sortKey += 1
      }

      // 2. Supplements not yet done today.
      for s in suppDefs where !doneSupplementIDs.contains(s.id) {
        result.append(NextItem(
          id: s.id, kind: "supplement",
          title: [s.emoji, s.title].compactMap { $0 }.joined(separator: " "),
          subtitle: nil, trailing: nil, overdue: false, sortKey: sortKey
        ))
        sortKey += 1
      }

      // 3. Chores due today or overdue (mirrors ChecklistMirror.choreItem logic).
      for chore in choreDefs {
        let dueDate     = computeDueDate(chore: chore, events: eventsByChore[chore.id] ?? [])
        let daysOverdue = daysBetween(start: dueDate, end: date)
        guard daysOverdue >= 0 else { continue }
        let trail = daysOverdue > 0 ? "\(daysOverdue)d overdue" : nil
        result.append(NextItem(
          id: chore.id, kind: "chore",
          title: [chore.emoji, chore.title].compactMap { $0 }.joined(separator: " "),
          subtitle: nil, trailing: trail, overdue: daysOverdue > 0, sortKey: sortKey
        ))
        sortKey += 1
      }

      self.items  = result
      self.bucket = bkt
      updateComplication()
      scheduleNextRefresh()
    } catch {
      errorMessage = error.localizedDescription
    }

    isLoading = false
  }

  // MARK: - Mutations

  func complete(_ item: NextItem) {
    items.removeAll { $0.id == item.id }
    updateComplication()

    let date = today
    Task {
      do {
        switch item.kind {
        case "habit":      try await saveHabitEvent(habitID: item.id, date: date)
        case "supplement": try await saveSupplementEvent(supplementID: item.id, date: date)
        case "chore":      try await saveChoreEvent(choreID: item.id, date: date)
        default: break
        }
      } catch {
        // Fire-and-forget: the iOS CKSyncEngine reconciles on next open.
      }
    }
  }

  // MARK: - CloudKit write helpers

  private func saveHabitEvent(habitID: String, date: String) async throws {
    // Record name mirrors HabitEventCloudKitSchema.recordName(for:) on iOS.
    let entityID   = "habit:\(date):\(habitID)"
    let recordID   = CKRecord.ID(recordName: "habit-event:\(entityID)", zoneID: ckZoneID)
    let existing   = try? await db.record(for: recordID)
    let record     = existing ?? CKRecord(recordType: "HabitEvent", recordID: recordID)
    record["date"]    = date
    record["habitID"] = habitID
    record["done"]    = 1
    record["skipped"] = 0
    try await db.save(record)
  }

  private func saveSupplementEvent(supplementID: String, date: String) async throws {
    let entityID = "supplement:\(date):\(supplementID)"
    let recordID = CKRecord.ID(recordName: "supplement-event:\(entityID)", zoneID: ckZoneID)
    let existing = try? await db.record(for: recordID)
    let record   = existing ?? CKRecord(recordType: "SupplementEvent", recordID: recordID)
    record["date"]         = date
    record["supplementID"] = supplementID
    record["done"]         = 1
    try await db.save(record)
  }

  private func saveChoreEvent(choreID: String, date: String) async throws {
    // Each completion is a new event record; UUID avoids ID collisions.
    let eventID  = UUID().uuidString
    let recordID = CKRecord.ID(recordName: "chore-event:\(eventID)", zoneID: ckZoneID)
    let record   = CKRecord(recordType: "ChoreEvent", recordID: recordID)
    record["choreID"] = choreID
    record["action"]  = "complete"
    record["date"]    = date
    record["sortKey"] = "\(date)::\(eventID)"
    try await db.save(record)
  }

  // MARK: - CloudKit read helper

  private func fetchAll(_ recordType: String) async throws -> [CKRecord] {
    let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
    var results: [CKRecord] = []

    let (matchResults, cursor) = try await db.records(
      matching: query,
      inZoneWith: ckZoneID
    )
    for (_, result) in matchResults {
      if let r = try? result.get() { results.append(r) }
    }

    var nextCursor = cursor
    while let c = nextCursor {
      let (more, moreCursor) = try await db.records(continuingMatchFrom: c)
      for (_, result) in more {
        if let r = try? result.get() { results.append(r) }
      }
      nextCursor = moreCursor
    }

    return results
  }

  // MARK: - Complication

  private func updateComplication() {
    NextComplicationData(
      bucket: bucket,
      remaining: items.count,
      firstTitle: items.first?.title,
      updatedAt: Date()
    ).save()
    WidgetCenter.shared.reloadTimelines(ofKind: "SeptenaNext")
  }

  // MARK: - Chore due-date logic (mirrors ChecklistMirror.choreItem on iOS)

  private func computeDueDate(chore: ChoreDef, events: [ChoreEventRec]) -> String {
    var dueDate = today
    for event in events {
      switch event.action {
      case "complete":
        if let cadence = chore.cadenceDays,
           let next    = shiftDate(event.date, byDays: cadence) {
          dueDate = next
        }
      case "defer":
        if let newDue = event.newDueDate { dueDate = newDue }
      default:
        break
      }
    }
    return dueDate
  }

  private func shiftDate(_ dateStr: String, byDays days: Int) -> String? {
    guard let base    = Self.dateFmt.date(from: dateStr),
          let shifted = Calendar.current.date(byAdding: .day, value: days, to: base)
    else { return nil }
    return Self.dateFmt.string(from: shifted)
  }

  private func daysBetween(start: String, end: String) -> Int {
    guard let s = Self.dateFmt.date(from: start),
          let e = Self.dateFmt.date(from: end) else { return 0 }
    return Calendar.current.dateComponents([.day], from: s, to: e).day ?? 0
  }
}

// MARK: - Lightweight record decoders

private struct HabitDef {
  let id: String
  let title: String
  let emoji: String?
  let bucket: String
  let sortIndex: Int

  init(_ r: CKRecord) {
    id        = String(r.recordID.recordName.dropFirst("habit-def:".count))
    title     = r["title"] as? String ?? ""
    emoji     = r["emoji"] as? String
    bucket    = r["bucket"] as? String ?? "morning"
    sortIndex = r["sortIndex"] as? Int ?? 0
  }
}

private struct SuppDef {
  let id: String
  let title: String
  let emoji: String?
  let sortIndex: Int

  init(_ r: CKRecord) {
    id        = String(r.recordID.recordName.dropFirst("supplement-def:".count))
    title     = r["title"] as? String ?? ""
    emoji     = r["emoji"] as? String
    sortIndex = r["sortIndex"] as? Int ?? 0
  }
}

private struct ChoreDef {
  let id: String
  let title: String
  let emoji: String?
  let cadenceDays: Int?
  let sortIndex: Int

  init(_ r: CKRecord) {
    id          = String(r.recordID.recordName.dropFirst("chore-def:".count))
    title       = r["title"] as? String ?? ""
    emoji       = r["emoji"] as? String
    cadenceDays = r["cadenceDays"] as? Int
    sortIndex   = r["sortIndex"] as? Int ?? 0
  }
}

private struct HabitEventRec {
  let habitID: String
  let date: String
  let done: Bool

  init?(_ r: CKRecord) {
    guard let hid = r["habitID"] as? String,
          let d   = r["date"]    as? String else { return nil }
    habitID = hid
    date    = d
    done    = (r["done"] as? Int ?? 0) != 0
  }
}

private struct SuppEventRec {
  let supplementID: String
  let date: String
  let done: Bool

  init?(_ r: CKRecord) {
    guard let sid = r["supplementID"] as? String,
          let d   = r["date"]         as? String else { return nil }
    supplementID = sid
    date         = d
    done         = (r["done"] as? Int ?? 0) != 0
  }
}

private struct ChoreEventRec {
  let choreID: String
  let action: String
  let date: String
  let sortKey: String
  let newDueDate: String?

  init?(_ r: CKRecord) {
    guard let cid = r["choreID"] as? String,
          let act = r["action"]  as? String,
          let d   = r["date"]    as? String else { return nil }
    choreID    = cid
    action     = act
    date       = d
    sortKey    = r["sortKey"] as? String ?? d
    newDueDate = r["newDueDate"] as? String
  }
}
