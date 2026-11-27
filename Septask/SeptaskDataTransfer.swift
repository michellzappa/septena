import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// Plain JSON export & import for Septena (the task app).
//
// Free on every tier, with no account and no network
// (docs/SYNC_SUBSCRIPTION_SPEC.md §3). Uses the same `septena_export_version: 1`
// envelope as the old life OS so exports round-trip cleanly and a full Septena
// Life backup can import its tasks/areas/projects/attachments directly here
// (non-task tables are skipped and counted).

@MainActor
enum TaskJSONTransfer {
  static let envelopeVersion = 1

  struct Envelope {
    let version: Int
    let section: String
    let exportedAt: String?
    let appVersion: String?
    let tables: [String: [[String: Any]]]

    var areaCount: Int { tables["area"]?.count ?? 0 }
    var projectCount: Int { tables["project"]?.count ?? 0 }
    var taskCount: Int { tables["task"]?.count ?? 0 }
    var attachmentCount: Int { tables["task_attachment"]?.count ?? 0 }
    var supportedRowCount: Int { areaCount + projectCount + taskCount + attachmentCount }
    var skippedRowCount: Int {
      let supported: Set<String> = ["area", "project", "task", "task_attachment", "checklist_item", "task_ref", "tag"]
      return tables.reduce(0) { acc, pair in
        supported.contains(pair.key) ? acc : acc + pair.value.count
      }
    }
  }

  struct ApplyResult {
    var areas: Int
    var projects: Int
    var tasks: Int
    var attachments: Int
    var skipped: Int

    var applied: Int { areas + projects + tasks + attachments }
  }

  enum TransferError: LocalizedError {
    case notJSON
    case missingEnvelope
    case unsupportedVersion(Int)
    case malformed(String)

    var errorDescription: String? {
      switch self {
      case .notJSON:
        return String(localized: "That file isn't valid JSON.",
                      comment: "Task JSON import: parse failed")
      case .missingEnvelope:
        return String(localized: "Missing the Septena export header (septena_export_version, section, tables).",
                      comment: "Task JSON import: missing envelope")
      case .unsupportedVersion(let v):
        return String(localized: "Export version \(v) is newer than this version of Septena understands.",
                      comment: "Task JSON import: newer version")
      case .malformed(let reason):
        return reason
      }
    }
  }

