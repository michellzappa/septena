import Foundation
import Observation
import SwiftData

// The app-side task sync client (docs/SEPTASK_BACKEND.md §6, §7, §9).
// Active only in Septask, which is backend-only and never starts CloudKit
// (phase 4, 2026-11-19). In Septena every entry point is a no-op.
//
// Local edit → backend:
//   A mutator saves SwiftData and calls `CKEngine.noteTaskChange` (or the
//   area / project / attachment twin), as it always did. In backend mode
//   CKEngine does not queue a CloudKit change; it calls
//   `captureLocalChange`. That diffs the row against its shadow
//   (`TaskSyncStore`) and appends the changed fields to the persistent
//   outbox, coalesced per row. A debounced push sends the outbox in order,
//   ≤500 ops per request, with retries and backoff.
//
// Backend → screen:
//   `pull` reads `GET /v1/sync/pull?since=` page by page and writes rows
//   straight into SwiftData (TaskSyncApply.swift). That path never calls
//   CKEngine, so it enqueues no echo. A field with a queued local op is not
//   overwritten (local wins until its push lands). Then it posts the same
//   notifications the CloudKit apply path posts.
//
// Pull runs on start, on foreground, after every push, on a WebSocket
// nudge, and on a slow fallback poll (`pollLoop`) that covers a dead socket
// or a missed nudge. Push and pull never overlap (`runSync` serializes them).
//
// macOS keeps all of this running while the app is not active: a Mac app's
// window stays on screen behind other apps, so its list must keep up with
// edits from the phone or Claude. Only iOS closes the socket in background.
//
// Settings: Septask's account-wide settings sync as the `setting` entity
// (TaskSyncSettings.swift), through the same outbox, shadow and pull.
//
// Signed out: nothing is sent or pulled, but every local edit is still
// captured into the persistent outbox, which drains after sign-in.
//
// Mutators stay the write boundary: nothing here is called from a view.

@MainActor
@Observable
final class TaskSyncEngine {
  static let shared = TaskSyncEngine()

  // MARK: Status (observable, for the settings pane)

  private(set) var signedIn: Bool = TaskBackendClient.hasSession
  /// True when an account has previously signed in on this device (and was not
  /// deleted). Lets free no-account installs stay quiet without "Not signed in"
  /// banners while still surfacing a dismissible prompt if an existing session
  /// ends.
  private(set) var hadAccount: Bool = UserDefaults.standard.string(forKey: TaskSyncEngine.lastUserKey) != nil
  /// Ops in the outbox, uploads included.
  private(set) var pendingOps = 0
  var lastPull: Date?
  private(set) var lastError: String?
  private(set) var wsConnected = false
  /// True when the server refused sync for this device (`402 device_not_syncing`
  /// or `GET /v1/entitlement` says this device has no sync slot). The device
  /// keeps working locally with no error banner (spec §6.3, §7).
  private(set) var deviceNotSyncing = false
  /// True when live WebSocket nudges are unavailable on the current plan
  /// (`402 live_sync_not_in_plan` or `limits.liveSync == false`). Sync falls
  /// back to polling `/v1/sync/pull` at most every 2 minutes while active
  /// (spec §6.3, §6.4 finding 8).
  private(set) var liveSyncBlocked = false
  /// Attachments kept locally on this device because the server refused their
  /// upload with `402 attachments_not_in_plan` or `attachment_quota`.
  private(set) var localOnlyAttachmentIDs: Set<String> = []
  /// Pulled attachment metadata rows whose bytes were never uploaded to the
  /// server (`uploadedAt == null`) and are not on this device.
  private(set) var elsewhereAttachmentIDs: Set<String> = []
  private(set) var isRunning = false
  private(set) var isSyncing = false
  /// Ops the backend rejected or dropped, and rows that fail the backend's
  /// limits and so cannot be sent. Newest last, capped. Also logged.
  private(set) var issues: [TaskBackendIssue] = []

  // MARK: Internal state

  @ObservationIgnored let client = TaskBackendClient.shared
  @ObservationIgnored private var storeCache: TaskSyncStore?
  @ObservationIgnored private var syncTimer: Task<Void, Never>?
  /// When the pending `syncTimer` fires; nil once its run has started.
  @ObservationIgnored private var syncTimerDeadline: Date?
  @ObservationIgnored private var syncAgain = false
  @ObservationIgnored private var retryDelay: TimeInterval = 0
  @ObservationIgnored var needsRepairPull = false
  @ObservationIgnored private var appActive = true
  @ObservationIgnored private var lastReconcile: Date = .distantPast
  /// The first pull of this process is a launch signpost (docs/LAUNCH_PERF.md).
  @ObservationIgnored private var firstPullTraced = false
  @ObservationIgnored private var socket: URLSessionWebSocketTask?
  @ObservationIgnored private var socketGeneration = 0
  @ObservationIgnored private var socketRetry: TimeInterval = 1
  @ObservationIgnored private var lastSocketPlanRefresh: Date = .distantPast
  @ObservationIgnored private var localOnlyAttachmentReasons: [String: String] = [:]
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  /// Current fallback-poll interval; doubles after a failed run (see `pollLoop`).
  @ObservationIgnored private var pollBackoff: TimeInterval = 0
  @ObservationIgnored private let socketSession = URLSession(configuration: .default)
  /// The backend refused a setting op this launch (a server that predates
  /// the `setting` entity). Settings then stop being sent until the next
  /// launch, so the refusal does not repeat on every sync.
  @ObservationIgnored private var settingsRefused = false
  /// The backend does not take reference writes yet (an older server, or one
  /// whose core cannot check a key). References then stay on this device and
  /// wait for the next launch, so the refusal does not repeat on every sync.
  @ObservationIgnored private var taskRefsRefused = false

  /// Soft-delete grace: a delete waits this long in the outbox, so ⌘Z (which
  /// restores the row) cancels it before the backend sees it. The backend
  /// never revives a deleted row (§6.4).
  static let deleteGrace: TimeInterval = TimeInterval(RegistryRules.deleteGraceSeconds)
  static let batchLimit = RegistryEntityLimits.maxOpsPerPush
  static let sinceKey = "septena.taskSync.since"
  /// True once a pull that asked for settings finished. Until then a local
  /// setting is not sent, so a value another device already pushed wins.
  static let settingsReadyKey = "septena.taskSync.settingsReady"
  /// True once a pull that asked for references finished.
  static let taskRefsReadyKey = "septena.taskSync.taskRefsReady"
  /// True once a pull that asked for Do sessions finished.
  static let doSessionsReadyKey = "septena.taskSync.doSessionsReady"
  /// Backend user id of the last sign-in, compared on the next sign-in.
  static let lastUserKey = "septena.taskSync.lastUserID"
  @ObservationIgnored private static let issueCap = 200

  /// Optional lifecycle hooks for remote push token registration/cleanup
  /// (`SeptaskPushNotifications`), keeping `SeptenaCore` decoupled from app targets.
  static var onSignInHook: (@MainActor () -> Void)?
  static var beforeSignOutHook: (@MainActor () async -> Void)?

  private init() {}

  var main: ModelContext { LocalStore.shared.container.mainContext }

  /// Highest backend rev applied to SwiftData. Written only after the page
  /// it ends was saved (§6.2).
  var since: Int {
    get { UserDefaults.standard.integer(forKey: Self.sinceKey) }
    set { UserDefaults.standard.set(newValue, forKey: Self.sinceKey) }
  }

  func store() -> TaskSyncStore? {
    if let storeCache { return storeCache }
    do {
      let s = try TaskSyncStore()
      storeCache = s
      return s
    } catch {
      lastError = "The sync queue could not be opened: \(error.localizedDescription)"
      SeptenaLog.error("[TaskSync] store open failed", error)
      return nil
    }
  }

  func refreshPendingCount() {
    pendingOps = storeCache?.opCount() ?? 0
  }

  // MARK: - Lifecycle

  /// Called from `SeptenaServices.start()`. No-op outside Septask.
  func start() {
    guard !isRunning, !DemoSeedMode.isOn else { return }
    guard let store = store() else { return }
    if !settingsReady || !taskRefsReady || !doSessionsReady {
      // Pulls before this build skipped setting, reference and Do rows, and
      // `since` moved past them. Read everything once, so the rows another
      // device or an agent wrote arrive.
      since = 0
    }
    hydrateAttachmentLimitState(store: store)
    isRunning = true
    signedIn = TaskBackendClient.hasSession
    deviceNotSyncing = PlanStatus.shared.deviceNotSyncing
    liveSyncBlocked = !PlanStatus.shared.liveSyncAllowed
    refreshPendingCount()
    guard signedIn else {
      // Free no-account mode (docs/SYNC_SUBSCRIPTION_SPEC.md §3, §7): local
      // writes still land in the outbox so signing in later syncs them, but do
      // not spin up the network sync loop, poll timer or WebSocket.
      lastError = nil
      deviceNotSyncing = false
      liveSyncBlocked = false
      SeptenaLog.info("[TaskSync] started offline (no account) pending=\(pendingOps)")
      return
    }
    SeptenaLog.info("[TaskSync] started since=\(since) pending=\(pendingOps)")
    Task { @MainActor in
      if !self.deviceNotSyncing {
        await self.runSync(reconcileFirst: true)
        self.connectSocket()
      }
    }
    startPolling()
  }

  func stop() {
    isRunning = false
    syncTimer?.cancel()
    syncTimer = nil
    syncTimerDeadline = nil
    pollTask?.cancel()
    pollTask = nil
    disconnectSocket()
  }

