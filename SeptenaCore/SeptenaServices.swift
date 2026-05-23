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
          let id = record.recordID.recordName
          if let entity = try? context.fetch(FetchDescriptor<TaskEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            entity.apply(record)
          } else {
            context.insert(TaskEntity(cloudKit: record))
          }
        case ProjectCloudKitSchema.recordType:
          let id = ProjectCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<ProjectEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            entity.apply(record)
          } else {
            context.insert(ProjectEntity(cloudKit: record))
          }
        case AreaCloudKitSchema.recordType:
          let id = AreaCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<AreaEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            entity.apply(record)
          } else {
            context.insert(AreaEntity(cloudKit: record))
          }
        case SettingsCloudKitSchema.recordType:
          if let entity = try? context.fetch(FetchDescriptor<SettingsEntity>(
            predicate: #Predicate { $0.id == settingsSingletonID }
          )).first {
            entity.apply(record)
          } else {
            context.insert(SettingsEntity(cloudKit: record))
          }
        case SectionCloudKitSchema.recordType:
          let id = SectionCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<SectionEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            entity.apply(record)
          } else {
            context.insert(SectionEntity(cloudKit: record))
          }
        case HabitDefinitionCloudKitSchema.recordType:
          let id = HabitDefinitionCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<HabitDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            entity.apply(record)
          } else {
            context.insert(HabitDefinitionEntity(cloudKit: record))
          }
        case HabitEventCloudKitSchema.recordType:
          let id = HabitEventCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<HabitDayStateEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            entity.apply(record)
          } else {
            context.insert(HabitDayStateEntity(cloudKit: record))
          }
        case SupplementDefinitionCloudKitSchema.recordType:
          let id = SupplementDefinitionCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<SupplementDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            entity.apply(record)
          } else {
            context.insert(SupplementDefinitionEntity(cloudKit: record))
          }
        case SupplementEventCloudKitSchema.recordType:
          let id = SupplementEventCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<SupplementDayStateEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            entity.apply(record)
          } else {
            context.insert(SupplementDayStateEntity(cloudKit: record))
          }
        case ChoreDefinitionCloudKitSchema.recordType:
          let id = ChoreDefinitionCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<ChoreDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            entity.apply(record)
          } else {
            context.insert(ChoreDefinitionEntity(cloudKit: record))
          }
        case ChoreEventCloudKitSchema.recordType:
          let id = ChoreEventCloudKitSchema.entityID(from: record.recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<ChoreEventEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            entity.apply(record)
          } else {
            context.insert(ChoreEventEntity(cloudKit: record))
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
          let id = recordID.recordName
          if let entity = try? context.fetch(FetchDescriptor<TaskEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case ProjectCloudKitSchema.recordType:
          let id = ProjectCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<ProjectEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case AreaCloudKitSchema.recordType:
          let id = AreaCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<AreaEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case SettingsCloudKitSchema.recordType:
          if let entity = try? context.fetch(FetchDescriptor<SettingsEntity>(
            predicate: #Predicate { $0.id == settingsSingletonID }
          )).first {
            context.delete(entity)
          }
        case SectionCloudKitSchema.recordType:
          let id = SectionCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<SectionEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case HabitDefinitionCloudKitSchema.recordType:
          let id = HabitDefinitionCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<HabitDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case HabitEventCloudKitSchema.recordType:
          let id = HabitEventCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<HabitDayStateEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case SupplementDefinitionCloudKitSchema.recordType:
          let id = SupplementDefinitionCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<SupplementDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case SupplementEventCloudKitSchema.recordType:
          let id = SupplementEventCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<SupplementDayStateEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case ChoreDefinitionCloudKitSchema.recordType:
          let id = ChoreDefinitionCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<ChoreDefinitionEntity>(
            predicate: #Predicate { $0.id == id }
          )).first {
            context.delete(entity)
          }
        case ChoreEventCloudKitSchema.recordType:
          let id = ChoreEventCloudKitSchema.entityID(from: recordID.recordName)
          if let entity = try? context.fetch(FetchDescriptor<ChoreEventEntity>(
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
        NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
        NotificationCenter.default.post(name: .septenaDataChanged, object: nil)
      }
      taskMutator.bind(ckEngine: ckEngine)
      checklistMutator.bind(ckEngine: ckEngine)
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