  static var todayStamp: String {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: Date())
  }

  static var suggestedFilename: String {
    "septena-tasks-\(todayStamp).json"
  }

  // MARK: - Export

  /// How `exportJSON` writes attachment bytes.
  enum AttachmentMode {
    /// Base64 inside `task_attachment` rows (importable, the default).
    case inline
    /// No attachment rows at all.
    case omit
    /// File metadata in a top-level `attachment_files` list that points at
    /// `attachments/...` next to the JSON inside a .zip bundle. The
    /// `task_attachment` table stays out so an import of the inner JSON
    /// restores every other row instead of failing on missing bytes.
    case manifest([[String: Any]])
  }

  static func exportJSON(context: ModelContext? = nil,
                         attachments attachmentMode: AttachmentMode = .inline) throws -> Data {
    let context = context ?? LocalStore.shared.container.mainContext
    let areas = try context.fetch(FetchDescriptor<AreaEntity>(sortBy: [SortDescriptor(\.position), SortDescriptor(\.id)]))
    let projects = try context.fetch(FetchDescriptor<ProjectEntity>(sortBy: [SortDescriptor(\.position), SortDescriptor(\.id)]))
    let tasks = try context.fetch(FetchDescriptor<TaskEntity>(sortBy: [SortDescriptor(\.position), SortDescriptor(\.id)]))
    let attachments: [TaskAttachmentEntity]
    if case .inline = attachmentMode {
      attachments = try context.fetch(FetchDescriptor<TaskAttachmentEntity>(sortBy: [SortDescriptor(\.position), SortDescriptor(\.id)]))
    } else {
      attachments = []
    }
    let checklistItems = try context.fetch(FetchDescriptor<TaskChecklistItemEntity>(sortBy: [SortDescriptor(\.position), SortDescriptor(\.id)]))
    let refs = try context.fetch(FetchDescriptor<TaskRefEntity>(sortBy: [SortDescriptor(\.taskID), SortDescriptor(\.id)]))
    let doSessions = try context.fetch(FetchDescriptor<DoSessionEntity>(sortBy: [SortDescriptor(\.taskID), SortDescriptor(\.id)]))
    let tags = try context.fetch(FetchDescriptor<TagEntity>(sortBy: [SortDescriptor(\.id)]))

    var tables: [String: [[String: Any]]] = [
      "area": areas.map(areaDict),
      "project": projects.map(projectDict),
      "task": tasks.map(taskDict),
      "checklist_item": checklistItems.map(checklistItemDict),
      "task_ref": refs.map(taskRefDict),
      "do_session": doSessions.map(doSessionDict),
      "tag": tags.map(tagDict),
    ]
    if case .inline = attachmentMode {
      tables["task_attachment"] = attachments.compactMap(attachmentDict)
    }

    var envelope: [String: Any] = [
      "septena_export_version": envelopeVersion,
      "section": "tasks",
      "exported_at": ISO8601DateFormatter().string(from: .now),
      "app_version": appVersion(),
      "tables": tables,
    ]
    if case .manifest(let files) = attachmentMode {
      envelope["attachment_files"] = files
    }
    return try JSONSerialization.data(withJSONObject: envelope,
                                      options: [.prettyPrinted, .sortedKeys])
  }

  private static func appVersion() -> String {
    let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    return "\(v) (\(b))"
  }

  private static func compact(_ dict: [String: Any?]) -> [String: Any] {
    dict.compactMapValues { $0 }
  }

  private static func areaDict(_ e: AreaEntity) -> [String: Any] {
    compact([
      "id": e.id, "title": e.title, "context": e.context,
      "emoji": e.emoji,
      "position": e.position, "updatedAt": e.updatedAt,
    ])
  }

  private static func projectDict(_ e: ProjectEntity) -> [String: Any] {
    compact([
      "id": e.id, "title": e.title, "status": e.statusRaw, "area": e.area,
      "created": e.created, "completedAt": e.completedAt,
      "notes": e.notes, "githubRepo": e.githubRepo, "checklistMode": e.checklistModeRaw,
      "position": e.position, "updatedAt": e.updatedAt, "deletedAt": e.deletedAt,
    ])
  }

  private static func taskDict(_ e: TaskEntity) -> [String: Any] {
    let iso = ISO8601DateFormatter()
    return compact([
      "id": e.id, "title": e.title, "status": e.statusRaw,
      "created": e.created, "scheduled": e.scheduled,
      "startTime": e.startTime, "durationMinutes": e.durationMinutes, "timeZone": e.timeZone,
      "deadline": e.deadline, "deferredDeadline": e.deferredDeadline,
      "waitingOn": e.waitingOn, "waitingSince": e.waitingSince,
      "today": e.today, "starred": e.starred ? true : nil,
      "tags": e.tagIDs.isEmpty ? nil : e.tagIDs,
      "todaySetOn": e.todaySetOn, "completedAt": e.completedAt,
      "area": e.area, "project": e.project, "notes": e.notes,
      "conversationJSON": e.conversationJSON,
      "recurrenceUnit": e.recurrenceUnit,
      "recurrenceInterval": e.recurrenceUnit != nil ? e.recurrenceInterval : nil,
      "recurrenceAfterCompletion": e.recurrenceUnit != nil ? e.recurrenceAfterCompletion : nil,
      "recurrenceMissed": e.recurrenceMissed, "recurrenceMissedFrom": e.recurrenceMissedFrom,
      "recurrencePaused": e.recurrencePaused ? true : nil,
      "recurrenceSeriesID": e.recurrenceSeriesID,
      "recurrenceAnchorDate": e.recurrenceAnchorDate,
      "recurrenceWeekdays": e.recurrence?.weekdays,
      "recurrenceMonthDay": e.recurrence?.monthDay,
      "recurrenceOrdinalWeekday": e.recurrence?.ordinalWeekday.map { ["ordinal": $0.ordinal, "weekday": $0.weekday] },
      "reminderAt": e.reminderAt,
      "reminderMode": e.reminderMode,
      "reminderSnoozedUntil": e.reminderSnoozedUntil,
      "reminderDismissedAt": e.reminderDismissedAt,
      "position": e.position, "todayPosition": e.todayPosition,
      "kind": e.kind.isEmpty ? nil : e.kind,
      "heading": e.heading,
      "sortIndex": e.sortIndex,
      "source": e.source,
      "sourceClient": e.sourceClient,
      "acknowledgedAt": e.acknowledgedAt.map { iso.string(from: $0) },
      "createdAt": e.createdAt == .distantPast ? nil : iso.string(from: e.createdAt),
      "touchedAt": e.touchedAt.map { iso.string(from: $0) },
      "deferCount": e.deferCount > 0 ? e.deferCount : nil,
      "fadedAt": e.fadedAt.map { iso.string(from: $0) },
      "dropReason": e.dropReason,
      "effort": e.effort,
      "updatedAt": e.updatedAt, "deletedAt": e.deletedAt,
    ])
  }

  private static func attachmentDict(_ e: TaskAttachmentEntity) -> [String: Any]? {
    guard let url = TaskAttachmentFiles.url(for: e),
          let data = try? Data(contentsOf: url) else { return nil }
    return compact([
      "id": e.id, "taskID": e.taskID, "filename": e.filename,
      "contentType": e.contentType, "byteCount": e.byteCount,
      "createdAt": ISO8601DateFormatter().string(from: e.createdAt),
      "position": e.position, "dataBase64": data.base64EncodedString(),
    ])
  }

  private static func checklistItemDict(_ e: TaskChecklistItemEntity) -> [String: Any] {
    let iso = ISO8601DateFormatter()
    return compact([
      "id": e.id,
      "taskID": e.taskID,
      "title": e.title,
      "checked": e.checked,
      "checkedAt": e.checkedAt.map { iso.string(from: $0) },
      "position": e.position,
      "createdAt": e.createdAt == .distantPast ? nil : iso.string(from: e.createdAt),
    ])
  }

  private static func taskRefDict(_ e: TaskRefEntity) -> [String: Any] {
    compact([
      "id": e.id,
      "taskID": e.taskID,
      "key": e.key,
      "kind": e.kind.isEmpty ? nil : e.kind,
      "role": e.role,
      "snapshot": e.snapshotJSON.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) },
      "position": e.position,
      "createdBy": e.createdBy,
      "lastSeenAt": e.lastSeenAt,
      "createdAt": e.createdAt == .distantPast ? nil : ISO8601DateFormatter().string(from: e.createdAt),
    ])
  }

  private static func doSessionDict(_ e: DoSessionEntity) -> [String: Any] {
    compact([
      "id": e.id,
      "taskID": e.taskID,
      "startedAt": e.startedAt,
      "plannedMinutes": e.plannedMinutes,
      "confirmedAt": e.confirmedAt,
      "endedAt": e.endedAt,
      "exit": e.exit,
      "lapsed": e.lapsed,
      "note": e.note,
      "sourceClient": e.sourceClient,
    ])
  }

  // MARK: - Parse

  static func parseEnvelope(_ data: Data) throws -> Envelope {
    let raw: Any
    do {
      raw = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
      throw TransferError.notJSON
    }
    guard let dict = raw as? [String: Any],
          let version = dict["septena_export_version"] as? Int,
          let section = dict["section"] as? String,
          let tablesRaw = dict["tables"] as? [String: Any]
    else { throw TransferError.missingEnvelope }
    if version > envelopeVersion {
      throw TransferError.unsupportedVersion(version)
    }
    var typed: [String: [[String: Any]]] = [:]
    for (table, rows) in tablesRaw {
      guard let rows = rows as? [[String: Any]] else {
        throw TransferError.malformed("Table '\(table)' is not an array of objects.")
      }
      typed[table] = rows
    }
    return Envelope(
      version: version,
      section: section,
      exportedAt: dict["exported_at"] as? String,
      appVersion: dict["app_version"] as? String,
      tables: typed
    )
  }

  // MARK: - Apply

  /// Upserts areas, projects, tasks and local attachment files into the local
  /// store and queues them for sync (if/when the user signs in). Runs
  /// completely offline with no account.
  static func apply(_ doc: Envelope,
                    context: ModelContext? = nil,
                    engine: CKEngine? = nil) throws -> ApplyResult {
    let context = context ?? LocalStore.shared.container.mainContext
    let engine = engine ?? SeptenaServices.shared.ckEngine
    var result = ApplyResult(areas: 0, projects: 0, tasks: 0, attachments: 0, skipped: doc.skippedRowCount)
    var areaIDs: [String] = []
    var projectIDs: [String] = []
    var taskIDs: [String] = []
    var attachmentIDs: [String] = []
    var checklistIDs: [String] = []
    var refIDs: [String] = []
    var doSessionIDs: [String] = []
    var tagIDs: [String] = []
    var tagIDRemap: [String: String] = [:]

    // Order: tags → areas → projects → tasks (headings first) → attachments → checklist_item → task_ref
    // so FK references resolve cleanly and case-insensitive tag merges remap task.tags.
    if let rows = doc.tables["tag"] {
      for r in rows {
        let (oldID, canonicalID) = try upsertTag(r, context: context)
        tagIDRemap[oldID] = canonicalID
        tagIDs.append(canonicalID)
      }
    }
    if let rows = doc.tables["area"] {
      for r in rows {
        let id = try upsertArea(r, context: context)
        areaIDs.append(id)
        result.areas += 1
      }
    }
    if let rows = doc.tables["project"] {
      for r in rows {
        let id = try upsertProject(r, context: context)
        projectIDs.append(id)
        result.projects += 1
      }
    }
    if let rows = doc.tables["task"] {
      let ordered = rows.sorted {
        (($0["kind"] as? String) == TaskKind.heading) && (($1["kind"] as? String) != TaskKind.heading)
      }
      for r in ordered {
        let id = try upsertTask(r, tagIDRemap: tagIDRemap, context: context)
        taskIDs.append(id)
        result.tasks += 1
      }
    }
    if let rows = doc.tables["task_attachment"] {
      for r in rows {
        let id = try upsertAttachment(r, context: context)
        attachmentIDs.append(id)
        result.attachments += 1
      }
    }
    if let rows = doc.tables["checklist_item"] {
      for r in rows {
        let id = try upsertChecklistItem(r, context: context)
        checklistIDs.append(id)
      }
    }

    if let rows = doc.tables["task_ref"] {
      for r in rows {
        if let id = try upsertTaskRef(r, context: context) {
          refIDs.append(id)
        } else {
          result.skipped += 1
        }
      }
    }

    if let rows = doc.tables["do_session"] {
      for r in rows {
        if let id = try upsertDoSession(r, context: context) {
          doSessionIDs.append(id)
        } else {
          result.skipped += 1
        }
      }
    }

    try StoreHealth.saveOrThrow(context, op: "TaskJSONTransfer.apply")

    for id in tagIDs { engine.noteTagChange(id: id) }
    for id in areaIDs { engine.noteAreaChange(id: id) }
    for id in projectIDs { engine.noteProjectChange(id: id) }
    for id in taskIDs { engine.noteTaskChange(id: id) }
    for id in attachmentIDs { engine.noteTaskAttachmentChange(id: id) }
    for id in checklistIDs { engine.noteChecklistItemChange(id: id) }
    for id in refIDs { engine.noteTaskRefChange(id: id) }
    for id in doSessionIDs { engine.noteDoSessionChange(id: id) }

    if !areaIDs.isEmpty || !projectIDs.isEmpty {
      NotificationCenter.default.post(name: .septenaStructureChanged, object: nil)
    }
    if !taskIDs.isEmpty || !attachmentIDs.isEmpty || !checklistIDs.isEmpty || !refIDs.isEmpty || !doSessionIDs.isEmpty || !tagIDs.isEmpty {
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    }
    return result
  }

  private static func upsertArea(_ r: [String: Any], context: ModelContext) throws -> String {
    guard let id = nonEmptyString(r["id"]), let title = r["title"] as? String else {
      throw TransferError.malformed("An area row is missing id or title.")
    }
    var desc = FetchDescriptor<AreaEntity>(predicate: #Predicate { $0.id == id })
    desc.fetchLimit = 1
    let existing = try context.fetch(desc).first
    let entity = existing ?? AreaEntity(id: id, title: title)
    if existing == nil { context.insert(entity) }
    entity.title = title
    entity.context = r["context"] as? String
    entity.emoji = r["emoji"] as? String
    if let pos = intValue(r["position"]) { entity.position = pos }
    if let updated = r["updatedAt"] as? String { entity.updatedAt = updated }
    return id
  }

  private static func upsertProject(_ r: [String: Any], context: ModelContext) throws -> String {
    guard let id = nonEmptyString(r["id"]), let title = r["title"] as? String else {
      throw TransferError.malformed("A project row is missing id or title.")
    }
    var desc = FetchDescriptor<ProjectEntity>(predicate: #Predicate { $0.id == id })
    desc.fetchLimit = 1
    let existing = try context.fetch(desc).first
    let statusRaw = normalizedProjectStatus(r["status"] as? String)
    let entity = existing ?? ProjectEntity(id: id, title: title, statusRaw: statusRaw)
    if existing == nil { context.insert(entity) }
    entity.title = title
    entity.statusRaw = statusRaw
    entity.checklistModeRaw = (r["checklistMode"] as? String).flatMap(ProjectChecklistMode.init(rawValue:))?.rawValue
    entity.area = nonEmptyString(r["area"])
    entity.created = r["created"] as? String
    entity.completedAt = r["completedAt"] as? String
    // Files written before ADR 0012 carry a separate project "context":
    // fold it into notes the way the backend's one-time merge did.
    entity.notes = ContainerNotes.mergingLegacyContext(
      notes: r["notes"] as? String, context: r["context"] as? String,
      day: SeptenaDate.today)
    entity.context = nil
    entity.githubRepo = r["githubRepo"] as? String
    if let pos = intValue(r["position"]) { entity.position = pos }
    entity.updatedAt = r["updatedAt"] as? String
    entity.deletedAt = r["deletedAt"] as? String
    return id
  }

  private static func upsertTask(_ r: [String: Any],
                                 tagIDRemap: [String: String] = [:],
                                 context: ModelContext) throws -> String {
    guard let id = nonEmptyString(r["id"]), let title = r["title"] as? String else {
      throw TransferError.malformed("A task row is missing id or title.")
    }
    var desc = FetchDescriptor<TaskEntity>(predicate: #Predicate { $0.id == id })
    desc.fetchLimit = 1
    let existing = try context.fetch(desc).first
    let statusRaw = normalizedTaskStatus(r["status"] as? String)
    let entity = existing ?? TaskEntity(id: id, title: title, statusRaw: statusRaw, createdAt: .now)
    if existing == nil { context.insert(entity) }
    entity.title = title
    entity.statusRaw = statusRaw
    entity.created = r["created"] as? String
    entity.scheduled = nonEmptyString(r["scheduled"])
    entity.startTime = nonEmptyString(r["startTime"])
    entity.durationMinutes = intValue(r["durationMinutes"]).map { min(1440, max(5, $0)) }
    entity.timeZone = nonEmptyString(r["timeZone"])
    entity.deadline = nonEmptyString(r["deadline"])
    entity.deferredDeadline = nonEmptyString(r["deferredDeadline"])
    entity.waitingOn = TaskWaiting.normalizedName(nonEmptyString(r["waitingOn"]))
    entity.waitingSince = entity.waitingOn == nil ? nil : nonEmptyString(r["waitingSince"])
    entity.today = (r["today"] as? Bool) ?? false
    entity.starred = (r["starred"] as? Bool) ?? false
    if let rawTags = r["tags"] as? [Any] {
      entity.tagIDs = rawTags.compactMap { nonEmptyString($0) }.map { tagIDRemap[$0] ?? $0 }
    } else {
      entity.tagIDs = []
    }
    entity.todaySetOn = nonEmptyString(r["todaySetOn"])
    entity.completedAt = nonEmptyString(r["completedAt"])
    entity.area = nonEmptyString(r["area"])
    entity.project = nonEmptyString(r["project"])
    entity.notes = r["notes"] as? String
    entity.recurrenceUnit = nonEmptyString(r["recurrenceUnit"])
    entity.recurrenceInterval = max(1, intValue(r["recurrenceInterval"]) ?? 1)
    entity.recurrenceAfterCompletion = (r["recurrenceAfterCompletion"] as? Bool) ?? true
    entity.recurrenceMissed = (r["recurrenceMissed"] as? String).flatMap(MissedRepeatBehavior.init(rawValue:))?.rawValue
    entity.recurrenceMissedFrom = r["recurrenceMissedFrom"] as? String
    entity.recurrencePaused = (r["recurrencePaused"] as? Bool) ?? false
    entity.recurrenceSeriesID = nonEmptyString(r["recurrenceSeriesID"])
    entity.recurrenceAnchorDate = nonEmptyString(r["recurrenceAnchorDate"])
    if let rawWeekdays = r["recurrenceWeekdays"] as? [Any] {
      let nums = rawWeekdays.compactMap(intValue).filter { (1...7).contains($0) }
      if !nums.isEmpty,
         let data = try? JSONEncoder().encode(Array(Set(nums)).sorted()),
         let s = String(data: data, encoding: .utf8) {
        entity.recurrenceWeekdaysJSON = s
      } else {
        entity.recurrenceWeekdaysJSON = nil
      }
    } else {
      entity.recurrenceWeekdaysJSON = nil
    }
    entity.recurrenceMonthDay = intValue(r["recurrenceMonthDay"])
    if let rawOrd = r["recurrenceOrdinalWeekday"] as? [String: Any],
       let ord = intValue(rawOrd["ordinal"]),
       let wd = intValue(rawOrd["weekday"]),
       let data = try? JSONEncoder().encode(RecurrenceOrdinalWeekday(ordinal: ord, weekday: wd)),
       let s = String(data: data, encoding: .utf8) {
      entity.recurrenceOrdinalWeekdayJSON = s
    } else {
      entity.recurrenceOrdinalWeekdayJSON = nil
    }
    entity.reminderAt = nonEmptyString(r["reminderAt"])
    entity.reminderMode = nonEmptyString(r["reminderMode"])
    entity.reminderSnoozedUntil = nonEmptyString(r["reminderSnoozedUntil"])
    entity.reminderDismissedAt = nonEmptyString(r["reminderDismissedAt"])
    entity.conversationJSON = nonEmptyString(r["conversationJSON"])
    entity.source = nonEmptyString(r["source"])
    entity.sourceClient = nonEmptyString(r["sourceClient"])
    let iso = ISO8601DateFormatter()
    if let ack = nonEmptyString(r["acknowledgedAt"]) { entity.acknowledgedAt = iso.date(from: ack) }
    if let cr = nonEmptyString(r["createdAt"]), let d = iso.date(from: cr) { entity.createdAt = d }
    if let touched = nonEmptyString(r["touchedAt"]) { entity.touchedAt = iso.date(from: touched) }
    if let defers = intValue(r["deferCount"]) { entity.deferCount = max(0, defers) }
    if let faded = nonEmptyString(r["fadedAt"]) { entity.fadedAt = iso.date(from: faded) }
    entity.dropReason = nonEmptyString(r["dropReason"])
    entity.effort = nonEmptyString(r["effort"])
    if let pos = doubleValue(r["position"]) { entity.position = pos }
    entity.todayPosition = doubleValue(r["todayPosition"])
    if let sort = intValue(r["sortIndex"]) { entity.sortIndex = sort }
    entity.kind = (r["kind"] as? String) ?? ""
    entity.heading = nonEmptyString(r["heading"])
    entity.updatedAt = r["updatedAt"] as? String
    entity.deletedAt = nonEmptyString(r["deletedAt"])
    return id
  }

  private static func upsertAttachment(_ r: [String: Any], context: ModelContext) throws -> String {
    guard let id = nonEmptyString(r["id"]),
          let taskID = nonEmptyString(r["taskID"]),
          let filename = nonEmptyString(r["filename"]),
          let contentType = nonEmptyString(r["contentType"]),
          let encoded = r["dataBase64"] as? String,
          let data = Data(base64Encoded: encoded)
    else {
      throw TransferError.malformed("An attachment row is missing file data or metadata.")
    }
    guard Int64(data.count) <= TaskAttachmentFiles.maxBytes else {
      throw TransferError.malformed("Attachment \(filename) is larger than 25 MB.")
    }
    var desc = FetchDescriptor<TaskAttachmentEntity>(predicate: #Predicate { $0.id == id })
    desc.fetchLimit = 1
    let existing = try context.fetch(desc).first
    let entity = existing ?? TaskAttachmentEntity(
      id: id, taskID: taskID, filename: filename,
      contentType: contentType, byteCount: Int64(data.count))
    if existing == nil { context.insert(entity) }
    entity.taskID = taskID
    entity.filename = filename
    entity.contentType = contentType
    entity.byteCount = Int64(data.count)
    entity.position = doubleValue(r["position"]) ?? 0
    if let stamp = r["createdAt"] as? String, let date = ISO8601DateFormatter().date(from: stamp) {
      entity.createdAt = date
    }
    let owned = TaskAttachmentFiles.ownedFilename(id: id, original: filename)
    try data.write(to: TaskAttachmentFiles.directory.appendingPathComponent(owned), options: .atomic)
    entity.localFilename = owned
    return id
  }

  private static func upsertChecklistItem(_ r: [String: Any], context: ModelContext) throws -> String {
    guard let id = nonEmptyString(r["id"]),
          let taskID = nonEmptyString(r["taskID"] ?? r["taskId"]),
          let title = r["title"] as? String else {
      throw TransferError.malformed("A checklist item row is missing id, taskID, or title.")
    }
    var desc = FetchDescriptor<TaskChecklistItemEntity>(predicate: #Predicate { $0.id == id })
    desc.fetchLimit = 1
    let existing = try context.fetch(desc).first
    let entity = existing ?? TaskChecklistItemEntity(id: id, taskID: taskID, title: title)
    if existing == nil { context.insert(entity) }
    entity.taskID = taskID
    entity.title = title
    entity.checked = (r["checked"] as? Bool) ?? false
    let iso = ISO8601DateFormatter()
    entity.checkedAt = (r["checkedAt"] as? String).flatMap { iso.date(from: $0) }
    entity.position = doubleValue(r["position"]) ?? 0
    if let stamp = r["createdAt"] as? String, let date = iso.date(from: stamp) {
      entity.createdAt = date
    }
    entity.updatedAt = Date()
    return id
  }

  /// Nil when the row cannot come back: its task is not here, or it has no
  /// start. An imported Do is history, so an open one ends where it started.
  private static func upsertDoSession(_ r: [String: Any], context: ModelContext) throws -> String? {
    guard let id = nonEmptyString(r["id"]),
          let taskID = nonEmptyString(r["taskID"] ?? r["taskId"]),
          let startedAt = nonEmptyString(r["startedAt"]), DoStamp.date(startedAt) != nil,
          try context.fetchCount(FetchDescriptor<TaskEntity>(predicate: #Predicate { $0.id == taskID })) > 0,
          try context.fetchCount(FetchDescriptor<DoSessionEntity>(predicate: #Predicate { $0.id == id })) == 0
    else { return nil }
    let entity = DoSessionEntity(id: id, taskID: taskID, startedAt: startedAt)
    entity.plannedMinutes = (r["plannedMinutes"] as? Int).map { min(max($0, 1), RegistryEntityLimits.doPlannedMinutesMax) }
    entity.confirmedAt = nonEmptyString(r["confirmedAt"]).flatMap { DoStamp.date($0) == nil ? nil : $0 }
    let ended = nonEmptyString(r["endedAt"]).flatMap { DoStamp.date($0) == nil ? nil : $0 }
    entity.endedAt = ended ?? startedAt
    entity.exit = nonEmptyString(r["exit"]).flatMap { RegistryEntityEnums.doExit.contains($0) ? $0 : nil }
      ?? DoExit.stopped.rawValue
    entity.lapsed = ended == nil || (r["lapsed"] as? Bool) ?? false
    entity.note = nonEmptyString(r["note"]).map { String($0.prefix(RegistryEntityLimits.doNoteMax)) }
    entity.sourceClient = nonEmptyString(r["sourceClient"])
    context.insert(entity)
    return id
  }

  /// Nil when the row cannot come back: its task is not here, the task is at
  /// its limit, the core does not read the key, or the row was deleted on the
  /// backend and this build cannot mint its next id.
  private static func upsertTaskRef(_ r: [String: Any], context: ModelContext) throws -> String? {
    guard let id = nonEmptyString(r["id"]),
          let taskID = nonEmptyString(r["taskID"] ?? r["taskId"]),
          let rawKey = nonEmptyString(r["key"]) else {
      throw TransferError.malformed("A reference row is missing id, taskID, or key.")
    }
    let role = nonEmptyString(r["role"]).flatMap { RegistryEntityEnums.taskRefRole.contains($0) ? $0 : nil }
      ?? TaskRefRole.about.rawValue
    let snapshotJSON = (r["snapshot"] as? [String: Any])
      .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
      .flatMap { try? JSONDecoder().decode(TaskRefSnapshot.self, from: $0) }?
      .storedJSON()

    let parsed = TaskRefCore.parse(rawKey)
    if TaskRefCore.isAvailable, parsed == nil { return nil }
    let key = parsed?.key ?? rawKey
    guard key.utf16.count <= RegistryEntityLimits.refKeyMax else { return nil }
    let siblings = try context.fetch(FetchDescriptor<TaskRefEntity>(predicate: #Predicate { $0.taskID == taskID }))
    if let existing = siblings.first(where: { $0.id == id }) ?? siblings.first(where: { $0.key == key }) {
      existing.role = role
      existing.snapshotJSON = snapshotJSON
      existing.position = doubleValue(r["position"])
      existing.updatedAt = Date()
      return existing.id
    }
    // An id that another task's reference holds: an insert would overwrite it.
    guard try context.fetchCount(FetchDescriptor<TaskRefEntity>(predicate: #Predicate { $0.id == id })) == 0,
          try context.fetchCount(FetchDescriptor<TaskEntity>(predicate: #Predicate { $0.id == taskID })) > 0,
          siblings.count < RegistryEntityLimits.maxRefsPerTask else { return nil }
    let sync = TaskSyncEngine.shared
    let liveID = sync.canRevive(.taskRef, id) ? id : sync.nextTaskRefID(taskID: taskID, key: key)
    guard let liveID else { return nil }
    let entity = TaskRefEntity(
      id: liveID, taskID: taskID, key: key, kind: parsed?.kind ?? (r["kind"] as? String) ?? "",
      role: role, snapshotJSON: snapshotJSON, position: doubleValue(r["position"]))
    entity.createdBy = nonEmptyString(r["createdBy"])
    entity.lastSeenAt = nonEmptyString(r["lastSeenAt"])
    if let stamp = nonEmptyString(r["createdAt"]), let date = ISO8601DateFormatter().date(from: stamp) {
      entity.createdAt = date
    }
    context.insert(entity)
    return liveID
  }

  private static func tagDict(_ e: TagEntity) -> [String: Any] {
    compact([
      "id": e.id,
      "name": e.name,
      "color": e.color,
      "position": e.position,
    ])
  }

  private static func upsertTag(_ r: [String: Any], context: ModelContext) throws -> (oldID: String, canonicalID: String) {
    guard let id = nonEmptyString(r["id"]),
          let rawName = r["name"] as? String else {
      throw TransferError.malformed("A tag row is missing id or name.")
    }
    let name = String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(RegistryEntityLimits.tagNameMax))
    guard !name.isEmpty else {
      throw TransferError.malformed("A tag row has an empty name.")
    }
    // Match by ID first, else case-insensitively by name to avoid duplicates on re-import.
    var byID = FetchDescriptor<TagEntity>(predicate: #Predicate { $0.id == id })
    byID.fetchLimit = 1
    if let existing = try context.fetch(byID).first {
      existing.name = name
      existing.color = nonEmptyString(r["color"])
      if let pos = intValue(r["position"]) { existing.position = pos }
      existing.updatedAt = Date()
      return (id, existing.id)
    }
    if let matched = LocalCache.tag(named: name, in: context) {
      return (id, matched.id)
    }
    let entity = TagEntity(
      id: id,
      name: name,
      color: nonEmptyString(r["color"]),
      position: intValue(r["position"]),
      updatedAt: Date()
    )
    context.insert(entity)
    return (id, entity.id)
  }

  private static func nonEmptyString(_ raw: Any?) -> String? {
    guard let s = raw as? String, !s.isEmpty else { return nil }
    return s
  }

  private static func intValue(_ raw: Any?) -> Int? {
    if let i = raw as? Int { return i }
    if let n = raw as? NSNumber { return n.intValue }
    return nil
  }

  private static func doubleValue(_ raw: Any?) -> Double? {
    if let d = raw as? Double { return d }
    if let n = raw as? NSNumber { return n.doubleValue }
    return nil
  }

  private static func normalizedTaskStatus(_ raw: String?) -> String {
    switch raw {
    case TaskStatus.done.rawValue: return TaskStatus.done.rawValue
    case TaskStatus.cancelled.rawValue: return TaskStatus.cancelled.rawValue
    case TaskStatus.checklistChecked.rawValue: return TaskStatus.checklistChecked.rawValue
    case TaskStatus.repeatExpired.rawValue: return TaskStatus.repeatExpired.rawValue
    default: return TaskStatus.open.rawValue
    }
  }

  private static func normalizedProjectStatus(_ raw: String?) -> String {
    switch raw {
    case ProjectStatus.done.rawValue, "completed": return ProjectStatus.done.rawValue
    case ProjectStatus.cancelled.rawValue: return ProjectStatus.cancelled.rawValue
    default: return ProjectStatus.active.rawValue
    }
  }

  // MARK: - Markdown & CSV Export (docs/DATA_EXPORT_SPEC.md, EX0)

  enum ExportFormat: String, CaseIterable, Identifiable {
    case json
    case markdown
    case csv

    var id: String { rawValue }

    var label: String {
      switch self {
      case .json: return String(localized: "JSON Backup", comment: "Export format")
      case .markdown: return String(localized: "Markdown", comment: "Export format")
      case .csv: return String(localized: "CSV", comment: "Export format")
      }
    }

    var contentType: UTType {
      switch self {
      case .json: return .json
      case .markdown: return UTType(filenameExtension: "md") ?? .plainText
      case .csv: return .commaSeparatedText
      }
    }

    var fileExtension: String {
      switch self {
      case .json: return "json"
      case .markdown: return "md"
      case .csv: return "csv"
      }
    }

    @MainActor
    func suggestedFilename(stamp: String? = nil) -> String {
      "septena-tasks-\(stamp ?? TaskJSONTransfer.todayStamp).\(fileExtension)"
    }
  }

  static func exportData(format: ExportFormat,
                         includeCompleted: Bool = true,
                         jsonAttachments: AttachmentMode = .inline,
                         context: ModelContext? = nil) throws -> Data {
    switch format {
    case .json:
      return try exportJSON(context: context, attachments: jsonAttachments)
    case .markdown:
      let text = try exportMarkdown(context: context, includeCompleted: includeCompleted)
      return Data(text.utf8)
    case .csv:
      let text = try exportCSV(context: context, includeCompleted: includeCompleted)
      return Data(text.utf8)
    }
  }

  static func exportMarkdown(context: ModelContext? = nil, includeCompleted: Bool = true) throws -> String {
    let context = context ?? LocalStore.shared.container.mainContext
    let tagsByID = LocalCache.tagsByID(in: context)
    let refsByTask = LocalCache.taskRefsByTask(in: context)
    let areas = try context.fetch(FetchDescriptor<AreaEntity>(sortBy: [SortDescriptor(\.position), SortDescriptor(\.id)]))
    let projects = try context.fetch(FetchDescriptor<ProjectEntity>(sortBy: [SortDescriptor(\.position), SortDescriptor(\.id)]))
      .filter { $0.deletedAt == nil }
    let allTasks = try context.fetch(FetchDescriptor<TaskEntity>(sortBy: [SortDescriptor(\.position), SortDescriptor(\.id)]))
      .filter { $0.deletedAt == nil }

    let openTasks = allTasks.filter { !$0.isHeading && $0.status == .open }
    let headingsByProject = Dictionary(grouping: allTasks.filter(\.isHeading)) { $0.project ?? "" }
    let completedTasks = allTasks
      .filter { !$0.isHeading && ($0.status == .done || $0.status == .cancelled) }
      .sorted { ($0.completedAt ?? "") > ($1.completedAt ?? "") }

    var lines: [String] = [
      "# Septena Tasks",
      "",
      "_Exported \(todayStamp)_",
      "",
    ]

    func appendTask(_ t: TaskEntity, indent: String = "") {
      let box: String
      switch t.status {
      case .open: box = "[ ]"
      case .done, .checklistChecked: box = "[x]"
      case .cancelled, .repeatExpired: box = "[-]"
      }
      var meta: [String] = []
      if t.today && t.status == .open { meta.append("today") }
      if t.starred { meta.append("★") }
      let tagNames = t.tagIDs.compactMap { tagsByID[$0]?.name }
      for tagName in tagNames {
        let token = tagName.contains(" ") ? "#\"\(tagName)\"" : "#\(tagName)"
        meta.append(token)
      }
      if let s = t.scheduled {
        if let slot = TaskTimeSlot.format(startTime: t.startTime, durationMinutes: t.durationMinutes) {
          meta.append("when: \(s) \(slot)")
        } else {
          meta.append("when: \(s)")
        }
      } else if let slot = TaskTimeSlot.format(startTime: t.startTime, durationMinutes: t.durationMinutes) {
        meta.append("time: \(slot)")
      }
      if let d = t.deadline { meta.append("deadline: \(d)") }
      if let r = t.recurrence { meta.append("repeat: \(r.shortLabel)") }
      if let rem = t.reminderAt { meta.append("reminder: \(rem)") }
      if let doneAt = t.completedAt, t.status != .open { meta.append("done: \(String(doneAt.prefix(10)))") }
      let suffix = meta.isEmpty ? "" : " _(\(meta.joined(separator: ", ")))_"
      lines.append("\(indent)- \(box) \(t.title)\(suffix)")
      if let notes = t.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
        for noteLine in notes.components(separatedBy: .newlines) {
          lines.append("\(indent)  > \(noteLine)")
        }
      }
      let steps = LocalCache.checklistItems(forTaskID: t.id, in: context)
      for step in steps {
        let stepBox = step.checked ? "[x]" : "[ ]"
        lines.append("\(indent)  - \(stepBox) \(step.title)")
      }
      for ref in refsByTask[t.id] ?? [] {
        let title = TaskTitleText.singleLine(ref.title ?? ref.key)
        let url = ref.webURL.map { " \($0.absoluteString)" } ?? ""
        lines.append("\(indent)  - \(title)\(url)")
      }
    }

    func appendProject(_ p: ProjectEntity, headingLevel: String) {
      let projectTasks = openTasks.filter { $0.project == p.id }
      let checked = allTasks.filter { $0.project == p.id && $0.status == .checklistChecked }
      let sections = (headingsByProject[p.id] ?? []).sorted { $0.position < $1.position }
      lines.append("\(headingLevel) \(p.title)")
      if let notes = p.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
        lines.append("")
        lines.append(notes)
      }
      lines.append("")
      let unsectioned = projectTasks.filter { $0.heading == nil }
      for t in unsectioned { appendTask(t) }
      if !unsectioned.isEmpty { lines.append("") }
      for s in sections {
        let inSection = projectTasks.filter { $0.heading == s.id }
        guard !inSection.isEmpty else { continue }
        lines.append("\(headingLevel)# \(s.title)")
        lines.append("")
        for t in inSection { appendTask(t) }
        lines.append("")
      }
      if !checked.isEmpty {
        lines.append("\(headingLevel)# Checked")
        lines.append("")
        for t in checked { appendTask(t) }
        lines.append("")
      }
    }

    let inbox = openTasks.filter { $0.area == nil && $0.project == nil }
    if !inbox.isEmpty {
      lines.append("## Inbox")
      lines.append("")
      for t in inbox { appendTask(t) }
      lines.append("")
    }

    for area in areas {
      let areaTasks = openTasks.filter { $0.area == area.id && $0.project == nil }
      let areaProjects = projects.filter { $0.area == area.id }
      guard !areaTasks.isEmpty || !areaProjects.isEmpty else { continue }
      let prefix = area.emoji.map { "\($0) " } ?? ""
      lines.append("## \(prefix)\(area.title)")
      lines.append("")
      for t in areaTasks { appendTask(t) }
      if !areaTasks.isEmpty { lines.append("") }
      for p in areaProjects { appendProject(p, headingLevel: "###") }
    }

    let standaloneProjects = projects.filter { $0.area == nil }
    if !standaloneProjects.isEmpty {
      lines.append("## Projects")
      lines.append("")
      for p in standaloneProjects { appendProject(p, headingLevel: "###") }
    }

    if includeCompleted && !completedTasks.isEmpty {
      lines.append("## Logbook")
      lines.append("")
      for t in completedTasks { appendTask(t) }
      lines.append("")
    }

    return lines.joined(separator: "\n")
  }

  /// RFC 4180 CSV with UTF-8 BOM for clean spreadsheet / importer ingestion.
  static func exportCSV(context: ModelContext? = nil, includeCompleted: Bool = true) throws -> String {
    let context = context ?? LocalStore.shared.container.mainContext
    let areas = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<AreaEntity>()).map { ($0.id, $0.title) })
    let projects = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<ProjectEntity>()).map { ($0.id, $0) })
    let tagsByID = LocalCache.tagsByID(in: context)
    let refsByTask = LocalCache.taskRefsByTask(in: context)
    let allTasks = try context.fetch(FetchDescriptor<TaskEntity>(sortBy: [SortDescriptor(\.position), SortDescriptor(\.id)]))
      .filter { $0.deletedAt == nil }
    let headings = Dictionary(uniqueKeysWithValues: allTasks.filter(\.isHeading).map { ($0.id, $0.title) })
    let rows = allTasks.filter { !$0.isHeading && (includeCompleted || $0.status == .open) }

    var out: [String] = [
      "\u{FEFF}id,title,status,area,project,section,today,starred,tags,scheduled,start_time,duration_minutes,deadline,reminder_at,recurrence,notes,created,completed_at,references"
    ]
    for t in rows {
      let projectEntity = t.project.flatMap { projects[$0] }
      let areaName = (t.area ?? projectEntity?.area).flatMap { areas[$0] } ?? ""
      let projectName = projectEntity?.title ?? ""
      let sectionName = t.heading.flatMap { headings[$0] } ?? ""
      let tagList = t.tagIDs.compactMap { tagsByID[$0]?.name }.joined(separator: ", ")
      let cols: [String] = [
        t.id,
        t.title,
        t.statusRaw,
        areaName,
        projectName,
        sectionName,
        t.today ? "true" : "false",
        t.starred ? "true" : "false",
        tagList,
        t.scheduled ?? "",
        t.startTime ?? "",
        t.durationMinutes.map(String.init) ?? "",
        t.deadline ?? "",
        t.reminderAt ?? "",
        t.recurrence?.shortLabel ?? "",
        t.notes ?? "",
        t.created ?? "",
        t.completedAt ?? "",
        (refsByTask[t.id] ?? []).map(\.key).joined(separator: " "),
      ]
      out.append(cols.map(csvEscape).joined(separator: ","))
    }
    return out.joined(separator: "\r\n") + "\r\n"
  }

  static func csvEscape(_ value: String) -> String {
    if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
      return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    return value
  }
}

// MARK: - Export bundle (docs/DATA_EXPORT_SPEC.md §2.4, EX1)

/// Builds one export file in a private temporary folder: a plain .json / .md /
/// .csv file, or a .zip bundle when attachments go out as separate files.
/// The bundle holds `septena-tasks.<ext>` plus `attachments/<id>-<filename>`.
/// Works offline with no account. Zips with `NSFileCoordinator`
/// `.forUploading`, the platform primitive on iOS and macOS.
@MainActor
enum TaskExportBundle {
  /// Inline base64 attachments in JSON up to this total; above it the export
  /// becomes a .zip so base64 does not inflate memory.
  static let inlineAttachmentLimit: Int64 = 25 * 1_024 * 1_024

  struct Result {
    let url: URL
    let contentType: UTType
    var filename: String { url.lastPathComponent }
    /// The temporary folder that holds `url`. Remove it when done.
    var workDirectory: URL { url.deletingLastPathComponent() }
  }

  private struct FileCopy: Sendable {
    let source: URL
    let relativePath: String
  }

  /// True when an export with these options saves as a .zip.
  static func producesZip(format: TaskJSONTransfer.ExportFormat,
                          includeAttachments: Bool,
                          attachmentCount: Int,
                          attachmentBytes: Int64) -> Bool {
    guard includeAttachments, attachmentCount > 0 else { return false }
    return format != .json || attachmentBytes > inlineAttachmentLimit
  }

  static func build(format: TaskJSONTransfer.ExportFormat,
                    includeCompleted: Bool,
                    includeAttachments: Bool,
                    context: ModelContext? = nil,
                    progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }) async throws -> Result {
    let context = context ?? LocalStore.shared.container.mainContext
    let work = FileManager.default.temporaryDirectory
      .appendingPathComponent("SeptenaExport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    do {
      let result = try await buildInto(work, format: format, includeCompleted: includeCompleted,
                                       includeAttachments: includeAttachments,
                                       context: context, progress: progress)
      progress(1)
      return result
    } catch {
      try? FileManager.default.removeItem(at: work)
      throw error
    }
  }

  private static func buildInto(_ work: URL,
                                format: TaskJSONTransfer.ExportFormat,
                                includeCompleted: Bool,
                                includeAttachments: Bool,
                                context: ModelContext,
                                progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> Result {
    progress(0)
    let rows = includeAttachments
      ? try attachmentRows(format: format, includeCompleted: includeCompleted, context: context)
      : []
    let totalBytes = rows.reduce(Int64(0)) { $0 + $1.byteCount }
    let zip = producesZip(format: format, includeAttachments: includeAttachments,
                          attachmentCount: rows.count, attachmentBytes: totalBytes)

    guard zip else {
      let data = try TaskJSONTransfer.exportData(
        format: format,
        includeCompleted: includeCompleted,
        jsonAttachments: includeAttachments ? .inline : .omit,
        context: context)
      try Task.checkCancellation()
      let url = work.appendingPathComponent(format.suggestedFilename())
      try data.write(to: url, options: .atomic)
      return Result(url: url, contentType: format.contentType)
    }

    let bundleName = "septena-tasks-\(TaskJSONTransfer.todayStamp)"
    let stage = work.appendingPathComponent(bundleName, isDirectory: true)
    let attachmentsDir = stage.appendingPathComponent("attachments", isDirectory: true)
    try FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)

    var copies: [FileCopy] = []
    var manifest: [[String: Any]] = []
    let iso = ISO8601DateFormatter()
    for row in rows {
      let relative = "attachments/" + bundleFilename(id: row.id, original: row.filename)
      copies.append(FileCopy(source: row.source, relativePath: relative))
      manifest.append([
        "id": row.id, "taskID": row.taskID, "filename": row.filename,
        "contentType": row.contentType, "byteCount": row.byteCount,
        "createdAt": iso.string(from: row.createdAt),
        "position": row.position, "path": relative,
      ])
    }

    let data = try TaskJSONTransfer.exportData(
      format: format,
      includeCompleted: includeCompleted,
      jsonAttachments: .manifest(manifest),
      context: context)
    try data.write(to: stage.appendingPathComponent("septena-tasks.\(format.fileExtension)"),
                   options: .atomic)
    progress(0.05)

    let zipURL = work.appendingPathComponent("\(bundleName).zip")
    let job = Task.detached(priority: .userInitiated) {
      for (index, copy) in copies.enumerated() {
        try Task.checkCancellation()
        try FileManager.default.copyItem(at: copy.source,
                                         to: stage.appendingPathComponent(copy.relativePath))
        await progress(0.05 + 0.85 * Double(index + 1) / Double(copies.count))
      }
      try Task.checkCancellation()
      try zipDirectory(stage, to: zipURL)
      try? FileManager.default.removeItem(at: stage)
    }
    try await withTaskCancellationHandler {
      try await job.value
    } onCancel: {
      job.cancel()
    }
    return Result(url: zipURL, contentType: .zip)
  }

  private struct AttachmentRow {
    let id: String
    let taskID: String
    let filename: String
    let contentType: String
    let byteCount: Int64
    let createdAt: Date
    let position: Double
    let source: URL
  }

  /// Attachments with a local file. JSON takes every row (it is lossless);
  /// Markdown and CSV take the rows of the tasks they export.
  private static func attachmentRows(format: TaskJSONTransfer.ExportFormat,
                                     includeCompleted: Bool,
                                     context: ModelContext) throws -> [AttachmentRow] {
    let entities = try context.fetch(FetchDescriptor<TaskAttachmentEntity>(
      sortBy: [SortDescriptor(\.position), SortDescriptor(\.id)]))
    var allowedTaskIDs: Set<String>?
    if format != .json {
      let tasks = try context.fetch(FetchDescriptor<TaskEntity>())
      allowedTaskIDs = Set(tasks
        .filter { $0.deletedAt == nil && !$0.isHeading && (includeCompleted || $0.status == .open) }
        .map(\.id))
    }
    return entities.compactMap { e in
      if let allowedTaskIDs, !allowedTaskIDs.contains(e.taskID) { return nil }
      guard let url = TaskAttachmentFiles.url(for: e),
            FileManager.default.fileExists(atPath: url.path) else { return nil }
      return AttachmentRow(id: e.id, taskID: e.taskID, filename: e.filename,
                           contentType: e.contentType, byteCount: e.byteCount,
                           createdAt: e.createdAt, position: e.position, source: url)
    }
  }

  private static func bundleFilename(id: String, original: String) -> String {
    let safe = original
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
    return safe.isEmpty ? id : "\(id)-\(safe)"
  }

  /// Zips `directory` into `destination`. The coordinator hands over a
  /// temporary .zip that is valid only inside the accessor, so copy it out.
  nonisolated private static func zipDirectory(_ directory: URL, to destination: URL) throws {
    var coordinatorError: NSError?
    var copyError: Error?
    NSFileCoordinator().coordinate(readingItemAt: directory,
                                   options: .forUploading,
                                   error: &coordinatorError) { zipped in
      do {
        try FileManager.default.copyItem(at: zipped, to: destination)
      } catch {
        copyError = error
      }
    }
    if let error = coordinatorError ?? copyError { throw error }
  }
}

// MARK: - Transferable & FileDocument

/// Builds the export file when the share sheet asks for it.
struct TaskExportFile: Transferable {
  let format: TaskJSONTransfer.ExportFormat
  let includeCompleted: Bool
  let includeAttachments: Bool

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .data) { item in
      let url = try await TaskExportBundle.build(
        format: item.format,
        includeCompleted: item.includeCompleted,
        includeAttachments: item.includeAttachments
      ).url
      return SentTransferredFile(url)
    }
  }
}

/// Kept for compatibility with any caller referencing the original JSON transferable.
struct TaskJSONExportFile: Transferable {
  let suggestedName: String

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: .json) { _ in
      try await MainActor.run { try TaskJSONTransfer.exportJSON() }
    }
    .suggestedFileName { $0.suggestedName }
  }
}

/// Hands a finished export file to `fileExporter` without loading it into memory.
struct TaskExportDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.data] }
  let url: URL

  init(url: URL) { self.url = url }

  init(configuration: ReadConfiguration) throws {
    throw CocoaError(.featureUnsupported)
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    try FileWrapper(url: url, options: .immediate)
  }
}

