import Foundation

// The task-store cutover flag (docs/SEPTASK_BACKEND.md §7 "Cutover flag", §9
// phase 3). `cloudkit`: tasks, areas, projects and attachments sync through
// CKEngine as before. `backend`: they sync through `TaskSyncEngine` to
// api.septena.app, and CloudKit freezes those four record types.
//
// Septena is backend-only since 2026-11-19 (phase 4): in Septena `current` is
// always `.backend`, and Septena never starts CloudKit at all.
//
// The STORED value is device-wide, in the shared app-group defaults, and is
// now only for Septena Life. Septena Life and Septena open the same SwiftData store
// (`MacStoreLocation` on the Mac, the app-group container on iOS). If Septena Life
// kept applying CloudKit task records into that store while Septena syncs
// with the backend, a device still on CloudKit could overwrite backend state
// through Septena Life's process. So Septena Life READS the flag and honors the freeze,
// and Septena writes `backend` at every launch (`markDeviceBackend`). The old
// key and value stay, rather than a new flag, so Septena Life builds already on
// devices keep honoring it with no change.

enum TaskStoreMode: String, Sendable {
  case cloudkit
  case backend

  static var current: TaskStoreMode {
    return .backend
  }

  /// Tells Septena on this device that the backend owns tasks, so it freezes
  /// the CloudKit task types. Idempotent; called at every Septena launch.
  static func markDeviceBackend() {
    let defaults = SeptenaAppGroup.defaults
    guard defaults.string(forKey: SettingsKey.taskStoreMode) != TaskStoreMode.backend.rawValue else { return }
    defaults.set(TaskStoreMode.backend.rawValue, forKey: SettingsKey.taskStoreMode)
  }

  /// The CloudKit record types the backend owns in `backend` mode.
  static let backendOwnedRecordTypes: Set<String> = [
    TaskCloudKitSchema.recordType,
    AreaCloudKitSchema.recordType,
    ProjectCloudKitSchema.recordType,
    TaskAttachmentCloudKitSchema.recordType,
  ]

  /// True for a record name of one of `backendOwnedRecordTypes`. Every other
  /// record type names its records `<prefix>:<id>`, except the settings
  /// singleton (`app`); task records use the bare task id. Used only where the
  /// record type is unknown (a queued CloudKit delete).
  static func isBackendOwnedRecordName(_ name: String) -> Bool {
    if name.hasPrefix("area:") || name.hasPrefix("project:")
      || name.hasPrefix(TaskAttachmentCloudKitSchema.prefix) { return true }
    if name == SettingsCloudKitSchema.singletonID { return false }
    return !name.contains(":")
  }
}
