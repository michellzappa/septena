import Foundation
import SwiftData

/// Process-wide accessor for the task-mutation stack.
///
/// AppIntents (Siri / Shortcuts / Spotlight "Add to Septena") can fire
/// while no SwiftUI scene is mounted — e.g. when the system cold-launches
/// the app in the background just to run `perform()`. The mutators and
/// the CloudKit engine therefore can't live on the `App` as `@State`
/// alone; they need a singleton entry point any process-local caller
/// (the scene's `.task`, an intent, the AppDelegate) can hand off to.
///
/// Lifecycle:
///   1. Singleton is created on first access (lazy, MainActor).
///   2. The first caller to `start()` wires CKEngine's SwiftData seams,
///      binds the three mutators, and starts the engine. Subsequent
///      callers await the same task — idempotent, so the SwiftUI scene
///      and an AppIntent racing each other both end up with a fully
///      bound stack and neither does the work twice.
///   3. Mutations call through `taskMutator` / `areasMutator` /
///      `projectsMutator`; these require `start()` to have completed so
///      the CloudKit backend is bound. Calls before bind throw.
///
/// AppDelegate intentionally still mirrors `ckEngine` into its own
/// `static weak var` slot — that stash is set by App.swift's `.task`
/// once the scene materializes and is read by silent-push handlers.
/// The two paths converge on the same `CKEngine` instance.
@MainActor
final class SeptenaServices {
  static let shared = SeptenaServices()

  let ckEngine: CKEngine
  let taskMutator: TaskMutator
  let taskAttachmentStore: TaskAttachmentStore
  let checklistMutator: ChecklistMutator
  let goalMutator: GoalMutator
  let coachVoiceMutator: CoachVoiceMutator
  let coachMessageMutator: CoachMessageMutator
  let gutMutator: GutMutator
  let activityMutator: ActivityMutator
  let symptomsMutator: SymptomsMutator
  let medicationsMutator: MedicationsMutator
  let moodMutator: MoodMutator
  let intakeMutator: IntakeMutator
  let groceryMutator: GroceryMutator
  let trainingMutator: TrainingMutator
  let nutritionMutator: NutritionMutator
  let areasMutator: AreasMutator
  let projectsMutator: ProjectsMutator
  let milestoneMutator: MilestoneMutator
  /// Cached start task. Holds the work of wiring CKEngine + binding
  /// mutators; replays its result to any caller. Nil until first
  /// `start()`; non-nil thereafter so repeated calls coalesce.
  private var startTask: Task<Void, Never>?
  /// Held for the process's lifetime — `SeptenaServices` is the shared
  /// singleton, so there is no deinit to balance it against.
  private var dayRolloverObserver: NSObjectProtocol?

  private init() {
    let context = LocalStore.shared.container.mainContext
    self.ckEngine = CKEngine()
    self.taskMutator = TaskMutator(context: context, ckEngine: nil)
    self.taskAttachmentStore = TaskAttachmentStore(context: context, engine: self.ckEngine)
    self.checklistMutator = ChecklistMutator(context: context, ckEngine: nil)
    self.goalMutator = GoalMutator(context: context, ckEngine: nil)
    self.coachVoiceMutator = CoachVoiceMutator(context: context, ckEngine: nil)
    self.coachMessageMutator = CoachMessageMutator(context: context, ckEngine: nil)
    self.gutMutator = GutMutator(context: context, ckEngine: nil)
    self.activityMutator = ActivityMutator(context: context, ckEngine: nil)
    self.symptomsMutator = SymptomsMutator(context: context, ckEngine: nil)
    self.medicationsMutator = MedicationsMutator(context: context, ckEngine: nil)
    self.moodMutator = MoodMutator(context: context)
    self.intakeMutator = IntakeMutator(context: context, ckEngine: nil)
    self.groceryMutator = GroceryMutator(context: context, ckEngine: nil)
    self.trainingMutator = TrainingMutator(context: context, ckEngine: nil)
    self.nutritionMutator = NutritionMutator(context: context, ckEngine: nil)
    self.areasMutator = AreasMutator(context: context)
    self.projectsMutator = ProjectsMutator(context: context)
    self.milestoneMutator = MilestoneMutator(context: context, ckEngine: nil)
  }

  /// Idempotently enable a section as a side-effect of logging to it from
  /// an App Intent. Logging is implicit consent to use the section, and a
  /// disable never destroys data, so turning it back on is free and keeps
  /// every Shortcut / Siri action working regardless of the user's current
  /// section toggles. No-op when already enabled. Call from
  /// `SectionLogIntent.prepareSection()`, after `start()`.
  func ensureSectionEnabled(_ key: String) {
    SettingsMirror.setSectionEnabled(
      key, true,
      context: LocalStore.shared.container.mainContext,
      engine: ckEngine)
  }

  /// The section keys that are active right now — gated purely on `isEnabled`.
  /// `section_order` is ORDERING, never membership: a section enabled but
  /// absent from a stale order is still active (filtering on the order once hid
  /// newly-shipped sections' MCP tools + App Intents entirely — see below). The
  /// single gate shared by the MCP tool list (`MCPDispatch`) and the App Intents
  /// surface (`SectionLogIntent.requireSection`) so both honor the SAME rule,
  /// and mirrors the gateway's tools/list rule (src/mcp.ts). No sections at all
  /// ⇒ empty, never "everything".
  func enabledSectionKeys() -> Set<String> {
    let context = LocalStore.shared.container.mainContext
    let sections = SettingsMirror.loadSections(context: context)
    // `sectionOrder` defines ORDERING, not membership. A section seeded after
    // the user last saved an order (e.g. a newly shipped section like
    // `intake`) is enabled but absent from the order — filtering on the order
    // hid its MCP tools and App Intents entirely. Enablement is the gate;
    // every enabled section has a real SectionEntity row.
    return Set(sections.filter(\.isEnabled).map(\.key))
  }

  /// Section keys whose actions are ALWAYS available — the App Intents twin of
  /// MCP's GLOBAL tools. `MCPToolCatalog.global` exposes tasks + goals
  /// regardless of section enablement (they're structural, not life-domain
  /// logs), so their intents must stay available too even if the user hides the
  /// section. Everything else is a life-domain that gates on enablement.
  static let alwaysAvailableSectionKeys: Set<String> = ["tasks", "goals"]

  /// Whether a section may be written to right now. Always-on for `.always`
  /// sections and the MCP-global keys (tasks, goals); every other section must
  /// be in `enabledSectionKeys()`. App Intents call this to refuse politely
  /// when a section is off — matching MCP, which simply doesn't advertise a
  /// disabled section's tools.
  func isSectionEnabled(_ key: String) -> Bool {
    if SectionManifest.byKey[key]?.activation == .always { return true }
    if SeptenaServices.alwaysAvailableSectionKeys.contains(key) { return true }
    return enabledSectionKeys().contains(key)
  }

  /// Idempotent. First caller wires CKEngine's record provider / apply
  /// closures, binds the three mutators, and starts the engine.
  /// Subsequent callers await the same in-flight (or completed) work
  /// instead of redoing it.
  ///
  /// Call from the SwiftUI scene's `.task` and from every AppIntent's
  /// `perform()` before issuing a mutation. Without the intent-side
  /// call, an intent fired while the app is cold-launched in background
  /// could race the scene and hit an unbound `TaskMutator`.
  func start() async {
    if let existing = startTask {
      await existing.value
      return
    }
    let task = Task { @MainActor [self] in
      let context = LocalStore.shared.container.mainContext
      let settingsSingletonID = SettingsCloudKitSchema.singletonID

      // Single choke point for keeping the watch / widget Next snapshot fresh:
      // republish on any `.septenaDataChanged` / `.septenaTasksChanged` that
      // touches Next, so every data source (tasks, checklist, training,
      // nutrition, mood, intake) stays in sync without each mutator opting in.
      // Compile-gated: Septask ships a task-only watch snapshot publisher;
      // the full-app Next snapshot publisher stays out of the Septask target.
      #if SEPTASK
      TasksWatchSnapshotPublisher.install(context: context)
      #else
      WatchSnapshotPublisher.install(context: context)
      #endif

      // Legacy `hasOnboarded` backfill only — manifest seeding waits for the
      // first CloudKit pull in `absorbRemoteChanges()` so a reinstall never
      // writes all-off placeholder rows over synced section state.
      PerfTrace.spanSync("start.backfillSectionOnboarding") {
        SettingsMirror.backfillHasOnboardedForLegacySections(context: context)
      }
      let recordRegistry = CloudKitRecordRegistry(modelContainer: LocalStore.shared.container)
      ckEngine.recordProvider = { recordID in
        await recordRegistry.record(for: recordID)
      }
      ckEngine.applyFetchedRecord = { record in
        await recordRegistry.apply(record)
      }
      ckEngine.applyDeletedRecord = { recordID, recordType in
        await recordRegistry.delete(recordID: recordID, recordType: recordType)
      }
      ckEngine.applyDidFinishBatch = { notify in
        let changes = await recordRegistry.finishBatch()
        // Sent-record echoes only update CloudKit system fields. Remote or
        // conflict-winning batches publish exactly the domains they changed.
        guard notify else { return }
        await MainActor.run {
          if changes.touchedTasks {
            NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
          }
          if changes.touchedStructure {
            NotificationCenter.default.post(name: .septenaStructureChanged, object: nil)
          }
          if changes.touchedData {
            NotificationCenter.default.post(name: .septenaDataChanged, object: nil)
          }
        }
      }
      taskMutator.bind(ckEngine: ckEngine)
      areasMutator.bind(ckEngine: ckEngine)
      projectsMutator.bind(ckEngine: ckEngine)
      // Lets project deletion cascade-clear the link on referencing tasks.
      projectsMutator.taskMutator = taskMutator
      // The Next feed's write set binds in BOTH profiles: Septask hosts the
      // full Next feed as its own page (SeptaskNextPage), so the trio
      // toggles (checklist), inline intake nudges, and the fast-break new-meal
      // suggestion (nutrition) must reach CloudKit from the tasks-only shell
      // too. (Mood needs no engine binding; gut isn't written by the page —
      // the Done Today log that read/edited it was cut, so gut stays full-only.)
      checklistMutator.bind(ckEngine: ckEngine)
      intakeMutator.bind(ckEngine: ckEngine)
      nutritionMutator.bind(ckEngine: ckEngine)
      // Everything below is life-OS-only. In the tasks-only profile (Septask)
      // these mutators stay unbound — their write paths are never reachable
      // from a task-only shell, and an unbound mutator dropping a write loudly
      // beats one silently queueing changes the shell can't show.
      // The provider stores (Oura / Withings / Readwise) also stay cold so a
      // tasks-only process never talks to third-party APIs.
      if !RuntimeProfile.current.isTasksOnly {
        goalMutator.bind(ckEngine: ckEngine)
        milestoneMutator.bind(ckEngine: ckEngine)
        coachVoiceMutator.bind(ckEngine: ckEngine)
        coachMessageMutator.bind(ckEngine: ckEngine)
        gutMutator.bind(ckEngine: ckEngine)
        activityMutator.bind(ckEngine: ckEngine)
        symptomsMutator.bind(ckEngine: ckEngine)
        medicationsMutator.bind(ckEngine: ckEngine)
        groceryMutator.bind(ckEngine: ckEngine)
        trainingMutator.bind(ckEngine: ckEngine)
        OuraStore.shared.bind(ckEngine: ckEngine)
        WithingsStore.shared.bind(ckEngine: ckEngine)
        QuoteStore.shared.bind(ckEngine: ckEngine)
      }
      // Demo-seed (screenshot) builds stay offline — never start sync.
      if !DemoSeedMode.isOn {
        // Start the engine (it kicks off its own background fetch) but do
        // NOT await a server round-trip here. start() gates the first frame
        // AND every background-launched App Intent, and the local mirror is
        // the launch source of truth — blocking either on the network broke
        // local-first at exactly the moment it matters most. The awaited
        // fetch + post-fetch repairs live in `absorbRemoteChanges()`, which
        // App.swift runs off the critical path after the first frame.
        PerfTrace.spanSync("start.ckEngineStart") {
          ckEngine.start()
        }
        // Same-device sibling app wrote (Septena ↔ Septask): fetch its
        // changes now rather than on next foreground. See SiblingNudge.
        SiblingNudge.observe { [weak self] in
          guard let self else { return }
          Task { try? await self.ckEngine.fetchChanges() }
        }
        // Readwise highlights are device-local now (see QuoteStore). Clear any
        // backlog a pre-change build queued — thousands of `quote:readwise:*`
        // uploads that re-locked the UI on every launch until drained. One-shot
        // and idempotent: a no-op once the queue is clean.
        ckEngine.dropPendingReadwiseQuoteChanges()
      }
      // Fixed-schedule repeats are a promise about DATES, so the series has
      // to advance when the date does — not only when someone ticks a box.
      // This covers a session that is running when the day flips (the Mac
      // case). A backgrounded app does not reliably get
      // `NSCalendarDayChanged`, which is why both roots also run the
      // catch-up on foreground, and `absorbRemoteChanges` runs it at launch.
      // All three are the same idempotent call.
      dayRolloverObserver = NotificationCenter.default.addObserver(
        forName: .NSCalendarDayChanged, object: nil, queue: .main
      ) { _ in
        Task { @MainActor in SeptenaServices.shared.taskMutator.catchUpFixedSchedules() }
      }
    }
    startTask = task
    await task.value
  }