  /// Foreground. Reconciles (at most once a minute), syncs, reopens the socket.
  func activate() {
    appActive = true
    guard isRunning else { return }
    signedIn = TaskBackendClient.hasSession
    guard signedIn else {
      lastError = nil
      deviceNotSyncing = false
      liveSyncBlocked = false
      return
    }
    if deviceNotSyncing {
      // Re-check entitlement on foreground instead of firing wasted 402 sync
      // calls; if the user upgraded or moved the slot, `applyPlanStatus`
      // clears `deviceNotSyncing` and resumes sync right away.
      Task { @MainActor in await PlanStatus.shared.refresh() }
    } else {
      Task { @MainActor in
        await self.runSync(reconcileFirst: true)
        self.connectSocket()
      }
    }
    startPolling()
  }

  /// Applies fresh server plan limits from `PlanStatus.refresh()` (spec §6.3).
  /// Resumes sync or live WebSocket when a limit lifts (upgrade, slot move)
  /// and re-queues attachments that were held local on a free account.
  func applyPlanStatus(deviceNotSyncing newDeviceNotSyncing: Bool,
                       liveSyncAllowed: Bool,
                       attachmentsAllowed: Bool) {
    let wasDevicePaused = deviceNotSyncing
    let wasLiveBlocked = liveSyncBlocked
    deviceNotSyncing = newDeviceNotSyncing
    liveSyncBlocked = !liveSyncAllowed

    if deviceNotSyncing {
      lastError = nil
      disconnectSocket()
      return
    }
    if liveSyncBlocked {
      disconnectSocket()
    }
    if attachmentsAllowed {
      requeuePlanBlockedAttachmentsIfNeeded()
    }
    guard isRunning, appActive, signedIn else { return }
    if wasDevicePaused {
      scheduleSync(after: 0)
    }
    if !liveSyncBlocked, (wasLiveBlocked || wasDevicePaused || !wsConnected) {
      connectSocket()
    }
  }

  /// Background: try once more to drain the outbox. iOS also closes the
  /// socket and stops the poll (the process is about to be suspended;
  /// `activate` reopens both). macOS keeps both: a Mac app keeps running
  /// with its window on screen behind other apps, and its list must stay
  /// current while it is not key (SwiftUI reports `.background` for the
  /// classic window when it closes or minimizes, which is not the app
  /// leaving the screen).
  func enterBackground() {
    guard isRunning else { return }
    #if os(iOS)
    appActive = false
    disconnectSocket()
    pollTask?.cancel()
    pollTask = nil
    #endif
    if signedIn, !deviceNotSyncing, pendingOps > 0 { scheduleSync(after: 0) }
  }

  // MARK: - Fallback poll

  /// Pull interval while the live socket is down (2 minutes, spec §6.4 finding 8).
  static let pollWhileSocketDown: TimeInterval = TaskSyncPollPolicy.pollWhileSocketDown
  /// Safety pull while the socket is up, for a nudge the socket dropped.
  static let pollWhileSocketUp: TimeInterval = TaskSyncPollPolicy.pollWhileSocketUp
  /// Backoff cap after failed runs.
  static let pollMax: TimeInterval = TaskSyncPollPolicy.pollMax

  /// One poll loop per process while the engine runs (and, on iOS, while the
  /// app is in the foreground). Idempotent.
  private func startPolling() {
    guard isRunning, appActive, pollTask == nil else { return }
    pollTask = Task { @MainActor [weak self] in
      await self?.pollLoop()
      // Ended on its own (stopped, or iOS went to background): let the next
      // `activate` start a fresh loop. A cancelled loop was already replaced
      // or cleared by whoever cancelled it.
      if !Task.isCancelled { self?.pollTask = nil }
    }
  }

  /// Sleeps, then pulls when nothing else did recently. The interval is
  /// at most 2 minutes while live sync is unavailable or the socket is down,
  /// and 10 minutes while the socket is up; a failed run doubles it (capped at
  /// `pollMax`), a clean run resets it.
  private func pollLoop() async {
    while !Task.isCancelled {
      let interval = TaskSyncPollPolicy.nextPollInterval(
        wsConnected: wsConnected,
        liveSyncBlocked: liveSyncBlocked,
        pollBackoff: pollBackoff
      )
      try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
      guard !Task.isCancelled, isRunning, appActive else { return }
      guard TaskBackendClient.hasSession else { continue }
      // This device has no sync slot on the current plan: keep local edits in
      // the outbox without hammering `/v1/sync/pull` or `/v1/sync/ws`.
      if deviceNotSyncing { continue }
      let base = TaskSyncPollPolicy.baseInterval(wsConnected: wsConnected, liveSyncBlocked: liveSyncBlocked)
      // A recent pull (nudge, push, foreground) already did this poll's job.
      if let lastPull, Date().timeIntervalSince(lastPull) < base * 0.8 { continue }
      await runSync(reconcileFirst: false)
      pollBackoff = lastError == nil ? 0 : min(Self.pollMax, max(base, pollBackoff) * 2)
      // The socket may have given up while signed out or offline; retry it
      // only when live sync is allowed by the plan and this device is syncing.
      if !wsConnected, TaskSyncPollPolicy.shouldConnectSocket(
        isRunning: isRunning, appActive: appActive, signedIn: signedIn,
        deviceNotSyncing: deviceNotSyncing, liveSyncBlocked: liveSyncBlocked
      ) {
        connectSocket()
      }
    }
  }

  /// Push then pull, awaited. For `absorbRemoteChanges` at launch.
  func syncNow() async {
    guard isRunning else { return }
    await runSync(reconcileFirst: false)
  }

  // MARK: - Capture (called by CKEngine)

  /// A mutator changed (or deleted) a row of a backend-owned type. Diffs it
  /// against its shadow and queues the changed fields. Safe before `start()`:
  /// the outbox is persistent and drains once the engine runs.
  func captureLocalChange(_ entity: BackendEntity, id: String) {
    guard !DemoSeedMode.isOn, let store = store() else { return }
    let lookup: (String) -> TaskSyncShadow? = { store.shadow($0) }
    switch entity {
    case .task: captureTask(id, row: fetchTask(id), store: store, reconciling: false, lookup: lookup)
    case .area: captureArea(id, row: fetchArea(id), store: store, lookup: lookup)
    case .project: captureProject(id, row: fetchProject(id), store: store, lookup: lookup)
    case .attachment: captureAttachment(id, row: fetchAttachment(id), store: store, lookup: lookup)
    case .checklistItem: captureChecklistItem(id, row: fetchChecklistItem(id), store: store, lookup: lookup)
    case .taskRef: captureTaskRef(id, row: fetchTaskRef(id), store: store, lookup: lookup)
    case .doSession: captureDoSession(id, row: fetchDoSession(id), store: store, lookup: lookup)
    case .tag: captureTag(id, row: fetchTag(id), store: store, lookup: lookup)
    case .convo, .turn, .setting: break
    }
    refreshPendingCount()
    if isRunning, signedIn, !deviceNotSyncing { scheduleSync(after: 0.8) }
  }

  /// True when a deleted area / project can come back under its own id: the
  /// backend never had it, or its delete still waits in the outbox (held for
  /// `deleteGrace`). False once the delete reached the backend, which never
  /// revives a deleted row — undo then has to mint a new id.
  func canRevive(_ entity: BackendEntity, _ id: String) -> Bool {
    guard let store = store() else { return true }
    guard let shadow = store.shadow("\(entity.rawValue):\(id)"), shadow.gone else { return true }
    guard let last = store.lastRowOp(entity: entity.rawValue, rowID: id) else {
      return false
    }
    return last.kind == TaskSyncOpKind.delete && !last.sent
  }

  /// The id of the task's next reference to this key (§4): `n` counts the rows
  /// the backend deleted. A delete that still waits in the outbox does not
  /// count, so adding the key again takes the same id back and cancels it. An
  /// id that a deleted row holds moves on to the next, as on the backend
  /// (purged tombstones lower the count). Nil until the core mints ids.
  func nextTaskRefID(taskID: String, key: String) -> String? {
    var deleted = 0
    if let store = store() {
      let entity = BackendEntity.taskRef
      deleted = store.goneShadows(entity: entity.rawValue).filter { shadow in
        let fields = TaskSyncJSON.decode(shadow.fields)
        return fields["taskId"] == .string(taskID) && fields["key"] == .string(key)
          && !canRevive(entity, String(shadow.key.dropFirst(entity.rawValue.count + 1)))
      }.count
    }
    while let id = TaskRefCore.mintID(taskID: taskID, key: key, deletedCount: deleted) {
      if canRevive(.taskRef, id) { return id }
      deleted += 1
    }
    return nil
  }

  /// True when the backend has (or will get, from the outbox) this task, so
  /// a delete must be sent rather than kept local. Septena never opens the
  /// store and answers true: its notes are dropped by the freeze anyway.
  func backendKnowsTask(_ id: String) -> Bool {
    guard let store = store(), let shadow = store.shadow("task:\(id)") else { return false }
    return TaskSyncJSON.decode(shadow.fields)["_remote"] == .bool(true) || shadow.gone
  }

