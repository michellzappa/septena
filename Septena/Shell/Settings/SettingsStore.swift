import SwiftUI
import SwiftData

// The settings mirror cache — extracted from SettingsView.swift so both
// shells compile it (Septask injects it for the profile name, telemetry
// level, and What's New; docs/SEPTASK.md). No view types referenced.

// MARK: - Store
//
// One Observable holding the in-memory view of the user's settings,
// hydrated from the CloudKit-mirrored `SettingsEntity` + `SectionEntity`
// records via SettingsMirror. Local prefs continue to live as @AppStorage
// at use sites — they're already shared through the SettingsKey constants
// and don't need wrapping.

@MainActor
@Observable
final class SettingsStore {
  var serverSettings: AppSettings? = nil
  var sections: [SectionConfig] = []
  var macros: MacrosConfig? = nil
  var sessionTypes: [SessionTypeConfig] = []
  var chores: [ChoreItem] = []
  var serverLoading: Bool = false

  /// True once the onboarded-state is *known* — set synchronously at init when
  /// the device-local welcome flag is already settled, and by the launch path
  /// once the first CloudKit pull has run (so a synced `onboardedAt` would have
  /// been adopted). The welcome gate waits for this: on a reinstall the local
  /// flag is false but the account is onboarded, and the marker only arrives
  /// with the pull — presenting the welcome before then is the bug this fixes.
  /// Genuinely fresh accounts still get the welcome, just after the (usually
  /// brief) first pull instead of on a pre-sync frame.
  var onboardingResolved: Bool = false

  /// Hydrate from the local mirror / disk cache during construction so the
  /// dashboard's first frame uses the user's saved section order and config
  /// instead of an empty array (which falls back to the `SectionManifest`
  /// catalog order and causes a half-second reorder flash).
  init() {
    paintFromCache()
  }

  private enum CacheKey {
    static let serverSettings = "settings.serverSettings"
    static let sections       = "settings.sections"
    static let macros         = "settings.macros"
    static let sessionTypes   = "settings.sessionTypes"
    static let chores         = "settings.chores"
  }

  /// Synchronous read from disk-cached responses. Run at app launch
  /// before `refresh()` so the dashboard's tile order (driven by
  /// `sections`) and the section-config sub-panes render with last-known
  /// data instead of empty / default state during the network round-trip.
  func paintFromCache() {
    let context = LocalStore.shared.container.mainContext
    if let v = SettingsMirror.loadSettings(context: context) {
      serverSettings = v
      HealthKitBridge.shared.syncSettings = v.hkSync ?? HKSyncSettings()
    } else if let v = ResponseCache.load(AppSettings.self, forKey: CacheKey.serverSettings) {
      serverSettings = v
      HealthKitBridge.shared.syncSettings = v.hkSync ?? HKSyncSettings()
    }
    let mirroredSections = SettingsMirror.loadSections(context: context)
    if !mirroredSections.isEmpty {
      sections = mirroredSections
      ResponseCache.save(mirroredSections, forKey: CacheKey.sections)
    } else if let v = ResponseCache.load([SectionConfig].self, forKey: CacheKey.sections) {
      sections = v
    }
    if let v = ResponseCache.load(MacrosConfig.self, forKey: CacheKey.macros) { macros = v }
    if let v = ResponseCache.load([SessionTypeConfig].self, forKey: CacheKey.sessionTypes) { sessionTypes = v }
    if let v = ResponseCache.load([ChoreItem].self, forKey: CacheKey.chores) { chores = v }
    // Adopt a CloudKit-synced welcome name cached in the local mirror so the
    // first frame's greeting is right. No engine here (init context), so the
    // local→cloud migration leg is deferred to the launch reconcile.
    reconcileWelcomeName(context: context, engine: nil)
    reconcileDayBucketCutoffs(context: context, engine: nil)
    // Seed the weight-unit mirror from the locale (or adopt a synced value) so
    // the first frame's Training / Body weights format correctly. Inbound-only
    // here (no engine); the launch task pushes a fresh seed up.
    reconcileUnits(context: context, engine: nil)
    // Same bridge for the fasting flag: adopt an inbound synced value into the
    // local @AppStorage mirror so the Nutrition tile / dashboard read it on the
    // first frame. Inbound-only here (no engine); the launch task pushes a
    // pre-existing local-only value up.
    reconcileTrackFasting(context: context, engine: nil)
    // Same bridge for the analytics privacy level: adopt an inbound synced level
    // into the local @AppStorage mirror so `TelemetryClient` gates correctly from
    // the first frame. Inbound-only here (no engine); the launch task pushes a
    // legacy/default level up.
    reconcileTelemetryLevel(context: context, engine: nil)
    // Inbound-only at init (no engine): if a synced `onboardedAt` is already
    // in the local mirror, adopt it into the device-local flag now so the
    // welcome gate decides synchronously on the first frame and never waits
    // on (or flashes during) the launch sync.
    reconcileOnboarding(context: context, engine: nil)
    // Established account with no marker yet (in-place update — their data is
    // already on disk): set the local flag synchronously so the gate suppresses
    // the welcome on the first frame. The durable stamp + CloudKit push happens
    // in the launch task's `grandfatherOnboardingIfEstablished`.
    adoptWelcomeFlagIfEstablished(context: context)
    // If the answer is already known locally — the flag was set previously, or
    // adopted just above because the local store already holds the user's data —
    // resolve now so a normal launch shows the gate's final decision with zero
    // delay. Otherwise stay UNRESOLVED until the launch pull settles it: that's
    // the reinstall path (empty local store, flag false, `onboardedAt` still
    // syncing in), where showing the welcome would be wrong.
    if UserDefaults.standard.bool(forKey: SettingsKey.welcomeCompleted) {
      onboardingResolved = true
    }
  }