  /// Launch follow-up to `start()`: pull the server's current state, then run
  /// the repairs that want fetched data in hand. App.swift calls this in an
  /// unawaited task after the first frame paints — CK arrival patches the UI
  /// through the batch notifications, so nothing waits on it. Requires
  /// `start()` to have completed (engine created, seams wired).
  @MainActor
  func absorbRemoteChanges() async {
    guard !DemoSeedMode.isOn else { return }
    let context = LocalStore.shared.container.mainContext
    try? await ckEngine.fetchChanges()
    // Seed any manifest keys still missing AFTER the pull. A genuinely fresh
    // account (no section rows and no other account signals) seeds OFF for the
    // welcome picker; reinstalls and new devices seed from manifest defaults
    // so we never clobber synced enablement with pre-sync placeholders.
    PerfTrace.spanSync("absorb.seedSections") {
      let sectionCount =
        (try? context.fetchCount(FetchDescriptor<SectionEntity>())) ?? 0
      let freshAccount = sectionCount == 0
        && !SettingsMirror.accountHasExistingContent(context: context)
      if SettingsMirror.seedMissingManifestSections(context: context,
                                                    freshAccount: freshAccount) {
        NotificationCenter.default.post(name: .septenaDataChanged, object: nil)
      }
    }
    // Heal dangling project references now that the initial fetch has
    // landed (so we never stub a project that's merely mid-sync).
    await reconcileProjectGraph(context: context)
    // Life-domain repairs run only in the full profile: a tasks-only process
    // (Septask) leaves gut/medication/event history untouched — those
    // migrators write through mutators that are unbound there, and the full
    // app repairs the same rows on its own next launch anyway.
    if !RuntimeProfile.current.isTasksOnly {
      // Repair pre-`occurredAt` event rows (local-only).
      OccurredAtBackfill.runIfNeeded(context: context)
      // Lift the symptom-shaped gut fields (discomfort, blood) into standalone
      // Symptoms events. Local-only, idempotent, gated once-per-device; runs
      // after the fetch so synced gut rows are present.
      GutSymptomMigrator.runIfNeeded(context: context, mutator: symptomsMutator)
    }
    // Retire the legacy `someday` task status — the "Someday" bucket merged
    // into "Anytime". Rewrites stored statusRaw → "open" and pushes the fix;
    // gated once-per-device, after the fetch so synced someday rows are present.
    SomedayStatusMigrator.runIfNeeded(context: context, engine: ckEngine)
    // Undo Septask peek/select acks that exiled undated MCP proposals to Anytime.
    PeekAckProposalRecovery.runIfNeeded(context: context, mutator: taskMutator)
    // Advance fixed-schedule repeats to today. AFTER the fetch on purpose:
    // occurrences another device already created are in the mirror by now, so
    // the deterministic-id guard sees them and this adds only what is missing.
    taskMutator.catchUpFixedSchedules()
    if !RuntimeProfile.current.isTasksOnly {
      // Fold any retired `bedtime` medication bucket into `evening`.
      medicationsMutator.migrateBedtimeBuckets()
    }
    // Publish this device's timezone so the gateway resolves the user's real
    // zone instead of defaulting to UTC — task tools need it too.
    SettingsMirror.publishDeviceTimezone(context: context, engine: ckEngine)
  }

  /// Heals the project graph surfaced by the launch crosswalk. Tasks imported
  /// under the retired slug model can carry `project` ids ("ios", "septena", …)
  /// that never got a `ProjectEntity`, so they resolve to *no* project chip in
  /// the UI (`TaskListView` joins on `ProjectEntity.id`). Rather than log the
  /// orphans every launch, materialize a stub project per id through the mutator
  /// — idempotent, since `createWithExplicitID` returns the existing record if
  /// present — so the tasks regain their grouping and the project surfaces in
  /// the sidebar for the user to rename / merge / delete intentionally.
  ///
  /// Also drops the stale empty `seed-project` artifact left over from earlier
  /// seeding, but only when nothing references it, so a task is never stranded.
  /// Runs after the initial CloudKit fetch; routes every write through the
  /// `projectsMutator` boundary (local update + CloudKit queue + notifications).
  @MainActor
  func reconcileProjectGraph(context: ModelContext) async {
    let tasks = (try? context.fetch(FetchDescriptor<TaskEntity>())) ?? []
    let projects = (try? context.fetch(FetchDescriptor<ProjectEntity>())) ?? []
    let projectIds = Set(projects.map { $0.id })
    let referenced = Set(tasks.compactMap { $0.project })
    let orphans = referenced.subtracting(projectIds).sorted()

    for id in orphans {
      _ = try? await projectsMutator.createWithExplicitID(
        id: id, title: Self.humanizeProjectSlug(id))
    }

    let removedSeed = projectIds.contains("seed-project") && !referenced.contains("seed-project")
    if removedSeed {
      try? await projectsMutator.delete(id: "seed-project")
    }

    if !orphans.isEmpty || removedSeed {
      SeptenaLog.info(
        "[Crosswalk] reconciled project graph: stubbed \(orphans), removedSeedProject=\(removedSeed)")
    }
  }

  /// Best-effort display title for a rebuilt stub project id. "ios" → "iOS",
  /// "septena" → "Septena"; the user can rename it afterward.
  private static func humanizeProjectSlug(_ slug: String) -> String {
    switch slug {
    case "ios": return "iOS"
    default: return slug.prefix(1).uppercased() + slug.dropFirst()
    }
  }
}

@MainActor
@Observable
final class ChecklistMutator {
  private let context: ModelContext
  private var ckEngine: CKEngine?

  init(context: ModelContext, ckEngine: CKEngine? = nil) {
    self.context = context
    self.ckEngine = ckEngine
  }

  func bind(ckEngine: CKEngine) {
    self.ckEngine = ckEngine
  }

  @discardableResult
  func createHabit(name: String, bucket: String, emoji: String? = nil) -> HabitDayItem {
    let id = uniqueHabitID()
    let def = HabitDefinitionEntity(id: id,
                                    title: name,
                                    emoji: normalized(emoji),
                                    bucket: bucket,
                                    sortIndex: nextHabitSortIndex())
    context.insert(def)
    commitHabitDefinition(def, op: "create")
    return HabitDayItem(id: id, name: name, emoji: normalized(emoji),
                        bucket: bucket, done: false, skipped: false,
                        note: nil, time: nil)
  }

  func updateHabit(id: String, name: String, bucket: String, emoji: String?) {
    guard let def = fetchHabitDefinition(id: id) else { return }
    def.title = name
    def.bucket = bucket
    def.emoji = normalized(emoji)
    def.updatedAt = .now
    commitHabitDefinition(def, op: "update")
  }

  func deleteHabit(id: String) {
    guard let def = fetchHabitDefinition(id: id) else { return }
    let states = (try? context.fetch(FetchDescriptor<HabitDayStateEntity>(
      predicate: #Predicate { $0.habitID == id }
    ))) ?? []
    for state in states { context.delete(state) }
    context.delete(def)
    saveContext("CK habits delete")
    ckEngine?.noteHabitDefinitionDeletion(id: id)
    for state in states { ckEngine?.noteHabitEventDeletion(id: state.id) }
    postChecklistChanged("habits")
  }

  func toggleHabit(id: String, date: String, done: Bool) {
    setHabitState(id: id, date: date, done: done, skipped: false,
                  note: nil, time: done ? SeptenaDate.nowHHMM : nil)
  }

  func skipHabit(id: String, date: String, skipped: Bool) {
    setHabitState(id: id, date: date, done: false, skipped: skipped,
                  note: nil, time: nil)
  }

  @discardableResult
  func createSupplement(name: String, emoji: String? = nil, bucket: String? = nil) -> SupplementDayItem {
    let id = uniqueSupplementID()
    let def = SupplementDefinitionEntity(id: id,
                                         title: name,
                                         emoji: normalized(emoji),
                                         bucket: bucket,
                                         sortIndex: nextSupplementSortIndex())
    context.insert(def)
    commitSupplementDefinition(def, op: "create")
    return SupplementDayItem(id: id, name: name, emoji: normalized(emoji),
                             bucket: bucket, done: false, note: nil, time: nil)
  }

  func updateSupplement(id: String, name: String, emoji: String?, bucket: String?) {
    guard let def = fetchSupplementDefinition(id: id) else { return }
    def.title = name
    def.emoji = normalized(emoji)
    def.bucket = bucket
    def.updatedAt = .now
    commitSupplementDefinition(def, op: "update")
  }

  func deleteSupplement(id: String) {
    guard let def = fetchSupplementDefinition(id: id) else { return }
    let states = (try? context.fetch(FetchDescriptor<SupplementDayStateEntity>(
      predicate: #Predicate { $0.supplementID == id }
    ))) ?? []
    for state in states { context.delete(state) }
    context.delete(def)
    saveContext("CK supplements delete")
    ckEngine?.noteSupplementDefinitionDeletion(id: id)
    for state in states { ckEngine?.noteSupplementEventDeletion(id: state.id) }
    postChecklistChanged("supplements")
  }

  func toggleSupplement(id: String, date: String, done: Bool) {
    setSupplementState(id: id, date: date, done: done, skipped: false,
                       time: done ? SeptenaDate.nowHHMM : nil)
  }

  func skipSupplement(id: String, date: String, skipped: Bool) {
    setSupplementState(id: id, date: date, done: false, skipped: skipped, time: nil)
  }

  /// Shared write boundary for a supplement day-state — mirrors `setHabitState`.
  /// A row exists only when there's something to record (taken or skipped);
  /// clearing both deletes it so an untouched supplement leaves no trace.
  private func setSupplementState(id: String, date: String, done: Bool, skipped: Bool, time: String?) {
    let stateID = "supplement:\(date):\(id)"
    let normalizedTime = normalized(time)
    let needsRow = done || skipped
    if !needsRow {
      if let state = fetchSupplementState(id: stateID) {
        context.delete(state)
        saveContext("CK supplements state delete")
        ckEngine?.noteSupplementEventDeletion(id: state.id)
        postChecklistChanged("supplements")
      }
      return
    }
    let state = fetchSupplementState(id: stateID) ?? SupplementDayStateEntity(
      id: stateID,
      date: date,
      supplementID: id,
      done: done,
      skipped: skipped
    )
    state.date = date
    state.supplementID = id
    state.done = done
    state.skipped = skipped
    // Empty string rather than nil so the `note` field registers with
    // CloudKit on first write. Display code already treats "" the same
    // as nil (both render as "no note").
    state.note = ""
    state.occurredAt = EventTimestamp.from(date: date, time: normalizedTime)
    state.updatedAt = .now
    if state.modelContext == nil { context.insert(state) }
    commitSupplementEvent(state, op: "state")
  }

  @discardableResult
  func createChore(name: String, cadenceDays: Int, emoji: String? = nil) -> ChoreItem {
    let id = uniqueChoreID()
    let def = ChoreDefinitionEntity(id: id,
                                    title: name,
                                    emoji: normalized(emoji),
                                    cadenceDays: cadenceDays,
                                    sortIndex: nextChoreSortIndex())
    context.insert(def)
    commitChoreDefinition(def, op: "create")
    return ChecklistMirror.loadChores(context: context, today: SeptenaDate.today).first(where: { $0.id == id })
      ?? ChoreItem(fromFallbackID: id, name: name, emoji: normalized(emoji),
                   dueDate: SeptenaDate.today, lastCompleted: nil,
                   lastCompletedTime: nil, daysOverdue: 0,
                   cadenceDays: cadenceDays)
  }

  func updateChore(id: String, name: String, cadenceDays: Int, emoji: String?) {
    guard let def = fetchChoreDefinition(id: id) else { return }
    def.title = name
    def.cadenceDays = cadenceDays
    def.emoji = normalized(emoji)
    def.updatedAt = .now
    commitChoreDefinition(def, op: "update")
  }

  func deleteChore(id: String) {
    guard let def = fetchChoreDefinition(id: id) else { return }
    let events = (try? context.fetch(FetchDescriptor<ChoreEventEntity>(
      predicate: #Predicate { $0.choreID == id }
    ))) ?? []
    for event in events { context.delete(event) }
    context.delete(def)
    saveContext("CK chores delete")
    ckEngine?.noteChoreDefinitionDeletion(id: id)
    for event in events { ckEngine?.noteChoreEventDeletion(id: event.id) }
    postChecklistChanged("chores")
  }

  func completeChore(id: String, date: String) {
    // `note` (and `reason` in the defer path) get empty-string defaults so
    // the fields register with CloudKit on first event write, enabling the
    // MCP gateway to write them. `newDueDate` stays nil for completions —
    // it's a date string and "" isn't a valid date.
    let event = ChoreEventEntity(id: uniqueChoreEventID(for: id, date: date),
                                 choreID: id,
                                 action: "complete",
                                 date: date,
                                 reason: "",
                                 note: "",
                                 sortKey: sortKey(for: date))
    event.occurredAt = EventTimestamp.from(date: date, time: SeptenaDate.nowHHMM)
    context.insert(event)
    commitChoreEvent(event, op: "complete")
  }

  func deferChore(id: String, mode: String, from today: String) {
    let event = ChoreEventEntity(id: uniqueChoreEventID(for: id, date: today),
                                 choreID: id,
                                 action: "defer",
                                 date: today,
                                 newDueDate: deferredDueDate(mode: mode, from: today),
                                 reason: mode,
                                 note: "",
                                 sortKey: sortKey(for: today))
    event.occurredAt = EventTimestamp.from(date: today, time: SeptenaDate.nowHHMM)
    context.insert(event)
    commitChoreEvent(event, op: "defer")
  }

  func uncompleteChore(id: String, date: String) {
    let matches = (try? context.fetch(FetchDescriptor<ChoreEventEntity>(
      predicate: #Predicate { $0.choreID == id && $0.date == date && $0.action == "complete" },
      sortBy: [SortDescriptor(\.sortKey, order: .reverse)]
    ))) ?? []
    guard let latest = matches.first else { return }
    context.delete(latest)
    saveContext("CK chores uncomplete")
    ckEngine?.noteChoreEventDeletion(id: latest.id)
    postChecklistChanged("chores")
  }

  private func setHabitState(id: String,
                             date: String,
                             done: Bool,
                             skipped: Bool,
                             note: String?,
                             time: String?) {
    let stateID = "habit:\(date):\(id)"
    let normalizedNote = normalized(note)
    let normalizedTime = normalized(time)
    let needsRow = done || skipped || normalizedNote != nil || normalizedTime != nil
    if !needsRow {
      if let state = fetchHabitState(id: stateID) {
        context.delete(state)
        saveContext("CK habits state delete")
        ckEngine?.noteHabitEventDeletion(id: state.id)
        postChecklistChanged("habits")
      }
      return
    }

    let state = fetchHabitState(id: stateID) ?? HabitDayStateEntity(id: stateID,
                                                                    date: date,
                                                                    habitID: id,
                                                                    done: done,
                                                                    skipped: skipped)
    state.date = date
    state.habitID = id
    state.done = done
    state.skipped = skipped
    // Empty string rather than nil when there's no note/time so the fields
    // register with CloudKit on first write. `time` stays nil when absent —
    // empty isn't a valid HH:MM. Display code treats "" the same as nil.
    state.note = normalizedNote ?? ""
    state.occurredAt = EventTimestamp.from(date: date, time: normalizedTime)
    state.updatedAt = .now
    if state.modelContext == nil { context.insert(state) }
    commitHabitEvent(state, op: "state")
    // Milestone detection at the write boundary so every path (views,
    // intents, MCP) detects. Backfills (date != today) grant silently —
    // history stays honest but never animates.
    if done {
      let today = SeptenaDate.today
      SeptenaServices.shared.milestoneMutator.evaluateHabitStreak(
        habitID: id, now: .now, today: today, celebrate: date == today)
    }
  }

