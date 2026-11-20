import Foundation
import CloudKit
import OSLog
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// CKEngine — process-wide CKSyncEngine coordinator for the local-first
// SwiftData mirror. All app data uses this direct CloudKit path.

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
  ///
  /// Created on first use, not in `init`: Septask builds this object (the
  /// mutators take it) but has no iCloud entitlement, and `CKContainer`
  /// raises an exception for a container the app is not entitled to. Septask
  /// never starts the engine, so it never reaches this.
  var container: CKContainer {
    if let containerCache { return containerCache }
    let created = CKContainer(identifier: SeptenaCloudKit.containerIdentifier)
    containerCache = created
    return created
  }
  @ObservationIgnored private var containerCache: CKContainer?
  private var database: CKDatabase { container.privateCloudDatabase }

  /// Set on `start()`. Nil until Phase 1 wires the boot call in App.swift.
  private var engine: CKSyncEngine?

  /// Plug-in points. The engine calls these to (a) materialize a CKRecord
  /// for upload from the local mirror, (b) fold a downloaded record into
  /// the mirror, (c) erase a deleted record locally. Held as closures
  /// rather than a delegate protocol so the engine stays agnostic of
  /// SwiftData / TaskEntity, keeping this file in SeptenaCore without a
  /// forward import on the higher layer.
  ///
  /// The registry behind these closures covers every mirrored record type.
  /// The deleted closure gets the record type too, because the local mirror
  /// no longer holds the row by the time it needs to route the deletion.
var recordProvider: ((CKRecord.ID) async -> CKRecord?)?
var applyFetchedRecord: ((CKRecord) async -> Void)?
var applyDeletedRecord: ((CKRecord.ID, CKRecord.RecordType) async -> Void)?
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
var applyDidFinishBatch: ((_ notify: Bool) async -> Void)?
  /// Runs after a whole fetch pass has been applied (CKSyncEngine's
  /// `didFetchChanges`): the point where every delete the server had for this
  /// device is local. The delete-cascade sweep hangs off it
  /// (`AreasMutator.sweepDeletedContainerOrphans`).
var applyDidFetchChanges: (() async -> Void)?

  /// Current iCloud account status. Refreshed on init, when the system
  /// posts `.CKAccountChanged`, and any time `refreshAccountStatus()` is
  /// called explicitly (e.g. on scenePhase active). Observable so views
  /// can disable migration / show a banner without polling.
var accountStatus: CKAccountStatus = .couldNotDetermine
  /// Number of in-flight `sendChanges` / `fetchChanges` calls. Views can
  /// observe `isSyncing` to show a sync indicator while > 0.
  private(set) var inflightSyncCount: Int = 0
  var isSyncing: Bool { inflightSyncCount > 0 }

  /// True from `start()` until the first full fetch pass completes, and only
  /// when there was no persisted engine state to resume from — i.e. this
  /// device is pulling an existing account down for the first time. Views need
  /// this because `isSyncing` alone can't tell "downloading everything" from
  /// "saving one edit", and the two want very different UI: a bootstrap leaves
  /// the app looking empty for reasons that have nothing to do with the user.
  private(set) var isBootstrapping: Bool = false

  /// Records folded in during the current bootstrap, so the UI can show a
  /// number that visibly moves. Deliberately not a percentage: CKSyncEngine
  /// reports no total up front, so any progress bar would be invented.
  private(set) var bootstrapFetchedCount: Int = 0

  /// One-line status for the first-run download. Lives here rather than in a
  /// view so the SwiftUI indicator and the AppKit list's empty label can't
  /// drift apart. No count until the first batch lands, so nothing ever
  /// flashes "0 items".
  var bootstrapStatusText: String {
    bootstrapFetchedCount > 0
      ? String(localized: "Syncing… \(bootstrapFetchedCount) items",
               comment: "CloudKit first-run download, with a running record count")
      : String(localized: "Syncing…",
               comment: "CloudKit first-run download, before any records have arrived")
  }
  private var lastSendFailureSummary: String?

init() {
    #if !SEPTASK
    // Septask is CloudKit-free: no container, no account query (see
    // `container`).
    // The CKAccountChanged notification fires on an arbitrary thread, so
    // bounce back to MainActor before touching `self`.
    NotificationCenter.default.addObserver(
      forName: .CKAccountChanged, object: nil, queue: nil
    ) { [weak self] _ in
      Task { @MainActor in await self?.refreshAccountStatus() }
    }
    Task { await refreshAccountStatus() }
    #endif
  }

  /// Re-query the container for the user's iCloud status. Cheap; safe
  /// to call on every foreground transition.
  func refreshAccountStatus() async {
    #if SEPTASK
    return
    #else
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
    #endif
  }

  /// Boots the sync engine. Idempotent — safe to call repeatedly. No-op
  /// when called pre-Phase-1 (CKSyncEngine creation hits the network for
  /// account status; we don't want to pay that cost until we're ready
  /// to actually sync).
