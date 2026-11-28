import Foundation
import SwiftData

@MainActor
enum SettingsMirror {
  private static let decoder = JSONDecoder()

  // `nonisolated`: a pure context read, so `DashboardReader` can pull
  // settings on its background context off-main. Uses a local decoder
  // rather than the enum's `@MainActor` shared one (the write methods here
  // genuinely need main — they push through CKEngine — so the enum stays
  // `@MainActor` and only this read opts out).
  nonisolated static func loadSettings(context: ModelContext) -> AppSettings? {
    // Septena syncs no CloudKit record: its settings are the synced-settings
    // blob (TaskSyncSettings.swift), never the shared `SettingsEntity` row
    // Septena syncs through CloudKit.
    guard let data = UserDefaults.standard.data(forKey: SeptaskSyncedSettings.storeKey) else { return nil }
    return settingsCache.value(forPayload: data)
  }

  /// The settings CloudKit last synced to this device (the shared
  /// `SettingsEntity` row), in either app. Septena reads it once, to seed
  /// its synced-settings blob (`SeptaskSyncedSettings.seedIfNeeded`).
  static func loadCloudKitSettingsRow(context: ModelContext) -> AppSettings? {
    let singletonID = SettingsCloudKitSchema.singletonID
    var descriptor = FetchDescriptor<SettingsEntity>(predicate: #Predicate { $0.id == singletonID })
    descriptor.fetchLimit = 1
    guard let entity = try? context.fetch(descriptor).first else { return nil }
    return try? decoder.decode(AppSettings.self, from: entity.payloadData)
  }

  /// Memoized decode of the settings singleton, keyed by the payload bytes.
  ///
  /// `loadSettings` is on many read paths, and a decode costs a JSON pass. The
  /// payload changes only when settings are written, so comparing the bytes is
  /// a cheap, exact cache key.
  private static let settingsCache = SettingsPayloadCache()

  /// Whether the account shows any sign of prior use: synced settings or task
  /// data. A reinstall or new device does, once the first pull lands. Used to
  /// avoid treating an empty local store as a fresh account.
  nonisolated static func accountHasExistingContent(context: ModelContext) -> Bool {
    if let settings = loadSettings(context: context) {
      if settings.onboardedAt != nil { return true }
      if !(settings.welcomeName?.isEmpty ?? true) { return true }
    }
    func any<T: PersistentModel>(_ type: T.Type) -> Bool {
      var d = FetchDescriptor<T>()
      d.fetchLimit = 1
      return ((try? context.fetchCount(d)) ?? 0) > 0
    }
    return any(TaskEntity.self)
      || any(ProjectEntity.self)
      || any(AreaEntity.self)
  }

  /// Publishes this device's current timezone into the synced Settings `time`
  /// block as `home_timezone`, so the hosted MCP gateway — which has no device
  /// to read — resolves the user's real zone instead of silently defaulting to
  /// UTC. The device is the authoritative source for *home*; gateway-owned
  /// `travel_mode` / `travel_timezone` are preserved untouched. Idempotent:
  /// `upsert` only pushes when the encoded payload actually changes, so the
  /// no-change common case is a cheap local read. Creates the settings record
  /// if the user has none yet (decode of `{}` yields all-nil/defaulted fields).
  static func publishDeviceTimezone(context: ModelContext, engine: CKEngine? = nil) {
    let deviceID = TimeZone.current.identifier
    guard var settings = loadSettings(context: context)
      ?? (try? decoder.decode(AppSettings.self, from: Data("{}".utf8))) else { return }
    guard settings.time?.homeTimezone != deviceID else { return }
    settings.time = AppTimeSettings(homeTimezone: deviceID,
                                    travelMode: settings.time?.travelMode,
                                    travelTimezone: settings.time?.travelTimezone)
    upsert(settings: settings, context: context, engine: engine)
  }

  // MARK: - "Rolled into today" banner dismissal

  /// Device-local mirror of `AppSettings.rolledInDismissedOn`. Read first so
  /// the banner decision is instant and correct offline; both task surfaces
  /// (SwiftUI `TaskListView`, AppKit `SeptaskKitTaskList`) already read this
  /// key, so syncing through it leaves their read paths unchanged.
  static let rolledInDismissedKey = RegistrySettings.StorageKey.rolledInDismissedOn

  /// The day the rolled-in banner was last dismissed — the LATER of the synced
  /// value and the device-local mirror.
  ///
  /// Taking the later of the two is what makes this safe in both directions. A
  /// device that dismissed offline keeps its dismissal until it pushes. A
  /// device receiving an older synced payload (a sibling that has not opened
  /// since yesterday) cannot un-dismiss today's banner. ISO `yyyy-MM-dd` sorts
  /// lexically, so the comparison is a plain string compare.
  static func rolledInDismissedOn(context: ModelContext) -> String? {
    let local = UserDefaults.standard.string(forKey: rolledInDismissedKey)
    let synced = loadSettings(context: context)?.rolledInDismissedOn
    switch (local, synced) {
    case let (l?, s?): return max(l, s)
    case let (l?, nil): return l
    case let (nil, s?): return s
    case (nil, nil): return nil
    }
  }

  /// Dismiss the banner for `day` on every device. Writes the device-local
  /// mirror first (so this device's next reload is correct with no round trip),
  /// then pushes the synced field. Idempotent — a repeat dismissal for the same
  /// day changes no bytes, so `upsert` notes no change and nothing is pushed.
  static func dismissRolledIn(on day: String, context: ModelContext, engine: CKEngine?) {
    UserDefaults.standard.set(day, forKey: rolledInDismissedKey)
    var settings = loadSettings(context: context) ?? AppSettings()
    guard settings.rolledInDismissedOn != day else { return }
    settings.rolledInDismissedOn = day
    upsert(settings: settings, context: context, engine: engine)
  }

  // MARK: - "Get started" checklist (Septena)

  /// Synced dismissal flag for the "Get started" checklist. True once dismissed
  /// or every step is completed on any device.
  static func getStartedDismissed(context: ModelContext) -> Bool {
    loadSettings(context: context)?.getStartedDismissed == true
  }

  /// Mark "Get started" dismissed account-wide so other devices stop showing it.
  /// Idempotent: a repeat write changes no bytes and pushes nothing.
  static func dismissGetStarted(context: ModelContext, engine: CKEngine?) {
    var settings = loadSettings(context: context) ?? AppSettings()
    guard settings.getStartedDismissed != true else { return }
    settings.getStartedDismissed = true
    upsert(settings: settings, context: context, engine: engine)
  }

  /// Synced set of completed "Get started" step raw IDs, or `nil` when no
  /// device has published step progress yet.
  static func getStartedSteps(context: ModelContext) -> [String]? {
    loadSettings(context: context)?.getStartedSteps
  }

  /// Persist the completed "Get started" step raw IDs account-wide.
  static func setGetStartedSteps(_ steps: [String], context: ModelContext, engine: CKEngine?) {
    let sorted = Array(Set(steps)).sorted()
    var settings = loadSettings(context: context) ?? AppSettings()
    guard settings.getStartedSteps != sorted else { return }
    settings.getStartedSteps = sorted
    upsert(settings: settings, context: context, engine: engine)
  }

  /// Clear synced "Get started" state (Settings ▸ About ▸ Show Get started
  /// again, or after deleting an account). Writes `nil` (never deletes the
  /// setting row — backend clears with `value: null`).
  static func resetGetStarted(context: ModelContext, engine: CKEngine?) {
    guard var settings = loadSettings(context: context) else { return }
    guard settings.getStartedDismissed != nil || settings.getStartedSteps != nil else { return }
    settings.getStartedDismissed = nil
    settings.getStartedSteps = nil
    upsert(settings: settings, context: context, engine: engine)
  }

  // MARK: - Upsell moments (docs/SYNC_SUBSCRIPTION_SPEC.md §3.2, §7.1)

  /// The upsell moment ids this account has seen, on any device.
  static func upsellsSeen(context: ModelContext) -> Set<String> {
    Set(loadSettings(context: context)?.upsellsSeen ?? [])
  }

  /// Marks one upsell moment seen account-wide, so no device shows it as a
  /// prompt again. Idempotent: a repeat write changes no bytes and pushes
  /// nothing.
  static func markUpsellSeen(_ id: String, context: ModelContext, engine: CKEngine?) {
    var settings = loadSettings(context: context) ?? AppSettings()
    var seen = Set(settings.upsellsSeen ?? [])
    guard seen.insert(id).inserted else { return }
    settings.upsellsSeen = seen.sorted()
    upsert(settings: settings, context: context, engine: engine)
  }

  /// Reads the synced settings, changes them, and pushes what changed.
  static func updateSynced(_ change: (inout AppSettings) -> Void) {
    let context = LocalStore.shared.container.mainContext
    var settings = loadSettings(context: context) ?? AppSettings()
    change(&settings)
    upsert(settings: settings, context: context)
  }

  // MARK: - Fade (docs/TASK_FADE_SPEC.md §4)

  /// Turns "Fade inactive tasks" on or off for the account. The device mirror
  /// changes first, so rows repaint with no round trip.
  static func setFadeEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: TaskFade.enabledDefaultsKey)
    updateSynced { $0.tasksShowAging = enabled }
  }

  /// Copies the account's value into the device mirror. The account has none
  /// yet: `publish` sends a device that had fading off before the setting
  /// synced.
  static func reconcileFadeEnabled(publish: Bool) {
    if let synced = SeptaskSyncedSettings.current().tasksShowAging {
      UserDefaults.standard.set(synced, forKey: TaskFade.enabledDefaultsKey)
    } else if publish, !TaskFade.isEnabled {
      updateSynced { $0.tasksShowAging = false }
    }
  }

  static func upsert(settings: AppSettings,
                     context: ModelContext,
                     engine: CKEngine? = nil) {
    // Septena: write the synced-settings blob and queue the changed keys for
    // the task backend. `engine` is unused (Septena never starts CloudKit).
    let data = SeptaskSyncedSettings.encode(settings)
    guard UserDefaults.standard.data(forKey: SeptaskSyncedSettings.storeKey) != data else { return }
    UserDefaults.standard.set(data, forKey: SeptaskSyncedSettings.storeKey)
    TaskSyncEngine.shared.captureSettings()
    return
  }

}