  private func fetchHabitDefinition(id: String) -> HabitDefinitionEntity? {
    try? context.fetch(FetchDescriptor<HabitDefinitionEntity>(
      predicate: #Predicate { $0.id == id }
    )).first
  }

  private func fetchHabitState(id: String) -> HabitDayStateEntity? {
    try? context.fetch(FetchDescriptor<HabitDayStateEntity>(
      predicate: #Predicate { $0.id == id }
    )).first
  }

  private func fetchSupplementDefinition(id: String) -> SupplementDefinitionEntity? {
    try? context.fetch(FetchDescriptor<SupplementDefinitionEntity>(
      predicate: #Predicate { $0.id == id }
    )).first
  }

  private func fetchSupplementState(id: String) -> SupplementDayStateEntity? {
    try? context.fetch(FetchDescriptor<SupplementDayStateEntity>(
      predicate: #Predicate { $0.id == id }
    )).first
  }

  private func fetchChoreDefinition(id: String) -> ChoreDefinitionEntity? {
    try? context.fetch(FetchDescriptor<ChoreDefinitionEntity>(
      predicate: #Predicate { $0.id == id }
    )).first
  }

  private func uniqueHabitID() -> String { uniqueDefinitionID(fetch: fetchHabitDefinition(id:)) }
  private func uniqueSupplementID() -> String { uniqueDefinitionID(fetch: fetchSupplementDefinition(id:)) }
  private func uniqueChoreID() -> String { uniqueDefinitionID(fetch: fetchChoreDefinition(id:)) }

  private func uniqueDefinitionID(fetch: (String) -> AnyObject?) -> String {
    let first = IDShortcode.generate(length: 4)
    if fetch(first) == nil { return first }
    let second = IDShortcode.generate(length: 6)
    if fetch(second) == nil { return second }
    return String(UUID().uuidString.prefix(8)).lowercased()
  }

  private func uniqueChoreEventID(for choreID: String, date: String) -> String {
    let candidate = "chore:\(date):\(choreID):\(IDShortcode.generate(length: 6))"
    if (try? context.fetch(FetchDescriptor<ChoreEventEntity>(
      predicate: #Predicate { $0.id == candidate }
    )).first) == nil {
      return candidate
    }
    return "chore:\(date):\(choreID):\(UUID().uuidString.lowercased())"
  }

  private func nextHabitSortIndex() -> Int {
    ((try? context.fetch(FetchDescriptor<HabitDefinitionEntity>(
      sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]
    )).first?.sortIndex) ?? -1) + 1
  }

  private func nextSupplementSortIndex() -> Int {
    ((try? context.fetch(FetchDescriptor<SupplementDefinitionEntity>(
      sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]
    )).first?.sortIndex) ?? -1) + 1
  }

  private func nextChoreSortIndex() -> Int {
    ((try? context.fetch(FetchDescriptor<ChoreDefinitionEntity>(
      sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]
    )).first?.sortIndex) ?? -1) + 1
  }

  private func deferredDueDate(mode: String, from date: String) -> String? {
    guard let base = SeptenaDate.parse(date) else { return nil }
    let calendar = Calendar.current
    switch mode {
    case "today":
      return SeptenaDate.format(base)
    case "day":
      return calendar.date(byAdding: .day, value: 1, to: base).flatMap(SeptenaDate.format)
    case "weekend":
      let weekday = calendar.component(.weekday, from: base)
      let saturday = 7
      let delta = ((saturday - weekday + 7) % 7 == 0) ? 7 : ((saturday - weekday + 7) % 7)
      return calendar.date(byAdding: .day, value: delta, to: base).flatMap(SeptenaDate.format)
    default:
      return nil
    }
  }

  private func sortKey(for date: String) -> String {
    "\(date)::\(String(format: "%.6f", Date().timeIntervalSince1970))"
  }

  private func normalized(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else { return nil }
    return trimmed
  }

  private func commitHabitDefinition(_ entity: HabitDefinitionEntity, op: String) {
    saveContext("CK habits \(op)")
    ckEngine?.noteHabitDefinitionChange(id: entity.id)
    postChecklistChanged("habits")
  }

  private func commitHabitEvent(_ entity: HabitDayStateEntity, op: String) {
    saveContext("CK habit event \(op)")
    ckEngine?.noteHabitEventChange(id: entity.id)
    postChecklistChanged("habits")
  }

  private func commitSupplementDefinition(_ entity: SupplementDefinitionEntity, op: String) {
    saveContext("CK supplements \(op)")
    ckEngine?.noteSupplementDefinitionChange(id: entity.id)
    postChecklistChanged("supplements")
  }

  private func commitSupplementEvent(_ entity: SupplementDayStateEntity, op: String) {
    saveContext("CK supplement event \(op)")
    ckEngine?.noteSupplementEventChange(id: entity.id)
    postChecklistChanged("supplements")
  }

  private func commitChoreDefinition(_ entity: ChoreDefinitionEntity, op: String) {
    saveContext("CK chores \(op)")
    ckEngine?.noteChoreDefinitionChange(id: entity.id)
    postChecklistChanged("chores")
  }

  private func commitChoreEvent(_ entity: ChoreEventEntity, op: String) {
    saveContext("CK chore event \(op)")
    ckEngine?.noteChoreEventChange(id: entity.id)
    postChecklistChanged("chores")
  }

  private func saveContext(_ label: String) {
    // Every startup/reconcile write in this file funnels here, so this is also
    // the one place they all get the failed-save rollback (`StoreHealth.save`).
    StoreHealth.save(context, op: label)
  }

  /// One mutator, three sections — callers pass the section key of the
  /// entity they touched ("habits" / "supplements" / "chores") so listeners
  /// showing unrelated sections skip their reload. The task surfaces
  /// (sidebar, Tasks tile, menu bar) never cared about checklist toggles,
  /// so no `.septenaTasksChanged` here.
  private func postChecklistChanged(_ section: String) {
    // Posting the scoped change is enough: `WatchSnapshotPublisher.install`
    // observes `.septenaDataChanged` and republishes the watch/widget snapshot
    // (debounced) for any Next-relevant section, so the rebuild no longer has to
    // be wired per-mutator — that omission is what left training/mood stale.
    DataChange.post(section)
  }
}

// MARK: - GoalMutator

@MainActor
@Observable
final class GoalMutator {
  /// Section key this mutator's scoped `.septenaDataChanged` posts carry.
  static let changeScope = "goals"
  private let context: ModelContext
  private var ckEngine: CKEngine?

  init(context: ModelContext, ckEngine: CKEngine? = nil) {
    self.context = context
    self.ckEngine = ckEngine
  }

  func bind(ckEngine: CKEngine) {
    self.ckEngine = ckEngine
  }

  @discardableResult
  func createGoal(text: String) -> Goal {
    let id = uniqueGoalID()
    let today = SeptenaDate.today
    let entity = GoalEntity(id: id,
                            text: text,
                            sections: [],
                            created: today,
                            sortIndex: nextSortIndex())
    context.insert(entity)
    commit(entity, op: "create")
    return Goal(entity)
  }

  func updateGoal(id: String, text: String, sections: [String]) {
    guard let entity = fetchGoal(id: id) else { return }
    entity.text = text
    entity.sections = sections
    entity.updatedAt = .now
    commit(entity, op: "update")
  }

  /// Attach (or clear) the optional measurement spec on a goal. Passing
  /// `metricKey == nil` clears every metric field together — they are
  /// always set or cleared as a unit. `baseline` is independent of
  /// metric vs. no-metric (it's only meaningful when metricKey is set,
  /// and is freely nullable for goals that don't need it).
  func updateGoalMetric(id: String,
                        metricKey: String?,
                        window: String?,
                        comparator: String?,
                        target: Double?,
                        baseline: Double?,
                        upper: Double? = nil) {
    guard let entity = fetchGoal(id: id) else { return }
    if let metricKey {
      entity.metricKey = metricKey
      entity.metricWindow = window
      entity.metricComparator = comparator
      entity.metricTarget = target
      entity.metricBaseline = baseline
      // Upper bound only meaningful for the range comparator; clear otherwise
      // so a goal switched away from "between" doesn't keep a stale ceiling.
      entity.metricTargetUpper = (comparator == "range") ? upper : nil
    } else {
      entity.metricKey = nil
      entity.metricWindow = nil
      entity.metricComparator = nil
      entity.metricTarget = nil
      entity.metricBaseline = nil
      entity.metricTargetUpper = nil
    }
    entity.updatedAt = .now
    commit(entity, op: "update metric")
  }

  /// Pin (or unpin) a goal to the top of the Week dashboard. Pure
  /// presentation flag — doesn't touch the goal's metric or sections.
  func setPinned(id: String, pinned: Bool) {
    guard let entity = fetchGoal(id: id), entity.pinned != pinned else { return }
    entity.pinned = pinned
    entity.updatedAt = .now
    commit(entity, op: "pin")
  }

  /// Set a goal-specific dashboard accent. Nil restores the section-derived
  /// color used by older goals.
  func setColor(id: String, color: String?) {
    guard let entity = fetchGoal(id: id), entity.color != color else { return }
    entity.color = color
    entity.updatedAt = .now
    commit(entity, op: "set color")
  }

  func deleteGoal(id: String) {
    guard let entity = fetchGoal(id: id) else { return }
    context.delete(entity)
    saveContext("CK goals delete")
    ckEngine?.noteGoalDeletion(id: id)
    postChanged()
  }

  /// The unify: an intake kind's `objective` IS a Goal on one of its metrics.
  /// Create/update the kind's single objective-goal (identified by its metric
  /// key prefix), or clear it when the objective is `log`. The cap for a "limit"
  /// objective lives here as `metricTarget` — no separate field. See
  /// docs/CONSUMABLES_PLAN.md.
  func syncIntakeObjectiveGoal(kindID: String, kindName: String,
                               objective: String, target: Double?,
                               weekly: Bool? = nil) {
    let existing = ((try? context.fetch(FetchDescriptor<GoalEntity>())) ?? [])
      .first { $0.metricKey?.hasPrefix("intake.\(kindID).") == true }

    guard let spec = IntakeObjective.goalSpec(objective, weekly: weekly) else {
      // log → no measured objective; remove the auto-created goal if present.
      if let existing { deleteGoal(id: existing.id) }
      return
    }

    let text = IntakeObjective.goalText(objective, kindName: kindName)
    let goalID: String
    if let existing {
      existing.text = text
      existing.sections = ["intake"]
      existing.updatedAt = .now
      commit(existing, op: "update (intake objective)")
      goalID = existing.id
    } else {
      let g = createGoal(text: text)
      updateGoal(id: g.id, text: text, sections: ["intake"])
      goalID = g.id
    }
    updateGoalMetric(id: goalID,
                     metricKey: "intake.\(kindID).\(spec.metricSuffix)",
                     window: spec.window,
                     comparator: spec.comparator,
                     target: target ?? spec.defaultTarget,
                     baseline: nil)
  }

  // MARK: - Helpers

  private func fetchGoal(id: String) -> GoalEntity? {
    try? context.fetch(FetchDescriptor<GoalEntity>(
      predicate: #Predicate { $0.id == id }
    )).first
  }

  private func uniqueGoalID() -> String {
    let first = IDShortcode.generate(length: 4)
    if fetchGoal(id: first) == nil { return first }
    let second = IDShortcode.generate(length: 6)
    if fetchGoal(id: second) == nil { return second }
    return String(UUID().uuidString.prefix(8)).lowercased()
  }

  private func nextSortIndex() -> Int {
    ((try? context.fetch(FetchDescriptor<GoalEntity>(
      sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]
    )).first?.sortIndex) ?? -1) + 1
  }

  private func commit(_ entity: GoalEntity, op: String) {
    saveContext("CK goals \(op)")
    ckEngine?.noteGoalChange(id: entity.id)
    postChanged()
  }

  /// `StoreHealth.save` logs the real error and rolls the context back. A
  /// failed save that keeps its pending changes wedges every later save on
  /// this shared context — see `StoreHealth`.
  private func saveContext(_ label: String) {
    StoreHealth.save(context, op: label)
  }

  private func postChanged() {
    DataChange.post(Self.changeScope)
  }
}

// MARK: - CoachVoiceMutator

/// Upserts the per-coach voice settings (tone dials + custom note). One row
/// per coach, keyed by coach key. Raw-string API so SeptenaCore stays free of
/// the app-side voice enums; the app's `CoachVoiceStore` maps to/from them.
@MainActor
@Observable
final class CoachVoiceMutator {
  static let changeScope = "coach"
  private let context: ModelContext
  private var ckEngine: CKEngine?

  init(context: ModelContext, ckEngine: CKEngine? = nil) {
    self.context = context
    self.ckEngine = ckEngine
  }

  func bind(ckEngine: CKEngine) {
    self.ckEngine = ckEngine
  }

  /// The stored voice row for a coach, or nil if the user never changed it
  /// (callers fall back to the coach's defaults).
  func voice(forCoachKey key: String) -> CoachVoiceEntity? {
    fetch(key)
  }

  func save(coachKey: String,
            warmth: String, brevity: String,
            challenge: String, formality: String, note: String) {
    let entity: CoachVoiceEntity
    if let existing = fetch(coachKey) {
      existing.warmth = warmth
      existing.brevity = brevity
      existing.challenge = challenge
      existing.formality = formality
      existing.note = note
      existing.updatedAt = .now
      entity = existing
    } else {
      entity = CoachVoiceEntity(id: coachKey, warmth: warmth, brevity: brevity,
                                challenge: challenge, formality: formality, note: note)
      context.insert(entity)
    }
    saveContext("CK coachVoice save")
    ckEngine?.noteCoachVoiceChange(id: entity.id)
    postChanged()
  }

  func delete(coachKey: String) {
    guard let entity = fetch(coachKey) else { return }
    context.delete(entity)
    saveContext("CK coachVoice delete")
    ckEngine?.noteCoachVoiceDeletion(id: coachKey)
    postChanged()
  }

  private func fetch(_ key: String) -> CoachVoiceEntity? {
    try? context.fetch(FetchDescriptor<CoachVoiceEntity>(
      predicate: #Predicate { $0.id == key }
    )).first
  }

  private func saveContext(_ label: String) {
    StoreHealth.save(context, op: label)
  }

  private func postChanged() {
    DataChange.post(Self.changeScope)
  }
}

// MARK: - CoachMessageMutator

