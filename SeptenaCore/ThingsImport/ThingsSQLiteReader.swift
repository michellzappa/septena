import Foundation
import SQLite3

// Thin, testable SQLite wrapper for read-only Things database access.

struct ThingsSQLiteReader {
  private final class Handle {
    var db: OpaquePointer?
    init(path: String) throws {
      var handle: OpaquePointer?
      let flags = SQLITE_OPEN_READONLY
      let code = sqlite3_open_v2(path, &handle, flags, nil)
      guard code == SQLITE_OK, let handle else {
        let msg = String(cString: sqlite3_errmsg(handle))
        sqlite3_close(handle)
        throw ThingsImportError.sqliteOpenFailed(msg)
      }
      db = handle
    }
    deinit {
      if let db { sqlite3_close(db) }
    }
  }

  private let handle: Handle

  init(path: String) throws {
    handle = try Handle(path: path)
  }

  func tableExists(_ name: String) -> Bool {
    let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1"
    guard let value = try? querySingleInt(sql: sql, bindings: [.text(name)]) else { return false }
    return value == 1
  }

  func listTables() throws -> [String] {
    let rows = try queryRows(sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
    return rows.compactMap { $0["name"] as? String }
  }

  func columnNames(in table: String) -> Set<String> {
    guard tableExists(table) else { return [] }
    let sql = "PRAGMA table_info(\(table))"
    guard let rows = try? queryRows(sql: sql) else { return [] }
    return Set(rows.compactMap { $0["name"] as? String })
  }

  func queryRows(sql: String, bindings: [SQLiteBinding] = []) throws -> [[String: Any?]] {
    guard let db = handle.db else { throw ThingsImportError.sqliteQueryFailed("database closed") }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
      throw ThingsImportError.sqliteQueryFailed(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(stmt) }

    for (i, binding) in bindings.enumerated() {
      let idx = Int32(i + 1)
      switch binding {
      case .text(let s):
        sqlite3_bind_text(stmt, idx, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
      case .int(let n):
        sqlite3_bind_int64(stmt, idx, n)
      }
    }

    var rows: [[String: Any?]] = []
    let colCount = sqlite3_column_count(stmt)
    while sqlite3_step(stmt) == SQLITE_ROW {
      var row: [String: Any?] = [:]
      for c in 0..<colCount {
        let name = String(cString: sqlite3_column_name(stmt, c))
        switch sqlite3_column_type(stmt, c) {
        case SQLITE_NULL:
          row[name] = nil
        case SQLITE_INTEGER:
          row[name] = sqlite3_column_int64(stmt, c)
        case SQLITE_FLOAT:
          row[name] = sqlite3_column_double(stmt, c)
        case SQLITE_TEXT:
          if let ptr = sqlite3_column_text(stmt, c) {
            row[name] = String(cString: ptr)
          } else {
            row[name] = nil
          }
        default:
          if let ptr = sqlite3_column_text(stmt, c) {
            row[name] = String(cString: ptr)
          }
        }
      }
      rows.append(row)
    }
    return rows
  }

  private func querySingleInt(sql: String, bindings: [SQLiteBinding]) throws -> Int? {
    let rows = try queryRows(sql: sql, bindings: bindings)
    guard let first = rows.first?.values.compactMap({ $0 as? Int64 }).first else { return nil }
    return Int(first)
  }
}

enum SQLiteBinding {
  case text(String)
  case int(Int64)
}