  /// Synchronous, local-only welcome suppression for established accounts: if
  /// the welcome hasn't been completed and there's no marker yet but the local
  /// store already holds the user's data, set the device-local flag so the gate
  /// never shows the welcome on the first frame. Pure flag write — no context
  /// mutation, no network (safe to call from `paintFromCache` during init).
  func adoptWelcomeFlagIfEstablished(context: ModelContext) {
    guard !UserDefaults.standard.bool(forKey: SettingsKey.welcomeCompleted),
          SettingsMirror.loadSettings(context: context)?.onboardedAt == nil,
          SettingsMirror.accountHasExistingContent(context: context) else { return }
    UserDefaults.standard.set(true, forKey: SettingsKey.welcomeCompleted)
  }

  /// Reload settings + sections from the SwiftData mirror. Called after every
  /// CloudKit pull and on `.septenaDataChanged` so `sections` stays in parity
  /// with `SectionEntity` rows (the tab bar, dashboard tiles, and Settings all
  /// read this cache).
  func reloadFromMirror(context: ModelContext) {
    if let v = SettingsMirror.loadSettings(context: context) {
      serverSettings = v
      ResponseCache.save(v, forKey: CacheKey.serverSettings)
      HealthKitBridge.shared.syncSettings = v.hkSync ?? HKSyncSettings()
    }
    let mirroredSections = SettingsMirror.loadSections(context: context)
    sections = mirroredSections
    if !mirroredSections.isEmpty {
      ResponseCache.save(mirroredSections, forKey: CacheKey.sections)
    }
  }

  func moveSections(fromOffsets: IndexSet, toOffset: Int,
                    context: ModelContext, engine: CKEngine?) {
    sections.move(fromOffsets: fromOffsets, toOffset: toOffset)
    var s = serverSettings ?? AppSettings(sectionOrder: nil, targets: nil, units: nil,
                                          time: nil, theme: nil, eink: nil, nutrition: nil,
                                          hkSync: nil)
    s.sectionOrder = sections.map(\.key)
    serverSettings = s
    SettingsMirror.upsert(settings: s, context: context, engine: engine)
  }

