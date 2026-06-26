import Foundation

enum ThingsImportParser {

  /// Resolve `main.sqlite` inside a `.thingsdatabase` bundle or accept a direct sqlite path.
  static func resolveDatabaseURL(_ url: URL) throws -> URL {
    var isDir: ObjCBool = false
    let path = url.path
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
      throw ThingsImportError.databaseNotFound
    }

    let name = url.lastPathComponent.lowercased()
    let isThingsBundle = name.hasSuffix(".thingsdatabase")

    if isDir.boolValue || isThingsBundle {
      let inner = url.appendingPathComponent("main.sqlite")
      if FileManager.default.fileExists(atPath: inner.path) { return inner }
      throw ThingsImportError.databaseNotFound
    }
    if name.hasSuffix(".sqlite") || name.hasSuffix(".sqlite3") { return url }
    throw ThingsImportError.databaseNotFound
  }

  static func parse(databaseURL: URL, options: ThingsImportOptions, copyToScratchpad: Bool = true) throws -> ThingsDatabaseSnapshot {
    let source = try resolveDatabaseURL(databaseURL)
    let dbURL = copyToScratchpad ? try ThingsImportScratchpad.prepareForParsing(source: source) : source
    return try parseResolvedDatabase(at: dbURL, options: options)
  }

  static func parseResolvedDatabase(at dbURL: URL, options: ThingsImportOptions) throws -> ThingsDatabaseSnapshot {
    let dbPath = dbURL.path
    let reader = try ThingsSQLiteReader(path: dbPath)

    guard reader.tableExists("TMTask") else {
      let tables = (try? reader.listTables()) ?? []
      throw ThingsImportError.notThingsDatabase(foundTables: tables)
    }

    let taskColumns = reader.columnNames(in: "TMTask")
    let hasDeadlineCol = taskColumns.contains("deadline")
    let hasDueDateCol = taskColumns.contains("dueDate")
    let hasStartDateCol = taskColumns.contains("startDate")

    var areas: [ThingsAreaRecord] = []
    if reader.tableExists("TMArea") {
      let areaRows = try reader.queryRows(sql: "SELECT uuid, title, trashed FROM TMArea")
      areas = areaRows.compactMap { parseArea($0) }
    }

    let projectRows = try reader.queryRows(sql: """
      SELECT uuid, title, notes, area, status, trashed, type
      FROM TMTask
      WHERE type = 1
      """)
    var projects = projectRows.compactMap { parseProject($0) }

    let taskRows = try reader.queryRows(sql: """
      SELECT uuid, title, notes, area, project, status, trashed, type, "index",
             todayIndex, start, \(hasStartDateCol ? "startDate" : "NULL AS startDate"),
             \(hasDeadlineCol ? "deadline" : "NULL AS deadline"),
             \(hasDueDateCol ? "dueDate" : "NULL AS dueDate"),
             creationDate, stopDate
      FROM TMTask
      WHERE type = 0
      """)
    var tasks = taskRows.compactMap { parseTask($0, hasDeadlineCol: hasDeadlineCol, hasDueDateCol: hasDueDateCol, hasStartDateCol: hasStartDateCol) }

    let tagsByTask = try loadTags(reader: reader)
    let checklistByTask = try loadChecklists(reader: reader)

    for i in tasks.indices {
      tasks[i].tags = tagsByTask[tasks[i].id] ?? []
      tasks[i].checklistLines = checklistByTask[tasks[i].id] ?? []
    }

    tasks = tasks.filter { shouldInclude($0, options: options) }
    projects = projects.filter { shouldIncludeProject($0, options: options) }
    areas = areas.filter { !$0.trashed || options.includeTrashed }

    if tasks.isEmpty && projects.isEmpty && areas.isEmpty {
      throw ThingsImportError.emptyDatabase
    }

    return ThingsDatabaseSnapshot(areas: areas, projects: projects, tasks: tasks)
  }

  // MARK: - Row parsers

  private static func parseArea(_ row: [String: Any?]) -> ThingsAreaRecord? {
    guard let id = row["uuid"] as? String, let title = row["title"] as? String else { return nil }
    return ThingsAreaRecord(
      id: id,
      title: title.trimmingCharacters(in: .whitespacesAndNewlines),
      trashed: intValue(row["trashed"]) != 0
    )
  }

  private static func parseProject(_ row: [String: Any?]) -> ThingsProjectRecord? {
    guard let id = row["uuid"] as? String, let title = row["title"] as? String else { return nil }
    let statusRaw = intValue(row["status"]) ?? 0
    return ThingsProjectRecord(
      id: id,
      title: title.trimmingCharacters(in: .whitespacesAndNewlines),
      areaID: row["area"] as? String,
      notes: nonEmpty(row["notes"] as? String),
      status: ThingsItemStatus(rawValue: statusRaw) ?? .open,
      trashed: intValue(row["trashed"]) != 0
    )
  }

  private static func parseTask(
    _ row: [String: Any?],
    hasDeadlineCol: Bool,
    hasDueDateCol: Bool,
    hasStartDateCol: Bool
  ) -> ThingsTaskRecord? {
    guard let id = row["uuid"] as? String, let title = row["title"] as? String else { return nil }
    let statusRaw = intValue(row["status"]) ?? 0
    let startMode = intValue(row["start"]) ?? 0
    let todayIndex = intValue(row["todayIndex"]) ?? 0

    let deadline: Date? = {
      if hasDeadlineCol, let raw = row["deadline"] as? Int64 {
        return ThingsDateDecoder.decodeThingsDate(raw)
      }
      if hasDueDateCol, let raw = row["dueDate"] as? Double {
        return ThingsDateDecoder.decodeUnixTimestamp(raw)
      }
      return nil
    }()

    let scheduled: Date? = {
      if hasStartDateCol, let raw = row["startDate"] as? Int64 {
        return ThingsDateDecoder.decodeThingsDate(raw)
      }
      return nil
    }()

    let onToday = todayIndex > 0

    return ThingsTaskRecord(
      id: id,
      title: title.trimmingCharacters(in: .whitespacesAndNewlines),
      notes: nonEmpty(row["notes"] as? String),
      areaID: row["area"] as? String,
      projectID: row["project"] as? String,
      status: ThingsItemStatus(rawValue: statusRaw) ?? .open,
      trashed: intValue(row["trashed"]) != 0,
      sortIndex: doubleValue(row["index"]) ?? 0,
      today: onToday,
      scheduled: scheduled,
      deadline: deadline,
      created: ThingsDateDecoder.decodeUnixTimestamp(row["creationDate"] as? Double),
      completedAt: ThingsDateDecoder.decodeUnixTimestamp(row["stopDate"] as? Double),
      tags: [],
      checklistLines: []
    )
  }

  private static func shouldInclude(_ task: ThingsTaskRecord, options: ThingsImportOptions) -> Bool {
    if task.trashed { return options.includeTrashed }
    switch task.status {
    case .completed: return options.includeCompleted
    case .cancelled: return options.includeCancelled
    case .open: return true
    }
  }

  private static func shouldIncludeProject(_ project: ThingsProjectRecord, options: ThingsImportOptions) -> Bool {
    if project.trashed { return options.includeTrashed }
    switch project.status {
    case .completed: return options.includeCompleted
    case .cancelled: return options.includeCancelled
    case .open: return true
    }
  }

  private static func loadTags(reader: ThingsSQLiteReader) throws -> [String: [String]] {
    guard reader.tableExists("TMTag"), reader.tableExists("TMTaskTag") else { return [:] }
    let rows = try reader.queryRows(sql: """
      SELECT TTT.tasks AS taskID, TT.title AS tagTitle
      FROM TMTaskTag TTT
      JOIN TMTag TT ON TTT.tags = TT.uuid
      """)
    var out: [String: [String]] = [:]
    for row in rows {
      guard let taskID = row["taskID"] as? String,
            let tag = row["tagTitle"] as? String else { continue }
      out[taskID, default: []].append(tag)
    }
    return out
  }

  private static func loadChecklists(reader: ThingsSQLiteReader) throws -> [String: [String]] {
    guard reader.tableExists("TMChecklistItem") else { return [:] }
    let cols = reader.columnNames(in: "TMChecklistItem")
    let taskCol = cols.contains("task") ? "task" : (cols.contains("tasks") ? "tasks" : nil)
    guard let taskCol else { return [:] }
    let statusCol = cols.contains("status") ? "status" : "NULL AS status"
    let rows = try reader.queryRows(sql: """
      SELECT \(taskCol) AS taskID, title, \(statusCol)
      FROM TMChecklistItem
      ORDER BY "index"
      """)
    var out: [String: [String]] = [:]
    for row in rows {
      guard let taskID = row["taskID"] as? String,
            let title = row["title"] as? String else { continue }
      let done = intValue(row["status"]) == 3
      let prefix = done ? "- [x] " : "- [ ] "
      out[taskID, default: []].append(prefix + title)
    }
    return out
  }

  private static func intValue(_ any: Any?) -> Int? {
    if let i = any as? Int64 { return Int(i) }
    if let i = any as? Int { return i }
    if let d = any as? Double { return Int(d) }
    return nil
  }

  private static func doubleValue(_ any: Any?) -> Double? {
    if let d = any as? Double { return d }
    if let i = any as? Int64 { return Double(i) }
    return nil
  }

  private static func nonEmpty(_ s: String?) -> String? {
    guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return s
  }
}