func start() {
    #if SEPTASK
    // Septask is CloudKit-free (docs/SEPTASK_BACKEND.md §9, phase 4): no
    // engine, no zone fetch, no push registration.
    SeptenaLog.info("[CKEngine] start skipped: Septask does not use CloudKit")
    return
    #else
    guard engine == nil else { return }
    // No persisted engine state means nothing has ever synced on this device,
    // so the fetch below pulls the whole account rather than a delta.
    let resumeState = loadStateSerialization()
    isBootstrapping = (resumeState == nil)
    bootstrapFetchedCount = 0
    let configuration = CKSyncEngine.Configuration(
      database: database,
      stateSerialization: resumeState,
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
    #endif
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
func noteTaskChange(id: String) { if routeToTaskBackend(.task, id) { return }; noteChange(recordName: id, kind: "task") }
func noteTaskDeletion(id: String) { if routeToTaskBackend(.task, id) { return }; noteDeletion(recordName: id, kind: "task") }

  // Area / Project pendants. CK doesn't distinguish by record type at the
  // engine layer — a pending save is a pending save — but logging the
  // kind helps when reading [CKEngine] traces post-mortem.
func noteAreaChange(id: String) { if routeToTaskBackend(.area, id) { return }; noteChange(recordName: AreaCloudKitSchema.recordName(for: id), kind: "area") }
func noteAreaDeletion(id: String) { if routeToTaskBackend(.area, id) { return }; noteDeletion(recordName: AreaCloudKitSchema.recordName(for: id), kind: "area") }
func noteProjectChange(id: String) { if routeToTaskBackend(.project, id) { return }; noteChange(recordName: ProjectCloudKitSchema.recordName(for: id), kind: "project") }
func noteProjectDeletion(id: String) { if routeToTaskBackend(.project, id) { return }; noteDeletion(recordName: ProjectCloudKitSchema.recordName(for: id), kind: "project") }

  /// Whether a deleted area / project can come back under its own id (undo).
  /// CloudKit accepts a save under a deleted record name; the task backend
  /// never revives a deleted row, so there it holds only while the delete
  /// still waits in the outbox (`TaskSyncEngine.canRevive`).
  func canReviveContainer(_ kind: DeletedContainerLedger.Kind, id: String) -> Bool {
    if TaskStoreMode.current == .backend {
      return TaskSyncEngine.shared.canRevive(kind == .area ? .area : .project, id)
    }
    return true
  }

  /// CloudKit only: take back an area / project delete that has not gone out
  /// yet, so the revived row's save is an ordinary update of the record
  /// CloudKit still has. Returns true when one was pending (the caller then
  /// keeps the row's old system fields). The backend cancels its own held
  /// delete on capture.
  func cancelPendingContainerDeletion(_ kind: DeletedContainerLedger.Kind, id: String) -> Bool {
    guard TaskStoreMode.current != .backend, let engine else { return false }
    let name = kind == .area ? AreaCloudKitSchema.recordName(for: id)
                             : ProjectCloudKitSchema.recordName(for: id)
    let recordID = CKRecord.ID(recordName: name, zoneID: SeptenaCloudKit.zoneID)
    let delete = CKSyncEngine.PendingRecordZoneChange.deleteRecord(recordID)
    guard engine.state.pendingRecordZoneChanges.contains(delete) else { return false }
    engine.state.remove(pendingRecordZoneChanges: [delete])
    return true
  }
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
func noteTaskAttachmentChange(id: String) { if routeToTaskBackend(.attachment, id) { return }; noteChange(recordName: TaskAttachmentCloudKitSchema.recordName(for: id), kind: "taskAttachment") }
func noteTaskAttachmentDeletion(id: String) { if routeToTaskBackend(.attachment, id) { return }; noteDeletion(recordName: TaskAttachmentCloudKitSchema.recordName(for: id), kind: "taskAttachment") }

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

  // MARK: - Task-store cutover (docs/SEPTASK_BACKEND.md §7, §9 phase 3)
  //
  // In `TaskStoreMode.backend` the four task record types (Task, Area,
  // Project, TaskAttachment) FREEZE here: a local change is routed to the
  // backend sync instead of queued for CloudKit, a queued CloudKit change for
  // them is never sent, and an incoming CloudKit record of those types is
  // ignored, so a device still on CloudKit cannot overwrite backend state.
  // Every other record type syncs as before.

  /// True while `TaskStoreRollback` sends the local rows back: the send-side
  /// freeze is lifted for that send only. Incoming records stay frozen until
  /// the rollback flips the mode.
  var taskRollbackSending = false

  private var blocksTaskSends: Bool { TaskStoreMode.current == .backend && !taskRollbackSending }
  private var blocksTaskApplies: Bool { TaskStoreMode.current == .backend }

  /// The swap point. In backend mode, hands the change to `TaskSyncEngine`
  /// (Septask) or drops it (Septena, which never syncs tasks to the backend;
  /// Septask's reconcile picks the row up from the shared store) and returns
  /// true. In CloudKit mode returns false and the caller queues as before.
  private func routeToTaskBackend(_ entity: BackendEntity, _ id: String) -> Bool {
    guard TaskStoreMode.current == .backend else { return false }
    TaskSyncEngine.shared.captureLocalChange(entity, id: id)
    return true
  }

  /// Whether a task row never reached the store it syncs with, so a delete
  /// or purge of it can stay local. CloudKit: no system fields. Backend: the
  /// sync shadow does not know it.
  func taskNeverSynced(id: String, systemFields: Data?) -> Bool {
    if TaskStoreMode.current == .backend { return !TaskSyncEngine.shared.backendKnowsTask(id) }
    return systemFields == nil
  }

  /// Rollback only: queue saves / deletes for task-type records past the
  /// routing above.
  func queueTaskRollbackSaves(recordNames: [String]) { noteChanges(recordNames: recordNames) }
  func queueTaskRollbackDeletions(recordNames: [String]) { noteDeletions(recordNames: recordNames) }

  /// Count of writes the engine has accepted but not yet sent to CloudKit.
  /// Non-zero before sendChanges drains; useful in diagnostics to see if a
  /// device has un-pushed local mutations.
  var pendingRecordZoneChangesCount: Int {
    engine?.state.pendingRecordZoneChanges.count ?? 0
  }

  /// True when a save for this task is queued and not yet confirmed. Lets the
  /// task backend tell a deferred draft (never queued, nothing to send) from a
  /// fresh row whose first upload is still pending (which must carry later
  /// edits such as a soft delete).
  func hasPendingTaskSave(id: String) -> Bool {
    guard let engine else { return false }
    return engine.state.pendingRecordZoneChanges.contains { change in
      if case .saveRecord(let recordID) = change { return recordID.recordName == id }
      return false
    }
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
      // Only drop SAVES — those are the flood. DELETIONS are intentional cleanup
      // a prior build may have enqueued and must survive a relaunch to finish.
      case .saveRecord(let id): return id.recordName.hasPrefix(prefix)
      default: return false
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

  /// True once `start()` has created the sync engine.
  var isStarted: Bool { engine != nil }

  /// Read-only. How many queued saves or deletes target one of these record
  /// names. The task-backend import refuses to start while any task, area,
  /// project or attachment change is still unsent, because the local mirror
  /// would then hold edits CloudKit has not confirmed.
  func pendingChangeCount(recordNames: Set<String>) -> Int {
    guard let engine else { return 0 }
    return engine.state.pendingRecordZoneChanges.reduce(0) { count, change in
      switch change {
      case .saveRecord(let id), .deleteRecord(let id):
        return recordNames.contains(id.recordName) ? count + 1 : count
      @unknown default:
        return count
      }
    }
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
      // Log only. Nothing here wipes the local mirror on sign-out or
      // re-uploads it on sign-in: the SwiftData rows stay as they are, so a
      // switched iCloud account keeps the previous account's local rows on
      // this device. A wipe is deliberately not implemented (data-loss risk).
      logger.info("CKEngine accountChange: \(String(describing: change), privacy: .public)")

    case .fetchedRecordZoneChanges(let changes):
      Log.cloudKit.debug("[CKEngine] fetched: +\(changes.modifications.count) ~ -\(changes.deletions.count) reset=\(self.applyingResetCascade)")
      if isBootstrapping { bootstrapFetchedCount += changes.modifications.count }
      // Materialize into the registry's background ModelActor. This keeps
      // large CloudKit pulls from monopolizing the UI actor.
      let callbacks = await MainActor.run {
        (self.applyFetchedRecord, self.applyDeletedRecord, self.applyDidFinishBatch)
      }
      let frozen = blocksTaskApplies ? TaskStoreMode.backendOwnedRecordTypes : []
      var ignored = 0
      for mod in changes.modifications {
        if frozen.contains(mod.record.recordType) { ignored += 1; continue }
        await callbacks.0?(mod.record)
      }
      for del in changes.deletions {
        if applyingResetCascade {
          SeptenaLog.info("[CKEngine] fetched.delete IGNORED (reset) id=\(del.recordID.recordName)")
          continue
        }
        if frozen.contains(String(del.recordType)) { ignored += 1; continue }
        await callbacks.1?(del.recordID, del.recordType)
      }
      if ignored > 0 {
        SeptenaLog.info("[CKEngine] fetched: ignored \(ignored) task-type changes (task store is the backend)")
      }
      // Inbound remote changes — the UI hasn't seen these; repaint.
      await callbacks.2?(true)

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
        guard fail.error.code == .serverRecordChanged else { return nil }
        return fail.record.recordID
      }
      var freshServerRecords: [CKRecord] = []
      if !oplockIDs.isEmpty {
        let db: CKDatabase = await MainActor.run { self.database }
        let results = (try? await db.records(for: oplockIDs)) ?? [:]
        freshServerRecords = results.values.compactMap { try? $0.get() }
        SeptenaLog.info("[CKEngine] fetched \(freshServerRecords.count) fresh records for oplock resolution")
      }

      let applyRecord = await MainActor.run { self.applyFetchedRecord }
      for save in sent.savedRecords {
        await applyRecord?(save)
      }
      // Apply fresh server versions of oplock-conflicting records so the
      // next CKSyncEngine retry sends the correct etag instead of looping.
      // Not for task types while the backend owns them: the CloudKit version
      // would overwrite the row the rollback is copying back.
      let frozenTypes = blocksTaskApplies ? TaskStoreMode.backendOwnedRecordTypes : []
      for fresh in freshServerRecords {
        if frozenTypes.contains(fresh.recordType) {
          SeptenaLog.error("[CKEngine] oplock on \(fresh.recordID.recordName) NOT resolved (task store is the backend)")
          continue
        }
        await applyRecord?(fresh)
      }
      await MainActor.run {
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
        // The server now holds these changes — ring the same-device sibling
        // app (Septena ↔ Septask) so it fetches now instead of on its next
        // foreground. Purely a hint; see SiblingNudge.
        if !sent.savedRecords.isEmpty || !sent.deletedRecordIDs.isEmpty {
          SiblingNudge.post()
        }
      }
      // Our own writes echoing back. Fold in system fields (the save in the
      // batch handler), but only repaint when an oplock conflict made the
      // server's version win — otherwise the optimistic write + the
      // mutator's scoped post already brought the UI current, and a second
      // app-wide reload here is the per-edit hitch we're eliminating.
      let finishBatch = await MainActor.run { self.applyDidFinishBatch }
      await finishBatch?(!freshServerRecords.isEmpty)

    case .didFetchChanges:
      // A fetch pass finished. If that was the bootstrap, everything the
      // account had is now local and later fetches are ordinary deltas.
      if isBootstrapping {
        logger.info("CKEngine bootstrap complete: \(self.bootstrapFetchedCount, privacy: .public) records")
        isBootstrapping = false
      }
      let didFetch = await MainActor.run { self.applyDidFetchChanges }
      await didFetch?()

    case .fetchedDatabaseChanges, .sentDatabaseChanges,
         .willFetchChanges,
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
    var pending = syncEngine.state.pendingRecordZoneChanges
      .filter { context.options.scope.contains($0) }
    // Send-side freeze: a task-type change queued past the routing (another
    // process on the shared store, or one queued before the switch) is
    // removed, never sent.
    let blocksSends = await MainActor.run { self.blocksTaskSends }
    if blocksSends {
      let frozen = pending.filter { change in
        switch change {
        case .saveRecord(let id), .deleteRecord(let id):
          return TaskStoreMode.isBackendOwnedRecordName(id.recordName)
        @unknown default:
          return false
        }
      }
      if !frozen.isEmpty {
        syncEngine.state.remove(pendingRecordZoneChanges: frozen)
        pending.removeAll { frozen.contains($0) }
        SeptenaLog.info("[CKEngine] removed \(frozen.count) queued task-type changes (task store is the backend)")
      }
    }
    guard !pending.isEmpty else { return nil }
    // Pre-resolve every record on the registry's background ModelActor before
    // handing the batch builder a pure dictionary-lookup closure.
    let provider = await MainActor.run { self.recordProvider }
    var resolved: [CKRecord.ID: CKRecord] = [:]
    for change in pending {
      // PendingRecordZoneChange is an enum (.saveRecord(id) / .deleteRecord(id)).
      // We only need the save case here — deletes don't ask the resolver for
      // a CKRecord.
      guard case .saveRecord(let id) = change else { continue }
      if resolved[id] == nil, let rec = await provider?(id) {
        resolved[id] = rec
      }
    }
    let resolvedRecords = resolved
    return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
      resolvedRecords[recordID]
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
