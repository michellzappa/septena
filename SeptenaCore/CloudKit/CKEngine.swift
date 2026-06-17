import Foundation
import CloudKit
import OSLog
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// CKEngine — Phase 0 scaffolding.
//
// Owns the `CKSyncEngine` for the Septena CloudKit container. Nothing in
// the app instantiates this yet; the FastAPI/Outbox path remains live.
// Phase 1 will:
//   1. Construct one of these from `App.swift` on launch.
//   2. Have `TaskMutator` call `noteTaskChange(id:)` after each write.
//   3. Fill in the `recordProvider` and `applyFetched(...)` paths so
//      incoming records fold into the SwiftData mirror.
//
// The shape mirrors the Apple sample (CloudKitSyncEngine, WWDC23) so the
// gap between "Phase 0 skeleton" and "Phase 1 production" stays narrow.

// MARK: - Constants

/// Single source of truth for container / zone identifiers. Both are
/// effectively immutable post-Production deploy — re-publishing schema
/// to a new zone or container forces a migration we don't want.
enum SeptenaCloudKit {
static let containerIdentifier = "iCloud.com.septena.cloud"

  /// Custom zone name. CKSyncEngine requires a custom zone — the default
  /// zone has no per-zone change-tracking. The `-v1` suffix lets us cut
  /// over to a fresh zone if a schema-incompatible pivot is ever needed
  /// rather than mutate this one.
static let zoneName = "septena-v1"

static var zoneID: CKRecordZone.ID {
    CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
  }
}

// MARK: - CKEngine

@MainActor
@Observable
final class CKEngine {
  private let logger = Log.cloudKit
  /// Exposed read-only so DEBUG diagnostics can query userRecordID — both
  /// devices must report the same one or they're hitting different
  /// private databases entirely.
  let container: CKContainer
  private let database: CKDatabase

  /// Set on `start()`. Nil until Phase 1 wires the boot call in App.swift.
  private var engine: CKSyncEngine?

  /// Plug-in points. The engine calls these to (a) materialize a CKRecord
  /// for upload from the local mirror, (b) fold a downloaded record into
  /// the mirror, (c) erase a deleted record locally. Held as closures
  /// rather than a delegate protocol so the engine stays agnostic of
  /// SwiftData / TaskEntity, keeping this file in SeptenaCore without a
  /// forward import on the higher layer.
  ///
  /// The single-closure shape covers all three record types (Task, Area,
  /// Project): App.swift dispatches by `record.recordType` for fetched
  /// events and tries each entity type in order in the provider. The
  /// deleted closure gets the recordType as a second argument because
  /// the local mirror no longer holds the row by the time we'd need to
  /// look it up.
var recordProvider: ((CKRecord.ID) -> CKRecord?)?
var applyFetchedRecord: ((CKRecord) -> Void)?
var applyDeletedRecord: ((CKRecord.ID, CKRecord.RecordType) -> Void)?
  /// Called once after every batch of fetched/sent record events is
  /// drained, so the host can perform a single `context.save()` and
  /// post one repaint notification instead of N. During a 553-row
  /// migrate the per-record save-and-notify path was taking 60+ sec
  /// of main-actor work; the batched version is sub-second.
  ///
  /// `notify` is true for genuine inbound changes (remote/other-device
  /// fetches, conflict resolution) that the UI hasn't seen yet, and false
  /// for our own just-sent records echoing back: those only fold in
  /// CloudKit system fields — the user-visible data was already applied
  /// optimistically and the mutator already posted a scoped change. Posting
  /// again would re-run the whole app's reload path for nothing.
var applyDidFinishBatch: ((_ notify: Bool) -> Void)?

  /// Current iCloud account status. Refreshed on init, when the system
  /// posts `.CKAccountChanged`, and any time `refreshAccountStatus()` is
  /// called explicitly (e.g. on scenePhase active). Observable so views
  /// can disable migration / show a banner without polling.
var accountStatus: CKAccountStatus = .couldNotDetermine
  /// Number of in-flight `sendChanges` / `fetchChanges` calls. Views can
  /// observe `isSyncing` to show a sync indicator while > 0.
  private(set) var inflightSyncCount: Int = 0
  var isSyncing: Bool { inflightSyncCount > 0 }
  private var lastSendFailureSummary: String?

init() {
    self.container = CKContainer(identifier: SeptenaCloudKit.containerIdentifier)
    self.database = container.privateCloudDatabase
    // The CKAccountChanged notification fires on an arbitrary thread, so
    // bounce back to MainActor before touching `self`.
    NotificationCenter.default.addObserver(
      forName: .CKAccountChanged, object: nil, queue: nil
    ) { [weak self] _ in
      Task { @MainActor in await self?.refreshAccountStatus() }
    }
    Task { await refreshAccountStatus() }
  }