// MARK: - Settings pane

struct SeptaskImportExportPane: View {
  @Environment(\.modelContext) private var modelContext
  @State private var exportFormat: TaskJSONTransfer.ExportFormat = .json
  @State private var includeCompleted = true
  @State private var includeAttachments = true
  @State private var exportResult: TaskExportBundle.Result?
  @State private var exportDocument: TaskExportDocument?
  @State private var showingFileExporter = false
  @State private var exportError: String?
  @State private var exportTask: Task<Void, Never>?
  @State private var exportProgress: Double = 0

  @State private var showingFilePicker = false
  @State private var importDoc: TaskJSONTransfer.Envelope?
  @State private var importMessage: String?
  @State private var importIsError = false

  var body: some View {
    Form {
      moveInSection
      storageSection
      exportSection
      importSection
    }
    .formStyle(.grouped)
    .navigationTitle(RegistrySettings.pageById[RegistrySettings.PageID.importExport]?.title ?? "")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .fileExporter(
      isPresented: $showingFileExporter,
      document: exportDocument,
      contentType: exportResult?.contentType ?? exportFormat.contentType,
      defaultFilename: exportResult?.filename ?? exportFormat.suggestedFilename()
    ) { result in
      if case .failure(let error) = result {
        exportError = error.localizedDescription
      } else {
        exportError = nil
      }
      discardExportFile()
    }
    .onChange(of: exportFormat) { _, format in
      includeAttachments = format == .json
    }
    .onDisappear {
      exportTask?.cancel()
      if !showingFileExporter { discardExportFile() }
    }
    .fileImporter(
      isPresented: $showingFilePicker,
      allowedContentTypes: [.json],
      allowsMultipleSelection: false
    ) { handleFileImport($0) }
  }