  /// Apply a new display order for the *enabled* sections, leaving every other
  /// section's relative slot in the saved order untouched. Backs the Sections
  /// pane, where the active group is reorderable but the "Off" group is not —
  /// so a drag among enabled rows must splice back onto the full
  /// `sectionOrder` without disturbing disabled (or non–logging-domain)
  /// sections. `enabledOrder` is the enabled keys in their new order.
  func applySectionOrder(enabledOrder: [String],
                         context: ModelContext, engine: CKEngine?) {
    let enabledSet = Set(enabledOrder)
    let currentOrder = serverSettings?.sectionOrder ?? sections.map(\.key)
    var iter = enabledOrder.makeIterator()
    // Walk the saved order; wherever an enabled key sat, drop in the next key
    // from the new enabled order. Non-enabled keys keep their positions.
    var newOrder = currentOrder.map { enabledSet.contains($0) ? (iter.next() ?? $0) : $0 }
    // Append any keys missing from the saved order (newly seeded sections).
    let known = Set(newOrder)
    newOrder += sections.map(\.key).filter { !known.contains($0) }
    let rank = Dictionary(uniqueKeysWithValues: newOrder.enumerated().map { ($1, $0) })
    sections.sort { (rank[$0.key] ?? .max) < (rank[$1.key] ?? .max) }
    var s = serverSettings ?? AppSettings(sectionOrder: nil, targets: nil, units: nil,
                                          time: nil, theme: nil, eink: nil, nutrition: nil,
                                          hkSync: nil)
    s.sectionOrder = sections.map(\.key)
    serverSettings = s
    SettingsMirror.upsert(settings: s, context: context, engine: engine)
  }

  /// Update the synced welcome name and push it to CloudKit, mirroring the
  /// `moveSections` write pattern. The local `welcomeName` @AppStorage key
  /// (read by `WelcomeHeader`) is written at the edit site, so both the
  /// synced payload and the local mirror stay in lockstep.
  func setWelcomeName(_ name: String, context: ModelContext, engine: CKEngine?) {
    guard (serverSettings?.welcomeName ?? "") != name else { return }
    var s = serverSettings ?? AppSettings(sectionOrder: nil, targets: nil, units: nil,
                                          time: nil, theme: nil, eink: nil,
                                          nutrition: nil, hkSync: nil)
    s.welcomeName = name
    serverSettings = s
    SettingsMirror.upsert(settings: s, context: context, engine: engine)
  }

  /// Set the user's weight/distance unit preference. Writes the device-local
  /// `@AppStorage` mirror that display surfaces read (so the UI re-formats
  /// instantly) and the CloudKit-synced `AppUnits` payload (so the choice
  /// follows them across devices). Distance rides along with the same
  /// metric/imperial decision so the two `AppUnits` fields stay coherent.
  /// Mirrors the `setWelcomeName` write pattern.
  func setWeightUnit(_ unit: WeightUnit, context: ModelContext, engine: CKEngine?) {
    UserDefaults.standard.set(unit.rawValue, forKey: SettingsKey.weightUnit)
    let distance = unit == .kg ? "km" : "mi"
    UserDefaults.standard.set(distance, forKey: SettingsKey.distanceUnit)
    // Volume rides the same metric/imperial decision (mirror only, not synced).
    UserDefaults.standard.set(unit == .kg ? VolumeUnit.ml.rawValue : VolumeUnit.flOz.rawValue,
                              forKey: SettingsKey.volumeUnit)
    guard serverSettings?.units?.weight != unit.rawValue
            || serverSettings?.units?.distance != distance else { return }
    var s = serverSettings ?? AppSettings(sectionOrder: nil, targets: nil, units: nil,
                                          time: nil, theme: nil, eink: nil,
                                          nutrition: nil, hkSync: nil)
    s.units = AppUnits(weight: unit.rawValue, distance: distance)
    serverSettings = s
    SettingsMirror.upsert(settings: s, context: context, engine: engine)
  }

