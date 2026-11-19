import Foundation

// Septask's synced settings (docs/SEPTASK_BACKEND.md §5.2 `settings`). Septask
// syncs no CloudKit record, so the few account-wide settings it uses ride the
// task backend as the `setting` entity: one row per key, `value` = JSON.
//
// Where the values live on the device: a JSON `AppSettings` blob in Septask's
// own defaults (`storeKey`), holding ONLY the keys below. It is NOT the shared
// `SettingsEntity` row. Septena and Septask open the same SwiftData store, and
// Septena still syncs that row through CloudKit: if Septask synced it too,
// each app's sync would keep writing the other's older value back.
//
// In Septask, `SettingsMirror.loadSettings` reads this blob and
// `SettingsMirror.upsert` writes it (both `#if SEPTASK`), so `SettingsStore`
// and every caller keep their API. A write diffs the keys and hands the
// changed ones to `TaskSyncEngine.captureSettings()`; a pull writes the blob
// with `write(_:)`, which captures nothing.
//
// Device-only preferences (text size, sidebar state, …) stay in UserDefaults
// and never come here. The server accepts only these keys, each with its own
// schema (`../septena-mcp-gateway/src/store/columns.ts`, `SETTING_VALUES`).
// Keep the two lists in lockstep.

enum SeptaskSyncedSettings {
  static let keys = ["welcomeName", "telemetryLevel", "calendarHiddenTitles", "rolledInDismissedOn", "homeTimezone",
                     "agentsPaused"]

  /// The blob. `v1`: the shape is `AppSettings`' own JSON.
  static let storeKey = "septask.syncedSettings.v1"

  // MARK: Blob

  /// Writes the blob. No capture: for the pull and the one-time seed.
  static func write(_ settings: AppSettings) {
    UserDefaults.standard.set(encode(settings), forKey: storeKey)
  }

  static func current() -> AppSettings {
    guard let data = UserDefaults.standard.data(forKey: storeKey),
          let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return empty }
    return s
  }

  static var empty: AppSettings {
    AppSettings(sectionOrder: nil, targets: nil, units: nil, time: nil,
                theme: nil, eink: nil, nutrition: nil, hkSync: nil)
  }

  /// Keeps only the synced keys, so a caller that passed a whole settings
  /// value (the MCP `settings_update` tool) cannot park other fields here.
  static func encode(_ settings: AppSettings) -> Data {
    var only = empty
    for key in keys { _ = apply(key, value(key, in: settings), to: &only) }
    return (try? JSONEncoder().encode(only)) ?? Data("{}".utf8)
  }

  // MARK: Key ⇄ field

  static func value(_ key: String, in s: AppSettings) -> BackendJSON {
    switch key {
    case "welcomeName": return .from(s.welcomeName)
    case "telemetryLevel": return .from(s.telemetryLevel)
    case "calendarHiddenTitles": return s.calendarHiddenTitles.map { .array($0.map { .string($0) }) } ?? .null
    case "rolledInDismissedOn": return .from(s.rolledInDismissedOn)
    case "homeTimezone": return .from(s.time?.homeTimezone)
    case "agentsPaused": return s.agentsPaused.map { .bool($0) } ?? .null
    default: return .null
    }
  }

  /// Sets one key from a JSON value. False when the value has the wrong
  /// shape (the field is then left as it was).
  @discardableResult
  static func apply(_ key: String, _ v: BackendJSON, to s: inout AppSettings) -> Bool {
    func string() -> String?? {
      if v.isNull { return .some(nil) }
      return v.stringValue.map { .some($0) }
    }
    switch key {
    case "welcomeName":
      guard let x = string() else { return false }
      s.welcomeName = x
    case "telemetryLevel":
      guard let x = string() else { return false }
      s.telemetryLevel = x
    case "rolledInDismissedOn":
      guard let x = string() else { return false }
      s.rolledInDismissedOn = x
    case "homeTimezone":
      guard let x = string() else { return false }
      // `homeTimezone` is not optional in `AppTimeSettings`: no zone, no block.
      s.time = x.map { AppTimeSettings(homeTimezone: $0, travelMode: nil, travelTimezone: nil) }
    case "agentsPaused":
      switch v {
      case .null: s.agentsPaused = nil
      case .bool(let b): s.agentsPaused = b
      default: return false
      }
    case "calendarHiddenTitles":
      switch v {
      case .null: s.calendarHiddenTitles = nil
      case .array(let list):
        let titles = list.compactMap(\.stringValue)
        guard titles.count == list.count else { return false }
        s.calendarHiddenTitles = titles
      default: return false
      }
    default:
      return false
    }
    return true
  }

  // MARK: One-time seed

  private static let seededKey = "septask.syncedSettings.seeded"

  /// First run of a CloudKit-free Septask: start the blob from the values
  /// the shared `SettingsEntity` row holds (what CloudKit last synced to this
  /// device). The backend still wins: these values are pushed only for keys
  /// the first pull did not bring (`TaskSyncEngine.reconcileSettings`).
  @MainActor
  static func seedIfNeeded(from legacy: AppSettings?) {
    guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
    if UserDefaults.standard.data(forKey: storeKey) == nil {
      write(legacy ?? empty)
    }
    UserDefaults.standard.set(true, forKey: seededKey)
  }
}

extension Notification.Name {
  /// A pull changed Septask's synced settings. `SettingsStore` reloads and
  /// copies the values into the device-local mirrors.
  static let septaskSettingsPulled = Notification.Name("septask.settingsPulled")
}