/// Persists a coach conversation as flat per-message rows keyed by coach key.
/// Append-only during a chat; `clear` wipes one coach's transcript. Plain
/// strings for role so SeptenaCore needn't know the app's Message type.
@MainActor
@Observable
final class CoachMessageMutator {
  static let changeScope = "coach"
  private let context: ModelContext
  private var ckEngine: CKEngine?

  init(context: ModelContext, ckEngine: CKEngine? = nil) {
    self.context = context
    self.ckEngine = ckEngine
  }

  func bind(ckEngine: CKEngine) {
    self.ckEngine = ckEngine
  }

  /// One coach's transcript, oldest-first.
  func messages(forCoachKey key: String) -> [CoachMessageEntity] {
    (try? context.fetch(FetchDescriptor<CoachMessageEntity>(
      predicate: #Predicate { $0.coachKey == key },
      sortBy: [SortDescriptor(\.sortIndex, order: .forward)]
    ))) ?? []
  }

  @discardableResult
  func append(coachKey: String, role: String, text: String) -> CoachMessageEntity {
    let entity = CoachMessageEntity(id: UUID().uuidString.lowercased(),
                                    coachKey: coachKey,
                                    role: role,
                                    text: text,
                                    sortIndex: nextSortIndex(forCoachKey: coachKey))
    context.insert(entity)
    saveContext("CK coachMessage append")
    ckEngine?.noteCoachMessageChange(id: entity.id)
    postChanged()
    return entity
  }

  /// Wipe one coach's transcript (queues a CK deletion per row).
  func clear(coachKey: String) {
    let rows = messages(forCoachKey: coachKey)
    guard !rows.isEmpty else { return }
    let ids = rows.map(\.id)
    for entity in rows { context.delete(entity) }
    saveContext("CK coachMessage clear")
    for id in ids { ckEngine?.noteCoachMessageDeletion(id: id) }
    postChanged()
  }

  private func nextSortIndex(forCoachKey key: String) -> Int {
    ((try? context.fetch(FetchDescriptor<CoachMessageEntity>(
      predicate: #Predicate { $0.coachKey == key },
      sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]
    )).first?.sortIndex) ?? -1) + 1
  }

  private func saveContext(_ label: String) {
    StoreHealth.save(context, op: label)
  }

  private func postChanged() {
    DataChange.post(Self.changeScope)
  }
}

@MainActor
@Observable
final class GutMutator {
  static let changeScope = "gut"
  private let context: ModelContext
  private var ckEngine: CKEngine?

  init(context: ModelContext, ckEngine: CKEngine? = nil) {
    self.context = context
    self.ckEngine = ckEngine
  }

  func bind(ckEngine: CKEngine) {
    self.ckEngine = ckEngine
  }

  @discardableResult
  func addEntry(date: String,
                time: String,
                bristol: Int,
                // Free-form text defaults to "" rather than nil so the first
                // in-app entry registers the field with CloudKit, enabling the
                // MCP gateway (which uses Web Services API) to write to it.
                volume: String? = nil,
                note: String? = "") -> GutEventEntity {
    let id = uniqueID()
    // Symptom-shaped fields (blood, discomfort) are retired from Gut — they
    // live in Symptoms now (docs/GUT_SYMPTOMS_MIGRATION_PLAN). New rows leave
    // the dormant storage at its empty defaults; the GutSymptomMigrator still
    // reads legacy values off existing rows.
    let entity = GutEventEntity(id: id,
                                date: date,
                                bristol: bristol,
                                volume: volume,
                                note: note)
    entity.occurredAt = EventTimestamp.from(date: date, time: time)
    context.insert(entity)
    commit(entity, op: "create")
    return entity
  }

  func updateEntry(id: String,
                   date: String? = nil,
                   time: String? = nil,
                   bristol: Int? = nil,
                   volume: String?? = nil,
                   note: String?? = nil) {
    guard let entity = fetch(id: id) else { return }
    if let date { entity.date = date }
    if let bristol { entity.bristol = bristol }
    if let volume { entity.volume = volume }
    if let note { entity.note = note }
    // `time` STRING retired: fold a day/time change into the canonical
    // occurredAt, deriving the unspecified half from the existing instant.
    if date != nil || time != nil {
      let t = time ?? EventTimestamp.hhmm(from: entity.occurredAt)
      entity.occurredAt = EventTimestamp.from(date: entity.date, time: t)
    }
    entity.updatedAt = .now
    commit(entity, op: "update")
  }

  func deleteEntry(id: String) {
    guard let entity = fetch(id: id) else { return }
    context.delete(entity)
    saveContext("CK gut delete")
    ckEngine?.noteGutEventDeletion(id: id)
    postChanged()
  }

  private func fetch(id: String) -> GutEventEntity? {
    try? context.fetch(FetchDescriptor<GutEventEntity>(
      predicate: #Predicate { $0.id == id }
    )).first
  }

  private func uniqueID() -> String {
    var attempt = String(UUID().uuidString.lowercased().prefix(8))
    while fetch(id: attempt) != nil {
      attempt = String(UUID().uuidString.lowercased().prefix(8))
    }
    return attempt
  }

  private func commit(_ entity: GutEventEntity, op: String) {
    saveContext("CK gut \(op)")
    ckEngine?.noteGutEventChange(id: entity.id)
    postChanged()
  }

  private func saveContext(_ label: String) {
    StoreHealth.save(context, op: label)
  }

  private func postChanged() {
    DataChange.post(Self.changeScope)
  }
}

/// Write boundary for the HealthKit-sourced daily activity mirror. Unlike the
/// other mutators it takes no user input — the only caller is the iOS ingest
/// in `HealthKitBridge`. Its one job beyond the usual local-write + CK-queue is
/// the unchanged-skip in `upsert`: the ingest re-reads a trailing window on
/// every refresh, so without it each refresh would re-dirty `updatedAt` and
/// re-upload the whole window to CloudKit forever.
@MainActor
@Observable
final class ActivityMutator {
  static let changeScope = "activity"
  private let context: ModelContext
  private var ckEngine: CKEngine?

  init(context: ModelContext, ckEngine: CKEngine? = nil) {
    self.context = context
    self.ckEngine = ckEngine
  }

  func bind(ckEngine: CKEngine) { self.ckEngine = ckEngine }

  /// Idempotent daily upsert. Creates a row on first sight of a day with any
  /// data, updates it when a value changed, and does nothing (no save, no CK
  /// queue, no notification) when the values match what's already stored.
  @discardableResult
  func upsert(date: String,
              steps: Int?,
              activeKcal: Double?,
              exerciseMinutes: Int?) -> ActivityDayEntity? {
    let existing = fetch(id: date)
    // An all-nil day carries no signal; never create an empty record.
    if existing == nil, steps == nil, activeKcal == nil, exerciseMinutes == nil {
      return nil
    }
    if let entity = existing,
       entity.stepCount == steps,
       Self.sameKcal(entity.activeKcal, activeKcal),
       entity.exerciseMinutes == exerciseMinutes {
      return entity   // unchanged — skip
    }
    let entity = existing ?? ActivityDayEntity(id: date, date: date)
    entity.stepCount = steps
    entity.activeKcal = activeKcal
    entity.exerciseMinutes = exerciseMinutes
    entity.updatedAt = .now
    if existing == nil { context.insert(entity) }
    saveContext("CK activity upsert")
    ckEngine?.noteActivityDayChange(id: entity.id)
    DataChange.post(Self.changeScope)
    return entity
  }

  /// Energy is a Double from a statistics sum; treat sub-kcal jitter as equal
  /// so floating-point noise doesn't trigger spurious re-uploads.
  private static func sameKcal(_ a: Double?, _ b: Double?) -> Bool {
    switch (a, b) {
    case (nil, nil):       return true
    case let (x?, y?):     return abs(x - y) < 0.5
    default:               return false
    }
  }

  private func fetch(id: String) -> ActivityDayEntity? {
    try? context.fetch(FetchDescriptor<ActivityDayEntity>(
      predicate: #Predicate { $0.id == id }
    )).first
  }

  private func saveContext(_ label: String) {
    StoreHealth.save(context, op: label)
  }
}

@MainActor
@Observable
final class SymptomsMutator {
  static let changeScope = "symptoms"
  private let context: ModelContext
  private var ckEngine: CKEngine?

  init(context: ModelContext, ckEngine: CKEngine? = nil) {
    self.context = context
    self.ckEngine = ckEngine
  }

  func bind(ckEngine: CKEngine) {
    self.ckEngine = ckEngine
  }

  @discardableResult
  func addDefinition(title: String,
                     emoji: String? = nil,
                     bodySystem: String? = nil,
                     defaultBodyRegion: String? = nil) -> SymptomDefinitionEntity {
    let entity = SymptomDefinitionEntity(id: UUID().uuidString.lowercased(),
                                         title: title,
                                         emoji: emoji,
                                         bodySystem: bodySystem,
                                         defaultBodyRegion: defaultBodyRegion,
                                         sortIndex: nextDefinitionSortIndex())
    context.insert(entity)
    commitDefinition(entity, op: "create")
    return entity
  }

  func updateDefinition(id: String,
                        title: String? = nil,
                        emoji: String?? = nil,
                        bodySystem: String?? = nil,
                        defaultBodyRegion: String?? = nil,
                        archived: Bool? = nil) {
    guard let entity = fetchDefinition(id: id) else { return }
    if let title { entity.title = title }
    if let emoji { entity.emoji = emoji }
    if let bodySystem { entity.bodySystem = bodySystem }
    if let defaultBodyRegion { entity.defaultBodyRegion = defaultBodyRegion }
    if let archived { entity.archived = archived }
    entity.updatedAt = .now
    commitDefinition(entity, op: "update")
  }

  @discardableResult
  func addEvent(symptomID: String,
                date: String,
                time: String,
                severity: Int,
                durationMinutes: Int? = nil,
                bodyRegion: String? = nil,
                side: String? = nil,
                quality: String? = nil,
                triggerNote: String? = "",
                reliefNote: String? = "",
                note: String? = "",
                source: String? = "manual") -> SymptomEventEntity {
    let entity = SymptomEventEntity(id: UUID().uuidString.lowercased(),
                                    date: date,
                                    symptomID: symptomID,
                                    severity: max(0, min(10, severity)),
                                    durationMinutes: durationMinutes,
                                    bodyRegion: bodyRegion,
                                    side: side,
                                    quality: quality,
                                    triggerNote: triggerNote,
                                    reliefNote: reliefNote,
                                    note: note,
                                    source: source)
    entity.occurredAt = EventTimestamp.from(date: date, time: time)
    context.insert(entity)
    commitEvent(entity, op: "create")
    return entity
  }

  func updateEvent(id: String,
                   date: String? = nil,
                   time: String? = nil,
                   symptomID: String? = nil,
                   severity: Int? = nil,
                   durationMinutes: Int?? = nil,
                   bodyRegion: String?? = nil,
                   side: String?? = nil,
                   quality: String?? = nil,
                   triggerNote: String?? = nil,
                   reliefNote: String?? = nil,
                   note: String?? = nil) {
    guard let entity = fetchEvent(id: id) else { return }
    if let date { entity.date = date }
    if let symptomID { entity.symptomID = symptomID }
    if let severity { entity.severity = max(0, min(10, severity)) }
    if let durationMinutes { entity.durationMinutes = durationMinutes }
    if let bodyRegion { entity.bodyRegion = bodyRegion }
    if let side { entity.side = side }
    if let quality { entity.quality = quality }
    if let triggerNote { entity.triggerNote = triggerNote }
    if let reliefNote { entity.reliefNote = reliefNote }
    if let note { entity.note = note }
    if date != nil || time != nil {
      let t = time ?? EventTimestamp.hhmm(from: entity.occurredAt)
      entity.occurredAt = EventTimestamp.from(date: entity.date, time: t)
    }
    entity.updatedAt = .now
    commitEvent(entity, op: "update")
  }

  func deleteEvent(id: String) {
    guard let entity = fetchEvent(id: id) else { return }
    context.delete(entity)
    saveContext("CK symptoms delete")
    ckEngine?.noteSymptomEventDeletion(id: id)
    postChanged()
  }

  private func fetchDefinition(id: String) -> SymptomDefinitionEntity? {
    try? context.fetch(FetchDescriptor<SymptomDefinitionEntity>(
      predicate: #Predicate { $0.id == id }
    )).first
  }

  private func fetchEvent(id: String) -> SymptomEventEntity? {
    try? context.fetch(FetchDescriptor<SymptomEventEntity>(
      predicate: #Predicate { $0.id == id }
    )).first
  }

  private func nextDefinitionSortIndex() -> Int {
    ((try? context.fetch(FetchDescriptor<SymptomDefinitionEntity>(
      sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]
    )).first?.sortIndex) ?? -1) + 1
  }

  private func commitDefinition(_ entity: SymptomDefinitionEntity, op: String) {
    saveContext("CK symptoms definition \(op)")
    ckEngine?.noteSymptomDefinitionChange(id: entity.id)
    postChanged()
  }

  private func commitEvent(_ entity: SymptomEventEntity, op: String) {
    saveContext("CK symptoms event \(op)")
    ckEngine?.noteSymptomEventChange(id: entity.id)
    postChanged()
  }

  private func saveContext(_ label: String) {
    StoreHealth.save(context, op: label)
  }

  private func postChanged() {
    DataChange.post(Self.changeScope)
  }

  // MARK: - Migration upserts (deterministic ids)
  //
  // The Gut → Symptoms migrator writes through these so the write-boundary
  // invariant holds for migrators too. Definitions match by title first (so a
  // starter the user already added is reused, never duplicated); events upsert
  // on a deterministic id derived from the source gut row.

  /// Id of a definition titled `title` (case-insensitive), creating one with
  /// `fallbackID` if none exists. Idempotent across launches and devices.
  @discardableResult
  func ensureDefinition(title: String,
                        emoji: String?,
                        bodySystem: String?,
                        defaultBodyRegion: String?,
                        fallbackID: String) -> String {
    let all = (try? context.fetch(FetchDescriptor<SymptomDefinitionEntity>())) ?? []
    if let existing = all.first(where: { $0.title.lowercased() == title.lowercased() }) {
      return existing.id
    }
    let entity = SymptomDefinitionEntity(id: fallbackID,
                                         title: title,
                                         emoji: emoji,
                                         bodySystem: bodySystem,
                                         defaultBodyRegion: defaultBodyRegion,
                                         sortIndex: nextDefinitionSortIndex())
    context.insert(entity)
    commitDefinition(entity, op: "migrate")
    return fallbackID
  }

  /// Create-or-update a migrated symptom event keyed on a deterministic id, so a
  /// re-run (or a late-arriving gut row) converges instead of duplicating.
  func upsertMigratedEvent(id: String,
                           symptomID: String,
                           date: String,
                           occurredAt: Date,
                           severity: Int,
                           durationMinutes: Int?,
                           note: String?,
                           source: String) {
    let clamped = max(0, min(10, severity))
    if let existing = fetchEvent(id: id) {
      existing.symptomID = symptomID
      existing.date = date
      existing.occurredAt = occurredAt
      existing.severity = clamped
      existing.durationMinutes = durationMinutes
      existing.note = note
      existing.source = source
      existing.updatedAt = .now
      commitEvent(existing, op: "migrate")
      return
    }
    let entity = SymptomEventEntity(id: id,
                                    date: date,
                                    symptomID: symptomID,
                                    severity: clamped,
                                    durationMinutes: durationMinutes,
                                    note: note,
                                    source: source)
    entity.occurredAt = occurredAt
    context.insert(entity)
    commitEvent(entity, op: "migrate")
  }
}

