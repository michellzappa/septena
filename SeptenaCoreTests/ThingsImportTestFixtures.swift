import Foundation
import SQLite3

enum ThingsImportTestFixtures {

  /// Minimal Things-shaped SQLite file for parser/mapper tests.
  static func makeTemporaryDatabase(
    areas: [(id: String, title: String)] = [],
    projects: [(id: String, title: String, areaID: String?)] = [],
    tasks: [(id: String, title: String, areaID: String?, projectID: String?, status: Int, today: Bool)] = [],
    headings: [(id: String, title: String, projectID: String, index: Double)] = [],
    // taskID → owning heading uuid (writes the `heading` column on that task row)
    taskHeadings: [String: String] = [:]
  ) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("things-import-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dbURL = dir.appendingPathComponent("main.sqlite")

    var db: OpaquePointer?
    guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
      throw NSError(domain: "ThingsImportTestFixtures", code: 1)
    }
    defer { sqlite3_close(db) }

    try exec(db, """
      CREATE TABLE TMArea (uuid TEXT PRIMARY KEY, title TEXT, trashed INTEGER DEFAULT 0);
      CREATE TABLE TMTask (
        uuid TEXT PRIMARY KEY, title TEXT, type INTEGER, notes TEXT,
        area TEXT, project TEXT, heading TEXT, status INTEGER DEFAULT 0, trashed INTEGER DEFAULT 0,
        "index" REAL DEFAULT 0, todayIndex INTEGER DEFAULT 0, start INTEGER DEFAULT 0,
        startDate INTEGER, deadline INTEGER, dueDate REAL,
        creationDate REAL, stopDate REAL
      );
      CREATE TABLE TMTag (uuid TEXT PRIMARY KEY, title TEXT);
      CREATE TABLE TMTaskTag (tasks TEXT, tags TEXT);
      CREATE TABLE TMChecklistItem (uuid TEXT PRIMARY KEY, task TEXT, title TEXT, status INTEGER, "index" INTEGER);
      """)

    for area in areas {
      try exec(db, "INSERT INTO TMArea (uuid, title) VALUES ('\(area.id)', '\(sqlEscape(area.title))');")
    }
    for project in projects {
      let area = project.areaID.map { "'\($0)'" } ?? "NULL"
      try exec(db, """
        INSERT INTO TMTask (uuid, title, type, area, status)
        VALUES ('\(project.id)', '\(sqlEscape(project.title))', 1, \(area), 0);
        """)
    }
    for heading in headings {
      try exec(db, """
        INSERT INTO TMTask (uuid, title, type, project, status, "index")
        VALUES ('\(heading.id)', '\(sqlEscape(heading.title))', 2, '\(heading.projectID)', 0, \(heading.index));
        """)
    }
    for task in tasks {
      let area = task.areaID.map { "'\($0)'" } ?? "NULL"
      let project = task.projectID.map { "'\($0)'" } ?? "NULL"
      let heading = taskHeadings[task.id].map { "'\($0)'" } ?? "NULL"
      let todayIndex = task.today ? 1 : 0
      try exec(db, """
        INSERT INTO TMTask (uuid, title, type, area, project, heading, status, todayIndex)
        VALUES ('\(task.id)', '\(sqlEscape(task.title))', 0, \(area), \(project), \(heading), \(task.status), \(todayIndex));
        """)
    }

    return dbURL
  }

  private static func exec(_ db: OpaquePointer, _ sql: String) throws {
    var err: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
      let msg = err.map { String(cString: $0) } ?? "unknown"
      sqlite3_free(err)
      throw NSError(domain: "ThingsImportTestFixtures", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
    }
  }

  private static func sqlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "'", with: "''")
  }
}