  /// Reconcile the synced weight unit with the device-local `@AppStorage`
  /// mirror that the Training / Body surfaces read. Same inbound/outbound shape
  /// as `reconcileWelcomeName`:
  /// - A synced value wins: copy it into the local mirror so a choice made on
  ///   another device shows up here.
  /// - No synced value yet: seed the mirror from the device locale (US → lb,
  ///   else kg) so weights read correctly on the very first frame, and — only
  ///   on the launch path (engine in hand) — push that seed up so it syncs.
  func reconcileUnits(context: ModelContext, engine: CKEngine?) {
    let key = SettingsKey.weightUnit
    let distKey = SettingsKey.distanceUnit
    if let synced = serverSettings?.units?.weight, !synced.isEmpty {
      if UserDefaults.standard.string(forKey: key) != synced {
        UserDefaults.standard.set(synced, forKey: key)
      }
      // Distance rides with the weight choice; mirror the synced value (or
      // derive it if an older payload only carried weight).
      let dist = serverSettings?.units?.distance ?? (synced == "kg" ? "km" : "mi")
      if UserDefaults.standard.string(forKey: distKey) != dist {
        UserDefaults.standard.set(dist, forKey: distKey)
      }
      // Volume derives from the weight choice (no synced field of its own).
      let vol = synced == "kg" ? VolumeUnit.ml.rawValue : VolumeUnit.flOz.rawValue
      if UserDefaults.standard.string(forKey: SettingsKey.volumeUnit) != vol {
        UserDefaults.standard.set(vol, forKey: SettingsKey.volumeUnit)
      }
      return
    }
    // No synced preference. Adopt the locale defaults into the local mirrors the
    // first time we see this install so display is right immediately.
    if UserDefaults.standard.string(forKey: key) == nil {
      UserDefaults.standard.set(WeightUnit.localeDefault.rawValue, forKey: key)
      UserDefaults.standard.set(DistanceUnit.localeDefault.rawValue, forKey: distKey)
      UserDefaults.standard.set(VolumeUnit.localeDefault.rawValue, forKey: SettingsKey.volumeUnit)
    }
    // Persist the local choice up to the synced payload on the launch path.
    if engine != nil {
      setWeightUnit(WeightUnit.resolve(UserDefaults.standard.string(forKey: key)),
                    context: context, engine: engine)
    }
  }

  /// Set whether the user tracks fasting. Writes the device-local `@AppStorage`
  /// mirror (`SettingsKey.nutritionTrackFasting`, read by the Nutrition tile /
  /// dashboard for instant, offline-safe display) AND the CloudKit-synced
  /// `nutrition.trackFasting` payload (so the choice follows them across
  /// devices). Mirrors the `setWeightUnit` write pattern.
  ///
  /// Why synced matters: the watch macro complication's fasting morph is built
  /// by `WatchSnapshotPublisher.buildFasting`, which gates on this flag. When it
  /// lived only in per-device `UserDefaults.standard`, a second device (a Mac
  /// that was never told fasting is on) would republish the shared snapshot with
  /// `fasting: nil` and blank the wrist after midnight. Syncing the flag keeps
  /// every publisher in agreement.
  func setTrackFasting(_ on: Bool, context: ModelContext, engine: CKEngine?) {
    UserDefaults.standard.set(on, forKey: SettingsKey.nutritionTrackFasting)
    guard serverSettings?.nutrition?.trackFasting != on else { return }
    var s = serverSettings ?? AppSettings(sectionOrder: nil, targets: nil, units: nil,
                                          time: nil, theme: nil, eink: nil,
                                          nutrition: nil, hkSync: nil)
    var nut = s.nutrition ?? NutritionSettings(macroColors: nil, macroTiles: nil)
    nut.trackFasting = on
    s.nutrition = nut
    serverSettings = s
    SettingsMirror.upsert(settings: s, context: context, engine: engine)
  }

  /// Reconcile the synced fasting flag with the device-local `@AppStorage`
  /// mirror display surfaces read. Same inbound/outbound shape as
  /// `reconcileUnits`:
  /// - A synced value wins: copy it into the local mirror so a choice made on
  ///   another device shows up here (and so the wrist publisher agrees).
  /// - No synced value but the local mirror is on (upgrade from the old
  ///   local-only build): seed the payload from the local key and push it up.
  ///   That leg enqueues a CloudKit save, so it only runs with a non-nil
  ///   `engine` (the launch path); the init/paint path passes nil.
  func reconcileTrackFasting(context: ModelContext, engine: CKEngine?) {
    let key = SettingsKey.nutritionTrackFasting
    if let synced = serverSettings?.nutrition?.trackFasting {
      if UserDefaults.standard.bool(forKey: key) != synced {
        UserDefaults.standard.set(synced, forKey: key)
      }
      return
    }
    // No synced preference yet. If this install already had fasting on locally,
    // push that up so it syncs (launch path only).
    if engine != nil, UserDefaults.standard.bool(forKey: key) {
      setTrackFasting(true, context: context, engine: engine)
    }
  }