  /// Diffs every local row against its shadow and queues what differs. Picks
  /// up edits that reached SwiftData without a capture: a crash between the
  /// save and the queue write, or a write from Septena's process.
  func reconcile(store: TaskSyncStore) {
    let shadows = store.allShadows()
    let lookup: (String) -> TaskSyncShadow? = { shadows[$0] ?? store.shadow($0) }
    let tasks = (try? main.fetch(FetchDescriptor<TaskEntity>())) ?? []
    let areas = (try? main.fetch(FetchDescriptor<AreaEntity>())) ?? []
    let projects = (try? main.fetch(FetchDescriptor<ProjectEntity>())) ?? []
    let attachments = (try? main.fetch(FetchDescriptor<TaskAttachmentEntity>())) ?? []
    let checklistItems = (try? main.fetch(FetchDescriptor<TaskChecklistItemEntity>())) ?? []
    let taskRefs = (try? main.fetch(FetchDescriptor<TaskRefEntity>())) ?? []
    let doSessions = (try? main.fetch(FetchDescriptor<DoSessionEntity>())) ?? []
    let tags = (try? main.fetch(FetchDescriptor<TagEntity>())) ?? []
    for a in areas { captureArea(a.id, row: a, store: store, lookup: lookup) }
    for p in projects { captureProject(p.id, row: p, store: store, lookup: lookup) }
    for tag in tags { captureTag(tag.id, row: tag, store: store, lookup: lookup) }
    // Headings first, as the importer does, so members never precede them.
    for t in tasks.sorted(by: { $0.isHeading && !$1.isHeading }) {
      captureTask(t.id, row: t, store: store, reconciling: true, lookup: lookup)
    }
    for a in attachments { captureAttachment(a.id, row: a, store: store, lookup: lookup) }
    for item in checklistItems { captureChecklistItem(item.id, row: item, store: store, lookup: lookup) }
    for ref in taskRefs { captureTaskRef(ref.id, row: ref, store: store, lookup: lookup) }
    for s in doSessions { captureDoSession(s.id, row: s, store: store, lookup: lookup) }

    // Rows the backend has that are gone here: hard-deleted without a capture.
    let present: [String: Set<String>] = [
      "task": Set(tasks.map(\.id)), "area": Set(areas.map(\.id)),
      "project": Set(projects.map(\.id)), "attachment": Set(attachments.map(\.id)),
      "checklistItem": Set(checklistItems.map(\.id)), "taskRef": Set(taskRefs.map(\.id)),
      "doSession": Set(doSessions.map(\.id)), "tag": Set(tags.map(\.id)),
    ]
    for (key, shadow) in shadows where !shadow.gone {
      guard let colon = key.firstIndex(of: ":") else { continue }
      let kind = String(key[..<colon])
      let id = String(key[key.index(after: colon)...])
      guard let ids = present[kind], !ids.contains(id) else { continue }
      switch kind {
      case "task": captureTask(id, row: nil, store: store, reconciling: true, lookup: lookup)
      case "area": captureArea(id, row: nil, store: store, lookup: lookup)
      case "project": captureProject(id, row: nil, store: store, lookup: lookup)
      case "attachment": captureAttachment(id, row: nil, store: store, lookup: lookup)
      case "checklistItem": captureChecklistItem(id, row: nil, store: store, lookup: lookup)
      case "taskRef": captureTaskRef(id, row: nil, store: store, lookup: lookup)
      case "doSession": captureDoSession(id, row: nil, store: store, lookup: lookup)
      case "tag": captureTag(id, row: nil, store: store, lookup: lookup)
      default: break
      }
    }
    store.saveNow()
    lastReconcile = Date()
    refreshPendingCount()
  }

  // MARK: Capture per entity

  private func captureTask(_ id: String, row t: TaskEntity?, store: TaskSyncStore, reconciling: Bool,
                           lookup: (String) -> TaskSyncShadow?) {
    let key = "task:\(id)"
    let shadow = lookup(key)
    guard let t else {
      // Hard-deleted here (purge). Tell the backend unless it already knows.
      // Held like a soft delete: undoing a recurring completion purges the
      // spawned occurrence, and completing again re-creates the SAME id,
      // which the backend would refuse once the delete landed (§6.4).
      if let shadow, !shadow.gone {
        queueDeleteIfNeeded(.task, id, hold: true, store: store)
        shadow.gone = true
        store.saveSoon()
      }
      return
    }
    // A deferred inline draft (empty title, never noted) stays local until its
    // first real update, as on CloudKit.
    if reconciling, shadow == nil, t.title.isEmpty { return }

    let mapped: [String: BackendJSON]
    switch TaskBackendMapping.task(t) {
    case .success(let plan): mapped = plan.fields
    case .failure(let issue): noteBlocked(issue); return
    }
    clearBlocked(.task, id)

    let old = shadow.map { TaskSyncJSON.decode($0.fields) } ?? [:]
    var base = old
    let remote = old["_remote"] == .bool(true)
    let wasDeleted = old["_deleted"] == .bool(true)
    let deletedHere = t.deletedAt != nil

    if !remote {
      base = mapped
      base["_remote"] = .bool(!deletedHere)
      base["_deleted"] = .bool(deletedHere)
      if !deletedHere { enqueueUpsert(.task, id, mapped, store: store) }
      writeShadow(shadow, key, old: old, new: base, store: store)
      if !deletedHere { captureConvo(t, store: store, lookup: lookup) }
      return
    }

    if deletedHere {
      if !wasDeleted {
        if shadow?.gone != true {
          store.append(kind: TaskSyncOpKind.delete, entity: BackendEntity.task.rawValue, rowID: id,
                       payload: [:], notBefore: Date().addingTimeInterval(Self.deleteGrace))
        }
        base["_deleted"] = .bool(true)
        writeShadow(shadow, key, old: old, new: base, store: store)
      }
      return
    }

    // Live here.
    var patch: [String: BackendJSON] = [:]
    var cancelledDelete = false
    if let last = store.lastRowOp(entity: BackendEntity.task.rawValue, rowID: id),
       last.kind == TaskSyncOpKind.delete, !last.sent {
      // Restored (or re-created) inside the grace period: the backend never
      // saw the delete.
      store.remove(last)
      cancelledDelete = true
      if shadow?.gone == true { shadow?.gone = false }
    }
    if (wasDeleted || shadow?.gone == true) && !cancelledDelete {
      // The delete reached the backend (or came from it). Send the row; the
      // backend answers `dropped`, and `handleDropped` puts the row back in
      // Recently Deleted and reports it. Deleted stays deleted (§6.4).
      patch = mapped
    } else {
      for (k, v) in mapped where (old[k] ?? .null).canonical != v.canonical { patch[k] = v }
    }
    if !patch.isEmpty { enqueueUpsert(.task, id, patch, store: store) }
    for (k, v) in mapped { base[k] = v }
    base["_deleted"] = .bool(false)
    writeShadow(shadow, key, old: old, new: base, store: store)
    captureConvo(t, store: store, lookup: lookup)
  }

  private func captureConvo(_ t: TaskEntity, store: TaskSyncStore, lookup: (String) -> TaskSyncShadow?) {
    switch TaskBackendMapping.convo(taskID: t.id, json: t.conversationJSON) {
    case .failure(let issue):
      noteBlocked(issue)
    case .success(.none):
      return
    case .success(.some(let (row, turns))):
      clearBlocked(.convo, t.id)
      let key = "convo:\(t.id)"
      let shadow = lookup(key)
      let old = shadow.map { TaskSyncJSON.decode($0.fields) } ?? [:]
      var patch: [String: BackendJSON] = [:]
      for (k, v) in row.fields where shadow == nil || (old[k] ?? .null).canonical != v.canonical { patch[k] = v }
      if !patch.isEmpty {
        enqueueUpsert(.convo, t.id, patch, store: store)
        var base = old
        for (k, v) in patch { base[k] = v }
        writeShadow(shadow, key, old: old, new: base, store: store)
      }

      // Turns are append-only on the backend: queue the ones past what was
      // already queued or received.
      let turnsKey = "turns:\(t.id)"
      let turnsShadow = lookup(turnsKey)
      let tOld = turnsShadow.map { TaskSyncJSON.decode($0.fields) } ?? Self.emptyTurnsShadow
      let queued = Self.int(tOld["local"]) ?? 0
      if turns.turns.count > queued {
        for i in queued..<turns.turns.count {
          store.append(kind: TaskSyncOpKind.appendTurn, entity: BackendEntity.turn.rawValue, rowID: t.id,
                       turnIndex: i, payload: turns.turns[i])
        }
        var tNew = tOld
        tNew["local"] = .int(Int64(turns.turns.count))
        writeShadow(turnsShadow, turnsKey, old: tOld, new: tNew, store: store)
      } else if turns.turns.count < queued {
        SeptenaLog.info("[TaskSync] task \(t.id) thread shrank locally (\(turns.turns.count) < \(queued)); turns are append-only on the backend, nothing sent")
      }
    }
  }

  static let emptyTurnsShadow: [String: BackendJSON] = ["server": .int(0), "pushed": .array([]), "local": .int(0)]

  private func captureArea(_ id: String, row: AreaEntity?, store: TaskSyncStore, lookup: (String) -> TaskSyncShadow?) {
    captureSimple(.area, id, plan: row.map { TaskBackendMapping.area($0) }, store: store, lookup: lookup)
  }

  private func captureProject(_ id: String, row: ProjectEntity?, store: TaskSyncStore, lookup: (String) -> TaskSyncShadow?) {
    captureSimple(.project, id, plan: row.map { TaskBackendMapping.project($0) }, store: store, lookup: lookup)
  }

  private func captureAttachment(_ id: String, row: TaskAttachmentEntity?, store: TaskSyncStore,
                                 lookup: (String) -> TaskSyncShadow?) {
    let plan = row.map { a in TaskBackendMapping.attachment(a).map(\.row) }
    captureSimple(.attachment, id, plan: plan, store: store, lookup: lookup)
  }