/// The sweep writes: this device, then the account (`TaskFade` holds the rules).
extension TaskFade {
  @MainActor
  static func markSweepCompleted(at date: Date) {
    UserDefaults.standard.set(date.timeIntervalSince1970, forKey: lastSweepAtKey)
    SettingsMirror.updateSynced { $0.fadeSweptAt = date }
  }

  /// Dismisses this week's sweep banner on every device without dropping any tasks.
  @MainActor
  static func dismissSweepForCurrentWeek(now: Date, calendar: Calendar = .current) {
    let anchor = mostRecentSweepAnchor(now: now, calendar: calendar)
    UserDefaults.standard.set(anchor.timeIntervalSince1970, forKey: dismissedSweepWeekKey)
    let day = SeptenaDate.format(anchor)
    SettingsMirror.updateSynced { $0.fadeSweepDismissedOn = day }
  }
}

/// Byte-keyed memo for the decoded settings blob. `@unchecked Sendable` with an
/// explicit lock: `loadSettings` is `nonisolated` and genuinely runs on both the
/// main actor and background model actors, and `AppSettings` is a value type
/// that is safe to hand across once decoded.
private final class SettingsPayloadCache: @unchecked Sendable {
  private let lock = NSLock()
  private var payload: Data?
  private var decoded: AppSettings?
  private let decoder = JSONDecoder()

  func value(forPayload data: Data) -> AppSettings? {
    lock.lock()
    if payload == data {
      defer { lock.unlock() }
      return decoded
    }
    // Decode under the lock: it also serializes access to `decoder`, which is a
    // reference type and must not be entered concurrently.
    let fresh = try? decoder.decode(AppSettings.self, from: data)
    payload = data
    decoded = fresh
    lock.unlock()
    return fresh
  }
}
