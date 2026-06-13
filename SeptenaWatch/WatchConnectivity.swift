import CloudKit
import WidgetKit
import WatchKit

// MARK: - CloudKit constants (must match SeptenaCloudKit in the iOS target)

private let ckContainerID = "iCloud.com.septena.cloud"
private let ckZoneName    = "septena-v1"
private let ckZoneID      = CKRecordZone.ID(
  zoneName: ckZoneName,
  ownerName: CKCurrentUserDefaultName
)

// MARK: - WatchConnectivity

/// CloudKit-backed data source for the watch's Next view.
/// Reads one precomputed `WatchSnapshot` record (written by the iPhone) for the
/// list, and writes completion events straight to the `septena-v1` zone — no
/// WCSession or FastAPI dependency.
@Observable
final class WatchConnectivity {
  static let shared = WatchConnectivity()

  var items: [NextItem] = []
  /// Section key → authored color token from the snapshot, so the Next list
  /// can tint its group rules with the phone's actual section accents.
  var sectionColors: [String: String] = [:]
  /// The user's enabled intake trackers from the snapshot — the + menu offers
  /// one quick-log row per tracker, with container-aware choices.
  var intakeKinds: [IntakeKindWire] = []
  var bucket: String = ""
  var isLoading = false
  var errorMessage: String?
  /// Items tapped this session — held visible (struck through) for a beat
  /// before they fade, mirroring the iPhone's Next behaviour.
  var completedIDs: Set<String> = []

  private let db: CKDatabase
  /// The iPhone writes the snapshot to the default private zone.
  private let snapshotRecordID = CKRecord.ID(recordName: "watch-next-snapshot")

  private init() {
    db = CKContainer(identifier: ckContainerID).privateCloudDatabase
  }

  // MARK: - Local "done today" (sticky until the phone republishes)

  private let doneStore = UserDefaults.standard
  private func localDoneIDs(date: String) -> Set<String> {
    guard doneStore.string(forKey: "doneLocalDate") == date else { return [] }
    return Set(doneStore.stringArray(forKey: "doneLocalIDs") ?? [])
  }
  private func markDoneLocally(id: String, date: String) {
    if doneStore.string(forKey: "doneLocalDate") != date {
      doneStore.set(date, forKey: "doneLocalDate")
      doneStore.set([String](), forKey: "doneLocalIDs")
    }
    var ids = doneStore.stringArray(forKey: "doneLocalIDs") ?? []
    if !ids.contains(id) { ids.append(id) }
    doneStore.set(ids, forKey: "doneLocalIDs")
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

  // Bucket selection is shared with the phone via `DayBucket` so the two
  // never disagree about which habits are due now.
  private func currentBucket() -> String { DayBucket.current.rawValue }

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
      let bkt = currentBucket()

      // Confirm CloudKit has a usable account first — otherwise the read can
      // block indefinitely with no feedback.
      let container = CKContainer(identifier: ckContainerID)
      let status = try await container.accountStatus()
      guard status == .available else {
        errorMessage = "iCloud not available on watch (status: \(accountStatusLabel(status)))"
        isLoading = false
        return
      }

      // One O(1) read: the iPhone precomputes the whole day's open checklist
      // into a single `WatchSnapshot` record (default zone). No zone replay.
      // Timed out so a stall surfaces as an error, never an endless spinner.
      let record = try await withTimeout(seconds: 15) { [self] in
        try await db.record(for: snapshotRecordID)
      }
      guard
        let payload  = record["payload"] as? Data,
        let response = try? JSONDecoder().decode(NextItemsResponse.self, from: payload)
      else {
        errorMessage = "Couldn't read the watch snapshot. Open Septena on your iPhone."
        isLoading = false
        return
      }

      // Narrow to the current time-of-day bucket via the shared helper (keeps
      // the watch and the iOS widget from ever disagreeing), then drop items
      // completed locally this session until the phone republishes.
      let doneLocal = localDoneIDs(date: today)
      let filtered = response.itemsForBucket(DayBucket.current)
        .filter { !doneLocal.contains($0.id) }

      self.items         = filtered
      self.sectionColors = response.sectionColors ?? [:]
      self.intakeKinds   = response.intakeKinds ?? []
      self.bucket        = bkt
      updateComplication()
      scheduleNextRefresh()
    } catch let ckError as CKError where ckError.code == .unknownItem {
      errorMessage = "No data yet. Open Septena on your iPhone to sync your watch."
    } catch {
      errorMessage = error.localizedDescription
    }