  private func captureChecklistItem(_ id: String, row: TaskChecklistItemEntity?, store: TaskSyncStore,
                                    lookup: (String) -> TaskSyncShadow?) {
    captureSimple(.checklistItem, id, plan: row.map { TaskBackendMapping.checklistItem($0) },
                  store: store, lookup: lookup)
  }

  private func captureTaskRef(_ id: String, row: TaskRefEntity?, store: TaskSyncStore,
                              lookup: (String) -> TaskSyncShadow?) {
    // Refused this launch: keep the row, except where it takes back a delete.
    if taskRefsRefused, row != nil, lookup("taskRef:\(id)")?.gone != true { return }
    captureSimple(.taskRef, id, plan: row.map { TaskBackendMapping.taskRef($0) },
                  store: store, lookup: lookup)
  }

  private func captureDoSession(_ id: String, row: DoSessionEntity?, store: TaskSyncStore,
                                lookup: (String) -> TaskSyncShadow?) {
    captureSimple(.doSession, id, plan: row.map { TaskBackendMapping.doSession($0) },
                  store: store, lookup: lookup)
  }

  private func captureTag(_ id: String, row: TagEntity?, store: TaskSyncStore,
                          lookup: (String) -> TaskSyncShadow?) {
    captureSimple(.tag, id, plan: row.map { TaskBackendMapping.tag($0) },
                  store: store, lookup: lookup)
  }

  /// Every entity but tasks: no soft delete; a missing row is a delete.
  ///
  /// The delete is HELD for `deleteGrace`, like a task's: ⌘Z on the delete
  /// re-creates the row under the same id (`ProjectsMutator.revive`,
  /// `AreasMutator.revive`, the `restore…` mutators), and the backend never
  /// revives a deleted row, so the delete must still be in the outbox for
  /// undo to cancel it.
  private func captureSimple(_ entity: BackendEntity, _ id: String,
                             plan: Result<BackendRowPlan, TaskBackendIssue>?,
                             store: TaskSyncStore, lookup: (String) -> TaskSyncShadow?) {
    let key = "\(entity.rawValue):\(id)"
    let shadow = lookup(key)
    guard let plan else {
      if let shadow, !shadow.gone {
        queueDeleteIfNeeded(entity, id, hold: true, store: store)
        shadow.gone = true
        store.saveSoon()
      }
      return
    }
    let mapped: [String: BackendJSON]
    switch plan {
    case .success(let p): mapped = p.fields
    case .failure(let issue): noteBlocked(issue); return
    }
    clearBlocked(entity, id)
    let old = shadow.map { TaskSyncJSON.decode($0.fields) } ?? [:]

    // Re-created inside the grace period (undo): the backend never saw the
    // delete. Drop it and send only what differs from the last synced row.
    if let shadow, shadow.gone,
       let last = store.lastRowOp(entity: entity.rawValue, rowID: id),
       last.kind == TaskSyncOpKind.delete, !last.sent {
      store.remove(last)
      shadow.gone = false
      store.saveSoon()
      // A sync while the row was away drops its waiting upload. A file the
      // plan refused stays local.
      if entity == .attachment, old["_uploaded"] != .bool(true), old["_localOnly"] != .bool(true),
         let a = fetchAttachment(id), a.localFilename != nil,
         !store.ops(entity: entity.rawValue, rowID: id).contains(where: { $0.kind == TaskSyncOpKind.upload }) {
        store.append(kind: TaskSyncOpKind.upload, entity: entity.rawValue, rowID: id, payload: [:])
      }
    }

    if shadow == nil || shadow?.gone == true {
      // New here, or deleted on the backend (the upsert is then dropped and
      // reported).
      enqueueUpsert(entity, id, mapped, store: store)
      if entity == .attachment, shadow == nil {
        store.append(kind: TaskSyncOpKind.upload, entity: entity.rawValue, rowID: id, payload: [:])
      }
      writeShadow(shadow, key, old: old, new: mapped, store: store)
      return
    }
    var patch: [String: BackendJSON] = [:]
    for (k, v) in mapped where (old[k] ?? .null).canonical != v.canonical { patch[k] = v }
    if entity == .attachment {
      // Only the display fields may change after insert (columns.ts).
      let locked = patch.keys.filter { $0 != "filename" && $0 != "position" }
      if !locked.isEmpty {
        SeptenaLog.info("[TaskSync] attachment \(id) changed locked fields \(locked.sorted()); not sent")
      }
      patch = patch.filter { $0.key == "filename" || $0.key == "position" }
    }
    if entity == .taskRef {
      // Task and key are fixed at insert (registry/entities.json, `updatable`).
      patch = patch.filter { $0.key == "role" || $0.key == "snapshot" || $0.key == "position" }
    }
    if entity == .doSession {
      patch = patch.filter { !["taskId", "startedAt", "sourceClient"].contains($0.key) }
    }
    if !patch.isEmpty { enqueueUpsert(entity, id, patch, store: store) }
    var nextShadow = mapped
    if entity == .attachment {
      // Preserve local-only / server-upload state stored alongside the shadow.
      for metaKey in ["_localOnly", "_localOnlyReason", "_uploaded"] {
        if let v = old[metaKey] { nextShadow[metaKey] = v }
      }
    }
    writeShadow(shadow, key, old: old, new: nextShadow, store: store)
  }

  // MARK: Queue helpers

  /// Merges into the row's newest upsert when that one was never sent;
  /// otherwise appends a new op. A sealed (sent) op is never changed.
  private func enqueueUpsert(_ entity: BackendEntity, _ id: String, _ fields: [String: BackendJSON],
                             store: TaskSyncStore) {
    if let last = store.lastRowOp(entity: entity.rawValue, rowID: id),
       last.kind == TaskSyncOpKind.upsert, !last.sent {
      var merged = TaskSyncJSON.decode(last.payload)
      for (k, v) in fields { merged[k] = v }
      last.payload = TaskSyncJSON.encode(merged)
      store.saveSoon()
    } else {
      store.append(kind: TaskSyncOpKind.upsert, entity: entity.rawValue, rowID: id, payload: fields)
    }
  }

  private func queueDeleteIfNeeded(_ entity: BackendEntity, _ id: String, hold: Bool = false,
                                   store: TaskSyncStore) {
    // Already queued (a soft delete still in its grace period): nothing to add.
    if store.lastRowOp(entity: entity.rawValue, rowID: id)?.kind == TaskSyncOpKind.delete { return }
    store.append(kind: TaskSyncOpKind.delete, entity: entity.rawValue, rowID: id, payload: [:],
                 notBefore: hold ? Date().addingTimeInterval(Self.deleteGrace) : .distantPast)
  }

  func writeShadow(_ shadow: TaskSyncShadow?, _ key: String, old: [String: BackendJSON],
                   new: [String: BackendJSON], gone: Bool? = nil, store: TaskSyncStore) {
    if let shadow {
      let changed = BackendJSON.object(old).canonical != BackendJSON.object(new).canonical
      if changed { shadow.fields = TaskSyncJSON.encode(new) }
      if let gone, shadow.gone != gone { shadow.gone = gone }
      if changed || gone != nil { store.saveSoon() }
    } else {
      store.upsertShadow(key, fields: new, gone: gone)
    }
  }

  // MARK: Issues

  func addIssue(_ entity: BackendEntity, _ id: String, _ reason: String) {
    let issue = TaskBackendIssue(entity: entity, id: id, reason: reason)
    SeptenaLog.error("[TaskSync] \(entity.rawValue) \(id): \(reason)")
    issues.removeAll { $0.entity == entity && $0.id == id && $0.reason == reason }
    issues.append(issue)
    if issues.count > Self.issueCap { issues.removeFirst(issues.count - Self.issueCap) }
  }

  private func noteBlocked(_ issue: TaskBackendIssue) {
    guard !issues.contains(where: { $0.key == issue.key }) else { return }
    addIssue(issue.entity, issue.id, "not sent: " + issue.reason)
  }

  private func clearBlocked(_ entity: BackendEntity, _ id: String) {
    issues.removeAll { $0.entity == entity && $0.id == id && $0.reason.hasPrefix("not sent: ") }
  }

  func clearIssues() { issues = [] }

  // MARK: Local lookups