@MainActor
@Observable
final class MedicationsMutator {
  static let changeScope = "medications"
  private let context: ModelContext
  private var ckEngine: CKEngine?

  init(context: ModelContext, ckEngine: CKEngine? = nil) {
    self.context = context
    self.ckEngine = ckEngine
  }

  func bind(ckEngine: CKEngine) {
    self.ckEngine = ckEngine
  }

  /// One-time fold of the retired `bedtime` bucket into `evening` — buckets
  /// are now the canonical three (see docs/BUCKET_CONSISTENCY_SPEC.md).
  /// Idempotent: after the first pass no definitions match, so it's safe to
  /// run on every launch without a sentinel.
  func migrateBedtimeBuckets() {
    let stale = (try? context.fetch(FetchDescriptor<MedicationDefinitionEntity>(
      predicate: #Predicate { $0.bucket == "bedtime" }
    ))) ?? []
    guard !stale.isEmpty else { return }
    for def in stale {
      def.bucket = DayBucket.evening.rawValue
      def.updatedAt = .now
      commitDefinition(def, op: "migrate")
    }
  }

  @discardableResult
  func addDefinition(title: String,
                     genericName: String? = nil,
                     form: String? = nil,
                     route: String? = nil,
                     strengthValue: Double? = nil,
                     strengthUnit: String? = nil,
                     defaultDoseValue: Double? = nil,
                     defaultDoseUnit: String? = nil,
                     bucket: String? = nil,
                     scheduleKind: String? = "daily",
                     targetDosesPerDay: Int? = 1,
                     instructions: String? = nil) -> MedicationDefinitionEntity {
    let entity = MedicationDefinitionEntity(id: UUID().uuidString.lowercased(),
                                            title: title,
                                            genericName: genericName,
                                            form: form,
                                            route: route,
                                            strengthValue: strengthValue,
                                            strengthUnit: strengthUnit,
                                            defaultDoseValue: defaultDoseValue,
                                            defaultDoseUnit: defaultDoseUnit,
                                            bucket: bucket,
                                            scheduleKind: scheduleKind,
                                            targetDosesPerDay: targetDosesPerDay,
                                            instructions: instructions,
                                            sortIndex: nextDefinitionSortIndex())
    context.insert(entity)
    commitDefinition(entity, op: "create")
    return entity
  }

  func updateDefinition(id: String,
                        title: String? = nil,
                        genericName: String?? = nil,
                        form: String?? = nil,
                        route: String?? = nil,
                        strengthValue: Double?? = nil,
                        strengthUnit: String?? = nil,
                        defaultDoseValue: Double?? = nil,
                        defaultDoseUnit: String?? = nil,
                        bucket: String?? = nil,
                        scheduleKind: String?? = nil,
                        targetDosesPerDay: Int?? = nil,
                        instructions: String?? = nil,
                        archived: Bool? = nil) {
    guard let entity = fetchDefinition(id: id) else { return }
    if let title { entity.title = title }
    if let genericName { entity.genericName = genericName }
    if let form { entity.form = form }
    if let route { entity.route = route }
    if let strengthValue { entity.strengthValue = strengthValue }
    if let strengthUnit { entity.strengthUnit = strengthUnit }
    if let defaultDoseValue { entity.defaultDoseValue = defaultDoseValue }
    if let defaultDoseUnit { entity.defaultDoseUnit = defaultDoseUnit }
    if let bucket { entity.bucket = bucket }
    if let scheduleKind { entity.scheduleKind = scheduleKind }
    if let targetDosesPerDay { entity.targetDosesPerDay = targetDosesPerDay }
    if let instructions { entity.instructions = instructions }
    if let archived { entity.archived = archived }
    entity.updatedAt = .now
    commitDefinition(entity, op: "update")
  }

  @discardableResult
  func addDose(medicationID: String,
               date: String,
               time: String,
               status: String = "taken",
               doseValue: Double? = nil,
               doseUnit: String? = nil,
               reason: String? = "",
               effectNote: String? = "",
               sideEffectNote: String? = "",
               source: String? = "manual") -> MedicationDoseEventEntity {
    let entity = MedicationDoseEventEntity(id: UUID().uuidString.lowercased(),
                                           date: date,
                                           medicationID: medicationID,
                                           status: status,
                                           doseValue: doseValue,
                                           doseUnit: doseUnit,
                                           reason: reason,
                                           effectNote: effectNote,
                                           sideEffectNote: sideEffectNote,
                                           source: source)
    entity.occurredAt = EventTimestamp.from(date: date, time: time)
    context.insert(entity)
    commitDose(entity, op: "create")
    return entity
  }

  func updateDose(id: String,
                  date: String? = nil,
                  time: String? = nil,
                  medicationID: String? = nil,
                  status: String? = nil,
                  doseValue: Double?? = nil,
                  doseUnit: String?? = nil,
                  reason: String?? = nil,
                  effectNote: String?? = nil,
                  sideEffectNote: String?? = nil) {
    guard let entity = fetchDose(id: id) else { return }
    if let date { entity.date = date }
    if let medicationID { entity.medicationID = medicationID }
    if let status { entity.status = status }
    if let doseValue { entity.doseValue = doseValue }
    if let doseUnit { entity.doseUnit = doseUnit }
    if let reason { entity.reason = reason }
    if let effectNote { entity.effectNote = effectNote }
    if let sideEffectNote { entity.sideEffectNote = sideEffectNote }
    if date != nil || time != nil {
      let t = time ?? EventTimestamp.hhmm(from: entity.occurredAt)
      entity.occurredAt = EventTimestamp.from(date: entity.date, time: t)
    }
    entity.updatedAt = .now
    commitDose(entity, op: "update")
  }

  func deleteDose(id: String) {
    guard let entity = fetchDose(id: id) else { return }
    context.delete(entity)
    saveContext("CK medications delete")
    ckEngine?.noteMedicationDoseEventDeletion(id: id)
    postChanged()
  }

  private func fetchDefinition(id: String) -> MedicationDefinitionEntity? {
    try? context.fetch(FetchDescriptor<MedicationDefinitionEntity>(
      predicate: #Predicate { $0.id == id }
    )).first
  }

  private func fetchDose(id: String) -> MedicationDoseEventEntity? {
    try? context.fetch(FetchDescriptor<MedicationDoseEventEntity>(
      predicate: #Predicate { $0.id == id }
    )).first
  }

  private func nextDefinitionSortIndex() -> Int {
    ((try? context.fetch(FetchDescriptor<MedicationDefinitionEntity>(
      sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]
    )).first?.sortIndex) ?? -1) + 1
  }

  private func commitDefinition(_ entity: MedicationDefinitionEntity, op: String) {
    saveContext("CK medications definition \(op)")
    ckEngine?.noteMedicationDefinitionChange(id: entity.id)
    postChanged()
  }

  private func commitDose(_ entity: MedicationDoseEventEntity, op: String) {
    saveContext("CK medications dose \(op)")
    ckEngine?.noteMedicationDoseEventChange(id: entity.id)
    postChanged()
  }

  private func saveContext(_ label: String) {
    StoreHealth.save(context, op: label)
  }

  private func postChanged() {
    DataChange.post(Self.changeScope)
  }
}

// The single write boundary for the generic `intake` section — kinds, their
// item catalogs, and events (the generalization that retired the per-substance
// per-substance mutators): optimistic local write, CK enqueue, save, notify.
// Deletion posture is
// archive-only for kinds (no hard delete); items and events keep the legacy
// single-row delete (correction ≠ destruction). See docs/CONSUMABLES_PLAN.md.
@MainActor
@Observable
final class IntakeMutator {
  static let changeScope = "intake"
  private let context: ModelContext
  private var ckEngine: CKEngine?

  init(context: ModelContext, ckEngine: CKEngine? = nil) {
    self.context = context
    self.ckEngine = ckEngine
  }

  func bind(ckEngine: CKEngine) { self.ckEngine = ckEngine }

  // MARK: - Kinds

  @discardableResult
  func addKind(name: String,
               symbol: String = "circle",
               color: String = "",
               unit: String? = nil,
               doseStyle: String = "none",
               countNoun: String? = nil,
               containerNoun: String? = nil,
               containerCap: Int? = nil,
               catalogNoun: String? = nil,
               flourish: String = "bloom",
               metricMode: String = "countEvents",
               objective: String = "log",
               methods: [IntakeMethodRow] = [],
               templateID: String? = nil) -> IntakeKindEntity {
    let entity = IntakeKindEntity(id: uniqueKindID(),
                                  name: name,
                                  symbol: symbol,
                                  color: color,
                                  sortIndex: nextKindSortIndex(),
                                  unit: unit,
                                  doseStyle: doseStyle,
                                  countNoun: countNoun,
                                  containerNoun: containerNoun,
                                  containerCap: containerCap,
                                  catalogNoun: catalogNoun,
                                  flourish: flourish,
                                  metricMode: metricMode,
                                  objective: objective,
                                  templateID: templateID)
    entity.methods = methods
    context.insert(entity)
    commitKind(entity, op: "create")
    return entity
  }

  func updateKind(id: String,
                  name: String? = nil,
                  symbol: String? = nil,
                  color: String? = nil,
                  unit: String?? = nil,
                  doseStyle: String? = nil,
                  countNoun: String?? = nil,
                  containerNoun: String?? = nil,
                  containerCap: Int?? = nil,
                  catalogNoun: String?? = nil,
                  flourish: String? = nil,
                  metricMode: String? = nil,
                  objective: String? = nil,
                  methods: [IntakeMethodRow]? = nil) {
    guard let entity = fetchKind(id: id) else { return }
    if let name { entity.name = name }
    if let symbol { entity.symbol = symbol }
    if let color { entity.color = color }
    if let unit { entity.unit = unit }
    if let doseStyle { entity.doseStyle = doseStyle }
    if let countNoun { entity.countNoun = countNoun }
    if let containerNoun { entity.containerNoun = containerNoun }
    if let containerCap { entity.containerCap = containerCap }
    if let catalogNoun { entity.catalogNoun = catalogNoun }
    if let flourish { entity.flourish = flourish }
    if let metricMode { entity.metricMode = metricMode }
    if let objective { entity.objective = objective }
    if let methods { entity.methods = methods }
    entity.updatedAt = .now
    commitKind(entity, op: "update")
  }

  /// Hide-don't-delete: archived kinds drop their tile/drawer/metrics; events
  /// and items stay. `archivedAt: nil` unarchives.
  func setKindArchived(id: String, archived: Bool) {
    guard let entity = fetchKind(id: id) else { return }
    entity.archivedAt = archived ? .now : nil
    entity.updatedAt = .now
    commitKind(entity, op: archived ? "archive" : "unarchive")
  }

  // MARK: - Items (catalog)

  @discardableResult
  func addItem(kindID: String, name: String, emoji: String? = nil) -> IntakeItemEntity {
    let entity = IntakeItemEntity(id: uniqueItemID(),
                                  kindID: kindID,
                                  name: name,
                                  emoji: emoji,
                                  sortIndex: nextItemSortIndex(kindID: kindID))
    context.insert(entity)
    commitItem(entity, op: "create")
    return entity
  }

  func updateItem(id: String, name: String? = nil, emoji: String?? = nil) {
    guard let entity = fetchItem(id: id) else { return }
    if let name { entity.name = name }
    if let emoji { entity.emoji = emoji }
    entity.updatedAt = .now
    commitItem(entity, op: "update")
  }

  func deleteItem(id: String) {
    guard let entity = fetchItem(id: id) else { return }
    context.delete(entity)
    saveContext("CK intake-item delete")
    ckEngine?.noteIntakeItemDeletion(id: id)
    postChanged()
  }

  // MARK: - Events

  @discardableResult
  func addEntry(kindID: String,
                date: String,
                time: String,
                method: String,
                itemID: String? = nil,
                amount: Double? = nil,
                count: Int? = nil,
                // Free-form text defaults to "" so the field registers with
                // CloudKit on first in-app write. See GutMutator for details.
                note: String? = "") -> IntakeEventEntity {
    let entity = IntakeEventEntity(id: uniqueEntryID(),
                                   kindID: kindID,
                                   date: date,
                                   method: method,
                                   itemID: itemID,
                                   amount: amount,
                                   count: count,
                                   note: note)
    entity.occurredAt = EventTimestamp.from(date: date, time: time)
    context.insert(entity)
    commitEntry(entity, op: "create")
    return entity
  }

  func updateEntry(id: String,
                   date: String? = nil,
                   time: String? = nil,
                   method: String? = nil,
                   itemID: String?? = nil,
                   amount: Double?? = nil,
                   count: Int?? = nil,
                   note: String?? = nil) {
    guard let entity = fetchEntry(id: id) else { return }
    if let date { entity.date = date }
    if let method { entity.method = method }
    if let itemID { entity.itemID = itemID }
    if let amount { entity.amount = amount }
    if let count { entity.count = count }
    if let note { entity.note = note }
    if date != nil || time != nil {
      let t = time ?? EventTimestamp.hhmm(from: entity.occurredAt)
      entity.occurredAt = EventTimestamp.from(date: entity.date, time: t)
    }
    entity.updatedAt = .now
    commitEntry(entity, op: "update")
  }

  func deleteEntry(id: String) {
    guard let entity = fetchEntry(id: id) else { return }
    context.delete(entity)
    saveContext("CK intake-event delete")
    ckEngine?.noteIntakeEventDeletion(id: id)
    postChanged()
  }

  // MARK: - Kind creation (idempotent)

