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
      let supported: Set<String> = ["area", "project", "task", "task_attachment"]
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

    let tables: [String: [[String: Any]]] = [
      "area": areas.map(areaDict),
      "project": projects.map(projectDict),
      "task": tasks.map(taskDict),
      "task_attachment": attachments.compactMap(attachmentDict),
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
      "emoji": e.emoji, "position": e.position, "updatedAt": e.updatedAt,
    ])
  }

  private static func projectDict(_ e: ProjectEntity) -> [String: Any] {
    compact([
      "id": e.id, "title": e.title, "status": e.statusRaw, "area": e.area,
      "created": e.created, "completedAt": e.completedAt,
      "notes": e.notes, "context": e.context, "githubRepo": e.githubRepo,
      "position": e.position, "updatedAt": e.updatedAt, "deletedAt": e.deletedAt,
    ])
  }

  private static func taskDict(_ e: TaskEntity) -> [String: Any] {
    compact([
      "id": e.id, "title": e.title, "status": e.statusRaw,
      "created": e.created, "scheduled": e.scheduled, "deadline": e.deadline,
      "today": e.today, "todaySetOn": e.todaySetOn, "completedAt": e.completedAt,
      "area": e.area, "project": e.project, "notes": e.notes,
      "recurrenceUnit": e.recurrenceUnit,
      "recurrenceInterval": e.recurrenceUnit != nil ? e.recurrenceInterval : nil,
      "recurrenceAfterCompletion": e.recurrenceUnit != nil ? e.recurrenceAfterCompletion : nil,
      "recurrencePaused": e.recurrencePaused ? true : nil,
      "recurrenceSeriesID": e.recurrenceSeriesID,
      "recurrenceAnchorDate": e.recurrenceAnchorDate,
      "recurrenceWeekdays": e.recurrence?.weekdays,
      "recurrenceMonthDay": e.recurrence?.monthDay,
      "recurrenceOrdinalWeekday": e.recurrence?.ordinalWeekday.map { ["ordinal": $0.ordinal, "weekday": $0.weekday] },
      "position": e.position, "todayPosition": e.todayPosition,
      "kind": e.kind.isEmpty ? nil : e.kind,
      "heading": e.heading,
      "sortIndex": e.sortIndex,
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

    // Order: areas → projects → tasks (headings first) → attachments so FK
    // references resolve cleanly if synced later.
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
        let id = try upsertTask(r, context: context)
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

    try StoreHealth.saveOrThrow(context, op: "TaskJSONTransfer.apply")

    for id in areaIDs { engine.noteAreaChange(id: id) }
    for id in projectIDs { engine.noteProjectChange(id: id) }
    for id in taskIDs { engine.noteTaskChange(id: id) }
    for id in attachmentIDs { engine.noteTaskAttachmentChange(id: id) }

    if !areaIDs.isEmpty || !projectIDs.isEmpty {
      NotificationCenter.default.post(name: .septenaStructureChanged, object: nil)
    }
    if !taskIDs.isEmpty || !attachmentIDs.isEmpty {
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
    entity.notes = r["notes"] as? String
    entity.context = r["context"] as? String
    entity.githubRepo = r["githubRepo"] as? String
    if let pos = intValue(r["position"]) { entity.position = pos }
    entity.updatedAt = r["updatedAt"] as? String
    entity.deletedAt = r["deletedAt"] as? String
    return id
  }

  private static func upsertTask(_ r: [String: Any], context: ModelContext) throws -> String {
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
}

// MARK: - Transferable & FileDocument

/// Lazily builds the JSON dump when the share sheet asks for bytes.
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
  static var readableContentTypes: [UTType] { [.json] }
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
  @State private var exportDocument: TaskJSONDocument?
  @State private var showingFileExporter = false
  @State private var exportError: String?

  @State private var showingFilePicker = false
  @State private var showingPaste = false
  @State private var pasteBuffer = ""
  @State private var importDoc: TaskJSONTransfer.Envelope?
  @State private var importMessage: String?
  @State private var importIsError = false

  var body: some View {
    Form {
      storageSection
      exportSection
      importSection
    }
    .formStyle(.grouped)
    .navigationTitle("Import & Export")
    .fileExporter(
      isPresented: $showingFileExporter,
      document: exportDocument,
      contentType: .json,
      defaultFilename: TaskJSONTransfer.suggestedFilename
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
    .sheet(isPresented: $showingPaste) { pasteSheet }
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
    let filename = TaskJSONTransfer.suggestedFilename
    return Section {
      Button {
        do {
          exportDocument = TaskJSONDocument(data: try TaskJSONTransfer.exportJSON(context: modelContext))
          showingFileExporter = true
          exportError = nil
        } catch {
          exportError = error.localizedDescription
        }
      } label: {
        Label("Save JSON Backup…", systemImage: "square.and.arrow.down")
      }

      ShareLink(item: TaskJSONExportFile(suggestedName: filename),
                preview: SharePreview(filename, image: Image(systemName: "doc.text"))) {
        Label("Share JSON Backup…", systemImage: "square.and.arrow.up")
      }

      if let exportError {
        Text(exportError)
          .font(.septenaCaption)
          .foregroundStyle(.red)
      }
    } header: {
      Text("Export")
    } footer: {
      Text("Exports every task, project, area, and local attachment as plain JSON. Works offline with no account.")
    }
  }

  private var importSection: some View {
    Section {
      Button {
        showingFilePicker = true
      } label: {
        Label("Choose JSON File…", systemImage: "doc.badge.plus")
      }
      Button {
        pasteBuffer = ""
        importMessage = nil
        showingPaste = true
      } label: {
        Label("Paste JSON…", systemImage: "doc.on.clipboard")
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
      Text("Import")
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
