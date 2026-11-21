import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// Plain JSON export & import for Septena (the task app).
//
// Free on every tier, with no account and no network
// (docs/SYNC_SUBSCRIPTION_SPEC.md §3). Uses the same `septena_export_version: 1`
// envelope as Septena Life so exports round-trip cleanly and a full Septena
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
      let supported: Set<String> = ["area", "project", "task", "task_attachment", "checklist_item", "tag"]
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

  static func exportJSON(context: ModelContext? = nil) throws -> Data {
    let context = context ?? LocalStore.shared.container.mainContext
    let areas = try context.fetch(FetchDescriptor<AreaEntity>(sortBy: [SortDescriptor(\.position), SortDescriptor(\.id)]))
    let projects = try context.fetch(FetchDescriptor<ProjectEntity>(sortBy: [SortDescriptor(\.position), SortDescriptor(\.id)]))
    let tasks = try context.fetch(FetchDescriptor<TaskEntity>(sortBy: [SortDescriptor(\.position), SortDescriptor(\.id)]))
    let attachments = try context.fetch(FetchDescriptor<TaskAttachmentEntity>(sortBy: [SortDescriptor(\.position), SortDescriptor(\.id)]))
    let checklistItems = try context.fetch(FetchDescriptor<TaskChecklistItemEntity>(sortBy: [SortDescriptor(\.position), SortDescriptor(\.id)]))
    let tags = try context.fetch(FetchDescriptor<TagEntity>(sortBy: [SortDescriptor(\.id)]))

    let tables: [String: [[String: Any]]] = [
      "area": areas.map(areaDict),
      "project": projects.map(projectDict),
      "task": tasks.map(taskDict),
      "task_attachment": attachments.compactMap(attachmentDict),
      "checklist_item": checklistItems.map(checklistItemDict),
      "tag": tags.map(tagDict),
    ]

    let envelope: [String: Any] = [
      "septena_export_version": envelopeVersion,
      "section": "tasks",
      "exported_at": ISO8601DateFormatter().string(from: .now),
      "app_version": appVersion(),
      "tables": tables,
    ]
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
      "notes": e.notes, "githubRepo": e.githubRepo,
      "position": e.position, "updatedAt": e.updatedAt, "deletedAt": e.deletedAt,
    ])
  }

  private static func taskDict(_ e: TaskEntity) -> [String: Any] {
    let iso = ISO8601DateFormatter()
    return compact([
      "id": e.id, "title": e.title, "status": e.statusRaw,
      "created": e.created, "scheduled": e.scheduled, "deadline": e.deadline,
      "today": e.today, "starred": e.starred ? true : nil,
      "tags": e.tagIDs.isEmpty ? nil : e.tagIDs,
      "todaySetOn": e.todaySetOn, "completedAt": e.completedAt,
      "area": e.area, "project": e.project, "notes": e.notes,
      "conversationJSON": e.conversationJSON,
      "recurrenceUnit": e.recurrenceUnit,
      "recurrenceInterval": e.recurrenceUnit != nil ? e.recurrenceInterval : nil,
      "recurrenceAfterCompletion": e.recurrenceUnit != nil ? e.recurrenceAfterCompletion : nil,
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
    var tagIDs: [String] = []
    var tagIDRemap: [String: String] = [:]

    // Order: tags → areas → projects → tasks (headings first) → attachments → checklist_item
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

    try StoreHealth.saveOrThrow(context, op: "TaskJSONTransfer.apply")

    for id in tagIDs { engine.noteTagChange(id: id) }
    for id in areaIDs { engine.noteAreaChange(id: id) }
    for id in projectIDs { engine.noteProjectChange(id: id) }
    for id in taskIDs { engine.noteTaskChange(id: id) }
    for id in attachmentIDs { engine.noteTaskAttachmentChange(id: id) }
    for id in checklistIDs { engine.noteChecklistItemChange(id: id) }

    if !areaIDs.isEmpty || !projectIDs.isEmpty {
      NotificationCenter.default.post(name: .septenaStructureChanged, object: nil)
    }
    if !taskIDs.isEmpty || !attachmentIDs.isEmpty || !checklistIDs.isEmpty || !tagIDs.isEmpty {
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
    entity.deadline = nonEmptyString(r["deadline"])
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
                         context: ModelContext? = nil) throws -> Data {
    switch format {
    case .json:
      return try exportJSON(context: context)
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
    let areas = try context.fetch(FetchDescriptor<AreaEntity>(sortBy: [SortDescriptor(\.position), SortDescriptor(\.id)]))
    let projects = try context.fetch(FetchDescriptor<ProjectEntity>(sortBy: [SortDescriptor(\.position), SortDescriptor(\.id)]))
      .filter { $0.deletedAt == nil }
    let allTasks = try context.fetch(FetchDescriptor<TaskEntity>(sortBy: [SortDescriptor(\.position), SortDescriptor(\.id)]))
      .filter { $0.deletedAt == nil }

    let openTasks = allTasks.filter { !$0.isHeading && $0.status == .open }
    let headingsByProject = Dictionary(grouping: allTasks.filter(\.isHeading)) { $0.project ?? "" }
    let completedTasks = allTasks
      .filter { !$0.isHeading && $0.status != .open }
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
      case .done: box = "[x]"
      case .cancelled: box = "[-]"
      }
      var meta: [String] = []
      if t.today && t.status == .open { meta.append("today") }
      if t.starred { meta.append("★") }
      let tagNames = t.tagIDs.compactMap { tagsByID[$0]?.name }
      for tagName in tagNames {
        let token = tagName.contains(" ") ? "#\"\(tagName)\"" : "#\(tagName)"
        meta.append(token)
      }
      if let s = t.scheduled { meta.append("when: \(s)") }
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
    }

    func appendProject(_ p: ProjectEntity, headingLevel: String) {
      let projectTasks = openTasks.filter { $0.project == p.id }
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
    let allTasks = try context.fetch(FetchDescriptor<TaskEntity>(sortBy: [SortDescriptor(\.position), SortDescriptor(\.id)]))
      .filter { $0.deletedAt == nil }
    let headings = Dictionary(uniqueKeysWithValues: allTasks.filter(\.isHeading).map { ($0.id, $0.title) })
    let rows = allTasks.filter { !$0.isHeading && (includeCompleted || $0.status == .open) }

    var out: [String] = [
      "\u{FEFF}id,title,status,area,project,section,today,starred,tags,scheduled,deadline,reminder_at,recurrence,notes,created,completed_at"
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
        t.deadline ?? "",
        t.reminderAt ?? "",
        t.recurrence?.shortLabel ?? "",
        t.notes ?? "",
        t.created ?? "",
        t.completedAt ?? "",
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

// MARK: - Transferable & FileDocument

/// Lazily builds the export bytes when the share sheet asks for them.
struct TaskExportFile: Transferable {
  let format: TaskJSONTransfer.ExportFormat
  let includeCompleted: Bool
  let suggestedName: String

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: .data) { item in
      try await MainActor.run {
        try TaskJSONTransfer.exportData(format: item.format, includeCompleted: item.includeCompleted)
      }
    }
    .suggestedFileName { $0.suggestedName }
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

struct TaskJSONDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.json, .plainText, .commaSeparatedText] }
  var data: Data

  init(data: Data) { self.data = data }

  init(configuration: ReadConfiguration) throws {
    self.data = configuration.file.regularFileContents ?? Data()
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

// MARK: - Settings pane

struct SeptaskImportExportPane: View {
  @Environment(\.modelContext) private var modelContext
  @State private var exportFormat: TaskJSONTransfer.ExportFormat = .json
  @State private var includeCompleted = true
  @State private var exportDocument: TaskJSONDocument?
  @State private var showingFileExporter = false
  @State private var exportError: String?

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
      contentType: exportFormat.contentType,
      defaultFilename: exportFormat.suggestedFilename()
    ) { result in
      if case .failure(let error) = result {
        exportError = error.localizedDescription
      } else {
        exportError = nil
      }
      exportDocument = nil
    }
    .fileImporter(
      isPresented: $showingFilePicker,
      allowedContentTypes: [.json],
      allowsMultipleSelection: false
    ) { handleFileImport($0) }
  }

  private var moveIn: RegistrySettingsSection? {
    RegistrySettings.section("move_in", page: RegistrySettings.PageID.importExport)
  }

  private var thingsItem: RegistrySettingsItem? { RegistrySettings.itemBySurface["things_import"] }

  private var moveInSection: some View {
    Section {
      NavigationLink {
        ThingsImportView()
          .navigationTitle(thingsItem?.label ?? "")
      } label: {
        Label(thingsItem?.label ?? "", systemImage: thingsItem?.sfSymbol ?? "square.and.arrow.down")
      }
    } header: {
      Text(moveIn?.header ?? "")
    } footer: {
      if let footer = moveIn?.footer { Text(footer) }
    }
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
    let filename = exportFormat.suggestedFilename()
    return Section {
      Picker("Format", selection: $exportFormat) {
        ForEach(TaskJSONTransfer.ExportFormat.allCases) { fmt in
          Text(fmt.label).tag(fmt)
        }
      }
      .pickerStyle(.segmented)

      if exportFormat != .json {
        Toggle("Include completed tasks", isOn: $includeCompleted)
      }

      Button {
        do {
          let bytes = try TaskJSONTransfer.exportData(
            format: exportFormat,
            includeCompleted: includeCompleted,
            context: modelContext
          )
          exportDocument = TaskJSONDocument(data: bytes)
          showingFileExporter = true
          exportError = nil
        } catch {
          exportError = error.localizedDescription
        }
      } label: {
        Label("Save \(exportFormat.label)…", systemImage: "square.and.arrow.down")
      }

      ShareLink(item: TaskExportFile(format: exportFormat,
                                     includeCompleted: includeCompleted,
                                     suggestedName: filename),
                preview: SharePreview(filename, image: Image(systemName: "doc.text"))) {
        Label("Share \(exportFormat.label)…", systemImage: "square.and.arrow.up")
      }

      if let exportError {
        Text(exportError)
          .font(.septenaCaption)
          .foregroundStyle(.red)
      }
    } header: {
      Text("Export")
    } footer: {
      Text("JSON Backup is lossless (every task, project, area, conversation, and local attachment). Exports are unencrypted files stored where you choose. Free on every tier, offline with no account.")
    }
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
      Text("Imports a Septena JSON backup into this device. Matching IDs update in place; non-task records are skipped.")
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
        Button("Import") { applyImport(doc) }
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

/// Raw JSON paste utility, hosted in Settings ▸ About ▸ Advanced (`paste_json_import`,
/// docs/SETTINGS_UX_SPEC.md) so everyday Import & Export stays focused on files.
struct SeptaskPasteJSONSection: View {
  @Environment(\.modelContext) private var modelContext
  @State private var showingPaste = false
  @State private var pasteBuffer = ""
  @State private var importDoc: TaskJSONTransfer.Envelope?
  @State private var importMessage: String?
  @State private var importIsError = false

  private static let item = RegistrySettings.itemBySurface["paste_json_import"]
  private static let section = RegistrySettings.section("data_tools", page: RegistrySettings.PageID.advanced)

  var body: some View {
    Section {
      Button {
        pasteBuffer = ""
        importMessage = nil
        showingPaste = true
      } label: {
        Label(Self.item?.label ?? "", systemImage: Self.item?.sfSymbol ?? "doc.on.clipboard")
      }
      .sheet(isPresented: $showingPaste) { pasteSheet }

      if let doc = importDoc {
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
            Button("Import") { applyImport(doc) }
              .buttonStyle(.borderedProminent)
              .disabled(doc.supportedRowCount == 0)
            Button("Cancel", role: .cancel) { importDoc = nil }
          }
          .padding(.top, 2)
        }
        .padding(.vertical, 4)
      }

      if let importMessage {
        Text(importMessage)
          .font(.septenaCaption)
          .foregroundStyle(importIsError ? .red : .secondary)
      }
    } header: {
      Text(Self.section?.header ?? "")
    } footer: {
      if let footer = Self.section?.footer { Text(footer) }
    }
  }

  private var pasteSheet: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 10) {
        Text("Paste a Septena JSON export below.")
          .font(.septenaCaption)
          .foregroundStyle(.secondary)
        TextEditor(text: $pasteBuffer)
          .font(.septenaCaption)
          .frame(minHeight: 220)
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
          )
      }
      .padding()
      .navigationTitle("Paste JSON")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { showingPaste = false }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Review") {
            do {
              importDoc = try TaskJSONTransfer.parseEnvelope(Data(pasteBuffer.utf8))
              importMessage = nil
              importIsError = false
              showingPaste = false
            } catch {
              importMessage = error.localizedDescription
              importIsError = true
              showingPaste = false
            }
          }
          .disabled(pasteBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
    #if os(macOS)
    .frame(width: 480, height: 340)
    #endif
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