  /// Create a kind from a template seed if absent; if present, leave it
  /// untouched — the kind is user-owned after creation, so re-running must not
  /// clobber edits. Drives the first-enable template picker.
  @discardableResult
  func upsertKind(seed: IntakeKindSeed) -> IntakeKindEntity {
    if let existing = fetchKind(id: seed.id) { return existing }
    let entity = IntakeKindEntity(id: seed.id,
                                  name: seed.name,
                                  symbol: seed.symbol,
                                  color: seed.color,
                                  sortIndex: nextKindSortIndex(),
                                  unit: seed.unit,
                                  doseStyle: seed.doseStyle,
                                  countNoun: seed.countNoun,
                                  containerNoun: seed.containerNoun,
                                  containerCap: seed.containerCap,
                                  catalogNoun: seed.catalogNoun,
                                  flourish: seed.flourish,
                                  metricMode: seed.metricMode,
                                  objective: seed.objective,
                                  templateID: seed.templateID)
    entity.methods = seed.methods
    context.insert(entity)
    commitKind(entity, op: "create")
    return entity
  }

  // MARK: - Helpers

  private func fetchKind(id: String) -> IntakeKindEntity? {
    try? context.fetch(FetchDescriptor<IntakeKindEntity>(
      predicate: #Predicate { $0.id == id }
    )).first
  }

  private func fetchItem(id: String) -> IntakeItemEntity? {
    try? context.fetch(FetchDescriptor<IntakeItemEntity>(
      predicate: #Predicate { $0.id == id }
    )).first
  }

  private func fetchEntry(id: String) -> IntakeEventEntity? {
    try? context.fetch(FetchDescriptor<IntakeEventEntity>(
      predicate: #Predicate { $0.id == id }
    )).first
  }

  /// Opaque, name-independent kind ids — names are mutable, ids are forever
  /// (metric keys and item links hang off them). See §3.1.
  private func uniqueKindID() -> String {
    var attempt = "ik-" + String(UUID().uuidString.lowercased().prefix(8))
    while fetchKind(id: attempt) != nil {
      attempt = "ik-" + String(UUID().uuidString.lowercased().prefix(8))
    }
    return attempt
  }

  private func uniqueItemID() -> String {
    var attempt = "ii-" + String(UUID().uuidString.lowercased().prefix(8))
    while fetchItem(id: attempt) != nil {
      attempt = "ii-" + String(UUID().uuidString.lowercased().prefix(8))
    }
    return attempt
  }

  private func uniqueEntryID() -> String {
    var attempt = String(UUID().uuidString.lowercased().prefix(8))
    while fetchEntry(id: attempt) != nil {
      attempt = String(UUID().uuidString.lowercased().prefix(8))
    }
    return attempt
  }

  private func nextKindSortIndex() -> Int {
    ((try? context.fetch(FetchDescriptor<IntakeKindEntity>(
      sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]
    )).first?.sortIndex) ?? -1) + 1
  }

  private func nextItemSortIndex(kindID: String) -> Int {
    ((try? context.fetch(FetchDescriptor<IntakeItemEntity>(
      predicate: #Predicate { $0.kindID == kindID },
      sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]
    )).first?.sortIndex) ?? -1) + 1
  }

  private func commitKind(_ entity: IntakeKindEntity, op: String) {
    saveContext("CK intake-kind \(op)")
    ckEngine?.noteIntakeKindChange(id: entity.id)
    postChanged()
  }

  private func commitItem(_ entity: IntakeItemEntity, op: String) {
    saveContext("CK intake-item \(op)")
    ckEngine?.noteIntakeItemChange(id: entity.id)
    postChanged()
  }

  private func commitEntry(_ entity: IntakeEventEntity, op: String) {
    saveContext("CK intake-event \(op)")
    ckEngine?.noteIntakeEventChange(id: entity.id)
    postChanged()
  }

  private func saveContext(_ label: String) {
    StoreHealth.save(context, op: label)
  }

  private func postChanged() {
    DataChange.post(Self.changeScope)
  }
}


@MainActor
@Observable
final class GroceryMutator {
  static let changeScope = "groceries"
  private let context: ModelContext
  private var ckEngine: CKEngine?

  init(context: ModelContext, ckEngine: CKEngine? = nil) {
    self.context = context
    self.ckEngine = ckEngine
  }

  func bind(ckEngine: CKEngine) {
    self.ckEngine = ckEngine
  }

  // MARK: - Items

  @discardableResult
  func addItem(name: String, category: String, emoji: String = "") -> GroceryItemEntity {
    let id = uniqueItemID(for: name)
    let entity = GroceryItemEntity(id: id,
                                   name: name,
                                   category: category,
                                   emoji: emoji,
                                   low: false,
                                   sortIndex: nextItemSortIndex())
    context.insert(entity)
    commitItem(entity, op: "create")
    return entity
  }

  func updateItem(id: String,
                  name: String? = nil,
                  category: String? = nil,
                  emoji: String? = nil) {
    guard let entity = fetchItem(id: id) else { return }
    if let name { entity.name = name }
    if let category { entity.category = category }
    if let emoji { entity.emoji = emoji }
    entity.updatedAt = .now
    commitItem(entity, op: "update")
  }

  /// Toggle the `low` flag. Setting low=false stamps lastBought to today.
  func setLow(id: String, low: Bool) {
    guard let entity = fetchItem(id: id) else { return }
    entity.low = low
    if !low {
      entity.lastBought = SeptenaDate.today
    }
    entity.updatedAt = .now
    commitItem(entity, op: low ? "needed" : "bought")
  }

  func deleteItem(id: String) {
    guard let entity = fetchItem(id: id) else { return }
    context.delete(entity)
    saveContext("CK grocery item delete")
    ckEngine?.noteGroceryItemDeletion(id: id)
    postChanged()
  }

  // MARK: - Categories

  @discardableResult
  func addCategory(name: String) -> GroceryCategoryEntity {
    let id = uniqueCategoryID(for: name)
    let entity = GroceryCategoryEntity(id: id, name: name, sortIndex: nextCategorySortIndex())
    context.insert(entity)
    commitCategory(entity, op: "create")
    return entity
  }

  func updateCategory(id: String, name: String) {
    guard let entity = fetchCategory(id: id) else { return }
    entity.name = name
    entity.updatedAt = .now
    commitCategory(entity, op: "update")
  }

  func deleteCategory(id: String) {
    guard let entity = fetchCategory(id: id) else { return }
    context.delete(entity)
    saveContext("CK grocery category delete")
    ckEngine?.noteGroceryCategoryDeletion(id: id)
    postChanged()
  }

  // MARK: - Helpers

  private func fetchItem(id: String) -> GroceryItemEntity? {
    try? context.fetch(FetchDescriptor<GroceryItemEntity>(
      predicate: #Predicate { $0.id == id }
    )).first
  }

  private func fetchCategory(id: String) -> GroceryCategoryEntity? {
    try? context.fetch(FetchDescriptor<GroceryCategoryEntity>(
      predicate: #Predicate { $0.id == id }
    )).first
  }

  private func uniqueItemID(for name: String) -> String {
    var attempt = String(UUID().uuidString.lowercased().prefix(8))
    while fetchItem(id: attempt) != nil {
      attempt = String(UUID().uuidString.lowercased().prefix(8))
    }
    return attempt
  }

  private func uniqueCategoryID(for name: String) -> String {
    let base = name.lowercased()
      .replacingOccurrences(of: " ", with: "-")
      .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    var attempt = base.isEmpty ? IDShortcode.generate(length: 4) : base
    var n = 2
    while fetchCategory(id: attempt) != nil {
      attempt = "\(base)-\(n)"
      n += 1
    }
    return attempt
  }

  private func nextItemSortIndex() -> Int {
    ((try? context.fetch(FetchDescriptor<GroceryItemEntity>(
      sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]
    )).first?.sortIndex) ?? -1) + 1
  }

  private func nextCategorySortIndex() -> Int {
    ((try? context.fetch(FetchDescriptor<GroceryCategoryEntity>(
      sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]
    )).first?.sortIndex) ?? -1) + 1
  }

  private func commitItem(_ entity: GroceryItemEntity, op: String) {
    saveContext("CK grocery item \(op)")
    ckEngine?.noteGroceryItemChange(id: entity.id)
    postChanged()
  }

  private func commitCategory(_ entity: GroceryCategoryEntity, op: String) {
    saveContext("CK grocery category \(op)")
    ckEngine?.noteGroceryCategoryChange(id: entity.id)
    postChanged()
  }

  private func saveContext(_ label: String) {
    StoreHealth.save(context, op: label)
  }

  private func postChanged() {
    DataChange.post(Self.changeScope)
  }
}

// MARK: - TrainingMutator
//
// CloudKit-backed mutations for training entries + catalogs (exercise
// definitions, session types). Local-first: write to SwiftData, then queue
// the change with CKEngine for upload. Mirrors the Grocery/Caffeine pattern.

@MainActor
@Observable
final class TrainingMutator {
  static let changeScope = "training"
  private let context: ModelContext
  private var ckEngine: CKEngine?

  init(context: ModelContext, ckEngine: CKEngine? = nil) {
    self.context = context
    self.ckEngine = ckEngine
  }

  func bind(ckEngine: CKEngine) { self.ckEngine = ckEngine }

  // MARK: - Entries

  @discardableResult
  func addEntry(date: String,
                time: String,
                sessionType: String,
                exercise: String,
                weight: Double? = nil,
                sets: String? = nil,
                reps: String? = nil,
                difficulty: String? = nil,
                durationMin: Double? = nil,
                distanceM: Double? = nil,
                level: Double? = nil,
                note: String? = nil,
                concludedAt: String? = nil) -> ExerciseEntryEntity {
    let id = uniqueEntryID()
    // Tidy the name on the way in (case/separator cleanup only — see
    // CanonicalExerciseName.forStorage). Display still resolves through the
    // catalog, so this just stops new entries adding fresh casing drift.
    let entity = ExerciseEntryEntity(
      id: id,
      date: date,
      sessionType: sessionType,
      exercise: CanonicalExerciseName.forStorage(exercise),
      weight: weight,
      sets: sets,
      reps: reps,
      difficulty: difficulty,
      durationMin: durationMin,
      distanceM: distanceM,
      level: level,
      note: note,
      concludedAt: concludedAt,
      loggedAt: ISO8601DateFormatter().string(from: Date())
    )
    entity.occurredAt = EventTimestamp.from(date: date, time: time)
    context.insert(entity)
    commitEntry(entity, op: "create")
    // PR/XP detection at the write boundary; scoped to this exercise so the
    // scan stays narrow. Celebration is queued — the root presenter shows it.
    SeptenaServices.shared.milestoneMutator.evaluateTraining(
      now: .now, exercise: entity.exercise)
    return entity
  }

  /// Convenience: log a whole session in one call. Each entry shares a
  /// `concludedAt` stamp so views can group them as one workout.
  @discardableResult
  func addSession(date: String,
                  time: String,
                  sessionType: String,
                  entries: [TrainingEntryDraft]) -> [ExerciseEntryEntity] {
    let concluded = "\(date)T\(time.isEmpty ? "00:00" : time):00"
    var saved: [ExerciseEntryEntity] = []
    for draft in entries where !draft.skipped {
      let entity = addEntry(
        date: date,
        time: time,
        sessionType: sessionType,
        exercise: draft.exercise,
        weight: draft.weight,
        sets: draft.sets,
        reps: draft.reps,
        difficulty: draft.difficulty,
        durationMin: draft.durationMin,
        distanceM: draft.distanceM,
        level: draft.level,
        note: draft.note,
        concludedAt: concluded
      )
      saved.append(entity)
    }
    return saved
  }

  /// Result of a bulk history import, for the confirmation the user sees.
  struct TrainingImportOutcome: Sendable, Equatable {
    public var sessionsAdded = 0
    public var entriesAdded = 0
    /// Days that already carried training. Existing days win, so re-importing
    /// the same export is a no-op rather than a duplicated year.
    public var sessionsSkipped = 0
    public var definitionsCreated = 0
  }

  /// Write a parsed history from another app.
  ///
  /// Deliberately not `addSession` in a loop. That path saves the context,
  /// queues CloudKit and runs milestone detection **per entry** — over a
  /// multi-year export that is thousands of saves and thousands of PR scans,
  /// and the scans would queue a celebration for every record set in 2019.
  /// An import is history, not something that just happened, so it inserts in
  /// one pass, saves once, and skips milestone evaluation entirely.
  ///
  /// A date that already carries training is skipped whole. It is the one merge
  /// rule that makes importing twice safe, which matters because the first
  /// thing anyone does after an import that looks wrong is run it again.
  @discardableResult
  func importHistory(_ sessions: [ImportedSession]) -> TrainingImportOutcome {
    var outcome = TrainingImportOutcome()
    guard !sessions.isEmpty else { return outcome }

    let existing = (try? context.fetch(FetchDescriptor<ExerciseEntryEntity>())) ?? []
    // Built once. `uniqueEntryID()` fetches per call, which is fine for one
    // logged set and quadratic for ten thousand imported ones.
    var usedIDs = Set(existing.map(\.id))
    let occupiedDates = Set(existing.map(\.date))

    var knownKeys = Set(
      ((try? context.fetch(FetchDescriptor<ExerciseDefinitionEntity>())) ?? [])
        .flatMap { [exerciseKey($0.id), exerciseKey($0.name)] }
    )

    func freshID() -> String {
      var attempt = String(UUID().uuidString.lowercased().prefix(8))
      while usedIDs.contains(attempt) {
        attempt = String(UUID().uuidString.lowercased().prefix(8))
      }
      usedIDs.insert(attempt)
      return attempt
    }

    var pendingEntryIDs: [String] = []
    var pendingDefinitions: [ExerciseDefinitionEntity] = []
    var nextDefinitionIndex = nextDefinitionSortIndex()
    let loggedAt = ISO8601DateFormatter().string(from: Date())

    for session in sessions {
      guard !occupiedDates.contains(session.date) else {
        outcome.sessionsSkipped += 1
        continue
      }
      let time = session.time.isEmpty ? "12:00" : session.time
      let concluded = "\(session.date)T\(time):00"

      for entry in session.entries {
        let name = CanonicalExerciseName.forStorage(entry.exercise)
        // An unmatched name becomes a catalog entry rather than a loose string,
        // so it shows up in the picker and can be given muscle tags later —
        // untagged, because guessing a muscle from a name we already failed to
        // recognize would put wrong numbers on the balance screen.
        if !knownKeys.contains(exerciseKey(name)) {
          let type = (entry.distanceM ?? 0) > 0 || (entry.weight == nil && entry.reps == nil)
            ? "cardio" : "strength"
          let definition = ExerciseDefinitionEntity(id: uniqueDefinitionID(for: name),
                                                    name: name,
                                                    type: type,
                                                    sortIndex: nextDefinitionIndex)
          nextDefinitionIndex += 1
          context.insert(definition)
          pendingDefinitions.append(definition)
          knownKeys.insert(exerciseKey(name))
          knownKeys.insert(exerciseKey(definition.id))
          outcome.definitionsCreated += 1
        }

        let entity = ExerciseEntryEntity(
          id: freshID(),
          date: session.date,
          sessionType: session.sessionType,
          exercise: name,
          weight: entry.weight,
          sets: entry.sets,
          reps: entry.reps,
          difficulty: entry.difficulty,
          durationMin: entry.durationMin,
          distanceM: entry.distanceM,
          note: entry.note,
          concludedAt: concluded,
          loggedAt: loggedAt
        )
        entity.occurredAt = EventTimestamp.from(date: session.date, time: time)
        context.insert(entity)
        pendingEntryIDs.append(entity.id)
        outcome.entriesAdded += 1
      }
      outcome.sessionsAdded += 1
    }

    guard outcome.entriesAdded > 0 || outcome.definitionsCreated > 0 else { return outcome }
    saveContext("CK training import")
    for definition in pendingDefinitions {
      ckEngine?.noteExerciseDefinitionChange(id: definition.id)
    }
    for id in pendingEntryIDs {
      ckEngine?.noteExerciseEntryChange(id: id)
    }
    postChanged()
    return outcome
  }