  /// Re-query the container for the user's iCloud status. Cheap; safe
  /// to call on every foreground transition.
  func refreshAccountStatus() async {
    do {
      let status = try await container.accountStatus()
      if status != accountStatus {
        let label: String
        switch status {
        case .available:          label = "available"
        case .noAccount:          label = "noAccount"
        case .restricted:         label = "restricted"
        case .couldNotDetermine:  label = "couldNotDetermine"
        case .temporarilyUnavailable: label = "temporarilyUnavailable"
        @unknown default:         label = "unknown(\(status.rawValue))"
        }
        logger.info("CKEngine account status: \(label, privacy: .public)")
      }
      accountStatus = status
    } catch {
      logger.error("accountStatus query failed: \(error.localizedDescription, privacy: .public)")
      accountStatus = .couldNotDetermine
    }
  }

  /// Boots the sync engine. Idempotent — safe to call repeatedly. No-op
  /// when called pre-Phase-1 (CKSyncEngine creation hits the network for
  /// account status; we don't want to pay that cost until we're ready
  /// to actually sync).
func start() {
    guard engine == nil else { return }
    let configuration = CKSyncEngine.Configuration(
      database: database,
      stateSerialization: loadStateSerialization(),
      delegate: self
    )
    let engine = CKSyncEngine(configuration)
    self.engine = engine
    // Ensure the custom zone exists before any record-save fires.
    // CKSyncEngine doesn't auto-create zones from referenced recordIDs
    // — without this every saveRecord returns "Zone Not Found" (CKError
    // 2036). Idempotent: if the zone is already on the server, the
    // engine treats the pending change as a no-op and drops it.
    let zone = CKRecordZone(zoneID: SeptenaCloudKit.zoneID)
    engine.state.add(pendingDatabaseChanges: [.saveZone(zone)])
    logger.info("CKEngine started: container=\(SeptenaCloudKit.containerIdentifier, privacy: .public) zone=\(SeptenaCloudKit.zoneName, privacy: .public)")
    // Register for silent CK pushes so cross-device updates land in
    // sub-second rather than waiting for the engine's periodic refresh.
    // CKSyncEngine auto-creates its database subscription on first
    // sync; all we need here is the OS-level push token registration.
    registerForRemoteNotifications()
    // Bootstrap pull: without this, a cold launch sees only whatever
    // was already in SwiftData. Any record other devices wrote while
    // we were closed would have to wait for an opportunistic push to
    // arrive — APNs coalesces silent pushes aggressively, so don't
    // rely on that as the only refresh path.
    Task { [weak self] in
      try? await self?.engine?.fetchChanges()
    }
  }

  private func registerForRemoteNotifications() {
    #if canImport(UIKit)
    UIApplication.shared.registerForRemoteNotifications()
    #elseif canImport(AppKit)
    NSApplication.shared.registerForRemoteNotifications()
    #endif
  }

  /// Forward a silent push payload from the app delegate. CKSyncEngine
  /// translates the CKNotification into a fetch operation. Returns
  /// `true` if the payload was a CK notification we handled.
  @discardableResult
  func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> Bool {
    guard let engine else { return false }
    guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
      return false
    }
    // The notification just tells us "something changed for this
    // subscription" — the engine knows what's new from its tokens.
    _ = notification
    try? await engine.fetchChanges()
    return true
  }

  /// Tells the engine "this task changed locally"; the engine batches and
  /// uploads on the next drain. Safe before `start()` — calls are dropped.
func noteTaskChange(id: String) { noteChange(recordName: id, kind: "task") }
func noteTaskDeletion(id: String) { noteDeletion(recordName: id, kind: "task") }

  // Area / Project pendants. CK doesn't distinguish by record type at the
  // engine layer — a pending save is a pending save — but logging the
  // kind helps when reading [CKEngine] traces post-mortem.
