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

  private init() {
    let context = LocalStore.shared.container.mainContext
    self.ckEngine = CKEngine()
    self.taskMutator = TaskMutator(context: context, ckEngine: nil)
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

  /// The section keys that are active right now — `isEnabled` AND, when
  /// `section_order` is non-empty, present in that order. The single gate
  /// shared by the MCP tool list (`MCPDispatch`) and the App Intents surface
  /// (`SectionLogIntent.requireSection`) so both honor the SAME enabled-section
  /// rule. Mirrors the gateway's tools/list rule: a half-configured section
  /// (enabled but absent from the order) is NOT active, and no sections at all
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
  /// could race the scene and hit `TaskMutator.create` with `cloudBackend
  /// == nil`, silently falling back to FastAPI.
  func start() async {
    if let existing = startTask {
      await existing.value
      return
    }
    let task = Task { @MainActor [self] in
      let context = LocalStore.shared.container.mainContext
      let settingsSingletonID = SettingsCloudKitSchema.singletonID

      // Backfill: ensure every SectionManifest entry has a local
      // SectionEntity row so the central store is the source of truth
      // for which sections exist and whether they're enabled. Each
      // missing row is seeded with manifest-derived defaults
      // (`defaultEnabled`); existing rows (including user toggles) are
      // left alone.
      // Order matters: backfill runs BEFORE seeding so newly inserted
      // sections (with manifest-derived hasOnboarded values) aren't
      // accidentally clobbered by the legacy migration.
      PerfTrace.spanSync("start.seedSections") {
        SettingsMirror.backfillHasOnboardedForLegacySections(context: context)
        // A fresh account has zero SectionEntity rows before this loop. Seed
        // everything OFF in that case so the first-run welcome starts from a
        // blank slate (no pre-selected sections behind it); an account that
        // already has rows seeds any newly-shipped section from its default.
        let existingSectionCount =
          (try? context.fetchCount(FetchDescriptor<SectionEntity>())) ?? 0
        let isFreshAccount = existingSectionCount == 0
        var seededAny = false
        for manifest in SectionManifest.all {
          if SettingsMirror.seedManifestSectionIfMissing(
            manifest.key, context: context, freshAccount: isFreshAccount) {
            seededAny = true
          }
        }
        if seededAny {
          NotificationCenter.default.post(name: .septenaDataChanged, object: nil)
        }
      }
      var batchTouchedTasks = false
      var batchTouchedStructure = false
      var batchTouchedData = false
      // Per-batch apply counter — printed by `applyDidFinishBatch` so the Perf
      // log shows how many records each CloudKit delta materialized on the main
      // actor (each is a synchronous fetch-by-id; a large delta is a stall).
      var batchApplied = 0

      // Single-row lookup for the CK closures below: every fetch here
      // resolves a unique id, so cap at one match and stop scanning.
      func one<E: PersistentModel>(_ descriptor: FetchDescriptor<E>) -> E? {
        var d = descriptor
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
      }

      // Single dispatcher for outbound records. CK record IDs are
      // zone-wide, so Area/Project record names are type-prefixed to
      // avoid natural-id collisions like area "septena" and project
      // "septena".
      ckEngine.recordProvider = { recordID in
        let recordName = recordID.recordName
        if recordName.hasPrefix("area:") {
          let id = AreaCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<AreaEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("project:") {
          let id = ProjectCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<ProjectEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("section:") {
          let id = SectionCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<SectionEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("habit-def:") {
          let id = HabitDefinitionCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<HabitDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("habit-event:") {
          let id = HabitEventCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<HabitDayStateEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("supplement-def:") {
          let id = SupplementDefinitionCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<SupplementDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("supplement-event:") {
          let id = SupplementEventCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<SupplementDayStateEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("chore-def:") {
          let id = ChoreDefinitionCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<ChoreDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("chore-event:") {
          let id = ChoreEventCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<ChoreEventEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("goal:") {
          let id = GoalCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<GoalEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("gms:") {
          let id = GoalMilestoneCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<GoalMilestoneEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("coachVoice:") {
          let id = CoachVoiceCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<CoachVoiceEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("coachMsg:") {
          let id = CoachMessageCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<CoachMessageEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("gut-event:") {
          let id = GutEventCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<GutEventEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("mood-event:") {
          let id = MoodEventCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<MoodEventEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("oura-night:") {
          let id = OuraNightCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<OuraNightEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("quote:") {
          let id = QuoteCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<QuoteEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("withings-row:") {
          let id = WithingsRowCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<WithingsRowEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("intake-kind:") {
          let id = IntakeKindCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<IntakeKindEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("intake-item:") {
          let id = IntakeItemCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<IntakeItemEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("intake-event:") {
          let id = IntakeEventCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<IntakeEventEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("symptom-definition:") {
          let id = SymptomDefinitionCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<SymptomDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("symptom-event:") {
          let id = SymptomEventCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<SymptomEventEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("medication-definition:") {
          let id = MedicationDefinitionCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<MedicationDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("medication-dose-event:") {
          let id = MedicationDoseEventCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<MedicationDoseEventEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("grocery-item:") {
          let id = GroceryItemCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<GroceryItemEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("grocery-cat:") {
          let id = GroceryCategoryCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<GroceryCategoryEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("exercise-entry:") {
          let id = ExerciseEntryCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<ExerciseEntryEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("exercise-def:") {
          let id = ExerciseDefinitionCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<ExerciseDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("session-type:") {
          let id = SessionTypeCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<SessionTypeEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("nutrition-entry:") {
          let id = NutritionEntryCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<NutritionEntryEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("nutrition-day:") {
          let id = NutritionDailySummaryCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<NutritionDailySummaryEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("activity-day:") {
          let id = ActivityDayCloudKitSchema.entityID(from: recordName)
          if let entity = one(FetchDescriptor<ActivityDayEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName == SettingsCloudKitSchema.singletonID {
          if let entity = one(FetchDescriptor<SettingsEntity>(
            predicate: #Predicate { $0.id == settingsSingletonID }
          )) {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        let id = recordName
        if let entity = one(FetchDescriptor<TaskEntity>(
          predicate: #Predicate { $0.id == id }
        )) {
          return entity.toCloudKitRecord()
        }
        return nil
      }
      ckEngine.applyFetchedRecord = { record in
        batchApplied += 1
        switch record.recordType {
        case TaskCloudKitSchema.recordType:
          batchTouchedTasks = true
          let id = record.recordID.recordName
          if let entity = one(FetchDescriptor<TaskEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(TaskEntity(cloudKit: record))
          }
        case ProjectCloudKitSchema.recordType:
          batchTouchedStructure = true
          let id = ProjectCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<ProjectEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(ProjectEntity(cloudKit: record))
          }
        case AreaCloudKitSchema.recordType:
          batchTouchedStructure = true
          let id = AreaCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<AreaEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(AreaEntity(cloudKit: record))
          }
        case SettingsCloudKitSchema.recordType:
          batchTouchedData = true
          if let entity = one(FetchDescriptor<SettingsEntity>(
            predicate: #Predicate { $0.id == settingsSingletonID }
          )) {
            entity.apply(record)
          } else {
            context.insert(SettingsEntity(cloudKit: record))
          }
        case SectionCloudKitSchema.recordType:
          batchTouchedData = true
          let id = SectionCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<SectionEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(SectionEntity(cloudKit: record))
          }
        case HabitDefinitionCloudKitSchema.recordType:
          batchTouchedData = true
          let id = HabitDefinitionCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<HabitDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(HabitDefinitionEntity(cloudKit: record))
          }
        case HabitEventCloudKitSchema.recordType:
          batchTouchedData = true
          let id = HabitEventCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<HabitDayStateEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(HabitDayStateEntity(cloudKit: record))
          }
        case SupplementDefinitionCloudKitSchema.recordType:
          batchTouchedData = true
          let id = SupplementDefinitionCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<SupplementDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(SupplementDefinitionEntity(cloudKit: record))
          }
        case SupplementEventCloudKitSchema.recordType:
          batchTouchedData = true
          let id = SupplementEventCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<SupplementDayStateEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(SupplementDayStateEntity(cloudKit: record))
          }
        case ChoreDefinitionCloudKitSchema.recordType:
          batchTouchedData = true
          let id = ChoreDefinitionCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<ChoreDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(ChoreDefinitionEntity(cloudKit: record))
          }
        case ChoreEventCloudKitSchema.recordType:
          batchTouchedData = true
          let id = ChoreEventCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<ChoreEventEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(ChoreEventEntity(cloudKit: record))
          }
        case GoalCloudKitSchema.recordType:
          batchTouchedData = true
          let id = GoalCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<GoalEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(GoalEntity(cloudKit: record))
          }
        case GoalMilestoneCloudKitSchema.recordType:
          batchTouchedData = true
          let id = GoalMilestoneCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<GoalMilestoneEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            // Fetched milestones fold in silently — the detecting device owns
            // the celebration moment; this device just records history.
            context.insert(GoalMilestoneEntity(cloudKit: record))
          }
        case CoachVoiceCloudKitSchema.recordType:
          batchTouchedData = true
          let id = CoachVoiceCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<CoachVoiceEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(CoachVoiceEntity(cloudKit: record))
          }
        case CoachMessageCloudKitSchema.recordType:
          batchTouchedData = true
          let id = CoachMessageCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<CoachMessageEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(CoachMessageEntity(cloudKit: record))
          }
        case GutEventCloudKitSchema.recordType:
          batchTouchedData = true
          let id = GutEventCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<GutEventEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(GutEventEntity(cloudKit: record))
          }
        case MoodEventCloudKitSchema.recordType:
          batchTouchedData = true
          let id = MoodEventCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<MoodEventEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(MoodEventEntity(cloudKit: record))
          }
        case SymptomDefinitionCloudKitSchema.recordType:
          batchTouchedData = true
          let id = SymptomDefinitionCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<SymptomDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(SymptomDefinitionEntity(cloudKit: record))
          }
        case SymptomEventCloudKitSchema.recordType:
          batchTouchedData = true
          let id = SymptomEventCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<SymptomEventEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(SymptomEventEntity(cloudKit: record))
          }
        case MedicationDefinitionCloudKitSchema.recordType:
          batchTouchedData = true
          let id = MedicationDefinitionCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<MedicationDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(MedicationDefinitionEntity(cloudKit: record))
          }
        case MedicationDoseEventCloudKitSchema.recordType:
          batchTouchedData = true
          let id = MedicationDoseEventCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<MedicationDoseEventEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(MedicationDoseEventEntity(cloudKit: record))
          }
        case OuraNightCloudKitSchema.recordType:
          batchTouchedData = true
          let id = OuraNightCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<OuraNightEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(OuraNightEntity(cloudKit: record))
          }
          NotificationCenter.default.post(name: .septenaOuraChanged, object: nil)
        case QuoteCloudKitSchema.recordType:
          batchTouchedData = true
          let id = QuoteCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<QuoteEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(QuoteEntity(cloudKit: record))
          }
          NotificationCenter.default.post(name: .septenaQuotesChanged, object: nil)
        case WithingsRowCloudKitSchema.recordType:
          batchTouchedData = true
          let id = WithingsRowCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<WithingsRowEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(WithingsRowEntity(cloudKit: record))
          }
          NotificationCenter.default.post(name: .septenaWithingsChanged, object: nil)
        case IntakeKindCloudKitSchema.recordType:
          batchTouchedData = true
          let id = IntakeKindCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<IntakeKindEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(IntakeKindEntity(cloudKit: record))
          }
        case IntakeItemCloudKitSchema.recordType:
          batchTouchedData = true
          let id = IntakeItemCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<IntakeItemEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(IntakeItemEntity(cloudKit: record))
          }
        case IntakeEventCloudKitSchema.recordType:
          batchTouchedData = true
          let id = IntakeEventCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<IntakeEventEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(IntakeEventEntity(cloudKit: record))
          }
        case GroceryItemCloudKitSchema.recordType:
          batchTouchedData = true
          let id = GroceryItemCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<GroceryItemEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(GroceryItemEntity(cloudKit: record))
          }
        case GroceryCategoryCloudKitSchema.recordType:
          batchTouchedData = true
          let id = GroceryCategoryCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<GroceryCategoryEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(GroceryCategoryEntity(cloudKit: record))
          }
        case ExerciseEntryCloudKitSchema.recordType:
          batchTouchedData = true
          let id = ExerciseEntryCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<ExerciseEntryEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(ExerciseEntryEntity(cloudKit: record))
          }
        case ExerciseDefinitionCloudKitSchema.recordType:
          batchTouchedData = true
          let id = ExerciseDefinitionCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<ExerciseDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(ExerciseDefinitionEntity(cloudKit: record))
          }
        case SessionTypeCloudKitSchema.recordType:
          batchTouchedData = true
          let id = SessionTypeCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<SessionTypeEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(SessionTypeEntity(cloudKit: record))
          }
        case NutritionEntryCloudKitSchema.recordType:
          batchTouchedData = true
          let id = NutritionEntryCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<NutritionEntryEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(NutritionEntryEntity(cloudKit: record))
          }
        case NutritionDailySummaryCloudKitSchema.recordType:
          batchTouchedData = true
          let id = NutritionDailySummaryCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<NutritionDailySummaryEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(NutritionDailySummaryEntity(cloudKit: record))
          }
        case ActivityDayCloudKitSchema.recordType:
          batchTouchedData = true
          let id = ActivityDayCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = one(FetchDescriptor<ActivityDayEntity>(
            predicate: #Predicate { $0.id == id }
          )) {
            entity.apply(record)
          } else {
            context.insert(ActivityDayEntity(cloudKit: record))
          }
        default:
          SeptenaLog.info("[CKEngine] applyFetched: unknown recordType \(record.recordType) id=\(record.recordID.recordName)")
        }
        // No save / notification here — `applyDidFinishBatch` does
        // both once per batch.
      }
      ckEngine.applyDeletedRecord = { recordID, recordType in
        switch recordType {
        case TaskCloudKitSchema.recordType:
          batchTouchedTasks = true
          let id = recordID.recordName
          if let entity = try? context.fetch(FetchDescriptor<TaskEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case ProjectCloudKitSchema.recordType:
          batchTouchedStructure = true
          let id = ProjectCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<ProjectEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case AreaCloudKitSchema.recordType:
          batchTouchedStructure = true
          let id = AreaCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<AreaEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case SettingsCloudKitSchema.recordType:
          batchTouchedData = true
          if let entity = try? context.fetch(FetchDescriptor<SettingsEntity>(
            predicate: #Predicate { $0.id == settingsSingletonID }
          )).first {
            context.delete(entity)
          }
        case SectionCloudKitSchema.recordType:
          batchTouchedData = true
          let id = SectionCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<SectionEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case HabitDefinitionCloudKitSchema.recordType:
          batchTouchedData = true
          let id = HabitDefinitionCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<HabitDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case HabitEventCloudKitSchema.recordType:
          batchTouchedData = true
          let id = HabitEventCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<HabitDayStateEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case SupplementDefinitionCloudKitSchema.recordType:
          batchTouchedData = true
          let id = SupplementDefinitionCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<SupplementDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case SupplementEventCloudKitSchema.recordType:
          batchTouchedData = true
          let id = SupplementEventCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<SupplementDayStateEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case ChoreDefinitionCloudKitSchema.recordType:
          batchTouchedData = true
          let id = ChoreDefinitionCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<ChoreDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case ChoreEventCloudKitSchema.recordType:
          batchTouchedData = true
          let id = ChoreEventCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<ChoreEventEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case GoalCloudKitSchema.recordType:
          batchTouchedData = true
          let id = GoalCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<GoalEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case GoalMilestoneCloudKitSchema.recordType:
          batchTouchedData = true
          let id = GoalMilestoneCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<GoalMilestoneEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case CoachVoiceCloudKitSchema.recordType:
          batchTouchedData = true
          let id = CoachVoiceCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<CoachVoiceEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case CoachMessageCloudKitSchema.recordType:
          batchTouchedData = true
          let id = CoachMessageCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<CoachMessageEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case GutEventCloudKitSchema.recordType:
          batchTouchedData = true
          let id = GutEventCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<GutEventEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case MoodEventCloudKitSchema.recordType:
          batchTouchedData = true
          let id = MoodEventCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<MoodEventEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case SymptomDefinitionCloudKitSchema.recordType:
          batchTouchedData = true
          let id = SymptomDefinitionCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<SymptomDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case SymptomEventCloudKitSchema.recordType:
          batchTouchedData = true
          let id = SymptomEventCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<SymptomEventEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case MedicationDefinitionCloudKitSchema.recordType:
          batchTouchedData = true
          let id = MedicationDefinitionCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<MedicationDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case MedicationDoseEventCloudKitSchema.recordType:
          batchTouchedData = true
          let id = MedicationDoseEventCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<MedicationDoseEventEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case OuraNightCloudKitSchema.recordType:
          batchTouchedData = true
          let id = OuraNightCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<OuraNightEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case QuoteCloudKitSchema.recordType:
          batchTouchedData = true
          let id = QuoteCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<QuoteEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case WithingsRowCloudKitSchema.recordType:
          batchTouchedData = true
          let id = WithingsRowCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<WithingsRowEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case IntakeKindCloudKitSchema.recordType:
          batchTouchedData = true
          let id = IntakeKindCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<IntakeKindEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case IntakeItemCloudKitSchema.recordType:
          batchTouchedData = true
          let id = IntakeItemCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<IntakeItemEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case IntakeEventCloudKitSchema.recordType:
          batchTouchedData = true
          let id = IntakeEventCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<IntakeEventEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case GroceryItemCloudKitSchema.recordType:
          batchTouchedData = true
          let id = GroceryItemCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<GroceryItemEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case GroceryCategoryCloudKitSchema.recordType:
          batchTouchedData = true
          let id = GroceryCategoryCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<GroceryCategoryEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case ExerciseEntryCloudKitSchema.recordType:
          batchTouchedData = true
          let id = ExerciseEntryCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<ExerciseEntryEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case ExerciseDefinitionCloudKitSchema.recordType:
          batchTouchedData = true
          let id = ExerciseDefinitionCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<ExerciseDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case SessionTypeCloudKitSchema.recordType:
          batchTouchedData = true
          let id = SessionTypeCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<SessionTypeEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case NutritionEntryCloudKitSchema.recordType:
          batchTouchedData = true
          let id = NutritionEntryCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<NutritionEntryEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case NutritionDailySummaryCloudKitSchema.recordType:
          batchTouchedData = true
          let id = NutritionDailySummaryCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<NutritionDailySummaryEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case ActivityDayCloudKitSchema.recordType:
          batchTouchedData = true
          let id = ActivityDayCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<ActivityDayEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        default:
          SeptenaLog.info("[CKEngine] applyDeleted: unknown recordType \(recordType) id=\(recordID.recordName)")
        }
      }
      ckEngine.applyDidFinishBatch = { notify in
        PerfTrace.spanSync("ck.applyBatch.save", "\(batchApplied) records") {
          try? context.save()
        }
        batchApplied = 0
        // `notify == false` is our own sent records echoing back: the save
        // above folds in their fresh system fields, but the user-visible data
        // was already applied optimistically and the mutator already posted a
        // scoped change. Skipping the repaint here is what stops every local
        // edit from triggering a second, app-wide reload wave.
        if notify {
          if batchTouchedTasks {
            NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
          }
          if batchTouchedStructure {
            NotificationCenter.default.post(name: .septenaStructureChanged, object: nil)
          }
          if batchTouchedData {
            // Deliberately UNSCOPED — an inbound CK batch can touch any mix of
            // record types (cross-device writes), so every listener refreshes.
            // Local mutations post scoped instead (see `DataChange.post`).
            NotificationCenter.default.post(name: .septenaDataChanged, object: nil)
          }
        }
        batchTouchedTasks = false
        batchTouchedStructure = false
        batchTouchedData = false
      }
      taskMutator.bind(ckEngine: ckEngine)
      checklistMutator.bind(ckEngine: ckEngine)
      goalMutator.bind(ckEngine: ckEngine)
      milestoneMutator.bind(ckEngine: ckEngine)
      coachVoiceMutator.bind(ckEngine: ckEngine)
      coachMessageMutator.bind(ckEngine: ckEngine)
      gutMutator.bind(ckEngine: ckEngine)
      activityMutator.bind(ckEngine: ckEngine)
      symptomsMutator.bind(ckEngine: ckEngine)
      medicationsMutator.bind(ckEngine: ckEngine)
      intakeMutator.bind(ckEngine: ckEngine)
      groceryMutator.bind(ckEngine: ckEngine)
      trainingMutator.bind(ckEngine: ckEngine)
      nutritionMutator.bind(ckEngine: ckEngine)
      areasMutator.bind(ckEngine: ckEngine)
      projectsMutator.bind(ckEngine: ckEngine)
      // Lets project deletion cascade-clear the link on referencing tasks.
      projectsMutator.taskMutator = taskMutator
      OuraStore.shared.bind(ckEngine: ckEngine)
      WithingsStore.shared.bind(ckEngine: ckEngine)
      QuoteStore.shared.bind(ckEngine: ckEngine)
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
        // Readwise highlights are device-local now (see QuoteStore). Clear any
        // backlog a pre-change build queued — thousands of `quote:readwise:*`
        // uploads that re-locked the UI on every launch until drained. One-shot
        // and idempotent: a no-op once the queue is clean.
        ckEngine.dropPendingReadwiseQuoteChanges()
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
    // Heal dangling project references now that the initial fetch has
    // landed (so we never stub a project that's merely mid-sync).
    await reconcileProjectGraph(context: context)
    // Now that synced history is present: repair pre-`occurredAt` event
    // rows (local-only) and publish this device's timezone so the gateway
    // resolves the user's real zone instead of defaulting to UTC.
    OccurredAtBackfill.runIfNeeded(context: context)
    // Lift the symptom-shaped gut fields (discomfort, blood) into standalone
    // Symptoms events. Local-only, idempotent, gated once-per-device; runs
    // after the fetch so synced gut rows are present.
    GutSymptomMigrator.runIfNeeded(context: context, mutator: symptomsMutator)
    // Retire the legacy `someday` task status — the "Someday" bucket merged
    // into "Anytime". Rewrites stored statusRaw → "open" and pushes the fix;
    // gated once-per-device, after the fetch so synced someday rows are present.
    SomedayStatusMigrator.runIfNeeded(context: context, engine: ckEngine)
    // Fold any retired `bedtime` medication bucket into `evening`.
    medicationsMutator.migrateBedtimeBuckets()
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
    return ChecklistMirror.loadChores(context: context).first(where: { $0.id == id })
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
    do {
      try context.save()
    } catch {
      SeptenaLog.error(label, error)
    }
  }

  /// One mutator, three sections — callers pass the section key of the
  /// entity they touched ("habits" / "supplements" / "chores") so listeners
  /// showing unrelated sections skip their reload. The task surfaces
  /// (sidebar, Tasks tile, menu bar) never cared about checklist toggles,
  /// so no `.septenaTasksChanged` here.
  private func postChecklistChanged(_ section: String) {
    DataChange.post(section)
    // Keep the watch's one-shot snapshot in sync with every checklist edit.
    // Debounced: ticking several items in a row coalesces to one rebuild +
    // CloudKit write instead of one per toggle.
    let ctx = context
    Task { @MainActor in WatchSnapshotPublisher.schedule(context: ctx) }
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

  private func saveContext(_ label: String) {
    do { try context.save() }
    catch { SeptenaLog.error(label, error) }
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
    do { try context.save() }
    catch { SeptenaLog.error(label, error) }
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
    do { try context.save() }
    catch { SeptenaLog.error(label, error) }
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
    do { try context.save() }
    catch { SeptenaLog.error(label, error) }
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
    do { try context.save() }
    catch { SeptenaLog.error(label, error) }
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
    do { try context.save() }
    catch { SeptenaLog.error(label, error) }
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
    do { try context.save() }
    catch { SeptenaLog.error(label, error) }
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
  func addItem(kindID: String, name: String) -> IntakeItemEntity {
    let entity = IntakeItemEntity(id: uniqueItemID(),
                                  kindID: kindID,
                                  name: name,
                                  sortIndex: nextItemSortIndex(kindID: kindID))
    context.insert(entity)
    commitItem(entity, op: "create")
    return entity
  }

  func updateItem(id: String, name: String) {
    guard let entity = fetchItem(id: id) else { return }
    entity.name = name
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
    do { try context.save() }
    catch { SeptenaLog.error(label, error) }
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
    do { try context.save() }
    catch { SeptenaLog.error(label, error) }
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
                   concludedAt: String?? = nil) -> [String] {
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
    let entries = (try? context.fetch(FetchDescriptor<ExerciseEntryEntity>(
      predicate: #Predicate { $0.date == date && $0.sessionType == sessionType }
    ))) ?? []
    guard let concluding = entries.max(by: { $0.occurredAt < $1.occurredAt }) else { return false }
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    updateEntry(id: concluding.id, note: .some(trimmed.isEmpty ? nil : trimmed))
    return true
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
  func addSessionType(label: String, emoji: String? = nil, exercises: [String] = []) -> SessionTypeEntity {
    let id = uniqueSessionTypeID(for: label)
    let entity = SessionTypeEntity(id: id,
                                   label: label,
                                   emoji: emoji,
                                   exercises: exercises,
                                   sortIndex: nextSessionTypeSortIndex())
    context.insert(entity)
    commitSessionType(entity, op: "create")
    return entity
  }

  func updateSessionType(id: String,
                         label: String? = nil,
                         emoji: String?? = nil,
                         exercises: [String]? = nil) {
    guard let entity = fetchSessionType(id: id) else { return }
    if let label { entity.label = label }
    if let emoji { entity.emoji = emoji }
    if let exercises { entity.exercises = exercises }
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
    do { try context.save() }
    catch { SeptenaLog.error(label, error) }
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
    let entity = NutritionEntryEntity(
      id: id, loggedAt: loggedAt, updatedAt: now,
      emoji: emoji, foods: foods.joined(separator: "\n"),
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
    do { try context.save() }
    catch { SeptenaLog.error(label, error) }
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
    do { try context.save() }
    catch { SeptenaLog.error(label, error) }
  }

  private func postChanged() {
    DataChange.post(Self.changeScope)
  }
}