  /// Partial update — every parameter defaults to "leave as-is". Identity
  /// fields (date/time/sessionType/exercise) take a single optional (nil =
  /// unchanged); nullable per-set metrics take a double optional so `.some(nil)`
  /// clears them. `exercise` gets the same key-preserving tidy as `addEntry`
  /// (`CanonicalExerciseName.forStorage`), so a caller can canonicalize a logged
  /// spelling without fragmenting its history — display, PR baselines and
  /// prefill all key off `exerciseKey`. A date or time change recomputes the
  /// canonical `occurredAt`, filling the missing half from the existing row
  /// (mirrors `IntakeMutator.updateEntry`). Returns the names of the fields
  /// actually written — mirrors the hosted gateway's `training_entry_update` so
  /// the MCP layer can report a real write vs a no-op instead of always echoing
  /// success.
  @discardableResult
  func updateEntry(id: String,
                   date: String? = nil,
                   time: String? = nil,
                   sessionType: String? = nil,
                   exercise: String? = nil,
                   weight: Double?? = nil,
                   sets: String?? = nil,
                   reps: String?? = nil,
                   difficulty: String?? = nil,
                   durationMin: Double?? = nil,
                   distanceM: Double?? = nil,
                   level: Double?? = nil,
                   note: String?? = nil,
                   concludedAt: String?? = nil,
                   endedAt: String?? = nil) -> [String] {
    guard let entity = fetchEntry(id: id) else { return [] }
    var changed: [String] = []
    if let date { entity.date = date; changed.append("date") }
    if let sessionType { entity.sessionType = sessionType; changed.append("sessionType") }
    if let exercise { entity.exercise = CanonicalExerciseName.forStorage(exercise); changed.append("exercise") }
    if let v = weight { entity.weight = v; changed.append("weight") }
    if let v = sets { entity.sets = v; changed.append("sets") }
    if let v = reps { entity.reps = v; changed.append("reps") }
    if let v = difficulty { entity.difficulty = v; changed.append("difficulty") }
    if let v = durationMin { entity.durationMin = v; changed.append("durationMin") }
    if let v = distanceM { entity.distanceM = v; changed.append("distanceM") }
    if let v = level { entity.level = v; changed.append("level") }
    if let v = note { entity.note = v; changed.append("note") }
    if let v = concludedAt { entity.concludedAt = v; changed.append("concludedAt") }
    if let v = endedAt { entity.endedAt = v; changed.append("endedAt") }
    if date != nil || time != nil {
      let t = time ?? EventTimestamp.hhmm(from: entity.occurredAt)
      entity.occurredAt = EventTimestamp.from(date: entity.date, time: t)
      changed.append("occurredAt")
    }
    guard !changed.isEmpty else { return [] }
    entity.updatedAt = .now
    commitEntry(entity, op: "update")
    return changed
  }

  /// Attach a free-text note to a session — written to the session's
  /// concluding entry (latest `occurredAt` among entries sharing date +
  /// sessionType). A "session" is just that bucket (same model as
  /// `retagSession`), so there's no dedicated record to hang it on. Empty
  /// note clears it. Returns true if an entry was found to write to.
  @discardableResult
  func setSessionNote(date: String, sessionType: String, note: String) -> Bool {
    guard let concluding = concludingEntry(date: date, sessionType: sessionType) else { return false }
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    updateEntry(id: concluding.id, note: .some(trimmed.isEmpty ? nil : trimmed))
    return true
  }

  /// Persist session end time on the concluding entry. Local ISO8601 wall-clock
  /// (`YYYY-MM-DDTHH:mm:ss`), same format as `concludedAt`. Nil clears.
  @discardableResult
  func setSessionEndedAt(date: String, sessionType: String, endedAt: String?) -> Bool {
    guard let concluding = concludingEntry(date: date, sessionType: sessionType) else { return false }
    let trimmed = endedAt?.trimmingCharacters(in: .whitespacesAndNewlines)
    updateEntry(id: concluding.id, endedAt: .some(trimmed?.isEmpty == true ? nil : trimmed))
    return true
  }

  /// Bulk-set session start (`concludedAt`) on every entry in the bucket.
  @discardableResult
  func setSessionStartedAt(date: String, sessionType: String, startedAt: String) -> Int {
    let entries = sessionEntries(date: date, sessionType: sessionType)
    guard !entries.isEmpty else { return 0 }
    for entity in entries {
      entity.concludedAt = startedAt
      entity.updatedAt = .now
      ckEngine?.noteExerciseEntryChange(id: entity.id)
    }
    saveContext("CK exercise session start \(date)")
    postChanged()
    return entries.count
  }

  func deleteEntry(id: String) {
    guard let entity = fetchEntry(id: id) else { return }
    context.delete(entity)
    saveContext("CK exercise entry delete")
    ckEngine?.noteExerciseEntryDeletion(id: id)
    postChanged()
  }