func noteAreaChange(id: String) { noteChange(recordName: AreaCloudKitSchema.recordName(for: id), kind: "area") }
func noteAreaDeletion(id: String) { noteDeletion(recordName: AreaCloudKitSchema.recordName(for: id), kind: "area") }
func noteProjectChange(id: String) { noteChange(recordName: ProjectCloudKitSchema.recordName(for: id), kind: "project") }
func noteProjectDeletion(id: String) { noteDeletion(recordName: ProjectCloudKitSchema.recordName(for: id), kind: "project") }
func noteSettingsChange() { noteChange(recordName: SettingsCloudKitSchema.singletonID, kind: "settings") }
func noteSectionChange(id: String) { noteChange(recordName: SectionCloudKitSchema.recordName(for: id), kind: "section") }
func noteSectionDeletion(id: String) { noteDeletion(recordName: SectionCloudKitSchema.recordName(for: id), kind: "section") }
func noteHabitDefinitionChange(id: String) { noteChange(recordName: HabitDefinitionCloudKitSchema.recordName(for: id), kind: "habitDefinition") }
func noteHabitDefinitionDeletion(id: String) { noteDeletion(recordName: HabitDefinitionCloudKitSchema.recordName(for: id), kind: "habitDefinition") }
func noteHabitEventChange(id: String) { noteChange(recordName: HabitEventCloudKitSchema.recordName(for: id), kind: "habitEvent") }
func noteHabitEventDeletion(id: String) { noteDeletion(recordName: HabitEventCloudKitSchema.recordName(for: id), kind: "habitEvent") }
func noteSupplementDefinitionChange(id: String) { noteChange(recordName: SupplementDefinitionCloudKitSchema.recordName(for: id), kind: "supplementDefinition") }
func noteSupplementDefinitionDeletion(id: String) { noteDeletion(recordName: SupplementDefinitionCloudKitSchema.recordName(for: id), kind: "supplementDefinition") }
func noteSupplementEventChange(id: String) { noteChange(recordName: SupplementEventCloudKitSchema.recordName(for: id), kind: "supplementEvent") }
func noteSupplementEventDeletion(id: String) { noteDeletion(recordName: SupplementEventCloudKitSchema.recordName(for: id), kind: "supplementEvent") }
func noteChoreDefinitionChange(id: String) { noteChange(recordName: ChoreDefinitionCloudKitSchema.recordName(for: id), kind: "choreDefinition") }
func noteChoreDefinitionDeletion(id: String) { noteDeletion(recordName: ChoreDefinitionCloudKitSchema.recordName(for: id), kind: "choreDefinition") }
func noteChoreEventChange(id: String) { noteChange(recordName: ChoreEventCloudKitSchema.recordName(for: id), kind: "choreEvent") }
func noteChoreEventDeletion(id: String) { noteDeletion(recordName: ChoreEventCloudKitSchema.recordName(for: id), kind: "choreEvent") }
func noteGoalChange(id: String) { noteChange(recordName: GoalCloudKitSchema.recordName(for: id), kind: "goal") }
func noteGoalDeletion(id: String) { noteDeletion(recordName: GoalCloudKitSchema.recordName(for: id), kind: "goal") }
func noteGoalMilestoneChange(id: String) { noteChange(recordName: GoalMilestoneCloudKitSchema.recordName(for: id), kind: "goalMilestone") }
func noteGoalMilestoneDeletion(id: String) { noteDeletion(recordName: GoalMilestoneCloudKitSchema.recordName(for: id), kind: "goalMilestone") }
func noteGutEventChange(id: String) { noteChange(recordName: GutEventCloudKitSchema.recordName(for: id), kind: "gutEvent") }
func noteGutEventDeletion(id: String) { noteDeletion(recordName: GutEventCloudKitSchema.recordName(for: id), kind: "gutEvent") }
func noteMoodEventChange(id: String) { noteChange(recordName: MoodEventCloudKitSchema.recordName(for: id), kind: "moodEvent") }
func noteMoodEventDeletion(id: String) { noteDeletion(recordName: MoodEventCloudKitSchema.recordName(for: id), kind: "moodEvent") }
func noteSymptomDefinitionChange(id: String) { noteChange(recordName: SymptomDefinitionCloudKitSchema.recordName(for: id), kind: "symptomDefinition") }
func noteSymptomDefinitionDeletion(id: String) { noteDeletion(recordName: SymptomDefinitionCloudKitSchema.recordName(for: id), kind: "symptomDefinition") }
func noteSymptomEventChange(id: String) { noteChange(recordName: SymptomEventCloudKitSchema.recordName(for: id), kind: "symptomEvent") }
func noteSymptomEventDeletion(id: String) { noteDeletion(recordName: SymptomEventCloudKitSchema.recordName(for: id), kind: "symptomEvent") }
func noteMedicationDefinitionChange(id: String) { noteChange(recordName: MedicationDefinitionCloudKitSchema.recordName(for: id), kind: "medicationDefinition") }
func noteMedicationDefinitionDeletion(id: String) { noteDeletion(recordName: MedicationDefinitionCloudKitSchema.recordName(for: id), kind: "medicationDefinition") }
func noteMedicationDoseEventChange(id: String) { noteChange(recordName: MedicationDoseEventCloudKitSchema.recordName(for: id), kind: "medicationDoseEvent") }
func noteMedicationDoseEventDeletion(id: String) { noteDeletion(recordName: MedicationDoseEventCloudKitSchema.recordName(for: id), kind: "medicationDoseEvent") }
func noteOuraNightChange(id: String) { noteChange(recordName: OuraNightCloudKitSchema.recordName(for: id), kind: "ouraNight") }
func noteOuraNightDeletion(id: String) { noteDeletion(recordName: OuraNightCloudKitSchema.recordName(for: id), kind: "ouraNight") }
func noteQuoteChange(id: String) { noteChange(recordName: QuoteCloudKitSchema.recordName(for: id), kind: "quote") }
func noteQuoteDeletion(id: String) { noteDeletion(recordName: QuoteCloudKitSchema.recordName(for: id), kind: "quote") }
/// Batched quote enqueue — ONE `state.add` for the whole set, for bulk imports
/// (a Readwise sync can be thousands of rows). See `noteChanges`/`noteDeletions`.
func noteQuoteChanges(ids: [String]) { noteChanges(recordNames: ids.map { QuoteCloudKitSchema.recordName(for: $0) }) }
func noteQuoteDeletions(ids: [String]) { noteDeletions(recordNames: ids.map { QuoteCloudKitSchema.recordName(for: $0) }) }
func noteWithingsRowChange(id: String) { noteChange(recordName: WithingsRowCloudKitSchema.recordName(for: id), kind: "withingsRow") }
func noteWithingsRowDeletion(id: String) { noteDeletion(recordName: WithingsRowCloudKitSchema.recordName(for: id), kind: "withingsRow") }
func noteIntakeKindChange(id: String) { noteChange(recordName: IntakeKindCloudKitSchema.recordName(for: id), kind: "intakeKind") }
func noteIntakeKindDeletion(id: String) { noteDeletion(recordName: IntakeKindCloudKitSchema.recordName(for: id), kind: "intakeKind") }
func noteIntakeItemChange(id: String) { noteChange(recordName: IntakeItemCloudKitSchema.recordName(for: id), kind: "intakeItem") }
func noteIntakeItemDeletion(id: String) { noteDeletion(recordName: IntakeItemCloudKitSchema.recordName(for: id), kind: "intakeItem") }
func noteIntakeEventChange(id: String) { noteChange(recordName: IntakeEventCloudKitSchema.recordName(for: id), kind: "intakeEvent") }
func noteIntakeEventDeletion(id: String) { noteDeletion(recordName: IntakeEventCloudKitSchema.recordName(for: id), kind: "intakeEvent") }
func noteGroceryItemChange(id: String) { noteChange(recordName: GroceryItemCloudKitSchema.recordName(for: id), kind: "groceryItem") }
func noteGroceryItemDeletion(id: String) { noteDeletion(recordName: GroceryItemCloudKitSchema.recordName(for: id), kind: "groceryItem") }
func noteGroceryCategoryChange(id: String) { noteChange(recordName: GroceryCategoryCloudKitSchema.recordName(for: id), kind: "groceryCategory") }
func noteGroceryCategoryDeletion(id: String) { noteDeletion(recordName: GroceryCategoryCloudKitSchema.recordName(for: id), kind: "groceryCategory") }
func noteExerciseEntryChange(id: String) { noteChange(recordName: ExerciseEntryCloudKitSchema.recordName(for: id), kind: "exerciseEntry") }
func noteExerciseEntryDeletion(id: String) { noteDeletion(recordName: ExerciseEntryCloudKitSchema.recordName(for: id), kind: "exerciseEntry") }
func noteExerciseDefinitionChange(id: String) { noteChange(recordName: ExerciseDefinitionCloudKitSchema.recordName(for: id), kind: "exerciseDefinition") }
func noteExerciseDefinitionDeletion(id: String) { noteDeletion(recordName: ExerciseDefinitionCloudKitSchema.recordName(for: id), kind: "exerciseDefinition") }
func noteSessionTypeChange(id: String) { noteChange(recordName: SessionTypeCloudKitSchema.recordName(for: id), kind: "sessionType") }
func noteSessionTypeDeletion(id: String) { noteDeletion(recordName: SessionTypeCloudKitSchema.recordName(for: id), kind: "sessionType") }
func noteNutritionEntryChange(id: String) { noteChange(recordName: NutritionEntryCloudKitSchema.recordName(for: id), kind: "nutritionEntry") }
func noteNutritionEntryDeletion(id: String) { noteDeletion(recordName: NutritionEntryCloudKitSchema.recordName(for: id), kind: "nutritionEntry") }
func noteNutritionDayChange(id: String) { noteChange(recordName: NutritionDailySummaryCloudKitSchema.recordName(for: id), kind: "nutritionDay") }
func noteNutritionDayDeletion(id: String) { noteDeletion(recordName: NutritionDailySummaryCloudKitSchema.recordName(for: id), kind: "nutritionDay") }
func noteActivityDayChange(id: String) { noteChange(recordName: ActivityDayCloudKitSchema.recordName(for: id), kind: "activityDay") }
func noteActivityDayDeletion(id: String) { noteDeletion(recordName: ActivityDayCloudKitSchema.recordName(for: id), kind: "activityDay") }
func noteCoachVoiceChange(id: String) { noteChange(recordName: CoachVoiceCloudKitSchema.recordName(for: id), kind: "coachVoice") }
func noteCoachVoiceDeletion(id: String) { noteDeletion(recordName: CoachVoiceCloudKitSchema.recordName(for: id), kind: "coachVoice") }
func noteCoachMessageChange(id: String) { noteChange(recordName: CoachMessageCloudKitSchema.recordName(for: id), kind: "coachMessage") }
func noteCoachMessageDeletion(id: String) { noteDeletion(recordName: CoachMessageCloudKitSchema.recordName(for: id), kind: "coachMessage") }

  private func noteChange(recordName: String, kind: String) {
    guard let engine else {
      SeptenaLog.info("[CKEngine] note\(kind.capitalized)Change id=\(recordName) DROPPED (engine not started)")
      return
    }
    let recordID = CKRecord.ID(recordName: recordName, zoneID: SeptenaCloudKit.zoneID)
    engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    // Per-record logging used to fire here; on a 365-day Oura backfill
    // that produced 365 lines back-to-back. The `[CKEngine] sent: …`
    // batch summary already reports what actually went out, so the
    // per-enqueue log was pure noise and is gone.
  }

  private func noteDeletion(recordName: String, kind: String) {
    guard let engine else {
      SeptenaLog.info("[CKEngine] note\(kind.capitalized)Deletion id=\(recordName) DROPPED (engine not started)")
      return
    }
    let recordID = CKRecord.ID(recordName: recordName, zoneID: SeptenaCloudKit.zoneID)
    engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
  }

  /// Batched enqueue — ONE `state.add` for many records instead of N separate
  /// calls. CKSyncEngine persists its state on every `add`, so a per-record loop
  /// over thousands of rows (a Readwise import / disconnect) blocks the main
  /// thread on repeated disk writes; folding them into a single array is the fix.
  /// Empty input and a not-yet-started engine are both no-ops.
  private func noteChanges(recordNames: [String]) {
    guard let engine, !recordNames.isEmpty else { return }
    let changes = recordNames.map {
      CKSyncEngine.PendingRecordZoneChange.saveRecord(
        CKRecord.ID(recordName: $0, zoneID: SeptenaCloudKit.zoneID))
    }
    engine.state.add(pendingRecordZoneChanges: changes)
  }

  private func noteDeletions(recordNames: [String]) {
    guard let engine, !recordNames.isEmpty else { return }
    let changes = recordNames.map {
      CKSyncEngine.PendingRecordZoneChange.deleteRecord(
        CKRecord.ID(recordName: $0, zoneID: SeptenaCloudKit.zoneID))
    }
    engine.state.add(pendingRecordZoneChanges: changes)
  }

  /// Count of writes the engine has accepted but not yet sent to CloudKit.
  /// Non-zero before sendChanges drains; useful in diagnostics to see if a
  /// device has un-pushed local mutations.
  var pendingRecordZoneChangesCount: Int {
    engine?.state.pendingRecordZoneChanges.count ?? 0
  }

  /// Drop any queued uploads/deletes for Readwise-imported quotes. Those rows are
  /// now device-local (re-imported per device from the user's own token), so they
  /// never belong in CloudKit — and this clears a backlog a pre-change build may
  /// have left, where thousands of `quote:readwise:*` saves flooded the engine and
  /// locked the UI on every launch. Quote records are named `quote:<origin>:<id>`,
  /// so a `quote:readwise:` prefix match isolates exactly the imported highlights
  /// (user-authored `quote:user:*` lines are untouched and keep syncing). Returns
  /// how many were cleared. Idempotent: once the backlog is gone it's a no-op.
  @discardableResult
  func dropPendingReadwiseQuoteChanges() -> Int {
    guard let engine else { return 0 }
    let prefix = QuoteCloudKitSchema.recordName(for: "readwise:") // "quote:readwise:"
    let stale = engine.state.pendingRecordZoneChanges.filter { change in
      switch change {
      case .saveRecord(let id), .deleteRecord(let id): return id.recordName.hasPrefix(prefix)
      @unknown default: return false
      }
    }
    guard !stale.isEmpty else { return 0 }
    engine.state.remove(pendingRecordZoneChanges: stale)
    SeptenaLog.info("[CKEngine] cleared \(stale.count) stuck Readwise quote uploads")
    return stale.count
  }

  /// Count of pending database-level operations (zone saves / deletes).
  /// Usually 0 in steady state.
  var pendingDatabaseChangesCount: Int {
    engine?.state.pendingDatabaseChanges.count ?? 0
  }

  /// Force-flush all pending record-zone changes to CloudKit. Awaits
  /// completion. Used by `TasksMigrator` so the migration step blocks
  /// on actual server delivery rather than firing-and-hoping.
  func sendChanges() async throws {
    guard let engine else { return }
    lastSendFailureSummary = nil
    inflightSyncCount += 1
    defer { inflightSyncCount -= 1 }
    try await engine.sendChanges()
  }

  func consumeLastSendFailureSummary() -> String? {
    defer { lastSendFailureSummary = nil }
    return lastSendFailureSummary
  }

  /// Pull any server-side changes the engine hasn't seen yet. Awaits
  /// completion. Migration uses this to verify the push round-tripped.
  func fetchChanges() async throws {
    guard let engine else { return }
    inflightSyncCount += 1
    defer { inflightSyncCount -= 1 }
    try await PerfTrace.span("ck.fetchChanges") {
      try await engine.fetchChanges()
    }
  }

  /// Drop this install's persisted CKSyncEngine state without touching
  /// CloudKit records. Use before replacing the local mirror from a
  /// full-zone CloudKit query so stale pending saves/deletes from this
  /// device cannot replay after the mirror has been rebuilt.
  func discardLocalSyncState() {
    engine = nil
    lastSendFailureSummary = nil
    try? FileManager.default.removeItem(at: stateURL)
    SeptenaLog.info("[CKEngine] local sync state discarded")
  }

  /// Full-zone repair read. `CKSyncEngine.fetchChanges()` is token-based;
  /// if a local mirror was seeded from a different historical state, the
  /// token stream may not be enough for a human-visible "show me the whole
  /// cloud truth" repair.
  ///
  /// Use zone changes from a nil token instead of CKQuery. Querying all
  /// records requires queryable schema indexes, and Development schema
  /// may reject even broad queries when `recordName` is not marked
  /// queryable. Zone-change fetches are the native custom-zone replay API
  /// and return all current live records without those indexes.
  /// Pass `nil` to replay every record type in the zone.
  func fetchAllRecords(recordTypes: [CKRecord.RecordType]? = nil) async throws -> [CKRecord] {
    let acceptedTypes = recordTypes.map(Set.init)
    var token: CKServerChangeToken?
    var moreComing = true
    var recordsByID: [CKRecord.ID: CKRecord] = [:]

    while moreComing {
      let page = try await database.recordZoneChanges(
        inZoneWith: SeptenaCloudKit.zoneID,
        since: token,
        desiredKeys: nil,
        resultsLimit: nil
      )
      for (recordID, result) in page.modificationResultsByID {
        switch result {
        case .success(let modification):
          let record = modification.record
          if acceptedTypes?.contains(record.recordType) ?? true {
            recordsByID[recordID] = record
          }
        case .failure(let error):
          SeptenaLog.error("[CKEngine] zone replay record FAIL id=\(recordID.recordName) error=\(error.localizedDescription)")
        }
      }
      token = page.changeToken
      moreComing = page.moreComing
    }

    let records = Array(recordsByID.values)
    let counts = Dictionary(grouping: records, by: \.recordType)
      .mapValues(\.count)
    SeptenaLog.info("[CKEngine] zone replay records=\(records.count) counts=\(String(describing: counts))")
    return records
  }

  /// Nuclear option for dev: delete the custom zone on the server,
  /// then recreate it. Use when local SwiftData has been wiped /
  /// rebuilt and `cloudKitSystemFields` is missing across the board —
  /// without those tags every save into the existing CK records gets
  /// rejected with `serverRecordChanged`. After the reset, run Migrate
  /// to push local state fresh; new records will be stamped with tags
  /// the next applyFetchedRecord captures.
  ///
  /// Important: this bypasses CKSyncEngine for the delete. Routing
  /// `.deleteZone` through the engine causes it to emit a
  /// `fetchedRecordZoneChanges` deletion event for every record that
  /// was in the zone, which our `applyDeletedRecord` closure interprets
  /// as a user deletion and wipes from SwiftData — a 500-row cascade
  /// the user definitely didn't ask for. Direct `CKDatabase` API +
  /// engine-state file reset gives us a clean server slate without
  /// touching local state.
  func resetZone() async throws {
    let zoneID = SeptenaCloudKit.zoneID
    SeptenaLog.info("[CKEngine] resetZone: deleting \(zoneID.zoneName) via CKDatabase")
    applyingResetCascade = true
    defer { applyingResetCascade = false }
    do {
      _ = try await database.deleteRecordZone(withID: zoneID)
    } catch let error as CKError where error.code == .zoneNotFound {
      // Already gone — treat as success and move on to recreation.
      SeptenaLog.info("[CKEngine] resetZone: zone already absent")
    }
    // Throw away the engine and its persisted state. The state file
    // remembers tokens and pending changes for the old zone; with the
    // zone gone, none of it is meaningful anymore. A fresh engine
    // starts with no preconceptions and rebuilds from scratch.
    engine = nil
    lastSendFailureSummary = nil
    try? FileManager.default.removeItem(at: stateURL)
    SeptenaLog.info("[CKEngine] resetZone: engine state cleared, restarting")
    start()
    let zone = CKRecordZone(zoneID: zoneID)
    engine?.state.add(pendingDatabaseChanges: [.saveZone(zone)])
    try await engine?.sendChanges()
    SeptenaLog.info("[CKEngine] resetZone: zone recreated")
  }

  /// True while `resetZone` is in flight. Belt-and-suspenders: even if
  /// the engine somehow emits deletion events during a reset, the
  /// delegate handler can check this flag and skip the cascade.
  private var applyingResetCascade = false

  // MARK: - State persistence

  /// CKSyncEngine expects us to persist `State.Serialization` between
  /// launches — it includes pending operations and zone change tokens
  /// so the next launch resumes instead of re-fetching the world.
  private var stateURL: URL {
    let base = (try? FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true
    )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appendingPathComponent("CKEngineState.json")
  }

  private func loadStateSerialization() -> CKSyncEngine.State.Serialization? {
    guard let data = try? Data(contentsOf: stateURL) else { return nil }
    return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
  }

  private func persistStateSerialization(_ state: CKSyncEngine.State.Serialization) {
    guard let data = try? JSONEncoder().encode(state) else { return }
    try? data.write(to: stateURL, options: .atomic)
  }
}

