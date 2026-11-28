import Foundation

// Task record identity: the record type and record-name scheme for tasks,
// areas, projects and attachments. Split out of the CloudKit/*Record.swift
// files (#42, docs/SEPTASK_BACKEND.md §9 phase 4) so both apps compile it
// without the CKRecord mapping. Plain strings, no CloudKit import:
// `TaskStoreMode` freezes these record types in Septena Life, and the
// backend sync engine keys its pending-change ledger by these record names.
// The field names and the CKRecord encode/decode stay in the record files,
// which Septena does not compile.

enum TaskCloudKitSchema {
  /// CKRecord type. Capitalized by CloudKit convention. The record name is
  /// the bare task id.
  static let recordType = "Task"
}

enum AreaCloudKitSchema {
  static let recordType = "Area"
  static func recordName(for id: String) -> String { "area:\(id)" }
  static func entityID(from recordName: String) -> String {
    recordName.hasPrefix("area:") ? String(recordName.dropFirst(5)) : recordName
  }
}

enum ProjectCloudKitSchema {
  static let recordType = "Project"
  static func recordName(for id: String) -> String { "project:\(id)" }
  static func entityID(from recordName: String) -> String {
    recordName.hasPrefix("project:") ? String(recordName.dropFirst(8)) : recordName
  }
}

enum TaskAttachmentCloudKitSchema {
  static let recordType = "TaskAttachment"
  static let prefix = "task-attachment:"
  static func recordName(for id: String) -> String { prefix + id }
  static func entityID(from recordName: String) -> String {
    recordName.hasPrefix(prefix) ? String(recordName.dropFirst(prefix.count)) : recordName
  }
}