  /// Set the analytics privacy level. Writes the device-local `@AppStorage`
  /// mirror (`SettingsKey.telemetryLevel`, read synchronously by
  /// `TelemetryClient` to gate what it sends) AND the CloudKit-synced
  /// `telemetryLevel` payload (so the choice follows the user across devices).
  /// Mirrors the `setTrackFasting` / `setWeightUnit` write pattern. Also emits
  /// the operational level-change ping (sent even for `.none`, so opt-out counts
  /// stay knowable).
  func setTelemetryLevel(_ level: TelemetryClient.TelemetryLevel,
                         context: ModelContext, engine: CKEngine?) {
    UserDefaults.standard.set(level.rawValue, forKey: SettingsKey.telemetryLevel)
    Task { await TelemetryClient.shared.recordLevelChange(level) }
    guard serverSettings?.telemetryLevel != level.rawValue else { return }
    var s = serverSettings ?? AppSettings(sectionOrder: nil, targets: nil, units: nil,
                                          time: nil, theme: nil, eink: nil,
                                          nutrition: nil, hkSync: nil)
    s.telemetryLevel = level.rawValue
    serverSettings = s
    SettingsMirror.upsert(settings: s, context: context, engine: engine)
  }

  /// Reconcile the synced privacy level with the device-local `@AppStorage`
  /// mirror `TelemetryClient` reads. Same inbound/outbound shape as
  /// `reconcileTrackFasting`:
  /// - A synced value wins: copy it into the local mirror so a level chosen on
  ///   another device takes effect here.
  /// - No synced value yet: resolve the effective local level (honoring a local
  ///   pick or the legacy `shareUsageData` bool, else `.balanced`), materialize
  ///   it into the mirror so the picker binds to a concrete value, and push it
  ///   up so it syncs. The push enqueues a CloudKit save, so it only runs with a
  ///   non-nil `engine` (the launch path); the init/paint path passes nil.
  func reconcileTelemetryLevel(context: ModelContext, engine: CKEngine?) {
    let key = SettingsKey.telemetryLevel
    if let synced = serverSettings?.telemetryLevel,
       TelemetryClient.TelemetryLevel(rawValue: synced) != nil {
      if UserDefaults.standard.string(forKey: key) != synced {
        UserDefaults.standard.set(synced, forKey: key)
      }
      return
    }
    let effective = TelemetryClient.currentLevel()
    if UserDefaults.standard.string(forKey: key) != effective.rawValue {
      UserDefaults.standard.set(effective.rawValue, forKey: key)
    }
    if engine != nil {
      setTelemetryLevel(effective, context: context, engine: engine)
    }
  }

  /// Show or hide one calendar (by `EKCalendar.title`) from the day timeline /
  /// Next feed. Writes `CalendarBridge`'s local cache (the authority EventKit
  /// fetches filter on) AND the CloudKit-synced `calendarHiddenTitles` payload,
  /// so the selection follows the user across devices. Mirrors the
  /// `setTelemetryLevel` write shape.
  func setCalendarHidden(_ hidden: Bool, title: String,
                         context: ModelContext, engine: CKEngine?) {
    var titles = CalendarBridge.shared.hiddenCalendarTitles
    if hidden { titles.insert(title) } else { titles.remove(title) }
    let sorted = titles.sorted()
    guard serverSettings?.calendarHiddenTitles != sorted else { return }
    CalendarBridge.shared.hiddenCalendarTitles = titles
    var s = serverSettings ?? AppSettings(sectionOrder: nil, targets: nil, units: nil,
                                          time: nil, theme: nil, eink: nil,
                                          nutrition: nil, hkSync: nil)
    s.calendarHiddenTitles = sorted
    serverSettings = s
    SettingsMirror.upsert(settings: s, context: context, engine: engine)
  }