  func fetchTask(_ id: String) -> TaskEntity? {
    var d = FetchDescriptor<TaskEntity>(predicate: #Predicate { $0.id == id })
    d.fetchLimit = 1
    return try? main.fetch(d).first
  }

  func fetchArea(_ id: String) -> AreaEntity? {
    var d = FetchDescriptor<AreaEntity>(predicate: #Predicate { $0.id == id })
    d.fetchLimit = 1
    return try? main.fetch(d).first
  }

  func fetchProject(_ id: String) -> ProjectEntity? {
    var d = FetchDescriptor<ProjectEntity>(predicate: #Predicate { $0.id == id })
    d.fetchLimit = 1
    return try? main.fetch(d).first
  }

  func fetchAttachment(_ id: String) -> TaskAttachmentEntity? {
    var d = FetchDescriptor<TaskAttachmentEntity>(predicate: #Predicate { $0.id == id })
    d.fetchLimit = 1
    return try? main.fetch(d).first
  }

  func fetchChecklistItem(_ id: String) -> TaskChecklistItemEntity? {
    var d = FetchDescriptor<TaskChecklistItemEntity>(predicate: #Predicate { $0.id == id })
    d.fetchLimit = 1
    return try? main.fetch(d).first
  }

  func fetchDoSession(_ id: String) -> DoSessionEntity? {
    var d = FetchDescriptor<DoSessionEntity>(predicate: #Predicate { $0.id == id })
    d.fetchLimit = 1
    return try? main.fetch(d).first
  }

  func fetchTaskRef(_ id: String) -> TaskRefEntity? {
    var d = FetchDescriptor<TaskRefEntity>(predicate: #Predicate { $0.id == id })
    d.fetchLimit = 1
    return try? main.fetch(d).first
  }

  func fetchTag(_ id: String) -> TagEntity? {
    var d = FetchDescriptor<TagEntity>(predicate: #Predicate { $0.id == id })
    d.fetchLimit = 1
    return try? main.fetch(d).first
  }

  static func int(_ v: BackendJSON?) -> Int? {
    switch v {
    case .int(let i): return Int(i)
    case .double(let d) where d.isFinite: return Int(d)
    default: return nil
    }
  }

  // MARK: - Sync loop

  func scheduleSync(after delay: TimeInterval) {
    guard isRunning else { return }
    let deadline = Date().addingTimeInterval(max(0, delay))
    // A later request never displaces a sooner one: the held-ops timer
    // (`scheduleHeldOps`, up to `deleteGrace` away) used to replace a pending
    // 0.3 s nudge pull and push that pull back by minutes.
    if syncTimer != nil, let pending = syncTimerDeadline, pending <= deadline { return }
    syncTimer?.cancel()
    syncTimerDeadline = deadline
    syncTimer = Task { @MainActor [weak self] in
      if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
      guard !Task.isCancelled, let self else { return }
      // Past the delay, the run is no longer cancellable by a reschedule. A
      // nudge or a local edit used to cancel a pull mid-request: the
      // cancelled run swallowed its `CancellationError` and dropped the
      // `syncAgain` the newer request had set, so that change waited for the
      // next nudge or the next app activation. Now a newer request during a
      // run sets `syncAgain`, and this run goes round once more.
      self.syncTimer = nil
      self.syncTimerDeadline = nil
      await self.runSync(reconcileFirst: false)
    }
  }

  /// Push, then pull. One run at a time; a request during a run makes the
  /// run go round once more.
  func runSync(reconcileFirst: Bool) async {
    guard isRunning, let store = store() else { return }
    if isSyncing { syncAgain = true; return }
    isSyncing = true
    defer { isSyncing = false; refreshPendingCount() }
    signedIn = TaskBackendClient.hasSession
    guard signedIn else {
      // Signed out is a first-class free mode, not an error.
      lastError = nil
      return
    }
    // Reconcile needs the shadow: on a first run (since == 0) the pull fills
    // it first, and the reconcile follows.
    if reconcileFirst, since > 0, Date().timeIntervalSince(lastReconcile) > 60 {
      reconcile(store: store)
    }
    repeat {
      syncAgain = false
      do {
        try await pushPending(store: store)
        if needsRepairPull {
          // A rejected op: read the backend's whole state again, so rows this
          // device changed are put back to what the backend holds.
          needsRepairPull = false
          since = 0
        }
        if firstPullTraced {
          try await pull(store: store)
        } else {
          firstPullTraced = true
          try await LaunchTrace.span("sync.firstPull") { try await pull(store: store) }
        }
        if !settingsReady { settingsReady = true }
        if !taskRefsReady { taskRefsReady = true }
        if !doSessionsReady { doSessionsReady = true }
        if reconcileSettings(store: store) { syncAgain = true }
        if reconcileFirst, Date().timeIntervalSince(lastReconcile) > 60 {
          reconcile(store: store)
          if store.opCount() > 0 { syncAgain = true }
        }
        lastError = nil
        retryDelay = 0
      } catch {
        handleSyncError(error)
        return
      }
    } while syncAgain && isRunning
    scheduleHeldOps(store: store)
    // Every delete the backend had is local now: move tasks still pointing at
    // a deleted area / project to Recently Deleted (the receiver half of the
    // delete cascade; `AreasMutator.sweepDeletedContainerOrphans`).
    await SeptenaServices.shared.areasMutator.sweepDeletedContainerOrphans()
  }

  private func handleSyncError(_ error: Error) {
    if error is CancellationError || (error as? URLError)?.code == .cancelled {
      // A request asked for a run while this one was in flight: honor it.
      if syncAgain { scheduleSync(after: 0) }
      return
    }
    if let e = error as? TaskBackendError, case .limitReached(let limit) = e {
      // HTTP 402 plan limits are expected free-tier boundaries (spec §6.3, §7),
      // never a broken/red sync error state.
      lastError = nil
      retryDelay = 0
      switch limit.kind {
      case .deviceNotSyncing:
        deviceNotSyncing = true
        disconnectSocket()
        SeptenaLog.info("[TaskSync] device not syncing (402 \(limit.error)); keeping \(pendingOps) ops local")
      case .liveSyncNotInPlan:
        liveSyncBlocked = true
        disconnectSocket()
        SeptenaLog.info("[TaskSync] live sync not in plan (402 \(limit.error)); using 2-minute poll")
      case .attachmentsNotInPlan, .attachmentQuota, .historyEdge,
           .connectorCap, .shareCreate, .other:
        SeptenaLog.info("[TaskSync] plan limit reached (402 \(limit.error))")
      }
      PlanStatus.shared.noteLimitReached(limit)
      return
    }
    if let e = error as? TaskBackendError, e == .notSignedIn {
      signedIn = false
      lastError = e.errorDescription
      disconnectSocket()
      SeptenaLog.error("[TaskSync] signed out; \(pendingOps) ops kept in the outbox")
      return
    }
    lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    retryDelay = min(300, max(2, retryDelay * 2))
    SeptenaLog.error("[TaskSync] sync failed, retry in \(Int(retryDelay))s: \(lastError ?? "")")
    scheduleSync(after: retryDelay)
  }

  /// A rejected row op asks for a repair pull (the backend's state is read
  /// again). A rejected setting does not: it stops settings for this launch
  /// instead (`settingsRefused`), because the likely cause is a server that
  /// predates settings, and a repair pull would then repeat on every sync.
  /// Its shadow goes, so the next launch sends the value again.
  private func noteRejected(_ entity: BackendEntity, id: String, store: TaskSyncStore) {
    if entity == .setting {
      settingsRefused = true
      store.removeShadow("setting:\(id)")
    } else {
      needsRepairPull = true
    }
  }

  /// Keeps the rows of a refused reference write. The shadow forgets what the
  /// op carried, so the next launch finds the difference and sends it again.
  private func noteTaskRefsUnsupported(id: String, fields: [String: BackendJSON], store: TaskSyncStore) {
    if !taskRefsRefused {
      SeptenaLog.info("[TaskSync] the backend does not take references yet; they stay on this device")
    }
    taskRefsRefused = true
    let key = "taskRef:\(id)"
    guard let shadow = store.shadow(key) else { return }
    if fields["key"] != nil {
      store.removeShadow(key)   // an insert: the backend never had the row
    } else {
      let old = TaskSyncJSON.decode(shadow.fields)
      writeShadow(shadow, key, old: old, new: old.filter { fields[$0.key] == nil }, store: store)
    }
  }

  /// Wakes the loop when a held op (a soft delete in its grace period, an
  /// upload retry) becomes due.
  private func scheduleHeldOps(store: TaskSyncStore) {
    let now = Date()
    guard let next = store.allOps().map(\.notBefore).filter({ $0 > now }).min() else { return }
    scheduleSync(after: next.timeIntervalSince(now) + 0.5)
  }

  // MARK: - Push

  private func family(_ op: TaskSyncOp) -> String {
    switch op.opEntity {
    case BackendEntity.task.rawValue, BackendEntity.convo.rawValue, BackendEntity.turn.rawValue:
      return "t:" + op.rowID
    default:
      return op.opEntity + ":" + op.rowID
    }
  }

  private func wireOp(_ op: TaskSyncOp) -> BackendOp {
    let entity = BackendEntity(rawValue: op.opEntity) ?? .task
    var body: [String: BackendJSON] = ["clientOpId": .string(op.clientOpId), "op": .string(op.kind)]
    switch op.kind {
    case TaskSyncOpKind.appendTurn:
      body["taskId"] = .string(op.rowID)
      body["turn"] = .object(TaskSyncJSON.decode(op.payload))
    case TaskSyncOpKind.delete:
      body["entity"] = .string(op.opEntity)
      body["id"] = .string(op.rowID)
    default:
      body["entity"] = .string(op.opEntity)
      body["id"] = .string(op.rowID)
      body["fields"] = .object(TaskSyncJSON.decode(op.payload))
    }
    return BackendOp(clientOpId: op.clientOpId, body: .object(body), entity: entity, id: op.rowID)
  }

  /// Sends the outbox in order. An op that is held, or that follows a held
  /// op of the same row, waits. Uploads go last, each once its row is on the
  /// backend.
  private func pushPending(store: TaskSyncStore) async throws {
    var rounds = 0
    while isRunning {
      rounds += 1
      let now = Date()
      var blocked = Set<String>()
      var batch: [TaskSyncOp] = []
      for op in store.allOps() where op.kind != TaskSyncOpKind.upload {
        let fam = family(op)
        if blocked.contains(fam) { continue }
        if op.notBefore > now { blocked.insert(fam); continue }
        batch.append(op)
        if batch.count >= Self.batchLimit { break }
      }
      if batch.isEmpty || rounds > 1_000 { break }
      for op in batch { op.sent = true; op.attempts += 1 }
      store.saveNow()

      let outcome: TaskBackendClient.PushOutcome
      do {
        outcome = try await client.push(batch.map(wireOp))
      } catch TaskBackendError.limitReached(let limit) {
        // Refused before the server applied any op (e.g. 402 device_not_syncing):
        // unseal the batch so further local edits coalesce cleanly while paused.
        for op in batch { op.sent = false }
        store.saveNow()
        throw TaskBackendError.limitReached(limit)
      }
      switch outcome {
      case .ok(let response):
        // The core checks the answer covers the batch one for one, in
        // order; zip would pair results with the wrong ops otherwise.
        if let problem = TaskSyncDecisions.pushResponseProblem(
          sentIDs: batch.map(\.clientOpId), resultIDs: response.results.map(\.clientOpId)) {
          for op in batch { op.sent = false }
          store.saveNow()
          throw TaskBackendError.badResponse(problem)
        }
        handleResults(Array(zip(batch, response.results)), store: store)
      case .refused(let body):
        try await handleRefused(batch, body: body, store: store)
      }
      store.saveNow()
      refreshPendingCount()
    }
    try await uploadPending(store: store)
  }

  private func handleResults(_ pairs: [(TaskSyncOp, BackendOpResult)], store: TaskSyncStore) {
    var dropped: [(BackendEntity, String)] = []
    for (op, result) in pairs {
      // The push awaited the network; an op removed meanwhile (a reset)
      // must not be read again.
      guard !op.isDeleted, op.modelContext != nil else { continue }
      let entity = BackendEntity(rawValue: op.opEntity) ?? .task
      switch result.status {
      case .applied, .noop:
        if op.kind == TaskSyncOpKind.appendTurn, let seq = result.seq {
          notePushedTurn(taskID: op.rowID, seq: seq, store: store)
        }
        store.remove(op)
      case .dropped:
        store.remove(op)
        dropped.append((entity, op.rowID))
      case .rejected:
        if entity == .taskRef, op.kind == TaskSyncOpKind.upsert, let reason = result.reason {
          if reason.hasPrefix("not_supported") {
            let fields = TaskSyncJSON.decode(op.payload)
            store.remove(op)
            noteTaskRefsUnsupported(id: op.rowID, fields: fields, store: store)
            continue
          }
          if reason == "duplicate_ref" {
            // The task has the key under another id, which the pull brings.
            // This row never was on the backend, so it leaves no tombstone.
            if let row = fetchTaskRef(op.rowID) { main.delete(row) }
            _ = StoreHealth.save(main, op: "taskSync.duplicateRef")
            for queued in store.ops(entity: op.opEntity, rowID: op.rowID) { store.remove(queued) }
            store.removeShadow("taskRef:\(op.rowID)")
            NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
            continue
          }
        }
        store.remove(op)
        addIssue(entity, op.rowID, "rejected by the backend: \(result.reason ?? "no reason")")
        if entity == .attachment, op.kind == TaskSyncOpKind.upsert {
          for upload in store.ops(entity: op.opEntity, rowID: op.rowID) where upload.kind == TaskSyncOpKind.upload {
            store.remove(upload)
          }
        }
        noteRejected(entity, id: op.rowID, store: store)
      }
    }
    for (entity, id) in dropped { handleDropped(entity, id, store: store) }
  }

  /// The Worker refused the whole batch (HTTP 400). Its issues name the bad
  /// ops (`ops.<index>…`); those are rejected and the rest go again. When it
  /// names none, the ops go one by one so only the bad one is lost.
  private func handleRefused(_ batch: [TaskSyncOp], body: BackendErrorBody?, store: TaskSyncStore) async throws {
    let message = body?.issues?.first?.message ?? body?.error ?? "refused"
    let bad = Set((body?.issues ?? []).compactMap { issue -> Int? in
      guard let path = issue.path, path.count >= 2, path[0] == .string("ops") else { return nil }
      if case .int(let i) = path[1], i >= 0, Int(i) < batch.count { return Int(i) }
      return nil
    })
    func reject(_ op: TaskSyncOp, _ why: String) {
      let entity = BackendEntity(rawValue: op.opEntity) ?? .task
      let fields = TaskSyncJSON.decode(op.payload)
      store.remove(op)
      if entity == .taskRef {
        // A server that predates the entity refuses the op's shape. The answer
        // does not tell that from a bad field, and the row stays either way.
        noteTaskRefsUnsupported(id: op.rowID, fields: fields, store: store)
        return
      }
      addIssue(entity, op.rowID, "refused by the backend: \(why)")
      noteRejected(entity, id: op.rowID, store: store)
    }
    if !bad.isEmpty {
      for i in bad.sorted() { reject(batch[i], message) }
      return  // the rest stay queued and go in the next round
    }
    if batch.count == 1 { reject(batch[0], message); return }
    for op in batch {
      switch try await client.push([wireOp(op)]) {
      case .ok(let response): handleResults(Array(zip([op], response.results)), store: store)
      case .refused(let one): reject(op, one?.issues?.first?.message ?? one?.error ?? "refused")
      }
    }
  }

  private func uploadPending(store: TaskSyncStore) async throws {
    let all = store.allOps()
    let now = Date()
    for op in all where op.kind == TaskSyncOpKind.upload && op.notBefore <= now {
      guard isRunning else { return }
      // The metadata row must be on the backend first (§4).
      let waiting = all.contains {
        $0.seq < op.seq && $0.opEntity == op.opEntity && $0.rowID == op.rowID && $0.kind != TaskSyncOpKind.upload
      }
      if waiting { continue }
      guard let att = fetchAttachment(op.rowID) else { store.remove(op); continue }
      guard let url = TaskAttachmentFiles.url(for: att), FileManager.default.fileExists(atPath: url.path) else {
        addIssue(.attachment, op.rowID, "file is not on this device; bytes not uploaded")
        store.remove(op)
        continue
      }
      let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
      guard size == att.byteCount else {
        addIssue(.attachment, op.rowID, "file is \(size ?? -1) bytes, the row says \(att.byteCount); bytes not uploaded")
        store.remove(op)
        continue
      }
      if PlanStatus.shared.enforced, !PlanStatus.shared.attachmentsAllowed {
        // The server already reported 0 GB attachment allowance for this plan:
        // keep the file on this device and mark it local without uploading bytes.
        store.remove(op)
        markAttachmentLocalOnly(id: op.rowID, reason: "attachments_not_in_plan",
                                taskID: att.taskID, store: store)
        store.saveNow()
        continue
      }
      op.sent = true
      op.attempts += 1
      do {
        try await client.uploadAttachment(id: op.rowID, fileURL: url, contentType: att.contentType)
        store.remove(op)
        recordAttachmentUploadState(id: op.rowID, uploaded: true, hasLocalFile: true, store: store)
      } catch TaskBackendError.limitReached(let limit) {
        if limit.isAttachmentLimit {
          // 402 attachments_not_in_plan / attachment_quota (spec §6.3, §7):
          // keep the file on disk, mark it local so it is never retried
          // endlessly or lost, and surface the file upsell without a sync error.
          store.remove(op)
          markAttachmentLocalOnly(id: op.rowID, reason: limit.error,
                                  taskID: att.taskID, store: store)
          PlanStatus.shared.noteLimitReached(limit)
          SeptenaLog.info("[TaskSync] attachment \(op.rowID) kept local (402 \(limit.error))")
        } else {
          // e.g. 402 device_not_syncing: keep the upload queued for when this
          // device syncs again, and let `handleSyncError` pause cleanly.
          op.sent = false
          store.saveNow()
          throw TaskBackendError.limitReached(limit)
        }
      } catch TaskBackendError.http(let status, let code) {
        if status == 404, op.attempts < 6 {
          op.notBefore = Date().addingTimeInterval(TimeInterval(30 * op.attempts))
        } else {
          addIssue(.attachment, op.rowID, "upload refused (\(status) \(code))")
          store.remove(op)
        }
      }
      store.saveNow()
    }
  }

  // MARK: - Attachment local-only / elsewhere tracking (spec §6.3, §7)

  /// True when an attachment's bytes were kept on this device after a 402
  /// `attachments_not_in_plan` or `attachment_quota` response.
  func isAttachmentLocalOnly(_ id: String) -> Bool {
    localOnlyAttachmentIDs.contains(id)
  }

  /// True when this device has only the attachment's metadata row (no file on
  /// disk) and the server row reported no uploaded bytes (`uploadedAt == nil`).
  func isAttachmentElsewhere(_ entity: TaskAttachmentEntity) -> Bool {
    if let url = TaskAttachmentFiles.url(for: entity),
       FileManager.default.fileExists(atPath: url.path) {
      return false
    }
    return elsewhereAttachmentIDs.contains(entity.id)
  }

  func clearAttachmentLimitState(id: String) {
    localOnlyAttachmentIDs.remove(id)
    localOnlyAttachmentReasons.removeValue(forKey: id)
    elsewhereAttachmentIDs.remove(id)
  }

  func recordAttachmentUploadState(id: String, uploaded: Bool, hasLocalFile: Bool, store: TaskSyncStore) {
    let key = "attachment:\(id)"
    let shadow = store.shadow(key)
    let old = shadow.map { TaskSyncJSON.decode($0.fields) } ?? [:]
    var new = old
    new["_uploaded"] = .bool(uploaded)
    if uploaded {
      new.removeValue(forKey: "_localOnly")
      new.removeValue(forKey: "_localOnlyReason")
      localOnlyAttachmentIDs.remove(id)
      localOnlyAttachmentReasons.removeValue(forKey: id)
      elsewhereAttachmentIDs.remove(id)
    } else if !hasLocalFile {
      elsewhereAttachmentIDs.insert(id)
    } else {
      elsewhereAttachmentIDs.remove(id)
    }
    writeShadow(shadow, key, old: old, new: new, store: store)
  }

  private func markAttachmentLocalOnly(id: String, reason: String, taskID: String?, store: TaskSyncStore) {
    let key = "attachment:\(id)"
    let shadow = store.shadow(key)
    let old = shadow.map { TaskSyncJSON.decode($0.fields) } ?? [:]
    var new = old
    new["_localOnly"] = .bool(true)
    new["_localOnlyReason"] = .string(reason)
    new["_uploaded"] = .bool(false)
    writeShadow(shadow, key, old: old, new: new, store: store)
    localOnlyAttachmentIDs.insert(id)
    localOnlyAttachmentReasons[id] = reason
    elsewhereAttachmentIDs.remove(id)
    if let taskID { TaskChange.post(taskID) }
  }

  private func hydrateAttachmentLimitState(store: TaskSyncStore) {
    var localOnly = Set<String>()
    var reasons: [String: String] = [:]
    var elsewhere = Set<String>()
    for (key, shadow) in store.allShadows() where key.hasPrefix("attachment:") && !shadow.gone {
      let id = String(key.dropFirst("attachment:".count))
      let fields = TaskSyncJSON.decode(shadow.fields)
      if fields["_localOnly"] == .bool(true) {
        localOnly.insert(id)
        if let reason = fields["_localOnlyReason"]?.stringValue {
          reasons[id] = reason
        }
      } else if fields["_uploaded"] == .bool(false) {
        if let att = fetchAttachment(id),
           let url = TaskAttachmentFiles.url(for: att),
           FileManager.default.fileExists(atPath: url.path) {
          continue
        }
        elsewhere.insert(id)
      }
    }
    localOnlyAttachmentIDs = localOnly
    localOnlyAttachmentReasons = reasons
    elsewhereAttachmentIDs = elsewhere
  }

  /// When the user upgrades to a plan that allows server attachments, re-queue
  /// files that were previously held local under `attachments_not_in_plan`.
  private func requeuePlanBlockedAttachmentsIfNeeded() {
    guard let store = store() else { return }
    let candidates = localOnlyAttachmentIDs.filter {
      let reason = localOnlyAttachmentReasons[$0]
      return reason == nil || reason == "attachments_not_in_plan"
    }
    guard !candidates.isEmpty else { return }
    var queuedAny = false
    for id in candidates {
      guard let att = fetchAttachment(id),
            let url = TaskAttachmentFiles.url(for: att),
            FileManager.default.fileExists(atPath: url.path) else {
        localOnlyAttachmentIDs.remove(id)
        localOnlyAttachmentReasons.removeValue(forKey: id)
        continue
      }
      let key = "attachment:\(id)"
      let shadow = store.shadow(key)
      let old = shadow.map { TaskSyncJSON.decode($0.fields) } ?? [:]
      var new = old
      new.removeValue(forKey: "_localOnly")
      new.removeValue(forKey: "_localOnlyReason")
      writeShadow(shadow, key, old: old, new: new, store: store)
      localOnlyAttachmentIDs.remove(id)
      localOnlyAttachmentReasons.removeValue(forKey: id)
      let alreadyQueued = store.ops(entity: BackendEntity.attachment.rawValue, rowID: id)
        .contains { $0.kind == TaskSyncOpKind.upload }
      if !alreadyQueued {
        store.append(kind: TaskSyncOpKind.upload, entity: BackendEntity.attachment.rawValue,
                     rowID: id, payload: [:])
        queuedAny = true
      }
      TaskChange.post(att.taskID)
    }
    if queuedAny {
      store.saveNow()
      refreshPendingCount()
      if isRunning, signedIn, !deviceNotSyncing { scheduleSync(after: 0.5) }
    }
  }

  /// Records the server seq of a turn this device appended, so the next pull
  /// can tell it from a turn another client appended at the same time.
  private func notePushedTurn(taskID: String, seq: Int, store: TaskSyncStore) {
    let key = "turns:\(taskID)"
    let shadow = store.shadow(key)
    let old = shadow.map { TaskSyncJSON.decode($0.fields) } ?? Self.emptyTurnsShadow
    var new = old
    var pushed: [BackendJSON] = []
    if case .array(let list) = old["pushed"] ?? .array([]) { pushed = list }
    if (Self.int(old["server"]) ?? 0) < seq { pushed.append(.int(Int64(seq))) }
    new["pushed"] = .array(pushed)
    writeShadow(shadow, key, old: old, new: new, store: store)
  }

  // MARK: - Live nudge (WebSocket, §6.3)

  func connectSocket() {
    guard TaskSyncPollPolicy.shouldConnectSocket(
      isRunning: isRunning, appActive: appActive, signedIn: signedIn,
      deviceNotSyncing: deviceNotSyncing, liveSyncBlocked: liveSyncBlocked
    ), socket == nil else { return }
    socketGeneration += 1
    let generation = socketGeneration
    Task { @MainActor in
      do {
        let request = try await self.client.webSocketRequest()
        guard generation == self.socketGeneration,
              TaskSyncPollPolicy.shouldConnectSocket(
                isRunning: self.isRunning, appActive: self.appActive, signedIn: self.signedIn,
                deviceNotSyncing: self.deviceNotSyncing, liveSyncBlocked: self.liveSyncBlocked
              ),
              self.socket == nil else { return }
        let task = self.socketSession.webSocketTask(with: request)
        self.socket = task
        task.resume()
        self.receive(task, generation: generation)
        self.keepAlive(task, generation: generation)
      } catch {
        self.socketFailed(generation: generation, error: error, httpStatus: nil)
      }
    }
  }

  func disconnectSocket() {
    socketGeneration += 1
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    wsConnected = false
  }

  private func receive(_ task: URLSessionWebSocketTask, generation: Int) {
    Task { @MainActor in
      while generation == self.socketGeneration {
        do {
          let message = try await task.receive()
          guard generation == self.socketGeneration else { return }
          self.wsConnected = true
          self.socketRetry = 1
          let text: String?
          switch message {
          case .string(let s): text = s
          case .data(let d): text = String(data: d, encoding: .utf8)
          @unknown default: text = nil
          }
          guard let text, text != "pong", let data = text.data(using: .utf8),
                let nudge = try? JSONDecoder().decode(RevNudge.self, from: data) else { continue }
          if nudge.rev > self.since { self.scheduleSync(after: 0.3) }
        } catch {
          let status = (task.response as? HTTPURLResponse)?.statusCode
          self.socketFailed(generation: generation, error: error, httpStatus: status)
          return
        }
      }
    }
  }

  private struct RevNudge: Decodable { let rev: Int }

  private func keepAlive(_ task: URLSessionWebSocketTask, generation: Int) {
    Task { @MainActor in
      while generation == self.socketGeneration {
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        guard generation == self.socketGeneration else { return }
        do { try await task.send(.string("ping")) } catch {
          let status = (task.response as? HTTPURLResponse)?.statusCode
          self.socketFailed(generation: generation, error: error, httpStatus: status)
          return
        }
      }
    }
  }

  private func socketFailed(generation: Int, error: Error, httpStatus: Int?) {
    guard generation == socketGeneration else { return }
    let status = httpStatus ?? (socket?.response as? HTTPURLResponse)?.statusCode
    socket?.cancel(with: .abnormalClosure, reason: nil)
    socket = nil
    wsConnected = false
    if status == 402 {
      // HTTP 402 on `/v1/sync/ws` (`live_sync_not_in_plan` or
      // `device_not_syncing`, spec §6.3, §6.4 finding 8): stop reconnecting
      // the socket and fall back to polling `/v1/sync/pull` every 2 minutes.
      liveSyncBlocked = true
      socketRetry = 1
      SeptenaLog.info("[TaskSync] live socket returned HTTP 402; falling back to 2-minute poll")
      refreshPlanAfterSocketRefusal()
      return
    }
    if let e = error as? TaskBackendError, case .limitReached(let limit) = e {
      switch limit.kind {
      case .deviceNotSyncing: deviceNotSyncing = true
      case .liveSyncNotInPlan: liveSyncBlocked = true
      default: break
      }
      socketRetry = 1
      PlanStatus.shared.noteLimitReached(limit)
      return
    }
    if let e = error as? TaskBackendError, e == .notSignedIn {
      signedIn = false
      return
    }
    if (error as? URLError)?.code == .badServerResponse, !PlanStatus.shared.isPlus {
      // Safety net when the handshake failed with a non-101 HTTP response and
      // URLSession did not populate `task.response`: refresh plan limits so
      // `liveSync: false` stops further reconnect attempts.
      refreshPlanAfterSocketRefusal()
    }
    guard TaskSyncPollPolicy.shouldConnectSocket(
      isRunning: isRunning, appActive: appActive, signedIn: signedIn,
      deviceNotSyncing: deviceNotSyncing, liveSyncBlocked: liveSyncBlocked
    ) else { return }
    let delay = socketRetry
    socketRetry = min(60, socketRetry * 2)
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard generation == self.socketGeneration else { return }
      self.connectSocket()
    }
  }

  private func refreshPlanAfterSocketRefusal() {
    let now = Date()
    guard now.timeIntervalSince(lastSocketPlanRefresh) > 15 else { return }
    lastSocketPlanRefresh = now
    Task { @MainActor in await PlanStatus.shared.refresh() }
  }

  // MARK: - Account

  /// Sign in with Apple → a backend session, then sync at once.
  ///
  /// Same backend user as the last sign-in on this device: the outbox
  /// queued while signed out drains now. A different user: the outbox,
  /// the shadows and every local task, area, project and attachment row
  /// belong to the other account, so they are wiped and the new account
  /// pulls from rev 0. The engine pauses across the sign-in, so no run
  /// pushes the old outbox with the new session before that check.
  func signIn(identityToken: String, rawNonce: String) async throws {
    try await signIn { try await $0.signIn(identityToken: identityToken, rawNonce: rawNonce) }
  }

  /// The same, with the session a signed-in device approved (ADR 0016).
  func signIn(deviceSession session: BackendSession) async throws {
    try await signIn { try await $0.adoptDeviceSession(session) }
  }

  private func signIn(_ authenticate: (TaskBackendClient) async throws -> String) async throws {
    let wasRunning = await pauseSync()
    defer { if wasRunning { start() } }
    let userID = try await authenticate(client)
    // No stored id (the first sign-in on this device, or a session from a
    // build before this check): keep the local data, as before.
    if let last = lastUserID, last != userID {
      wipeLocalTaskData()
      SeptenaLog.info("[TaskSync] signed in as another account; local task data wiped")
    }
    lastUserID = userID
    signedIn = TaskBackendClient.hasSession
    lastError = nil
    // Today's upsell notices read the plan (spec §3.2).
    Task { @MainActor in await PlanStatus.shared.refresh() }
    Self.onSignInHook?()
  }

  /// Ends the session on this device. Local tasks and the outbox stay: edits
  /// made while signed out are sent after the next sign-in, when the same
  /// account signs in again (`signIn` wipes them for another account).
  func signOut() async {
    await Self.beforeSignOutHook?()
    syncTimer?.cancel()
    syncTimer = nil
    syncTimerDeadline = nil
    pollTask?.cancel()
    pollTask = nil
    disconnectSocket()
    await client.signOut()
    signedIn = TaskBackendClient.hasSession
    lastError = nil
    deviceNotSyncing = false
    liveSyncBlocked = false
    localOnlyAttachmentIDs = []
    localOnlyAttachmentReasons = [:]
    elsewhereAttachmentIDs = []
    Task { @MainActor in await PlanStatus.shared.refresh() }
    // The launch snapshot shows this account's Today (#82).
    TodaySnapshotStore.invalidate()
    TasksWidgetSnapshotStore.invalidate()
    #if os(iOS)
    WatchBridge.shared.accountChanged()
    #endif
  }

  /// Backend user id of the last sign-in on this device.
  private var lastUserID: String? {
    get { UserDefaults.standard.string(forKey: Self.lastUserKey) }
    set {
      UserDefaults.standard.set(newValue, forKey: Self.lastUserKey)
      hadAccount = newValue != nil
    }
  }

  /// Stops the engine and waits (up to 10 s) for a run that started before
  /// the stop to finish its current request. Returns whether it was running.
  private func pauseSync() async -> Bool {
    let wasRunning = isRunning
    stop()
    var waited = 0
    while isSyncing, waited < 100 {
      try? await Task.sleep(nanoseconds: 100_000_000)
      waited += 1
    }
    return wasRunning
  }

  /// Deletes the account on the backend, then wipes this device's task data:
  /// the outbox, the shadows, and every local task, area, project and
  /// attachment row (with the attachment files). The engine stops first so
  /// that no push in flight writes rows back after the server emptied the
  /// store. On failure nothing local changes and the engine starts again.
  func deleteAccount() async throws {
    _ = await pauseSync()
    do {
      try await client.deleteAccount()
    } catch {
      start()
      throw error
    }
    wipeLocalTaskData()
    lastUserID = nil
    signedIn = TaskBackendClient.hasSession
    SeptenaLog.info("[TaskSync] account deleted; local task data wiped")
  }

  /// Object-by-object deletes through the context, never `delete(model:)`:
  /// a batch delete leaves objects the context already holds registered,
  /// and the next read of one of them traps (see `TaskSyncStore`).
  private func wipeLocalTaskData() {
    let context = main
    for a in (try? context.fetch(FetchDescriptor<TaskAttachmentEntity>())) ?? [] {
      if let url = TaskAttachmentFiles.url(for: a) { try? FileManager.default.removeItem(at: url) }
      context.delete(a)
    }
    for c in (try? context.fetch(FetchDescriptor<TaskChecklistItemEntity>())) ?? [] { context.delete(c) }
    for r in (try? context.fetch(FetchDescriptor<TaskRefEntity>())) ?? [] { context.delete(r) }
    for s in (try? context.fetch(FetchDescriptor<DoSessionEntity>())) ?? [] { context.delete(s) }
    for t in (try? context.fetch(FetchDescriptor<TaskEntity>())) ?? [] { context.delete(t) }
    for p in (try? context.fetch(FetchDescriptor<ProjectEntity>())) ?? [] { context.delete(p) }
    for a in (try? context.fetch(FetchDescriptor<AreaEntity>())) ?? [] { context.delete(a) }
    for t in (try? context.fetch(FetchDescriptor<TagEntity>())) ?? [] { context.delete(t) }
    _ = StoreHealth.save(context, op: "taskSync.wipe")
    // Account switch / delete: clear cached per-account synced settings and
    // smart-list mirrors so the previous account cannot leak into the next one.
    SeptaskSyncedSettings.clearLocal()
    SmartListPreferences.shared.clearLocalForAccountSwitch()
    // Account switch / delete: the launch snapshot holds the old rows (#82).
    TodaySnapshotStore.invalidate()
    TasksWidgetSnapshotStore.invalidate()
    #if os(iOS)
    WatchBridge.shared.accountChanged()
    #endif
    store()?.deleteEverything()
    since = 0
    settingsReady = false
    lastPull = nil
    lastError = nil
    deviceNotSyncing = false
    liveSyncBlocked = false
    localOnlyAttachmentIDs = []
    localOnlyAttachmentReasons = [:]
    elsewhereAttachmentIDs = []
    issues = []
    refreshPendingCount()
    // The undo closures point at rows that no longer exist.
    TaskUndo.removeAll()
    NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    NotificationCenter.default.post(name: .septenaStructureChanged, object: nil)
  }

  // MARK: - Settings (TaskSyncSettings.swift)

  var settingsReady: Bool {
    get { UserDefaults.standard.bool(forKey: Self.settingsReadyKey) }
    set { UserDefaults.standard.set(newValue, forKey: Self.settingsReadyKey) }
  }

  var taskRefsReady: Bool {
    get { UserDefaults.standard.bool(forKey: Self.taskRefsReadyKey) }
    set { UserDefaults.standard.set(newValue, forKey: Self.taskRefsReadyKey) }
  }

  var doSessionsReady: Bool {
    get { UserDefaults.standard.bool(forKey: Self.doSessionsReadyKey) }
    set { UserDefaults.standard.set(newValue, forKey: Self.doSessionsReadyKey) }
  }

  /// `SettingsMirror.upsert` changed a synced setting. Queues it when the
  /// first settings pull has run; before that, `reconcileSettings` after
  /// the pull picks it up (and the backend's value wins if it has one).
  func captureSettings() {
    guard !DemoSeedMode.isOn, settingsReady, let store = store() else { return }
    if reconcileSettings(store: store), isRunning, signedIn, !deviceNotSyncing { scheduleSync(after: 0.8) }
    refreshPendingCount()
  }

  /// Diffs each synced setting against its shadow and queues an upsert for
  /// what differs. A key with no shadow was never sent nor received: it is
  /// sent only when it holds a value (the seed from this device). True when
  /// something was queued.
  @discardableResult
  func reconcileSettings(store: TaskSyncStore) -> Bool {
    guard settingsReady, !settingsRefused else { return false }
    let current = SeptaskSyncedSettings.current()
    var queued = false
    for key in SeptaskSyncedSettings.keys {
      let value = SeptaskSyncedSettings.value(key, in: current)
      let shadowKey = "setting:\(key)"
      let shadow = store.shadow(shadowKey)
      let old = shadow.map { TaskSyncJSON.decode($0.fields) } ?? [:]
      if shadow == nil, value.isNull { continue }
      if shadow != nil, (old["value"] ?? .null).canonical == value.canonical { continue }
      enqueueSetting(key, value, store: store)
      writeShadow(shadow, shadowKey, old: old, new: ["value": value], store: store)
      queued = true
    }
    return queued
  }

  private func enqueueSetting(_ key: String, _ value: BackendJSON, store: TaskSyncStore) {
    if let last = store.lastRowOp(entity: BackendEntity.setting.rawValue, rowID: key),
       last.kind == TaskSyncOpKind.upsert, !last.sent {
      last.payload = TaskSyncJSON.encode(["value": value])
      store.saveSoon()
    } else {
      store.append(kind: TaskSyncOpKind.upsert, entity: BackendEntity.setting.rawValue, rowID: key,
                   payload: ["value": value])
    }
  }

}

// MARK: - Attachment bytes on demand

extension TaskAttachmentStore {
  /// The attachment's local file, downloading it from the backend first when
  /// this device has only the metadata row (backend mode pulls rows, not
  /// bytes). Nil when the file is missing and cannot be fetched.
  func localFile(for entity: TaskAttachmentEntity) async throws -> URL? {
    if let url = TaskAttachmentFiles.url(for: entity), FileManager.default.fileExists(atPath: url.path) {
      return url
    }
    guard TaskStoreMode.current == .backend, TaskBackendClient.hasSession else { return nil }
    let name = TaskAttachmentFiles.ownedFilename(id: entity.id, original: entity.filename)
    let destination = TaskAttachmentFiles.directory.appendingPathComponent(name)
    try await TaskBackendClient.shared.downloadAttachment(id: entity.id, to: destination)
    // Local cache metadata only (not a synced field), so no mutator and no
    // sync op: the backend row does not carry `localFilename`.
    entity.localFilename = name
    _ = StoreHealth.save(LocalStore.shared.container.mainContext, op: "attachment.download")
    return destination
  }
}