    isLoading = false
  }

  // MARK: - Helpers

  private func accountStatusLabel(_ status: CKAccountStatus) -> String {
    switch status {
    case .available:                    return "available"
    case .noAccount:                    return "no iCloud account"
    case .restricted:                   return "restricted"
    case .couldNotDetermine:            return "could not determine"
    case .temporarilyUnavailable:       return "temporarily unavailable"
    @unknown default:                   return "unknown (\(status.rawValue))"
    }
  }

  /// Races an async operation against a timeout so a hung CloudKit call
  /// surfaces as a visible error instead of an infinite spinner.
  private func withTimeout<T: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        throw NSError(
          domain: "SeptenaWatch", code: -1000,
          userInfo: [NSLocalizedDescriptionKey:
            "Timed out after \(Int(seconds))s — CloudKit didn't respond"]
        )
      }
      guard let result = try await group.next() else {
        throw CancellationError()
      }
      group.cancelAll()
      return result
    }
  }

  // MARK: - Mutations

  func complete(_ item: NextItem) {
    // Completable kinds are defined once in `NextBlocks` (shared with the
    // phone). This naturally excludes read-only suggestions and anything
    // that isn't a Next member.
    guard NextBlocks.isCompletable(kind: item.kind) else { return }
    guard !completedIDs.contains(item.id) else { return }   // ignore double taps
    let date = today

    // Confirm with a success haptic, mark it done, and keep it on screen
    // (struck through) for a moment before it fades out. One uniform "done"
    // feel for every completable kind — on the wrist, eyes-off, a per-section
    // rhythm reads as noise, not signal.
    WKInterfaceDevice.current().play(.success)
    completedIDs.insert(item.id)
    markDoneLocally(id: item.id, date: date)   // stays hidden across refreshes
    updateComplication()

    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_100_000_000)
      items.removeAll { $0.id == item.id }
      completedIDs.remove(item.id)
    }

    Task {
      do {
        // Route off the shared `NextBlocks` descriptor: it declares the
        // completion strategy per member, so the *set* of completable kinds
        // lives in one place. The per-record writers stay bespoke (each
        // event record has different fields).
        guard let block = NextBlocks.byItemKind[item.kind] else { return }
        switch block.completion {
        case .recordStatus:
          try await saveTaskCompletion(taskID: item.id)
        case .event(let recordType):
          try await saveEvent(recordType: recordType, itemID: item.id, date: date)
        }
      } catch {
        // Fire-and-forget: the iOS CKSyncEngine reconciles on next open.
      }
    }
  }

  // MARK: - Quick-log (actionable suggestions)

  /// Log a `.choice`-input suggestion (hydration / gut) with the picked value.
  /// Optimistic: hides the nudge with a success haptic, then writes the event
  /// off the `SuggestionBlocks` descriptor (shared with the phone).
  func logChoice(kind: String, value: String, itemID: String) {
    guard let block = SuggestionBlocks.byKind[kind] else { return }
    finishSuggestion(itemID)
    let date = today
    Task {
      do {
        switch block.recordType {
        case "NutritionEntry":
          // hydration: the choice value is millilitres of water.
          if let ml = Double(value) { try await saveWaterEntry(ml: ml) }
        case "GutEvent":
          // gut: the choice value is the Bristol type (1–7).
          if let bristol = Int(value) { try await saveGutEvent(bristol: bristol, date: date) }
        default:
          assertionFailure("No watch quick-log writer for '\(block.recordType)'")
        }
      } catch {
        // Fire-and-forget: the iOS CKSyncEngine reconciles on next open.
      }
    }
  }

  /// Log against an intake tracker from the wire. `value` is a
  /// `ConsumableContainer` choice token ("<method>:N" / bare method), so a
  /// wrist log lands in the current container exactly like the phone's
  /// Continue / New container rows.
  func logIntake(kind: IntakeKindWire, value: String, itemID: String) {
    finishSuggestion(itemID)
    let date = today
    Task {
      do {
        try await saveIntakeEvent(kind: kind, value: value, date: date)
      } catch {
        // Fire-and-forget: the iOS CKSyncEngine reconciles on next open.
      }
    }
  }

  /// Log a mood check-in from the two-step picker (quadrant → emotion). Writes
  /// a real `MoodEvent` at the chosen emotion's `MoodVocabulary` coordinates.
  func logMood(quadrant: String, emotion: String, arousal: Int, valence: Int, itemID: String) {
    finishSuggestion(itemID)
    let date = today
    Task {
      do {
        try await saveMoodEvent(quadrant: quadrant, emotion: emotion,
                                arousal: arousal, valence: valence, date: date)
      } catch { }
    }
  }

  /// Shared optimistic hide for a just-logged suggestion: success haptic, mark
  /// it done locally (so it stays hidden across refreshes), then drop it from
  /// the list after the settle beat. Mirrors `complete()` without the
  /// `NextBlocks` completion path — suggestions aren't completable members.
  private func finishSuggestion(_ itemID: String) {
    guard !completedIDs.contains(itemID) else { return }
    let date = today
    WKInterfaceDevice.current().play(.success)
    completedIDs.insert(itemID)
    markDoneLocally(id: itemID, date: date)
    updateComplication()
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_100_000_000)
      items.removeAll { $0.id == itemID }
      completedIDs.remove(itemID)
    }
  }

  /// Maps a `NextBlocks`-declared event record type to its CloudKit writer.
  /// The writers stay separate because each event record has different
  /// fields; this only routes, so adding a member is a `NextBlocks` row plus
  /// (when it's a new record type) one writer here.
  private func saveEvent(recordType: String, itemID: String, date: String) async throws {
    switch recordType {
    case "HabitEvent":      try await saveHabitEvent(habitID: itemID, date: date)
    case "SupplementEvent": try await saveSupplementEvent(supplementID: itemID, date: date)
    case "ChoreEvent":      try await saveChoreEvent(choreID: itemID, date: date)
    default:
      assertionFailure("No watch writer for NextBlocks record type '\(recordType)'")
    }
  }

  // MARK: - CloudKit write helpers

  private func saveHabitEvent(habitID: String, date: String) async throws {
    // Record name mirrors HabitEventCloudKitSchema.recordName(for:) on iOS.
    let entityID   = "habit:\(date):\(habitID)"
    let recordID   = CKRecord.ID(recordName: "habit-event:\(entityID)", zoneID: ckZoneID)
    let existing   = try? await db.record(for: recordID)
    let record     = existing ?? CKRecord(recordType: "HabitEvent", recordID: recordID)
    let now = Date()
    record["date"]       = date
    record["habitID"]    = habitID
    record["done"]       = 1
    record["skipped"]    = 0
    record["time"]       = Self.timeFmt.string(from: now)
    record["occurredAt"] = now
    try await db.save(record)
  }

  private func saveSupplementEvent(supplementID: String, date: String) async throws {
    let entityID = "supplement:\(date):\(supplementID)"
    let recordID = CKRecord.ID(recordName: "supplement-event:\(entityID)", zoneID: ckZoneID)
    let existing = try? await db.record(for: recordID)
    let record   = existing ?? CKRecord(recordType: "SupplementEvent", recordID: recordID)
    let now = Date()
    record["date"]         = date
    record["supplementID"] = supplementID
    record["done"]         = 1
    record["time"]         = Self.timeFmt.string(from: now)
    record["occurredAt"]   = now
    try await db.save(record)
  }

  private func saveChoreEvent(choreID: String, date: String) async throws {
    // Each completion is a new event record; UUID avoids ID collisions.
    let eventID  = UUID().uuidString
    let recordID = CKRecord.ID(recordName: "chore-event:\(eventID)", zoneID: ckZoneID)
    let record   = CKRecord(recordType: "ChoreEvent", recordID: recordID)
    let now = Date()
    record["choreID"]    = choreID
    record["action"]     = "complete"
    record["date"]       = date
    record["time"]       = Self.timeFmt.string(from: now)
    record["occurredAt"] = now
    record["sortKey"]    = "\(date)::\(eventID)"
    try await db.save(record)
  }

  // MARK: - Task capture

  /// Quick-capture a task to the Inbox (no project/area, not Today), written
  /// straight to the `Task` record type the phone mirrors. Inbox tasks don't
  /// surface in the watch's today-scoped Next list, so there's nothing to
  /// insert locally — a success haptic confirms the write was queued; the
  /// iOS `CKSyncEngine` reconciles it into the Inbox on next fetch.
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

  /// Writes a fresh open `Task` record. Field names/values mirror
  /// `TaskCloudKitSchema` + `TasksBackend.create`: status "open", `created`
  /// today, `today` 0, app provenance. No area/project ⇒ Inbox.
  private func saveInboxTask(title: String, date: String) async throws {
    let id       = String(UUID().uuidString.lowercased().prefix(8))
    let recordID = CKRecord.ID(recordName: id, zoneID: ckZoneID)
    let record   = CKRecord(recordType: "Task", recordID: recordID)
    record["title"]        = title
    record["status"]       = "open"
    record["created"]      = date
    record["today"]        = 0
    record["source"]       = "app"
    record["sourceClient"] = "watch"
    record["createdAt"]    = Date()
    try await db.save(record)
  }

  // MARK: - Quick-log CloudKit writers
  //
  // Each suggestion log is a fresh event record (UUID id), mirroring the
  // phone's mutators: time-of-day lives in `occurredAt` (the phone derives the
  // display time from it and does NOT store a separate `time` field), and the
  // free-form `note` is written empty so the field registers. Record names +
  // fields match the `*CloudKitSchema` definitions so the phone mirrors them.

  /// One intake event against a tracker. Record name + fields match
  /// `IntakeEventCloudKitSchema` so the phone mirrors it like its own writes.
  /// Amount rides along only when the kind tracks amounts and the method has a
  /// default — the wrist never asks for a number.
  private func saveIntakeEvent(kind: IntakeKindWire, value: String, date: String) async throws {
    let (method, count) = ConsumableContainer.parse(value: value)
    let eventID  = String(UUID().uuidString.lowercased().prefix(8))
    let recordID = CKRecord.ID(recordName: "intake-event:\(eventID)", zoneID: ckZoneID)
    let record   = CKRecord(recordType: "IntakeEvent", recordID: recordID)
    record["kindID"]     = kind.id
    record["date"]       = date
    record["method"]     = method
    record["note"]       = ""
    record["occurredAt"] = Date()
    if let count { record["count"] = count }
    if kind.showsAmount == true,
       let amount = kind.methods.first(where: { $0.token == method })?.defaultAmount {
      record["amount"] = amount
    }
    try await db.save(record)
  }

  /// A water log — a macro-free `NutritionEntry`. Mirrors the phone's hydration
  /// quick-actions (`PlatformDelegates` / `HydrationIntents`): emoji 💧, the
  /// `["Water"]` foods marker (stored as the single line "Water"), zero macros,
  /// and the amount in `waterMl`. Time-of-day lives in `loggedAt`.
  private func saveWaterEntry(ml: Double) async throws {
    let eventID  = String(UUID().uuidString.lowercased().prefix(8))
    let recordID = CKRecord.ID(recordName: "nutrition-entry:\(eventID)", zoneID: ckZoneID)
    let record   = CKRecord(recordType: "NutritionEntry", recordID: recordID)
    record["loggedAt"] = Date()
    record["emoji"]    = "💧"
    record["foods"]    = "Water"   // the phone's HydrationPlugin.waterFoodsMarker
    record["note"]     = ""
    record["source"]   = "manual"
    record["proteinG"] = 0
    record["fatG"]     = 0
    record["carbsG"]   = 0
    record["waterMl"]  = ml
    try await db.save(record)
  }

  private func saveGutEvent(bristol: Int, date: String) async throws {
    let eventID  = String(UUID().uuidString.lowercased().prefix(8))
    let recordID = CKRecord.ID(recordName: "gut-event:\(eventID)", zoneID: ckZoneID)
    let record   = CKRecord(recordType: "GutEvent", recordID: recordID)
    record["date"]       = date
    record["bristol"]    = bristol
    record["note"]       = ""
    record["occurredAt"] = Date()
    try await db.save(record)
  }

  private func saveMoodEvent(quadrant: String, emotion: String,
                             arousal: Int, valence: Int, date: String) async throws {
    let eventID  = String(UUID().uuidString.lowercased().prefix(8))
    let recordID = CKRecord.ID(recordName: "mood-event:\(eventID)", zoneID: ckZoneID)
    let record   = CKRecord(recordType: "MoodEvent", recordID: recordID)
    record["date"]       = date
    record["bucket"]     = DayBucket.current.rawValue
    record["quadrant"]   = quadrant
    record["arousal"]    = arousal
    record["valence"]    = valence
    record["emotion"]    = emotion
    record["note"]       = ""
    record["occurredAt"] = Date()
    try await db.save(record)
  }

  /// Completes a task by mutating its `Task` record in place — mirrors
  /// `TasksBackend.complete`: status → done, stamp completedAt, clear today.
  private func saveTaskCompletion(taskID: String) async throws {
    let recordID = CKRecord.ID(recordName: taskID, zoneID: ckZoneID)
    guard let record = try? await db.record(for: recordID) else { return }
    record["status"]      = "done"
    record["completedAt"] = Self.tsFmt.string(from: Date())
    record["today"]       = 0
    try await db.save(record)
  }

  private static let tsFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()

  /// Wall-clock "HH:mm" of the completion, mirroring `currentTimeString()` in
  /// the iOS `ChecklistMutator` so a watch-logged item carries the same
  /// time-of-day the phone would have written.
  private static let timeFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()

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
}
