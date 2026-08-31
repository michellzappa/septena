import CloudKit
import SwiftData

/// One registry for every SwiftData entity mirrored through CKSyncEngine.
///
/// The previous startup path maintained three independent switches: record
/// provider, fetched-record materialization, and deletion. Keeping the route,
/// lookup, encode, merge, and delete behavior together makes a new record type
/// one deliberate registration instead of three drift-prone edits.
@ModelActor
actor CloudKitRecordRegistry {
  struct ChangeSet: Sendable {
    var touchedTasks = false
    var touchedStructure = false
    var touchedData = false
  }

  private enum Impact { case tasks, structure, data }

  private struct Handler {
    let recordType: String
    let impact: Impact
    let matchesRecordName: (String) -> Bool
    let record: (String, ModelContext) -> CKRecord?
    let apply: (CKRecord, ModelContext) -> Void
    let delete: (String, ModelContext) -> Void
  }

  private lazy var handlers = Self.makeHandlers()
  private lazy var handlerByRecordType: [String: Handler] =
    Dictionary(uniqueKeysWithValues: handlers.map { ($0.recordType, $0) })
  private var changes = ChangeSet()

  func record(for recordID: CKRecord.ID) -> CKRecord? {
    let name = recordID.recordName
    return handlers.first(where: { $0.matchesRecordName(name) })?.record(name, modelContext)
  }

  func apply(_ record: CKRecord) {
    guard let handler = handlerByRecordType[record.recordType] else {
      SeptenaLog.info("[CKEngine] applyFetched: unknown recordType \(record.recordType) id=\(record.recordID.recordName)")
      return
    }
    handler.apply(record, modelContext)
    mark(handler.impact)
  }

  func delete(recordID: CKRecord.ID, recordType: CKRecord.RecordType) {
    guard let handler = handlerByRecordType[String(recordType)] else {
      SeptenaLog.info("[CKEngine] applyDeleted: unknown recordType \(recordType) id=\(recordID.recordName)")
      return
    }
    handler.delete(recordID.recordName, modelContext)
    mark(handler.impact)
  }

  /// Persist one CK batch, then return the smallest set of UI invalidations
  /// the caller must publish. Local optimistic writes still issue their own
  /// scoped notification; callers pass `notify: false` for their echo batch.
  func finishBatch() -> ChangeSet {
    let result = changes
    guard result.touchedTasks || result.touchedStructure || result.touchedData else { return result }
    // Same rule as the main context (`StoreHealth.save`): a failed save leaves
    // its pending changes behind, so every later batch retries them and fails
    // the same way. This actor writes the SAME store as the main context, so a
    // wedged batch context also means inbound CloudKit changes stop landing
    // while the app still looks online. Log the real error and roll back.
    PerfTrace.spanSync("ck.applyBatch.save") {
      do {
        try modelContext.save()
      } catch {
        SeptenaLog.error("[CKEngine] applyBatch save failed: \(StoreHealth.detail(error))")
        modelContext.rollback()
      }
    }
    changes = ChangeSet()
    return result
  }

  private func mark(_ impact: Impact) {
    switch impact {
    case .tasks: changes.touchedTasks = true
    case .structure: changes.touchedStructure = true
    case .data: changes.touchedData = true
    }
  }

  private static func one<E: PersistentModel>(
    _ context: ModelContext,
    _ descriptor: FetchDescriptor<E>
  ) -> E? {
    var limited = descriptor
    limited.fetchLimit = 1
    return try? context.fetch(limited).first
  }

  private static func entityHandler<E: PersistentModel>(
    recordType: String,
    impact: Impact,
    matchesRecordName: @escaping (String) -> Bool,
    entityID: @escaping (String) -> String,
    lookup: @escaping (String, ModelContext) -> E?,
    make: @escaping (CKRecord) -> E,
    encode: @escaping (E) -> CKRecord,
    merge: @escaping (E, CKRecord) -> Void
  ) -> Handler {
    Handler(
      recordType: recordType,
      impact: impact,
      matchesRecordName: matchesRecordName,
      record: { name, context in
        lookup(entityID(name), context).map(encode)
      },
      apply: { record, context in
        let id = entityID(record.recordID.recordName)
        if let entity = lookup(id, context) {
          merge(entity, record)
        } else {
          context.insert(make(record))
        }
      },
      delete: { name, context in
        if let entity = lookup(entityID(name), context) { context.delete(entity) }
      }
    )
  }

  private static func makeHandlers() -> [Handler] {
    let taskAttachment = entityHandler(
      recordType: TaskAttachmentCloudKitSchema.recordType, impact: .tasks,
      matchesRecordName: { $0.hasPrefix(TaskAttachmentCloudKitSchema.prefix) },
      entityID: TaskAttachmentCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<TaskAttachmentEntity>(predicate: #Predicate { $0.id == id })) },
      make: { TaskAttachmentEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let task = entityHandler(
      recordType: TaskCloudKitSchema.recordType, impact: .tasks,
      matchesRecordName: { _ in true }, entityID: { $0 },
      lookup: { id, context in one(context, FetchDescriptor<TaskEntity>(predicate: #Predicate { $0.id == id })) },
      make: { TaskEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let project = entityHandler(
      recordType: ProjectCloudKitSchema.recordType, impact: .structure,
      matchesRecordName: { $0.hasPrefix("project:") }, entityID: ProjectCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<ProjectEntity>(predicate: #Predicate { $0.id == id })) },
      make: { ProjectEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let area = entityHandler(
      recordType: AreaCloudKitSchema.recordType, impact: .structure,
      matchesRecordName: { $0.hasPrefix("area:") }, entityID: AreaCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<AreaEntity>(predicate: #Predicate { $0.id == id })) },
      make: { AreaEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let settings = entityHandler(
      recordType: SettingsCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0 == SettingsCloudKitSchema.singletonID }, entityID: { _ in SettingsCloudKitSchema.singletonID },
      lookup: { id, context in one(context, FetchDescriptor<SettingsEntity>(predicate: #Predicate { $0.id == id })) },
      make: { SettingsEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let section = entityHandler(
      recordType: SectionCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("section:") }, entityID: SectionCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<SectionEntity>(predicate: #Predicate { $0.id == id })) },
      make: { SectionEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let habitDefinition = entityHandler(
      recordType: HabitDefinitionCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("habit-def:") }, entityID: HabitDefinitionCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<HabitDefinitionEntity>(predicate: #Predicate { $0.id == id })) },
      make: { HabitDefinitionEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let habitEvent = entityHandler(
      recordType: HabitEventCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("habit-event:") }, entityID: HabitEventCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<HabitDayStateEntity>(predicate: #Predicate { $0.id == id })) },
      make: { HabitDayStateEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let supplementDefinition = entityHandler(
      recordType: SupplementDefinitionCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("supplement-def:") }, entityID: SupplementDefinitionCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<SupplementDefinitionEntity>(predicate: #Predicate { $0.id == id })) },
      make: { SupplementDefinitionEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let supplementEvent = entityHandler(
      recordType: SupplementEventCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("supplement-event:") }, entityID: SupplementEventCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<SupplementDayStateEntity>(predicate: #Predicate { $0.id == id })) },
      make: { SupplementDayStateEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let choreDefinition = entityHandler(
      recordType: ChoreDefinitionCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("chore-def:") }, entityID: ChoreDefinitionCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<ChoreDefinitionEntity>(predicate: #Predicate { $0.id == id })) },
      make: { ChoreDefinitionEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let choreEvent = entityHandler(
      recordType: ChoreEventCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("chore-event:") }, entityID: ChoreEventCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<ChoreEventEntity>(predicate: #Predicate { $0.id == id })) },
      make: { ChoreEventEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let goal = entityHandler(
      recordType: GoalCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("goal:") }, entityID: GoalCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<GoalEntity>(predicate: #Predicate { $0.id == id })) },
      make: { GoalEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let goalMilestone = entityHandler(
      recordType: GoalMilestoneCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("gms:") }, entityID: GoalMilestoneCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<GoalMilestoneEntity>(predicate: #Predicate { $0.id == id })) },
      make: { GoalMilestoneEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let coachVoice = entityHandler(
      recordType: CoachVoiceCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("coachVoice:") }, entityID: CoachVoiceCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<CoachVoiceEntity>(predicate: #Predicate { $0.id == id })) },
      make: { CoachVoiceEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let coachMessage = entityHandler(
      recordType: CoachMessageCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("coachMsg:") }, entityID: CoachMessageCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<CoachMessageEntity>(predicate: #Predicate { $0.id == id })) },
      make: { CoachMessageEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let gut = entityHandler(
      recordType: GutEventCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("gut-event:") }, entityID: GutEventCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<GutEventEntity>(predicate: #Predicate { $0.id == id })) },
      make: { GutEventEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let mood = entityHandler(
      recordType: MoodEventCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("mood-event:") }, entityID: MoodEventCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<MoodEventEntity>(predicate: #Predicate { $0.id == id })) },
      make: { MoodEventEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let symptomsDefinition = entityHandler(
      recordType: SymptomDefinitionCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("symptom-definition:") }, entityID: SymptomDefinitionCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<SymptomDefinitionEntity>(predicate: #Predicate { $0.id == id })) },
      make: { SymptomDefinitionEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let symptomsEvent = entityHandler(
      recordType: SymptomEventCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("symptom-event:") }, entityID: SymptomEventCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<SymptomEventEntity>(predicate: #Predicate { $0.id == id })) },
      make: { SymptomEventEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let medicationDefinition = entityHandler(
      recordType: MedicationDefinitionCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("medication-definition:") }, entityID: MedicationDefinitionCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<MedicationDefinitionEntity>(predicate: #Predicate { $0.id == id })) },
      make: { MedicationDefinitionEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let medicationDose = entityHandler(
      recordType: MedicationDoseEventCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("medication-dose-event:") }, entityID: MedicationDoseEventCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<MedicationDoseEventEntity>(predicate: #Predicate { $0.id == id })) },
      make: { MedicationDoseEventEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let oura = entityHandler(
      recordType: OuraNightCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("oura-night:") }, entityID: OuraNightCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<OuraNightEntity>(predicate: #Predicate { $0.id == id })) },
      make: { OuraNightEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let quote = entityHandler(
      recordType: QuoteCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("quote:") }, entityID: QuoteCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<QuoteEntity>(predicate: #Predicate { $0.id == id })) },
      make: { QuoteEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let withings = entityHandler(
      recordType: WithingsRowCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("withings-row:") }, entityID: WithingsRowCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<WithingsRowEntity>(predicate: #Predicate { $0.id == id })) },
      make: { WithingsRowEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let intakeKind = entityHandler(
      recordType: IntakeKindCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("intake-kind:") }, entityID: IntakeKindCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<IntakeKindEntity>(predicate: #Predicate { $0.id == id })) },
      make: { IntakeKindEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let intakeItem = entityHandler(
      recordType: IntakeItemCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("intake-item:") }, entityID: IntakeItemCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<IntakeItemEntity>(predicate: #Predicate { $0.id == id })) },
      make: { IntakeItemEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let intakeEvent = entityHandler(
      recordType: IntakeEventCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("intake-event:") }, entityID: IntakeEventCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<IntakeEventEntity>(predicate: #Predicate { $0.id == id })) },
      make: { IntakeEventEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let groceryItem = entityHandler(
      recordType: GroceryItemCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("grocery-item:") }, entityID: GroceryItemCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<GroceryItemEntity>(predicate: #Predicate { $0.id == id })) },
      make: { GroceryItemEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let groceryCategory = entityHandler(
      recordType: GroceryCategoryCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("grocery-cat:") }, entityID: GroceryCategoryCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<GroceryCategoryEntity>(predicate: #Predicate { $0.id == id })) },
      make: { GroceryCategoryEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let exerciseEntry = entityHandler(
      recordType: ExerciseEntryCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("exercise-entry:") }, entityID: ExerciseEntryCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<ExerciseEntryEntity>(predicate: #Predicate { $0.id == id })) },
      make: { ExerciseEntryEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let exerciseDefinition = entityHandler(
      recordType: ExerciseDefinitionCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("exercise-def:") }, entityID: ExerciseDefinitionCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<ExerciseDefinitionEntity>(predicate: #Predicate { $0.id == id })) },
      make: { ExerciseDefinitionEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let sessionType = entityHandler(
      recordType: SessionTypeCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("session-type:") }, entityID: SessionTypeCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<SessionTypeEntity>(predicate: #Predicate { $0.id == id })) },
      make: { SessionTypeEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let nutritionEntry = entityHandler(
      recordType: NutritionEntryCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("nutrition-entry:") }, entityID: NutritionEntryCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<NutritionEntryEntity>(predicate: #Predicate { $0.id == id })) },
      make: { NutritionEntryEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let nutritionDay = entityHandler(
      recordType: NutritionDailySummaryCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("nutrition-day:") }, entityID: NutritionDailySummaryCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<NutritionDailySummaryEntity>(predicate: #Predicate { $0.id == id })) },
      make: { NutritionDailySummaryEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )
    let activityDay = entityHandler(
      recordType: ActivityDayCloudKitSchema.recordType, impact: .data,
      matchesRecordName: { $0.hasPrefix("activity-day:") }, entityID: ActivityDayCloudKitSchema.entityID,
      lookup: { id, context in one(context, FetchDescriptor<ActivityDayEntity>(predicate: #Predicate { $0.id == id })) },
      make: { ActivityDayEntity(cloudKit: $0) }, encode: { $0.toCloudKitRecord() }, merge: { $0.apply($1) }
    )

    // Task is the fallback because its historic record names are bare ids;
    // every prefixed/singleton record must get first refusal.
    return [project, area, settings, section,
            habitDefinition, habitEvent, supplementDefinition, supplementEvent,
            choreDefinition, choreEvent, goal, goalMilestone, coachVoice, coachMessage,
            gut, mood, symptomsDefinition, symptomsEvent, medicationDefinition, medicationDose,
            oura, quote, withings, intakeKind, intakeItem, intakeEvent,
            groceryItem, groceryCategory, exerciseEntry, exerciseDefinition, sessionType,
            nutritionEntry, nutritionDay, activityDay, taskAttachment, task]
  }
}