  /// Reconcile the synced hidden-calendar selection with `CalendarBridge`'s
  /// local cache. Same inbound/outbound shape as `reconcileTelemetryLevel`:
  /// - A synced value wins: adopt it into the bridge so a selection made on
  ///   another device takes effect here.
  /// - No synced value yet: migrate any legacy local selection (via
  ///   `allCalendars()`, which maps old identifiers → titles) and, if this
  ///   device has a non-empty selection, push it up so it seeds the account.
  ///   Empty is the default, so we don't push it — that avoids a fresh device
  ///   clobbering another device's real selection before it syncs in. The push
  ///   enqueues a CloudKit save, so it only runs with a non-nil `engine`.
  func reconcileHiddenCalendars(context: ModelContext, engine: CKEngine?) {
    if let synced = serverSettings?.calendarHiddenTitles {
      CalendarBridge.shared.hiddenCalendarTitles = Set(synced)
      return
    }
    _ = CalendarBridge.shared.allCalendars()   // folds any legacy id-keyed selection into titles
    let local = CalendarBridge.shared.hiddenCalendarTitles
    guard engine != nil, !local.isEmpty else { return }
    var s = serverSettings ?? AppSettings(sectionOrder: nil, targets: nil, units: nil,
                                          time: nil, theme: nil, eink: nil,
                                          nutrition: nil, hkSync: nil)
    s.calendarHiddenTitles = local.sorted()
    serverSettings = s
    SettingsMirror.upsert(settings: s, context: context, engine: engine)
  }

  /// Persist the saved practitioner-report definitions into the synced
  /// settings blob so the same reports show on every device.
  func setReports(_ reports: [ReportBundle], context: ModelContext, engine: CKEngine?) {
    var s = serverSettings ?? AppSettings(sectionOrder: nil, targets: nil, units: nil,
                                          time: nil, theme: nil, eink: nil,
                                          nutrition: nil, hkSync: nil)
    s.reports = reports
    serverSettings = s
    SettingsMirror.upsert(settings: s, context: context, engine: engine)
  }

  /// Reconcile the CloudKit-synced welcome name with the local @AppStorage
  /// key that `WelcomeHeader` reads for instant, offline-safe display.
  ///
  /// - A synced value wins: copy it into the local key so a name set on
  ///   another device shows up here.
  /// - No synced value but a local one exists (upgrade from the old
  ///   local-only build): seed the payload from the local key and push it
  ///   up. That leg enqueues a CloudKit save, so it only runs when given a
  ///   non-nil `engine` (the launch path); `paintFromCache` passes nil and
  ///   just does the inbound copy.
  func reconcileWelcomeName(context: ModelContext, engine: CKEngine?) {
    let key = SettingsKey.welcomeName
    let local = UserDefaults.standard.string(forKey: key) ?? ""
    let synced = serverSettings?.welcomeName ?? ""
    if !synced.isEmpty {
      if synced != local { UserDefaults.standard.set(synced, forKey: key) }
    } else if !local.isEmpty, engine != nil {
      setWelcomeName(local, context: context, engine: engine)
    }
  }

  /// Cosmetic supporter state follows the account (it gates nothing). The
  /// StoreKit truth lives in the app hosting purchases (Septena) — its local
  /// entitlement mirror is authoritative and pushes up, including a lapse.
  /// The tasks-only shell has no StoreKit and adopts the synced value only.
  func reconcileSupporter(context: ModelContext, engine: CKEngine?) {
    let key = SettingsKey.plusUnlocked
    let local = UserDefaults.standard.bool(forKey: key)
    if RuntimeProfile.current.isTasksOnly {
      if let synced = serverSettings?.supporter, synced != local {
        UserDefaults.standard.set(synced, forKey: key)
      }
      return
    }
    guard engine != nil, serverSettings?.supporter != local else { return }
    var s = serverSettings ?? AppSettings(sectionOrder: nil, targets: nil, units: nil,
                                          time: nil, theme: nil, eink: nil,
                                          nutrition: nil, hkSync: nil)
    s.supporter = local
    serverSettings = s
    SettingsMirror.upsert(settings: s, context: context, engine: engine)
  }

