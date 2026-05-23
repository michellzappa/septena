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
///      `projectsMutator`; if `start()` has completed those go to
///      CloudKit, otherwise to the (now dead-coded) FastAPI fallback.
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
  let gutMutator: GutMutator
  let caffeineMutator: CaffeineMutator
  let cannabisMutator: CannabisMutator
  let areasMutator: AreasMutator
  let projectsMutator: ProjectsMutator
  let httpOutbox: HTTPOutbox

  /// Cached start task. Holds the work of wiring CKEngine + binding
  /// mutators; replays its result to any caller. Nil until first
  /// `start()`; non-nil thereafter so repeated calls coalesce.
  private var startTask: Task<Void, Never>?

  private init() {
    let context = LocalStore.shared.container.mainContext
    let client = ClientProvider.shared.client
    self.ckEngine = CKEngine()
    self.taskMutator = TaskMutator(client: client, context: context, ckEngine: nil)
    self.checklistMutator = ChecklistMutator(context: context, ckEngine: nil)
    self.goalMutator = GoalMutator(context: context, ckEngine: nil)
    self.gutMutator = GutMutator(context: context, ckEngine: nil)
    self.caffeineMutator = CaffeineMutator(context: context, ckEngine: nil)
    self.cannabisMutator = CannabisMutator(context: context, ckEngine: nil)
    self.areasMutator = AreasMutator(client: client, context: context)
    self.projectsMutator = ProjectsMutator(client: client, context: context)
    self.httpOutbox = HTTPOutbox(client: client, context: context)
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
      let client = ClientProvider.shared.client
      let settingsSingletonID = SettingsCloudKitSchema.singletonID
      var batchTouchedTasks = false
      var batchTouchedStructure = false
      var batchTouchedData = false

      // Single dispatcher for outbound records. CK record IDs are
      // zone-wide, so Area/Project record names are type-prefixed to
      // avoid natural-id collisions like area "septena" and project
      // "septena".
      ckEngine.recordProvider = { recordID in
        let recordName = recordID.recordName
        if recordName.hasPrefix("area:") {
          let id = AreaCloudKitSchema.entityID(from: recordName)
          if let entity = try? context.fetch(FetchDescriptor<AreaEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("project:") {
          let id = ProjectCloudKitSchema.entityID(from: recordName)
          if let entity = try? context.fetch(FetchDescriptor<ProjectEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("section:") {
          let id = SectionCloudKitSchema.entityID(from: recordName)
          if let entity = try? context.fetch(FetchDescriptor<SectionEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("habit-def:") {
          let id = HabitDefinitionCloudKitSchema.entityID(from: recordName)
          if let entity = try? context.fetch(FetchDescriptor<HabitDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("habit-event:") {
          let id = HabitEventCloudKitSchema.entityID(from: recordName)
          if let entity = try? context.fetch(FetchDescriptor<HabitDayStateEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("supplement-def:") {
          let id = SupplementDefinitionCloudKitSchema.entityID(from: recordName)
          if let entity = try? context.fetch(FetchDescriptor<SupplementDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("supplement-event:") {
          let id = SupplementEventCloudKitSchema.entityID(from: recordName)
          if let entity = try? context.fetch(FetchDescriptor<SupplementDayStateEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("chore-def:") {
          let id = ChoreDefinitionCloudKitSchema.entityID(from: recordName)
          if let entity = try? context.fetch(FetchDescriptor<ChoreDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("chore-event:") {
          let id = ChoreEventCloudKitSchema.entityID(from: recordName)
          if let entity = try? context.fetch(FetchDescriptor<ChoreEventEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("goal:") {
          let id = GoalCloudKitSchema.entityID(from: recordName)
          if let entity = try? context.fetch(FetchDescriptor<GoalEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("gut-event:") {
          let id = GutEventCloudKitSchema.entityID(from: recordName)
          if let entity = try? context.fetch(FetchDescriptor<GutEventEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("caffeine-event:") {
          let id = CaffeineEventCloudKitSchema.entityID(from: recordName)
          if let entity = try? context.fetch(FetchDescriptor<CaffeineEventEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("caffeine-bean:") {
          let id = CaffeineBeanCloudKitSchema.entityID(from: recordName)
          if let entity = try? context.fetch(FetchDescriptor<CaffeineBeanEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("cannabis-event:") {
          let id = CannabisEventCloudKitSchema.entityID(from: recordName)
          if let entity = try? context.fetch(FetchDescriptor<CannabisEventEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName.hasPrefix("cannabis-strain:") {
          let id = CannabisStrainCloudKitSchema.entityID(from: recordName)
          if let entity = try? context.fetch(FetchDescriptor<CannabisStrainEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        if recordName == SettingsCloudKitSchema.singletonID {
          if let entity = try? context.fetch(FetchDescriptor<SettingsEntity>(
            predicate: #Predicate { $0.id == settingsSingletonID }
          )).first {
            return entity.toCloudKitRecord()
          }
          return nil
        }
        let id = recordName
        if let entity = try? context.fetch(FetchDescriptor<TaskEntity>(
          predicate: #Predicate { $0.id == id }
        )).first {
          return entity.toCloudKitRecord()
        }
        return nil
      }
      ckEngine.applyFetchedRecord = { record in
        switch record.recordType {
        case TaskCloudKitSchema.recordType:
          batchTouchedTasks = true
          let id = record.recordID.recordName
          if let entity = try? context.fetch(FetchDescriptor<TaskEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            entity.apply(record)
          } else {
            context.insert(TaskEntity(cloudKit: record))
          }
        case ProjectCloudKitSchema.recordType:
          batchTouchedStructure = true
          let id = ProjectCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<ProjectEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            entity.apply(record)
          } else {
            context.insert(ProjectEntity(cloudKit: record))
          }
        case AreaCloudKitSchema.recordType:
          batchTouchedStructure = true
          let id = AreaCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<AreaEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            entity.apply(record)
          } else {
            context.insert(AreaEntity(cloudKit: record))
          }
        case SettingsCloudKitSchema.recordType:
          batchTouchedData = true
          if let entity = try? context.fetch(FetchDescriptor<SettingsEntity>(
            predicate: #Predicate { $0.id == settingsSingletonID }
          )).first {
            entity.apply(record)
          } else {
            context.insert(SettingsEntity(cloudKit: record))
          }
        case SectionCloudKitSchema.recordType:
          batchTouchedData = true
          let id = SectionCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<SectionEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            entity.apply(record)
          } else {
            context.insert(SectionEntity(cloudKit: record))
          }
        case HabitDefinitionCloudKitSchema.recordType:
          batchTouchedData = true
          let id = HabitDefinitionCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<HabitDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            entity.apply(record)
          } else {
            context.insert(HabitDefinitionEntity(cloudKit: record))
          }
        case HabitEventCloudKitSchema.recordType:
          batchTouchedData = true
          let id = HabitEventCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<HabitDayStateEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            entity.apply(record)
          } else {
            context.insert(HabitDayStateEntity(cloudKit: record))
          }
        case SupplementDefinitionCloudKitSchema.recordType:
          batchTouchedData = true
          let id = SupplementDefinitionCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<SupplementDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            entity.apply(record)
          } else {
            context.insert(SupplementDefinitionEntity(cloudKit: record))
          }
        case SupplementEventCloudKitSchema.recordType:
          batchTouchedData = true
          let id = SupplementEventCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<SupplementDayStateEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            entity.apply(record)
          } else {
            context.insert(SupplementDayStateEntity(cloudKit: record))
          }
        case ChoreDefinitionCloudKitSchema.recordType:
          batchTouchedData = true
          let id = ChoreDefinitionCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<ChoreDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            entity.apply(record)
          } else {
            context.insert(ChoreDefinitionEntity(cloudKit: record))
          }
        case ChoreEventCloudKitSchema.recordType:
          batchTouchedData = true
          let id = ChoreEventCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<ChoreEventEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            entity.apply(record)
          } else {
            context.insert(ChoreEventEntity(cloudKit: record))
          }
        case GoalCloudKitSchema.recordType:
          batchTouchedData = true
          let id = GoalCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<GoalEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            entity.apply(record)
          } else {
            context.insert(GoalEntity(cloudKit: record))
          }
        case GutEventCloudKitSchema.recordType:
          batchTouchedData = true
          let id = GutEventCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<GutEventEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            entity.apply(record)
          } else {
            context.insert(GutEventEntity(cloudKit: record))
          }
        case CaffeineEventCloudKitSchema.recordType:
          batchTouchedData = true
          let id = CaffeineEventCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<CaffeineEventEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            entity.apply(record)
          } else {
            context.insert(CaffeineEventEntity(cloudKit: record))
          }
        case CaffeineBeanCloudKitSchema.recordType:
          batchTouchedData = true
          let id = CaffeineBeanCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<CaffeineBeanEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            entity.apply(record)
          } else {
            context.insert(CaffeineBeanEntity(cloudKit: record))
          }
        case CannabisEventCloudKitSchema.recordType:
          batchTouchedData = true
          let id = CannabisEventCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<CannabisEventEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            entity.apply(record)
          } else {
            context.insert(CannabisEventEntity(cloudKit: record))
          }
        case CannabisStrainCloudKitSchema.recordType:
          batchTouchedData = true
          let id = CannabisStrainCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<CannabisStrainEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            entity.apply(record)
          } else {
            context.insert(CannabisStrainEntity(cloudKit: record))
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
        case GutEventCloudKitSchema.recordType:
          batchTouchedData = true
          let id = GutEventCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<GutEventEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case CaffeineEventCloudKitSchema.recordType:
          batchTouchedData = true
          let id = CaffeineEventCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<CaffeineEventEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case CaffeineBeanCloudKitSchema.recordType:
          batchTouchedData = true
          let id = CaffeineBeanCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<CaffeineBeanEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case CannabisEventCloudKitSchema.recordType:
          batchTouchedData = true
          let id = CannabisEventCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<CannabisEventEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case CannabisStrainCloudKitSchema.recordType:
          batchTouchedData = true
          let id = CannabisStrainCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<CannabisStrainEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        default:
          SeptenaLog.info("[CKEngine] applyDeleted: unknown recordType \(recordType) id=\(recordID.recordName)")
        }
      }
      ckEngine.applyDidFinishBatch = {
        try? context.save()
        if batchTouchedTasks {
          NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
        }
        if batchTouchedStructure {
          NotificationCenter.default.post(name: .septenaStructureChanged, object: nil)
        }
        if batchTouchedData {
          NotificationCenter.default.post(name: .septenaDataChanged, object: nil)
        }
        batchTouchedTasks = false
        batchTouchedStructure = false
        batchTouchedData = false
      }
      taskMutator.bind(ckEngine: ckEngine)
      checklistMutator.bind(ckEngine: ckEngine)
      goalMutator.bind(ckEngine: ckEngine)
      gutMutator.bind(ckEngine: ckEngine)
      caffeineMutator.bind(ckEngine: ckEngine)
      cannabisMutator.bind(ckEngine: ckEngine)
      areasMutator.bind(ckEngine: ckEngine)
      projectsMutator.bind(ckEngine: ckEngine)
      ckEngine.start()
      try? await ckEngine.fetchChanges()
      let checklistBootstrapper = ChecklistCloudKitBootstrapper(context: context,
                                                                engine: ckEngine,
                                                                client: client)
      try? await checklistBootstrapper.bootstrapIfNeeded()
    }
    startTask = task
    await task.value
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
    postChecklistChanged()
  }

  func toggleHabit(id: String, date: String, done: Bool) {
    setHabitState(id: id, date: date, done: done, skipped: false,
                  note: nil, time: done ? currentTimeString() : nil)
  }

  func skipHabit(id: String, date: String, skipped: Bool) {
    setHabitState(id: id, date: date, done: false, skipped: skipped,
                  note: nil, time: nil)
  }

  @discardableResult
  func createSupplement(name: String, emoji: String? = nil) -> SupplementDayItem {
    let id = uniqueSupplementID()
    let def = SupplementDefinitionEntity(id: id,
                                         title: name,
                                         emoji: normalized(emoji),
                                         sortIndex: nextSupplementSortIndex())
    context.insert(def)
    commitSupplementDefinition(def, op: "create")
    return SupplementDayItem(id: id, name: name, emoji: normalized(emoji),
                             done: false, note: nil, time: nil)
  }

  func updateSupplement(id: String, name: String, emoji: String?) {
    guard let def = fetchSupplementDefinition(id: id) else { return }
    def.title = name
    def.emoji = normalized(emoji)
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
    postChecklistChanged()
  }

  func toggleSupplement(id: String, date: String, done: Bool) {
    let stateID = "supplement:\(date):\(id)"
    if !done {
      if let state = fetchSupplementState(id: stateID) {
        context.delete(state)
        saveContext("CK supplements toggle delete")
        ckEngine?.noteSupplementEventDeletion(id: state.id)
        postChecklistChanged()
      }
      return
    }
    let state = fetchSupplementState(id: stateID) ?? SupplementDayStateEntity(
      id: stateID,
      date: date,
      supplementID: id,
      done: true
    )
    state.date = date
    state.supplementID = id
    state.done = true
    state.note = nil
    state.time = currentTimeString()
    state.updatedAt = .now
    if state.modelContext == nil { context.insert(state) }
    commitSupplementEvent(state, op: "toggle")
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
    postChecklistChanged()
  }

  func completeChore(id: String, date: String) {
    let event = ChoreEventEntity(id: uniqueChoreEventID(for: id, date: date),
                                 choreID: id,
                                 action: "complete",
                                 date: date,
                                 time: currentTimeString(),
                                 sortKey: sortKey(for: date))
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
                                 sortKey: sortKey(for: today))
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
    postChecklistChanged()
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
        postChecklistChanged()
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
    state.note = normalizedNote
    state.time = normalizedTime
    state.updatedAt = .now
    if state.modelContext == nil { context.insert(state) }
    commitHabitEvent(state, op: "state")
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

  private func currentTimeString() -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: .now)
  }

  private func deferredDueDate(mode: String, from date: String) -> String? {
    guard let base = SeptenaDate.parse(date) else { return nil }
    let calendar = Calendar.current
    switch mode {
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
    postChecklistChanged()
  }

  private func commitHabitEvent(_ entity: HabitDayStateEntity, op: String) {
    saveContext("CK habit event \(op)")
    ckEngine?.noteHabitEventChange(id: entity.id)
    postChecklistChanged()
  }

  private func commitSupplementDefinition(_ entity: SupplementDefinitionEntity, op: String) {
    saveContext("CK supplements \(op)")
    ckEngine?.noteSupplementDefinitionChange(id: entity.id)
    postChecklistChanged()
  }

  private func commitSupplementEvent(_ entity: SupplementDayStateEntity, op: String) {
    saveContext("CK supplement event \(op)")
    ckEngine?.noteSupplementEventChange(id: entity.id)
    postChecklistChanged()
  }

  private func commitChoreDefinition(_ entity: ChoreDefinitionEntity, op: String) {
    saveContext("CK chores \(op)")
    ckEngine?.noteChoreDefinitionChange(id: entity.id)
    postChecklistChanged()
  }

  private func commitChoreEvent(_ entity: ChoreEventEntity, op: String) {
    saveContext("CK chore event \(op)")
    ckEngine?.noteChoreEventChange(id: entity.id)
    postChecklistChanged()
  }

  private func saveContext(_ label: String) {
    do {
      try context.save()
    } catch {
      SeptenaLog.error(label, error)
    }
  }

  private func postChecklistChanged() {
    NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
  }
}

// MARK: - GoalMutator

@MainActor
@Observable
final class GoalMutator {
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

  func deleteGoal(id: String) {
    guard let entity = fetchGoal(id: id) else { return }
    context.delete(entity)
    saveContext("CK goals delete")
    ckEngine?.noteGoalDeletion(id: id)
    postChanged()
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
    NotificationCenter.default.post(name: .septenaDataChanged, object: nil)
  }
}

@MainActor
@Observable
final class GutMutator {
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
                blood: Int = 0,
                volume: String? = nil,
                discomfortLevel: String? = nil,
                discomfortStart: String? = nil,
                discomfortEnd: String? = nil,
                note: String? = nil) -> GutEventEntity {
    let id = uniqueID()
    let entity = GutEventEntity(id: id,
                                date: date,
                                time: time,
                                bristol: bristol,
                                blood: blood,
                                volume: volume,
                                discomfortLevel: discomfortLevel,
                                discomfortStart: discomfortStart,
                                discomfortEnd: discomfortEnd,
                                note: note)
    context.insert(entity)
    commit(entity, op: "create")
    return entity
  }

  func updateEntry(id: String,
                   time: String? = nil,
                   bristol: Int? = nil,
                   blood: Int? = nil,
                   volume: String?? = nil,
                   discomfortLevel: String?? = nil,
                   discomfortStart: String?? = nil,
                   discomfortEnd: String?? = nil,
                   note: String?? = nil) {
    guard let entity = fetch(id: id) else { return }
    if let time { entity.time = time }
    if let bristol { entity.bristol = bristol }
    if let blood { entity.blood = blood }
    if let volume { entity.volume = volume }
    if let discomfortLevel { entity.discomfortLevel = discomfortLevel }
    if let discomfortStart { entity.discomfortStart = discomfortStart }
    if let discomfortEnd { entity.discomfortEnd = discomfortEnd }
    if let note { entity.note = note }
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
    NotificationCenter.default.post(name: .septenaDataChanged, object: nil)
  }
}

@MainActor
@Observable
final class CaffeineMutator {
  private let context: ModelContext
  private var ckEngine: CKEngine?

  init(context: ModelContext, ckEngine: CKEngine? = nil) {
    self.context = context
    self.ckEngine = ckEngine
  }

  func bind(ckEngine: CKEngine) {
    self.ckEngine = ckEngine
  }

  // MARK: - Entries

  @discardableResult
  func addEntry(date: String,
                time: String,
                method: String,
                beans: String? = nil,
                grams: Double? = nil,
                note: String? = nil) -> CaffeineEventEntity {
    let id = uniqueEntryID()
    let entity = CaffeineEventEntity(id: id,
                                     date: date,
                                     time: time,
                                     method: method,
                                     beans: beans,
                                     grams: grams,
                                     note: note)
    context.insert(entity)
    commitEntry(entity, op: "create")
    return entity
  }

  func updateEntry(id: String,
                   time: String? = nil,
                   method: String? = nil,
                   beans: String?? = nil,
                   grams: Double?? = nil,
                   note: String?? = nil) {
    guard let entity = fetchEntry(id: id) else { return }
    if let time { entity.time = time }
    if let method { entity.method = method }
    if let beans { entity.beans = beans }
    if let grams { entity.grams = grams }
    if let note { entity.note = note }
    entity.updatedAt = .now
    commitEntry(entity, op: "update")
  }

  func deleteEntry(id: String) {
    guard let entity = fetchEntry(id: id) else { return }
    context.delete(entity)
    saveContext("CK caffeine delete")
    ckEngine?.noteCaffeineEventDeletion(id: id)
    postChanged()
  }

  // MARK: - Beans catalog

  @discardableResult
  func addBean(name: String) -> CaffeineBeanEntity {
    let id = uniqueBeanID(for: name)
    let entity = CaffeineBeanEntity(id: id, name: name, sortIndex: nextBeanSortIndex())
    context.insert(entity)
    commitBean(entity, op: "create")
    return entity
  }

  func updateBean(id: String, name: String) {
    guard let entity = fetchBean(id: id) else { return }
    entity.name = name
    entity.updatedAt = .now
    commitBean(entity, op: "update")
  }

  func deleteBean(id: String) {
    guard let entity = fetchBean(id: id) else { return }
    context.delete(entity)
    saveContext("CK caffeine-bean delete")
    ckEngine?.noteCaffeineBeanDeletion(id: id)
    postChanged()
  }

  // MARK: - Helpers

  private func fetchEntry(id: String) -> CaffeineEventEntity? {
    try? context.fetch(FetchDescriptor<CaffeineEventEntity>(
      predicate: #Predicate { $0.id == id }
    )).first
  }

  private func fetchBean(id: String) -> CaffeineBeanEntity? {
    try? context.fetch(FetchDescriptor<CaffeineBeanEntity>(
      predicate: #Predicate { $0.id == id }
    )).first
  }

  private func uniqueEntryID() -> String {
    var attempt = String(UUID().uuidString.lowercased().prefix(8))
    while fetchEntry(id: attempt) != nil {
      attempt = String(UUID().uuidString.lowercased().prefix(8))
    }
    return attempt
  }

  private func uniqueBeanID(for name: String) -> String {
    let base = name.lowercased()
      .replacingOccurrences(of: " ", with: "-")
      .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    var attempt = base.isEmpty ? IDShortcode.generate(length: 4) : base
    var n = 2
    while fetchBean(id: attempt) != nil {
      attempt = "\(base)-\(n)"
      n += 1
    }
    return attempt
  }

  private func nextBeanSortIndex() -> Int {
    ((try? context.fetch(FetchDescriptor<CaffeineBeanEntity>(
      sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]
    )).first?.sortIndex) ?? -1) + 1
  }

  private func commitEntry(_ entity: CaffeineEventEntity, op: String) {
    saveContext("CK caffeine \(op)")
    ckEngine?.noteCaffeineEventChange(id: entity.id)
    postChanged()
  }

  private func commitBean(_ entity: CaffeineBeanEntity, op: String) {
    saveContext("CK caffeine-bean \(op)")
    ckEngine?.noteCaffeineBeanChange(id: entity.id)
    postChanged()
  }

  private func saveContext(_ label: String) {
    do { try context.save() }
    catch { SeptenaLog.error(label, error) }
  }

  private func postChanged() {
    NotificationCenter.default.post(name: .septenaDataChanged, object: nil)
  }
}

@MainActor
@Observable
final class CannabisMutator {
  private let context: ModelContext
  private var ckEngine: CKEngine?

  /// Per-use weight for vape entries. The legacy server auto-computed this
  /// from a capsule lifecycle (uses-remaining counter); on CK we keep it
  /// simple and use a constant — user confirmed 0.05g per use is always
  /// correct for their hardware.
  static let gramsPerVapeUse: Double = 0.05

  init(context: ModelContext, ckEngine: CKEngine? = nil) {
    self.context = context
    self.ckEngine = ckEngine
  }

  func bind(ckEngine: CKEngine) {
    self.ckEngine = ckEngine
  }

  // MARK: - Entries

  @discardableResult
  func addEntry(date: String,
                time: String,
                method: String,
                strain: String? = nil,
                hit: Int? = nil,
                grams: Double? = nil,
                effect: String? = nil,
                note: String? = nil) -> CannabisEventEntity {
    let id = uniqueEntryID()
    // Vape entries auto-fill grams from the constant when not supplied.
    let resolvedGrams = grams ?? (method == "vape" ? Self.gramsPerVapeUse : nil)
    let entity = CannabisEventEntity(id: id,
                                     date: date,
                                     time: time,
                                     method: method,
                                     strain: strain,
                                     hit: hit,
                                     grams: resolvedGrams,
                                     effect: effect,
                                     note: note)
    context.insert(entity)
    commitEntry(entity, op: "create")
    return entity
  }

  func updateEntry(id: String,
                   time: String? = nil,
                   method: String? = nil,
                   strain: String?? = nil,
                   hit: Int?? = nil,
                   grams: Double?? = nil,
                   effect: String?? = nil,
                   note: String?? = nil) {
    guard let entity = fetchEntry(id: id) else { return }
    if let time { entity.time = time }
    if let method { entity.method = method }
    if let strain { entity.strain = strain }
    if let hit { entity.hit = hit }
    if let grams { entity.grams = grams }
    if let effect { entity.effect = effect }
    if let note { entity.note = note }
    entity.updatedAt = .now
    commitEntry(entity, op: "update")
  }

  func deleteEntry(id: String) {
    guard let entity = fetchEntry(id: id) else { return }
    context.delete(entity)
    saveContext("CK cannabis delete")
    ckEngine?.noteCannabisEventDeletion(id: id)
    postChanged()
  }

  // MARK: - Strains catalog

  @discardableResult
  func addStrain(name: String) -> CannabisStrainEntity {
    let id = uniqueStrainID(for: name)
    let entity = CannabisStrainEntity(id: id, name: name, sortIndex: nextStrainSortIndex())
    context.insert(entity)
    commitStrain(entity, op: "create")
    return entity
  }

  func updateStrain(id: String, name: String) {
    guard let entity = fetchStrain(id: id) else { return }
    entity.name = name
    entity.updatedAt = .now
    commitStrain(entity, op: "update")
  }

  func deleteStrain(id: String) {
    guard let entity = fetchStrain(id: id) else { return }
    context.delete(entity)
    saveContext("CK cannabis-strain delete")
    ckEngine?.noteCannabisStrainDeletion(id: id)
    postChanged()
  }

  // MARK: - Helpers

  private func fetchEntry(id: String) -> CannabisEventEntity? {
    try? context.fetch(FetchDescriptor<CannabisEventEntity>(
      predicate: #Predicate { $0.id == id }
    )).first
  }

  private func fetchStrain(id: String) -> CannabisStrainEntity? {
    try? context.fetch(FetchDescriptor<CannabisStrainEntity>(
      predicate: #Predicate { $0.id == id }
    )).first
  }

  private func uniqueEntryID() -> String {
    var attempt = String(UUID().uuidString.lowercased().prefix(8))
    while fetchEntry(id: attempt) != nil {
      attempt = String(UUID().uuidString.lowercased().prefix(8))
    }
    return attempt
  }

  private func uniqueStrainID(for name: String) -> String {
    let base = name.lowercased()
      .replacingOccurrences(of: " ", with: "-")
      .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    var attempt = base.isEmpty ? IDShortcode.generate(length: 4) : base
    var n = 2
    while fetchStrain(id: attempt) != nil {
      attempt = "\(base)-\(n)"
      n += 1
    }
    return attempt
  }

  private func nextStrainSortIndex() -> Int {
    ((try? context.fetch(FetchDescriptor<CannabisStrainEntity>(
      sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]
    )).first?.sortIndex) ?? -1) + 1
  }

  private func commitEntry(_ entity: CannabisEventEntity, op: String) {
    saveContext("CK cannabis \(op)")
    ckEngine?.noteCannabisEventChange(id: entity.id)
    postChanged()
  }

  private func commitStrain(_ entity: CannabisStrainEntity, op: String) {
    saveContext("CK cannabis-strain \(op)")
    ckEngine?.noteCannabisStrainChange(id: entity.id)
    postChanged()
  }

  private func saveContext(_ label: String) {
    do { try context.save() }
    catch { SeptenaLog.error(label, error) }
  }

  private func postChanged() {
    NotificationCenter.default.post(name: .septenaDataChanged, object: nil)
  }
}