  /// Bulk-set sessionType on every ExerciseEntry for the given date. Mirrors
  /// the MCP gateway's `training_session_retag` — the data model has no
  /// dedicated TrainingSession record, so a "session" is just the bucket of
  /// entries sharing (date, sessionType). Used by the daily-list header menu
  /// to retroactively mark a day as Upper/Lower/Cardio/Yoga/etc.
  @discardableResult
  func retagSession(date: String, to newSessionType: String) -> Int {
    let entries = (try? context.fetch(
      FetchDescriptor<ExerciseEntryEntity>(predicate: #Predicate { $0.date == date })
    )) ?? []
    guard !entries.isEmpty else { return 0 }
    for entity in entries {
      entity.sessionType = newSessionType
      entity.updatedAt = .now
      ckEngine?.noteExerciseEntryChange(id: entity.id)
    }
    saveContext("CK exercise session retag \(date) -> \(newSessionType)")
    postChanged()
    return entries.count
  }

  // MARK: - Exercise definitions

  @discardableResult
  func addExerciseDefinition(name: String, type: String, subgroup: String? = nil) -> ExerciseDefinitionEntity {
    let id = uniqueDefinitionID(for: name)
    let entity = ExerciseDefinitionEntity(id: id,
                                          name: name,
                                          type: type,
                                          subgroup: subgroup,
                                          sortIndex: nextDefinitionSortIndex())
    context.insert(entity)
    commitDefinition(entity, op: "create")
    return entity
  }

  func updateExerciseDefinition(id: String,
                                name: String? = nil,
                                type: String? = nil,
                                subgroup: String?? = nil,
                                aliases: [String]? = nil,
                                primaryMuscle: String?? = nil,
                                secondaryMuscles: [String]? = nil,
                                archived: Bool? = nil) {
    guard let entity = fetchDefinition(id: id) else { return }
    if let name { entity.name = name }
    if let type { entity.type = type }
    if let subgroup { entity.subgroup = subgroup }
    if let aliases { entity.aliases = aliases }
    // Double-optional: nil = leave as-is, .some(nil) = clear the muscle.
    if let primaryMuscle { entity.primaryMuscle = primaryMuscle }
    if let secondaryMuscles { entity.secondaryMuscles = secondaryMuscles }
    if let archived { entity.archived = archived }
    entity.updatedAt = .now
    commitDefinition(entity, op: "update")
  }

  func deleteExerciseDefinition(id: String) {
    guard let entity = fetchDefinition(id: id) else { return }
    context.delete(entity)
    saveContext("CK exercise definition delete")
    ckEngine?.noteExerciseDefinitionDeletion(id: id)
    postChanged()
  }

  // MARK: - Session types

  @discardableResult
  func addSessionType(id: String? = nil,
                      label: String,
                      emoji: String? = nil,
                      exercises: [String] = [],
                      kind: SessionKind? = nil) -> SessionTypeEntity {
    // Seed the id from an explicit canonical key when given ('upper'), else from
    // the label; `uniqueSessionTypeID` slugifies + de-dupes either way so the id
    // stays a clean, collision-free key. Callers read the resolved id back off
    // the returned entity.
    let resolvedID = uniqueSessionTypeID(for: (id?.isEmpty == false) ? id! : label)
    let entity = SessionTypeEntity(id: resolvedID,
                                   label: label,
                                   emoji: emoji,
                                   exercises: exercises,
                                   sortIndex: nextSessionTypeSortIndex(),
                                   kindRaw: kind?.rawValue)
    context.insert(entity)
    commitSessionType(entity, op: "create")
    return entity
  }

  func updateSessionType(id: String,
                         label: String? = nil,
                         emoji: String?? = nil,
                         exercises: [String]? = nil,
                         kind: SessionKind? = nil,
                         archived: Bool? = nil) {
    guard let entity = fetchSessionType(id: id) else { return }
    if let label { entity.label = label }
    if let emoji { entity.emoji = emoji }
    if let exercises { entity.exercises = exercises }
    if let kind { entity.kindRaw = kind.rawValue }
    if let archived { entity.archived = archived }
    entity.updatedAt = .now
    commitSessionType(entity, op: "update")
  }

  func deleteSessionType(id: String) {
    guard let entity = fetchSessionType(id: id) else { return }
    context.delete(entity)
    saveContext("CK session type delete")
    ckEngine?.noteSessionTypeDeletion(id: id)
    postChanged()
  }

  // MARK: - Helpers

  private func sessionEntries(date: String, sessionType: String) -> [ExerciseEntryEntity] {
    (try? context.fetch(FetchDescriptor<ExerciseEntryEntity>(
      predicate: #Predicate { $0.date == date && $0.sessionType == sessionType }
    ))) ?? []
  }

  private func concludingEntry(date: String, sessionType: String) -> ExerciseEntryEntity? {
    sessionEntries(date: date, sessionType: sessionType)
      .max(by: { $0.occurredAt < $1.occurredAt })
  }

  private func fetchEntry(id: String) -> ExerciseEntryEntity? {
    try? context.fetch(FetchDescriptor<ExerciseEntryEntity>(predicate: #Predicate { $0.id == id })).first
  }
  private func fetchDefinition(id: String) -> ExerciseDefinitionEntity? {
    try? context.fetch(FetchDescriptor<ExerciseDefinitionEntity>(predicate: #Predicate { $0.id == id })).first
  }
  private func fetchSessionType(id: String) -> SessionTypeEntity? {
    try? context.fetch(FetchDescriptor<SessionTypeEntity>(predicate: #Predicate { $0.id == id })).first
  }

  private func uniqueEntryID() -> String {
    var attempt = String(UUID().uuidString.lowercased().prefix(8))
    while fetchEntry(id: attempt) != nil {
      attempt = String(UUID().uuidString.lowercased().prefix(8))
    }
    return attempt
  }

  private func slugify(_ s: String) -> String {
    s.lowercased()
      .replacingOccurrences(of: " ", with: "-")
      .filter { $0.isLetter || $0.isNumber || $0 == "-" }
  }

  private func uniqueDefinitionID(for name: String) -> String {
    let base = slugify(name)
    var attempt = base.isEmpty ? IDShortcode.generate(length: 4) : base
    var n = 2
    while fetchDefinition(id: attempt) != nil {
      attempt = "\(base)-\(n)"
      n += 1
    }
    return attempt
  }

  private func uniqueSessionTypeID(for label: String) -> String {
    let base = slugify(label)
    var attempt = base.isEmpty ? IDShortcode.generate(length: 4) : base
    var n = 2
    while fetchSessionType(id: attempt) != nil {
      attempt = "\(base)-\(n)"
      n += 1
    }
    return attempt
  }

  private func nextDefinitionSortIndex() -> Int {
    ((try? context.fetch(FetchDescriptor<ExerciseDefinitionEntity>(
      sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]
    )).first?.sortIndex) ?? -1) + 1
  }

  private func nextSessionTypeSortIndex() -> Int {
    ((try? context.fetch(FetchDescriptor<SessionTypeEntity>(
      sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]
    )).first?.sortIndex) ?? -1) + 1
  }

  private func commitEntry(_ entity: ExerciseEntryEntity, op: String) {
    saveContext("CK exercise entry \(op)")
    ckEngine?.noteExerciseEntryChange(id: entity.id)
    postChanged()
  }

  private func commitDefinition(_ entity: ExerciseDefinitionEntity, op: String) {
    saveContext("CK exercise definition \(op)")
    ckEngine?.noteExerciseDefinitionChange(id: entity.id)
    postChanged()
  }

  private func commitSessionType(_ entity: SessionTypeEntity, op: String) {
    saveContext("CK session type \(op)")
    ckEngine?.noteSessionTypeChange(id: entity.id)
    postChanged()
  }

  private func saveContext(_ label: String) {
    StoreHealth.save(context, op: label)
  }

  private func postChanged() {
    DataChange.post(Self.changeScope)
  }
}

/// Lightweight draft used by `TrainingMutator.addSession` so callers don't
/// have to pass a dozen positional arguments per exercise.
struct TrainingEntryDraft {
  var exercise: String
  var weight: Double? = nil
  var sets: String? = nil
  var reps: String? = nil
  var difficulty: String? = nil
  var durationMin: Double? = nil
  var distanceM: Double? = nil
  var level: Double? = nil
  var note: String? = nil
  var skipped: Bool = false
}

// MARK: - NutritionMutator
//
// CloudKit-backed mutations for nutrition entries and daily summaries.
// Local-first: write to SwiftData, rebuild the day summary, then queue
// with CKEngine. Mirrors the Grocery/Training pattern.

@MainActor
@Observable
final class NutritionMutator {
  static let changeScope = "nutrition"
  private let context: ModelContext
  private var ckEngine: CKEngine?

  init(context: ModelContext, ckEngine: CKEngine? = nil) {
    self.context = context
    self.ckEngine = ckEngine
  }

  func bind(ckEngine: CKEngine) {
    self.ckEngine = ckEngine
  }

  @discardableResult
  func addEntry(loggedAt: Date,
                // Free-form text defaults to "" so these fields register
                // with CloudKit on first in-app write. mealType stays nil —
                // it's an enum (breakfast|lunch|dinner|snack) and "" isn't
                // a valid value.
                emoji: String? = "",
                foods: [String],
                ingredients: [String]? = nil,
                note: String? = "",
                mealType: String? = nil,
                // Default "manual" — every entry written through this mutator
                // is user-initiated in the app. Callers that aren't (bootstrap,
                // import, MCP) pass their own value. This also guarantees the
                // `source` field gets populated on at least one record, which
                // is what registers the field with CloudKit so the Web Services
                // API (used by the MCP gateway) can write to it.
                source: String? = "manual",
                proteinG: Double = 0,
                fatG: Double = 0,
                carbsG: Double = 0,
                fiberG: Double? = nil,
                sugarG: Double? = nil,
                saturatedFatG: Double? = nil,
                alcoholG: Double? = nil,
                kcal: Double? = nil,
                sodiumMg: Double? = nil,
                cholesterolMg: Double? = nil,
                potassiumMg: Double? = nil,
                waterMl: Double? = nil,
                photoAssetID: String? = nil) -> NutritionEntryEntity {
    let id = generateID()
    let now = Date.now
    let joinedIngredients = ingredients?.filter { !$0.isEmpty }.joined(separator: "\n")
    let entity = NutritionEntryEntity(
      id: id, loggedAt: loggedAt, updatedAt: now,
      emoji: emoji, foods: foods.joined(separator: "\n"),
      ingredients: joinedIngredients.flatMap { $0.isEmpty ? nil : $0 },
      note: note, mealType: mealType, source: source,
      proteinG: proteinG, fatG: fatG, carbsG: carbsG,
      fiberG: fiberG, sugarG: sugarG, saturatedFatG: saturatedFatG,
      alcoholG: alcoholG, kcal: kcal,
      sodiumMg: sodiumMg, cholesterolMg: cholesterolMg,
      potassiumMg: potassiumMg, waterMl: waterMl,
      photoAssetID: photoAssetID,
      cloudKitSystemFields: nil
    )
    context.insert(entity)
    rebuildSummary(forDay: dayID(from: loggedAt))
    commitEntry(entity, op: "create")
    let ts = loggedAt
    Task {
      await HealthKitBridge.shared.writeNutritionEntry(
        kcal: kcal, proteinG: proteinG, fatG: fatG, carbsG: carbsG,
        fiberG: fiberG, sugarG: sugarG,
        sodiumMg: sodiumMg, cholesterolMg: cholesterolMg,
        waterMl: waterMl, date: ts)
    }
    return entity
  }

  func updateEntry(id: String,
                   pickedAt: Date? = nil,
                   emoji: String? = nil,
                   foods: [String]? = nil,
                   ingredients: [String]? = nil,
                   note: String? = nil,
                   mealType: String? = nil,
                   proteinG: Double? = nil,
                   fatG: Double? = nil,
                   carbsG: Double? = nil,
                   fiberG: Double? = nil,
                   sugarG: Double? = nil,
                   saturatedFatG: Double? = nil,
                   alcoholG: Double? = nil,
                   kcal: Double? = nil,
                   sodiumMg: Double? = nil,
                   cholesterolMg: Double? = nil,
                   potassiumMg: Double? = nil,
                   waterMl: Double? = nil,
                   photoAssetID: String?? = nil) {
    guard let entity = fetchEntry(id: id) else { return }
    let oldDay = dayID(from: entity.loggedAt)
    // `pickedAt` carries both day and time-of-day; assign directly so the
    // edit sheet's date picker can move an entry between days.
    if let pickedAt { entity.loggedAt = pickedAt }
    if let emoji { entity.emoji = emoji }
    if let foods { entity.foods = foods.joined(separator: "\n") }
    if let ingredients {
      let joined = ingredients.filter { !$0.isEmpty }.joined(separator: "\n")
      entity.ingredients = joined.isEmpty ? nil : joined
    }
    if let note { entity.note = note }
    if let mealType { entity.mealType = mealType }
    if let proteinG { entity.proteinG = proteinG }
    if let fatG { entity.fatG = fatG }
    if let carbsG { entity.carbsG = carbsG }
    if let fiberG { entity.fiberG = fiberG }
    if let sugarG { entity.sugarG = sugarG }
    if let saturatedFatG { entity.saturatedFatG = saturatedFatG }
    if let alcoholG { entity.alcoholG = alcoholG }
    if let kcal { entity.kcal = kcal }
    if let sodiumMg { entity.sodiumMg = sodiumMg }
    if let cholesterolMg { entity.cholesterolMg = cholesterolMg }
    if let potassiumMg { entity.potassiumMg = potassiumMg }
    if let waterMl { entity.waterMl = waterMl }
    // Double-optional: outer `.some(_)` means caller wants to write, inner
    // value may be nil to clear the attachment.
    if let photoAssetID { entity.photoAssetID = photoAssetID }
    entity.updatedAt = .now
    let newDay = dayID(from: entity.loggedAt)
    rebuildSummary(forDay: oldDay)
    if newDay != oldDay { rebuildSummary(forDay: newDay) }
    commitEntry(entity, op: "update")
  }

  func deleteEntry(id: String) {
    guard let entity = fetchEntry(id: id) else { return }
    let day = dayID(from: entity.loggedAt)
    context.delete(entity)
    rebuildSummary(forDay: day)
    saveContext("CK nutrition entry delete")
    ckEngine?.noteNutritionEntryDeletion(id: id)
    postChanged()
  }

  // MARK: - Helpers

  private func rebuildSummary(forDay day: String) {
    let entries = (try? context.fetch(FetchDescriptor<NutritionEntryEntity>())) ?? []
    let dayEntries = entries.filter { dayID(from: $0.loggedAt) == day }

    if dayEntries.isEmpty {
      if let existing = fetchSummary(id: day) {
        context.delete(existing)
        saveContext("CK nutrition day summary delete")
        ckEngine?.noteNutritionDayDeletion(id: day)
      }
      return
    }

    let sorted = dayEntries.sorted { $0.loggedAt < $1.loggedAt }
    let totalKcal = dayEntries.reduce(0.0) { sum, e in
      sum + (e.kcal ?? (4 * e.proteinG + 9 * e.fatG + 4 * e.carbsG + 7 * (e.alcoholG ?? 0)))
    }
    let sumOpt: (KeyPath<NutritionEntryEntity, Double?>) -> Double? = { kp in
      let vals = dayEntries.compactMap { $0[keyPath: kp] }
      return vals.isEmpty ? nil : vals.reduce(0, +)
    }

    let existing = fetchSummary(id: day)
    let summary = existing ?? NutritionDailySummaryEntity(
      id: day, date: day, entryCount: 0,
      firstLoggedAt: nil, lastLoggedAt: nil, computedAt: .now,
      kcal: nil, proteinG: nil, fatG: nil, carbsG: nil,
      fiberG: nil, sugarG: nil, saturatedFatG: nil, alcoholG: nil,
      sodiumMg: nil, cholesterolMg: nil, potassiumMg: nil, waterMl: nil,
      cloudKitSystemFields: nil
    )
    if existing == nil { context.insert(summary) }

    summary.entryCount = dayEntries.count
    summary.firstLoggedAt = sorted.first?.loggedAt
    summary.lastLoggedAt = sorted.last?.loggedAt
    summary.computedAt = .now
    summary.kcal = totalKcal > 0 ? totalKcal : nil
    summary.proteinG = dayEntries.reduce(0, { $0 + $1.proteinG }) > 0
      ? dayEntries.reduce(0, { $0 + $1.proteinG }) : nil
    summary.fatG = dayEntries.reduce(0, { $0 + $1.fatG }) > 0
      ? dayEntries.reduce(0, { $0 + $1.fatG }) : nil
    summary.carbsG = dayEntries.reduce(0, { $0 + $1.carbsG }) > 0
      ? dayEntries.reduce(0, { $0 + $1.carbsG }) : nil
    summary.fiberG = sumOpt(\.fiberG)
    summary.sugarG = sumOpt(\.sugarG)
    summary.saturatedFatG = sumOpt(\.saturatedFatG)
    summary.alcoholG = sumOpt(\.alcoholG)
    summary.sodiumMg = sumOpt(\.sodiumMg)
    summary.cholesterolMg = sumOpt(\.cholesterolMg)
    summary.potassiumMg = sumOpt(\.potassiumMg)
    summary.waterMl = sumOpt(\.waterMl)

    saveContext("CK nutrition day summary rebuild")
    ckEngine?.noteNutritionDayChange(id: day)
  }

  private func fetchEntry(id: String) -> NutritionEntryEntity? {
    try? context.fetch(FetchDescriptor<NutritionEntryEntity>(
      predicate: #Predicate { $0.id == id }
    )).first
  }

  private func fetchSummary(id: String) -> NutritionDailySummaryEntity? {
    try? context.fetch(FetchDescriptor<NutritionDailySummaryEntity>(
      predicate: #Predicate { $0.id == id }
    )).first
  }

  private func generateID() -> String {
    var attempt = IDShortcode.generate(length: 8)
    while fetchEntry(id: attempt) != nil {
      attempt = IDShortcode.generate(length: 8)
    }
    return attempt
  }

  private func dayID(from date: Date) -> String {
    let cal = Calendar.current
    let comps = cal.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
  }

  private func commitEntry(_ entity: NutritionEntryEntity, op: String) {
    saveContext("CK nutrition entry \(op)")
    ckEngine?.noteNutritionEntryChange(id: entity.id)
    postChanged()
  }

  private func saveContext(_ label: String) {
    StoreHealth.save(context, op: label)
  }

  private func postChanged() {
    DataChange.post(Self.changeScope)
  }
}
@MainActor
@Observable
final class MoodMutator {
  static let changeScope = "mood"
  private let context: ModelContext

  init(context: ModelContext) {
    self.context = context
  }

  /// Buckets a wall-clock time string into morning / afternoon / evening
  /// via the canonical `DayBucket`. Thin wrapper kept for call-site
  /// readability — the rule lives in `DayBucket.from(time:)`.
  static func bucket(for time: String) -> String {
    DayBucket.from(time: time).rawValue
  }

  @discardableResult
  func logEntry(date: String,
                time: String,
                quadrant: String,
                arousal: Int,
                valence: Int,
                emotion: String,
                note: String? = nil) -> MoodEventEntity {
    let id = uniqueEntryID()
    let entity = MoodEventEntity(id: id,
                                 date: date,
                                 bucket: Self.bucket(for: time),
                                 quadrant: quadrant,
                                 arousal: arousal,
                                 valence: valence,
                                 emotion: emotion,
                                 note: (note?.isEmpty ?? true) ? nil : note)
    entity.occurredAt = EventTimestamp.from(date: date, time: time)
    context.insert(entity)
    save("CK mood create")
    SeptenaServices.shared.ckEngine.noteMoodEventChange(id: id)
    postChanged()
    let ts = entity.occurredAt
    Task {
      let uuid = await HealthKitBridge.shared.writeMood(quadrant: quadrant,
                                                        valence: valence, emotion: emotion, date: ts)
      if let uuid {
        entity.hkSampleID = uuid
        self.save("HK mood uuid")
      }
    }
    return entity
  }

  func updateEntry(id: String,
                   date: String? = nil,
                   time: String? = nil,
                   quadrant: String? = nil,
                   arousal: Int? = nil,
                   valence: Int? = nil,
                   emotion: String? = nil,
                   note: String?? = nil) {
    guard let entity = fetch(id: id) else { return }
    let needsHKSync = date != nil || time != nil || quadrant != nil || valence != nil || emotion != nil
    let oldHKID = needsHKSync ? entity.hkSampleID : nil
    if let date { entity.date = date }
    if let time { entity.bucket = Self.bucket(for: time) }
    if let quadrant { entity.quadrant = quadrant }
    if let arousal { entity.arousal = arousal }
    if let valence { entity.valence = valence }
    if let emotion { entity.emotion = emotion }
    if let note { entity.note = (note?.isEmpty ?? true) ? nil : note }
    // `time` STRING retired: fold a day/time change into the canonical occurredAt.
    if date != nil || time != nil {
      let t = time ?? EventTimestamp.hhmm(from: entity.occurredAt)
      entity.occurredAt = EventTimestamp.from(date: entity.date, time: t)
    }
    entity.updatedAt = .now
    if needsHKSync {
      entity.hkSampleID = nil
      let ts = entity.occurredAt
      let q = entity.quadrant
      let v = entity.valence
      let em = entity.emotion
      Task {
        if let oldID = oldHKID {
          await HealthKitBridge.shared.deleteMoodSample(uuid: oldID)
        }
        let uuid = await HealthKitBridge.shared.writeMood(quadrant: q, valence: v, emotion: em, date: ts)
        if let uuid {
          entity.hkSampleID = uuid
          self.save("HK mood uuid update")
        }
      }
    }
    save("CK mood update")
    SeptenaServices.shared.ckEngine.noteMoodEventChange(id: id)
    postChanged()
  }

  func deleteEntry(id: String) {
    guard let entity = fetch(id: id) else { return }
    let hkID = entity.hkSampleID
    context.delete(entity)
    save("CK mood delete")
    SeptenaServices.shared.ckEngine.noteMoodEventDeletion(id: id)
    postChanged()
    if let hkID {
      Task {
        await HealthKitBridge.shared.deleteMoodSample(uuid: hkID)
      }
    }
  }

  private func fetch(id: String) -> MoodEventEntity? {
    try? context.fetch(FetchDescriptor<MoodEventEntity>(
      predicate: #Predicate { $0.id == id }
    )).first
  }

  private func uniqueEntryID() -> String {
    var attempt = String(UUID().uuidString.lowercased().prefix(8))
    while fetch(id: attempt) != nil {
      attempt = String(UUID().uuidString.lowercased().prefix(8))
    }
    return attempt
  }

  private func save(_ label: String) {
    StoreHealth.save(context, op: label)
  }

  private func postChanged() {
    DataChange.post(Self.changeScope)
  }
}
