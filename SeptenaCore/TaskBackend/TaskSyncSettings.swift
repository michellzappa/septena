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
// `SettingsMirror.upsert` writes it, so `SettingsStore`
// and every caller keep their API. A write diffs the keys and hands the
// changed ones to `TaskSyncEngine.captureSettings()`; a pull writes the blob
// with `write(_:)`, which captures nothing.
//
// Device-only preferences (text size, sidebar state, …) stay in UserDefaults
// and never come here. The server accepts only these keys, each with its own
// schema (`../septena-mcp-gateway/src/store/columns.ts`, `SETTING_VALUES`).
// Keep the two lists in lockstep.

enum SeptaskSyncedSettings {
  static let keys = RegistrySettings.syncedKeys

  /// The blob. `v1`: the shape is `AppSettings`' own JSON.
  static let storeKey = "septask.syncedSettings.v1"

  // MARK: Blob

  /// Writes the blob. No capture: for the pull and the one-time seed.
  static func write(_ settings: AppSettings) {
    UserDefaults.standard.set(encode(settings), forKey: storeKey)
  }

  /// Clears the local synced-settings blob on account switch or account delete
  /// so a previous account's preferences cannot leak into the next account.
  static func clearLocal() {
    UserDefaults.standard.removeObject(forKey: storeKey)
    for key in [TaskFade.enabledDefaultsKey, TaskFade.lastSweepAtKey, TaskFade.dismissedSweepWeekKey] {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }

  static func current() -> AppSettings {
    guard let data = UserDefaults.standard.data(forKey: storeKey),
          let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return empty }
    return s
  }