  /// Mark the first-run welcome complete: stamp the synced `onboardedAt` and
  /// push it to CloudKit (so other devices skip the welcome), and flip the
  /// device-local `welcomeCompleted` flag (so the gate dismisses immediately
  /// and this device never re-shows it). Mirrors the `setWelcomeName` write
  /// pattern. No-op if already stamped.
  func markOnboardingComplete(now: Date, context: ModelContext, engine: CKEngine?) {
    UserDefaults.standard.set(true, forKey: SettingsKey.welcomeCompleted)
    // Finishing the welcome clears any dev force-override so it stops re-showing.
    UserDefaults.standard.set(false, forKey: SettingsKey.welcomeForce)
    guard serverSettings?.onboardedAt == nil else { return }
    var s = serverSettings ?? AppSettings(sectionOrder: nil, targets: nil, units: nil,
                                          time: nil, theme: nil, eink: nil,
                                          nutrition: nil, hkSync: nil)
    s.onboardedAt = now
    serverSettings = s
    SettingsMirror.upsert(settings: s, context: context, engine: engine)
  }

  /// Dev/testing affordance (Settings ▸ About ▸ Advanced): re-show the first-run
  /// welcome on THIS device without wiping the app. Sets the `welcomeForce`
  /// override the gate honors over `welcomeCompleted`, so the welcome reappears
  /// immediately and on relaunch until it's completed again (which clears the
  /// override). Device-local only — does not touch the synced `onboardedAt`, so
  /// it never re-triggers the welcome on the user's other devices.
  func resetWelcomeForTesting() {
    UserDefaults.standard.set(true, forKey: SettingsKey.welcomeForce)
  }

  /// Reconcile the CloudKit-synced `onboardedAt` with the device-local
  /// `welcomeCompleted` flag the welcome gate reads. Same inbound/outbound
  /// shape as `reconcileWelcomeName`:
  /// - A synced stamp wins: set the local flag so a device that onboarded
  ///   elsewhere never shows the welcome once its data syncs in.
  /// - No synced stamp but the local flag is already set (upgrade from a
  ///   build predating this field, or a welcome finished while offline):
  ///   push a stamp up so siblings learn of it. Outbound leg only with a
  ///   non-nil `engine` (the launch path); `paintFromCache` passes nil.
  func reconcileOnboarding(context: ModelContext, engine: CKEngine?) {
    let key = SettingsKey.welcomeCompleted
    let localDone = UserDefaults.standard.bool(forKey: key)
    if serverSettings?.onboardedAt != nil {
      if !localDone { UserDefaults.standard.set(true, forKey: key) }
    } else if localDone, engine != nil {
      markOnboardingComplete(now: .now, context: context, engine: engine)
    }
  }

  /// Grandfather existing accounts past the first-run welcome. `onboardedAt`
  /// is a new field, so every pre-existing user starts with it nil — without
  /// this they'd be shown the welcome on the update that introduces it. If the
  /// account carries any real prior content, stamp the marker (which also sets
  /// the device-local flag and pushes to CloudKit so siblings learn of it).
  /// Idempotent and cheap: skips entirely once onboarded, and the probe uses
  /// `fetchCount` with a 1-row limit. Run at launch AFTER the CloudKit pull so
  /// a returning user's freshly-installed device sees their synced data.
  func grandfatherOnboardingIfEstablished(now: Date, context: ModelContext,
                                          engine: CKEngine?) {
    guard serverSettings?.onboardedAt == nil,
          !UserDefaults.standard.bool(forKey: SettingsKey.welcomeCompleted) else { return }
    guard SettingsMirror.accountHasExistingContent(context: context) else { return }
    markOnboardingComplete(now: now, context: context, engine: engine)
  }

  /// Whether the account shows any sign of prior use — delegates to the mirror
  /// helper so reinstall / new-device probes match the post-pull seeding gate.
  private func accountHasExistingContent(context: ModelContext) -> Bool {
    SettingsMirror.accountHasExistingContent(context: context)
  }