  /// Source picker and past imports, on the import engine (MOVING_IN_SPEC §4).
  private var moveInSection: some View {
    ImportSourcesSection()
  }

  private var storageSection: some View {
    let taskCount = (try? modelContext.fetchCount(FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.kind != "heading" }
    ))) ?? 0
    let projectCount = (try? modelContext.fetchCount(FetchDescriptor<ProjectEntity>())) ?? 0
    let areaCount = (try? modelContext.fetchCount(FetchDescriptor<AreaEntity>())) ?? 0
    let attachments = SeptenaServices.shared.taskAttachmentStore.storageSummary
    return Section {
      LabeledContent("Tasks", value: "\(taskCount)")
      LabeledContent("Projects", value: "\(projectCount)")
      LabeledContent("Areas", value: "\(areaCount)")
      LabeledContent("Attachments",
                     value: attachments.count == 0
                       ? "0"
                       : "\(attachments.count) (\(ByteCountFormatter.string(fromByteCount: attachments.bytes, countStyle: .file)))")
    } header: {
      Text("On this device")
    }
  }

  private var exportSection: some View {
    let attachments = SeptenaServices.shared.taskAttachmentStore.storageSummary
    let willZip = TaskExportBundle.producesZip(format: exportFormat,
                                               includeAttachments: includeAttachments,
                                               attachmentCount: attachments.count,
                                               attachmentBytes: attachments.bytes)
    let isExporting = exportTask != nil
    return Section {
      Picker("Format", selection: $exportFormat) {
        ForEach(TaskJSONTransfer.ExportFormat.allCases) { fmt in
          Text(fmt.label).tag(fmt)
        }
      }
      .pickerStyle(.segmented)
      .disabled(isExporting)

      if exportFormat != .json {
        Toggle("Include completed tasks", isOn: $includeCompleted)
          .disabled(isExporting)
      }

      if attachments.count > 0 {
        Toggle("Include attachments", isOn: $includeAttachments)
          .disabled(isExporting)
        if willZip {
          Text("Saves a .zip with the attachments as separate files.")
            .font(.septenaCaption)
            .foregroundStyle(.secondary)
        }
      }

      if isExporting {
        HStack(spacing: 12) {
          ProgressView(value: exportProgress)
          Button("Cancel", role: .cancel) { exportTask?.cancel() }
        }
      } else {
        Button {
          startExport()
        } label: {
          Label("Save \(exportFormat.label)…", systemImage: "square.and.arrow.down")
        }

        ShareLink(item: TaskExportFile(format: exportFormat,
                                       includeCompleted: includeCompleted,
                                       includeAttachments: includeAttachments),
                  preview: SharePreview(willZip ? "septena-tasks-\(TaskJSONTransfer.todayStamp).zip"
                                                : exportFormat.suggestedFilename(),
                                        image: Image(systemName: "doc.text"))) {
          Label("Share \(exportFormat.label)…", systemImage: "square.and.arrow.up")
        }
      }

      if let exportError {
        Text(exportError)
          .font(.septenaCaption)
          .foregroundStyle(.red)
      }
    } header: {
      Text("Export")
    } footer: {
      Text("JSON Backup is lossless (every task, project, area, conversation, and local attachment). Over 25 MB of attachments, it saves as a .zip. Exports are unencrypted files stored where you choose. Free on every tier, offline with no account.")
    }
  }

  private func startExport() {
    // A save panel dismissed without saving skips the completion handler,
    // so a stale file from the previous run can still be here.
    discardExportFile()
    exportError = nil
    exportProgress = 0
    let format = exportFormat
    let completed = includeCompleted
    let attachments = includeAttachments
    exportTask = Task {
      defer { exportTask = nil }
      do {
        let result = try await TaskExportBundle.build(
          format: format,
          includeCompleted: completed,
          includeAttachments: attachments,
          context: modelContext,
          progress: { exportProgress = $0 })
        if Task.isCancelled {
          try? FileManager.default.removeItem(at: result.workDirectory)
          return
        }
        exportResult = result
        exportDocument = TaskExportDocument(url: result.url)
        showingFileExporter = true
      } catch is CancellationError {
        exportError = nil
      } catch {
        exportError = error.localizedDescription
      }
    }
  }

  private func discardExportFile() {
    if let exportResult {
      try? FileManager.default.removeItem(at: exportResult.workDirectory)
    }
    exportResult = nil
    exportDocument = nil
  }

  private var importSection: some View {
    Section {
      Button {
        showingFilePicker = true
      } label: {
        Label("Choose JSON File…", systemImage: "doc.badge.plus")
      }

      if let doc = importDoc {
        importPreview(doc)
      }

      if let importMessage {
        Text(importMessage)
          .font(.septenaCaption)
          .foregroundStyle(importIsError ? .red : .secondary)
      }
    } header: {
      Text("Restore backup")
    } footer: {
      Text("Imports a Septena JSON backup into this device. Items with the same ID are replaced by the backup’s version, new items are added, and nothing is deleted. For a .zip backup, unzip it and choose the JSON file inside; its attachments are not restored yet.")
    }
  }

  @ViewBuilder
  private func importPreview(_ doc: TaskJSONTransfer.Envelope) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Ready to import")
        .font(.septenaLabel)
      Text("\(doc.taskCount) tasks · \(doc.projectCount) projects · \(doc.areaCount) areas · \(doc.attachmentCount) attachments")
        .font(.septenaCaption)
        .foregroundStyle(.secondary)
      if doc.skippedRowCount > 0 {
        Text("\(doc.skippedRowCount) non-task rows will be skipped.")
          .font(.septenaCaption)
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 12) {
        Button(RegistrySettings.copy("import_export", "importConfirm")) { applyImport(doc) }
          .buttonStyle(.borderedProminent)
          .disabled(doc.supportedRowCount == 0)
        Button("Cancel", role: .cancel) { importDoc = nil }
      }
      .padding(.top, 2)
    }
    .padding(.vertical, 4)
  }

  private func handleFileImport(_ result: Result<[URL], Error>) {
    do {
      guard let url = try result.get().first else { return }
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      let data = try Data(contentsOf: url)
      importDoc = try TaskJSONTransfer.parseEnvelope(data)
      importMessage = nil
      importIsError = false
    } catch {
      importDoc = nil
      importMessage = error.localizedDescription
      importIsError = true
    }
  }

  private func applyImport(_ doc: TaskJSONTransfer.Envelope) {
    do {
      let result = try TaskJSONTransfer.apply(doc, context: modelContext)
      importDoc = nil
      importIsError = false
      if result.skipped > 0 {
        importMessage = "Imported \(result.applied) records (\(result.skipped) non-task rows skipped)."
      } else {
        importMessage = "Imported \(result.applied) records."
      }
      TaskNotices.completeStep(.importTasks, context: modelContext)
    } catch {
      importIsError = true
      importMessage = error.localizedDescription
    }
  }
}