  static var empty: AppSettings {
    AppSettings()
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
    case "agentCommentNotifications": return .from(s.agentCommentNotifications)
    case "agentCommentNotificationsByAgent":
      return s.agentCommentNotificationsByAgent.map { .object($0.mapValues { .string($0) }) } ?? .null
    case "tasksShowAging": return s.tasksShowAging.map { .bool($0) } ?? .null
    case "fadeSweptAt": return s.fadeSweptAt.map { .string(stampFormatter.string(from: $0)) } ?? .null
    case "fadeSweepDismissedOn": return .from(s.fadeSweepDismissedOn)
    case "getStartedDismissed": return s.getStartedDismissed.map { .bool($0) } ?? .null
    case "getStartedSteps": return s.getStartedSteps.map { .array($0.map { .string($0) }) } ?? .null
    case "upsellsSeen": return s.upsellsSeen.map { .array($0.map { .string($0) }) } ?? .null
    // A `Date` on device, an ISO instant on the wire (registry format "stamp").
    case "onboardedAt": return s.onboardedAt.map { .string(stampFormatter.string(from: $0)) } ?? .null
    case "accentColor": return .from(s.accentColor)
    case "canvasTexture": return .from(s.canvasTexture)
    case "textureIntensity": return s.textureIntensity.map { .int(Int64($0)) } ?? .null
    case "textureMotion": return .from(s.textureMotion)
    case "smartListOrder": return s.smartListOrder.map { .array($0.map { .string($0) }) } ?? .null
    case "smartListHidden": return s.smartListHidden.map { .array($0.map { .string($0) }) } ?? .null
    case "smartListPlacement":
      return s.smartListPlacement.map { .object($0.mapValues { .string($0) }) } ?? .null
    // The settings key, which shares its name with the `listSort` surface.
    case "listSort": // septena-lint:allow registry-id-literal
      return s.listSort.map { .object($0.mapValues { .string($0) }) } ?? .null
    default: return .null
    }
  }

  /// Sets one key from a JSON value. False when the value has the wrong
  /// shape (the field is then left as it was).
  /// ISO 8601 with a zone, the backend's `stamp` pattern. Built per use:
  /// `ISO8601DateFormatter` is not `Sendable`.
  private static var stampFormatter: ISO8601DateFormatter { ISO8601DateFormatter() }

  /// The web and Android write fractional seconds; the formatter wants to know.
  private static func stamp(_ raw: String) -> Date? {
    if let date = stampFormatter.date(from: raw) { return date }
    let fractional = stampFormatter
    fractional.formatOptions.insert(.withFractionalSeconds)
    return fractional.date(from: raw)
  }

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
    case "onboardedAt":
      guard let x = string() else { return false }
      guard let raw = x else { s.onboardedAt = nil; break }
      guard let date = stamp(raw) else { return false }
      s.onboardedAt = date
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
    case "agentCommentNotifications":
      guard let x = string() else { return false }
      s.agentCommentNotifications = x
    case "agentCommentNotificationsByAgent":
      switch v {
      case .null: s.agentCommentNotificationsByAgent = nil
      case .object(let dict):
        var out: [String: String] = [:]
        for (k, val) in dict {
          guard let str = val.stringValue else { return false }
          out[k] = str
        }
        s.agentCommentNotificationsByAgent = out
      default: return false
      }
    case "tasksShowAging":
      switch v {
      case .null: s.tasksShowAging = nil
      case .bool(let b): s.tasksShowAging = b
      default: return false
      }
    case "fadeSweptAt":
      guard let x = string() else { return false }
      guard let raw = x else { s.fadeSweptAt = nil; break }
      guard let date = stamp(raw) else { return false }
      s.fadeSweptAt = date
    case "fadeSweepDismissedOn":
      guard let x = string() else { return false }
      s.fadeSweepDismissedOn = x
    case "getStartedDismissed":
      switch v {
      case .null: s.getStartedDismissed = nil
      case .bool(let b): s.getStartedDismissed = b
      default: return false
      }
    case "getStartedSteps":
      switch v {
      case .null: s.getStartedSteps = nil
      case .array(let list):
        let steps = list.compactMap(\.stringValue)
        guard steps.count == list.count else { return false }
        s.getStartedSteps = steps
      default: return false
      }
    case "upsellsSeen":
      switch v {
      case .null: s.upsellsSeen = nil
      case .array(let list):
        let ids = list.compactMap(\.stringValue)
        guard ids.count == list.count else { return false }
        s.upsellsSeen = ids
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
    case "accentColor":
      guard let x = string() else { return false }
      s.accentColor = x
    case "canvasTexture":
      guard let x = string() else { return false }
      s.canvasTexture = x
    case "textureIntensity":
      switch v {
      case .null: s.textureIntensity = nil
      case .int(let n): s.textureIntensity = Int(n)
      default: return false
      }
    case "textureMotion":
      guard let x = string() else { return false }
      s.textureMotion = x
    case "smartListOrder":
      switch v {
      case .null: s.smartListOrder = nil
      case .array(let list):
        let ids = list.compactMap(\.stringValue)
        guard ids.count == list.count else { return false }
        s.smartListOrder = ids
      default: return false
      }
    case "smartListHidden":
      switch v {
      case .null: s.smartListHidden = nil
      case .array(let list):
        let ids = list.compactMap(\.stringValue)
        guard ids.count == list.count else { return false }
        s.smartListHidden = ids
      default: return false
      }
    case "smartListPlacement":
      switch v {
      case .null: s.smartListPlacement = nil
      case .object(let dict):
        var out: [String: String] = [:]
        for (k, val) in dict {
          guard let str = val.stringValue, str == "top" || str == "bottom" else { return false }
          out[k] = str
        }
        s.smartListPlacement = out
      default: return false
      }
    // The settings key, which shares its name with the `listSort` surface.
    case "listSort": // septena-lint:allow registry-id-literal
      switch v {
      case .null: s.listSort = nil
      case .object(let dict):
        // A record of `listSort` values (registry `maxEntries` 256). Manual
        // is the absence of a key, so a stored `manual` is the wrong shape.
        // Literals, not `ListSort`: this file builds in SeptenaCoreTests.
        guard dict.count <= 256 else { return false }
        var out: [String: String] = [:]
        for (k, val) in dict {
          guard let str = val.stringValue, str != "manual",
                RegistryEntityEnums.listSort.contains(str) else { return false }
          out[k] = str
        }
        s.listSort = out
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