  /// Apply the welcome screen's section selection to the synced
  /// `SectionEntity` rows: enable every key the user picked, disable every
  /// other manage-able (logging-domain) section. Upsert-only — never deletes
  /// a row or its customizations, honoring the data-preservation guarantee.
  /// Enabled rows are marked `hasOnboarded` (the chained per-section
  /// onboarding presents from an explicit queue, so it doesn't depend on the
  /// bit). Posts one repaint after the batch.
  func applyWelcomeSelection(enabledKeys: Set<String>,
                             context: ModelContext, engine: CKEngine?) {
    for manifest in SectionManifest.all where manifest.kind == .loggingDomain {
      let shouldEnable = enabledKeys.contains(manifest.key)
      if shouldEnable {
        // hasOnboarded-setting overload: enabling implies set-up.
        SettingsMirror.setSectionEnabled(manifest.key, shouldEnable,
                                         context: context, engine: engine)
      } else {
        SettingsMirror.setSectionEnabled(manifest.key, enabled: false,
                                         context: context, engine: engine)
      }
    }
    sections = SettingsMirror.loadSections(context: context)
    NotificationCenter.default.post(name: .septenaDataChanged, object: nil)
  }

  /// The user's day-bucket cutoffs as currently configured, falling back to
  /// the synced payload and finally the historical defaults. Reads the App
  /// Group mirror that `DayBucket` uses, so the Settings pane and the rest of
  /// the app agree on the active value.
  var dayBucketCutoffs: DayBucketCutoffs { DayBucket.cutoffs }

  /// Update the day-bucket cutoffs: write the fast App Group mirror that
  /// `DayBucket` (and the widget/watch) read, then push the authoritative
  /// copy into the CloudKit-synced `AppSettings`. Mirrors `setWelcomeName`.
  func setDayBucketCutoffs(morningEnd: Int, afternoonEnd: Int,
                           context: ModelContext, engine: CKEngine?) {
    let c = DayBucketCutoffs(morningEnd: morningEnd, afternoonEnd: afternoonEnd)
    DayBucket.saveCutoffs(c)  // instant local mirror — UI updates immediately
    NotificationCenter.default.post(name: .septenaDataChanged, object: nil)
    guard serverSettings?.morningCutoffHour != c.morningEnd
            || serverSettings?.afternoonCutoffHour != c.afternoonEnd else { return }
    var s = serverSettings ?? AppSettings(sectionOrder: nil, targets: nil, units: nil,
                                          time: nil, theme: nil, eink: nil,
                                          nutrition: nil, hkSync: nil)
    s.morningCutoffHour = c.morningEnd
    s.afternoonCutoffHour = c.afternoonEnd
    serverSettings = s
    SettingsMirror.upsert(settings: s, context: context, engine: engine)
  }

  /// Reconcile the synced cutoffs with the App Group mirror `DayBucket` reads.
  /// A synced value (set on another device) wins → copy it into the suite. No
  /// synced value but a local override exists (upgrade leg) → push it up.
  /// Same inbound/outbound shape as `reconcileWelcomeName`.
  func reconcileDayBucketCutoffs(context: ModelContext, engine: CKEngine?) {
    if let m = serverSettings?.morningCutoffHour,
       let a = serverSettings?.afternoonCutoffHour {
      DayBucket.saveCutoffs(DayBucketCutoffs(morningEnd: m, afternoonEnd: a))
    } else {
      let local = DayBucket.cutoffs
      if local != .default, engine != nil {
        setDayBucketCutoffs(morningEnd: local.morningEnd,
                            afternoonEnd: local.afternoonEnd,
                            context: context, engine: engine)
      }
    }
  }

  func refresh(today: String) async {
    serverLoading = true
    defer { serverLoading = false }
    let context = LocalStore.shared.container.mainContext

    // Every source below is local. Settings / sections are CloudKit-
    // mirrored via SettingsEntity / SectionEntity; chores / beans /
    // strains / session-types ride on their own CK entities; macros
    // live in NSUbiquitousKeyValueStore.
    reloadFromMirror(context: context)

    let macs: MacrosConfig? = NutritionPrefs.loadMacrosConfig()
    let st: [SessionTypeConfig]? = ChecklistMirror.loadSessionTypes(context: context)
    let ch: [ChoreItem]? = ChecklistMirror.loadChores(context: context, today: today)
    if let macs { macros = macs; ResponseCache.save(macs, forKey: CacheKey.macros) }
    if let st { sessionTypes = st; ResponseCache.save(st, forKey: CacheKey.sessionTypes) }
    if let ch { chores = ch; ResponseCache.save(ch, forKey: CacheKey.chores) }
  }
}
