import Foundation

// The task-store cutover flag (docs/SEPTASK_BACKEND.md §7 "Cutover flag", §9
// phase 3). `cloudkit`: tasks, areas, projects and attachments sync through
// CKEngine as before. `backend`: they sync through `TaskSyncEngine` to
// api.septena.app, and CloudKit freezes those four record types.
//
// Septask is backend-only since 2026-11-19 (phase 4): in Septask `current` is
// always `.backend`, and Septask never starts CloudKit at all.
//
// The STORED value is device-wide, in the shared app-group defaults, and is
// now only for Septena. Septena and Septask open the same SwiftData store
// (`MacStoreLocation` on the Mac, the app-group container on iOS). If Septena
// kept applying CloudKit task records into that store while Septask syncs
// with the backend, a device still on CloudKit could overwrite backend state
// through Septena's process. So Septena READS the flag and honors the freeze,
// and Septask writes `backend` at every launch (`markDeviceBackend`). The old
// key and value stay, rather than a new flag, so Septena builds already on
// devices keep honoring it with no change.

enum TaskStoreMode: String, Sendable {
  case cloudkit
  case backend

  static var current: TaskStoreMode {
    #if SEPTASK
    return .backend
    #else
    return SeptenaAppGroup.defaults.string(forKey: SettingsKey.taskStoreMode)
      .flatMap(TaskStoreMode.init(rawValue:)) ?? .cloudkit
    #endif
  }

  #if SEPTASK
  /// Tells Septena on this device that the backend owns tasks, so it freezes
  /// the CloudKit task types. Idempotent; called at every Septask launch.
  static func markDeviceBackend() {
    let defaults = SeptenaAppGroup.defaults
    guard defaults.string(forKey: SettingsKey.taskStoreMode) != TaskStoreMode.backend.rawValue else { return }
    defaults.set(TaskStoreMode.backend.rawValue, forKey: SettingsKey.taskStoreMode)
  }
  #endif

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

enum TaskStoreSwitchError: LocalizedError, Equatable {
  case unavailable
  case notSignedIn
  case alreadyInMode
  case busy
  case cloudKitNotReady(String)
  case pendingCloudKitChanges(Int)
  case importRefused(String)
  case storeUnavailable(String)
  case rollbackFailed(String)

  var errorDescription: String? {
    switch self {
    case .unavailable: return "Only the Septena task app can change where tasks sync."
    case .notSignedIn: return "Sign in to the task backend first."
    case .alreadyInMode: return "Tasks already sync this way."
    case .busy: return "A switch is already running."
    case .cloudKitNotReady(let why): return why
    case .pendingCloudKitChanges(let n): return "\(n) task changes still wait to sync to iCloud. Try again when they are sent."
    case .importRefused(let why): return why
    case .storeUnavailable(let why): return "The sync queue could not be opened (\(why))."
    case .rollbackFailed(let why): return "Copy back to iCloud did not finish: \(why)"
    }
  }
}