// MARK: - CKSyncEngineDelegate

extension CKEngine: CKSyncEngineDelegate {
func handleEvent(
    _ event: CKSyncEngine.Event,
    syncEngine: CKSyncEngine
  ) async {
    switch event {
    case .stateUpdate(let update):
      persistStateSerialization(update.stateSerialization)

    case .accountChange(let change):
      // Phase 1: react to sign-in / sign-out / switched-account. On
      // signOut we wipe the local mirror; on signIn we re-upload.
      logger.info("CKEngine accountChange: \(String(describing: change), privacy: .public)")

    case .fetchedRecordZoneChanges(let changes):
      Log.cloudKit.debug("[CKEngine] fetched: +\(changes.modifications.count) ~ -\(changes.deletions.count) reset=\(self.applyingResetCascade)")
      // Force every closure invocation onto MainActor. The closures
      // touch SwiftData's mainContext, which isn't thread-safe — and
      // @MainActor on the enclosing class isn't sufficient because
      // CKSyncEngine calls our handlers from its own executor.
      await MainActor.run {
        for mod in changes.modifications {
          applyFetchedRecord?(mod.record)
        }
        for del in changes.deletions {
          if applyingResetCascade {
            SeptenaLog.info("[CKEngine] fetched.delete IGNORED (reset) id=\(del.recordID.recordName)")
            continue
          }
          applyDeletedRecord?(del.recordID, del.recordType)
        }
        // Inbound remote changes — the UI hasn't seen these; repaint.
        applyDidFinishBatch?(true)
      }

    case .sentRecordZoneChanges(let sent):
      // `savedRecords` are the records the server accepted and stamped
      // with a fresh recordChangeTag. We MUST fold them back into local
      // state to capture system fields — otherwise the next edit has
      // no tag to send and the server returns serverRecordChanged.
      // CKSyncEngine's `fetchChanges` won't redeliver them (the engine
      // already knows about them), so this is the only path that
      // updates `cloudKitSystemFields` post-send.
      Log.cloudKit.debug("[CKEngine] sent: saves=\(sent.savedRecords.count) deletes=\(sent.deletedRecordIDs.count) failedSaves=\(sent.failedRecordSaves.count) failedDeletes=\(sent.failedRecordDeletes.count)")

      // For serverRecordChanged (oplock) failures: CKSyncEngine doesn't
      // populate CKError.serverRecord in this context, so we fetch the
      // current server version directly. This must happen before the
      // MainActor block so the fresh records are ready to fold in.
      // Capture database on MainActor first (CKSyncEngine breaks @MainActor isolation).
      let oplockIDs = sent.failedRecordSaves.compactMap { fail -> CKRecord.ID? in
        guard let ckErr = fail.error as? CKError, ckErr.code == .serverRecordChanged else { return nil }
        return fail.record.recordID
      }
      var freshServerRecords: [CKRecord] = []
      if !oplockIDs.isEmpty {
        let db: CKDatabase = await MainActor.run { self.database }
        let results = (try? await db.records(for: oplockIDs)) ?? [:]
        freshServerRecords = results.values.compactMap { try? $0.get() }
        SeptenaLog.info("[CKEngine] fetched \(freshServerRecords.count) fresh records for oplock resolution")
      }

      await MainActor.run {
        for save in sent.savedRecords {
          applyFetchedRecord?(save)
        }
        // Apply fresh server versions of oplock-conflicting records so the
        // next CKSyncEngine retry sends the correct etag instead of looping.
        for fresh in freshServerRecords {
          applyFetchedRecord?(fresh)
        }
        for fail in sent.failedRecordSaves {
          SeptenaLog.error("[CKEngine] sent.save FAIL id=\(fail.record.recordID.recordName) error=\(fail.error.localizedDescription)")
        }
        for (recordID, error) in sent.failedRecordDeletes {
          SeptenaLog.error("[CKEngine] sent.delete FAIL id=\(recordID.recordName) error=\(error.localizedDescription)")
        }
        if !sent.failedRecordSaves.isEmpty || !sent.failedRecordDeletes.isEmpty {
          lastSendFailureSummary = Self.sendFailureSummary(
            failedSaves: sent.failedRecordSaves,
            failedDeletes: Array(sent.failedRecordDeletes)
          )
        }
        // Our own writes echoing back. Fold in system fields (the save in the
        // batch handler), but only repaint when an oplock conflict made the
        // server's version win — otherwise the optimistic write + the
        // mutator's scoped post already brought the UI current, and a second
        // app-wide reload here is the per-edit hitch we're eliminating.
        applyDidFinishBatch?(!freshServerRecords.isEmpty)
      }

    case .fetchedDatabaseChanges, .sentDatabaseChanges,
         .willFetchChanges, .didFetchChanges,
         .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
         .willSendChanges, .didSendChanges:
      break

    @unknown default:
      break
    }
  }

func nextRecordZoneChangeBatch(
    _ context: CKSyncEngine.SendChangesContext,
    syncEngine: CKSyncEngine
  ) async -> CKSyncEngine.RecordZoneChangeBatch? {
    let pending = syncEngine.state.pendingRecordZoneChanges
      .filter { context.options.scope.contains($0) }
    guard !pending.isEmpty else { return nil }
    // Pre-resolve every record on MainActor before handing the batch
    // builder a pure dictionary-lookup closure. CKSyncEngine's batch
    // builder may invoke the resolver on a background queue; if it
    // touched SwiftData there we'd corrupt the main context.
    let resolved: [CKRecord.ID: CKRecord] = await MainActor.run {
      var out: [CKRecord.ID: CKRecord] = [:]
      for change in pending {
        // PendingRecordZoneChange is an enum (.saveRecord(id) / .deleteRecord(id)).
        // We only need the save case here — deletes don't ask the
        // resolver for a CKRecord.
        guard case .saveRecord(let id) = change else { continue }
        if out[id] == nil, let rec = recordProvider?(id) {
          out[id] = rec
        }
      }
      return out
    }
    return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
      resolved[recordID]
    }
  }

  private static func sendFailureSummary(
    failedSaves: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave],
    failedDeletes: [(CKRecord.ID, any Error)]
  ) -> String {
    var lines: [String] = []
    for failure in failedSaves.prefix(5) {
      lines.append(describeSaveFailure(failure))
    }
    for (recordID, error) in failedDeletes.prefix(5) {
      lines.append("delete \(recordID.recordName): \(describeError(error))")
    }
    let overflow = failedSaves.count + failedDeletes.count - lines.count
    if overflow > 0 {
      lines.append("+\(overflow) more CloudKit failures")
    }
    return lines.joined(separator: "\n")
  }

  private static func describeSaveFailure(
    _ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave
  ) -> String {
    let record = failure.record
    return "save \(record.recordType)/\(record.recordID.recordName): \(describeError(failure.error))"
  }

  private static func describeError(_ error: any Error) -> String {
    guard let ckError = error as? CKError else {
      return error.localizedDescription
    }
    var parts = ["\(ckError.code)"]
    let message = ckError.localizedDescription
    if !message.isEmpty {
      parts.append(message)
    }
    if let server = ckError.serverRecord {
      parts.append("server=\(server.recordType)/\(server.recordID.recordName)")
    }
    if let ancestor = ckError.ancestorRecord {
      parts.append("ancestor=\(ancestor.recordType)/\(ancestor.recordID.recordName)")
    }
    return parts.joined(separator: " | ")
  }
}
