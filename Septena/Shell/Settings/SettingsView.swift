import SwiftUI
import SwiftData
import EventKit
import CloudKit
import CoreLocation
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

// Settings — the single unified surface for everything user-configurable.
// One sheet, one store, one entry point (sidebar row + ⌘,).
//
// Layout (Apple-style: app-wide rows on top, per-section rows below):
//   • Customize       — app-wide preferences (homepage layout, icon, quick actions)
//   • Integrations    — Reminders / Calendar / HealthKit permissions
//   • Sync            — server URL + manual sync
//   • Privacy         — analytics consent
//   • About           — version / links
//   ── Sections ────────────────────────────
//   • Tasks           — badge, today toggle, task sort + identity
//   • Training, Nutrition, Sleep, Habits, Intake, …
//                     — identity + (where applicable) catalog data
//
// Per-section rows are driven by `SectionManifest.all` filtered against
// the user's installed `SectionEntity` set (CloudKit-mirrored via
// CKEngine). Each row pushes to `SectionDetailPane(key:)` which composes
// identity + section-specific content.

// MARK: - Default keys

enum SettingsKey {
  static let badgeShowOverdue = "septena.badge.showOverdue"
  /// Master switch for local-notification nudges. Same string as
  /// `LocalNotificationScheduler.masterKey`. Absent → on (granting the
  /// permission prompt is the opt-in); flipping it off withdraws every
  /// pending nudge on the next reconcile.
  static let notificationsEnabled = "septena.notify.enabled"
  static let todayShowCompleted = "septena.today.showCompleted"
  /// Device-local mirror of `AppSettings.onboardedAt`: true once the
  /// first-run welcome has been completed (here or, after sync, on another
  /// device). The welcome gate reads this for an instant, offline-safe
  /// "skip the welcome" decision so it never flashes on a returning user's
  /// device. Written by `SettingsStore.markOnboardingComplete` /
  /// `reconcileOnboarding`.
  static let welcomeCompleted = "septena.welcome.completed"
  /// Device-local marker of the newest release the user has already seen in
  /// the "What's New" sheet. Empty on a fresh install (the welcome covers
  /// first run, so we adopt the current version silently instead of showing
  /// notes). On update, any release newer than this triggers the sheet once;
  /// dismissing it advances the marker to the latest version.
  static let lastSeenChangelogVersion = "septena.changelog.lastSeenVersion"
  /// Device-local dev override: forces the welcome to present even on an
  /// established account, surviving relaunch, so the first-run flow can be
  /// re-tested without wiping the app. Set by Settings ▸ About ▸ Advanced
  /// ("Reset first-run welcome"); cleared when the welcome is completed.
  /// Never set in normal use, so the gate behaves exactly as before.
  static let welcomeForce = "septena.welcome.force"
  /// Consent toggle for anonymous aggregate usage telemetry.
  /// Same key string is referenced by `TelemetryClient.consentKey` so the
  /// guard inside the actor and the @AppStorage binding stay in sync.
  static let shareUsageData   = "septena.privacy.shareUsageData"
  /// Which renderer the homepage uses. Raw value of `HomepageLayoutMode`.
  /// Default (`tiles`) preserves the existing card-grid behaviour, so
  /// users with no setting see no change.
  static let homepageLayout   = "septena.homepage.layout"
  /// How the front door shows "today at a glance" between the greeting and
  /// the layout: the circular Day dial, the linear timeline strip, or
  /// hidden. Raw value of `DayViewStyle`; default dial. Replaced the old
  /// show-timeline / show-dial boolean pair.
  static let homepageDayView = "septena.homepage.dayView"
  /// The dashboard dial's day boundary. On → the wheel rolls over at wake
  /// (sleep → 4am cutoff → midnight; see `WakingDay`) instead of calendar
  /// midnight, so a late night stays on one dial. Default on. This is the
  /// literal key `DayDialHero` / `RhythmHomepageView` / `TimeOfDayWheel`
  /// already read — kept verbatim so the constant binds to the same storage.
  static let wheelWakingDay = "wheel.wakingDay"
  /// Master switch for the optional daily-message line at the foot of the home
  /// dashboard. Off by default — a homepage display preference, device-local
  /// like the Day-dial toggles (the quote *content* syncs via `QuoteEntity`,
  /// the on/off does not).
  static let dailyMessageEnabled = "septena.dailyMessage.enabled"
  /// Which preset `QuotePack`s feed the rotation, comma-separated rawValues.
  /// Defaults to all three on; stored user lines are always in the pool when the
  /// feature is on, independent of this.
  static let dailyMessagePacks = "septena.dailyMessage.packs"
  /// Whether imported Readwise highlights feed the rotation. On by default;
  /// turning it off drops them from the pool WITHOUT disconnecting Readwise or
  /// deleting the imported lines (your own quotes + packs stay). Device-local,
  /// like the other daily-message display preferences.
  static let dailyMessageReadwiseEnabled = "septena.dailyMessage.readwise.enabled"
  /// Optional first name used to personalise the homepage welcome greeting.
  /// Local-only (@AppStorage); not synced to CloudKit.
  static let welcomeName = "septena.homepage.welcomeName"
  /// Device-local mirror of `AppSettings.units.weight` ("kg"/"lb") that the
  /// Training and Body display surfaces read via `@AppStorage` for instant,
  /// offline-safe formatting. The literal lives on `WeightUnit` so the helper
  /// and this constant can't drift (same arrangement as `localMcpEnabled` →
  /// `MCPDefaultsKey.enabled`). Written by `SettingsStore.setWeightUnit` /
  /// `reconcileUnits`; seeded from the device locale on first launch.
  static let weightUnit = WeightUnit.defaultsKey
  /// Device-local mirror of `AppSettings.units.distance` ("km"/"mi"), paired
  /// with `weightUnit` — the one metric/imperial switch sets both. Read by the
  /// cardio distance/speed readouts via `@AppStorage` / `DistanceUnit.current`.
  static let distanceUnit = DistanceUnit.defaultsKey
  /// Device-local mirror of the fluid-volume unit ("ml"/"floz"), derived from
  /// the same metric/imperial choice. Not a separate `AppUnits` field — it
  /// rides the weight decision, so old synced payloads need no migration. Read
  /// by the hydration / nutrition-water surfaces via `VolumeUnit.current`.
  static let volumeUnit = VolumeUnit.defaultsKey
  /// Voice of the generated welcome greeting. Raw value of `WelcomeTone`.
  static let welcomeTone = "septena.homepage.welcomeTone"
  /// Today's on-device generated welcome lines, JSON-encoded and keyed by
  /// phase. Reset whenever the day or `welcomeName` changes.
  static let welcomeCache = "septena.homepage.welcomeCache"
  /// Time window (in days) the Correlations homepage mode computes over.
  /// Same key as the old Insights destination so prior preference carries
  /// forward.
  static let correlationsWindowDays = "insights.windowDays"
  /// Section filter for the Correlations homepage mode. "all" or a
  /// section key (e.g. "sleep").
  static let correlationsSectionFilter = "septena.correlations.sectionFilter"
  /// Whether to show the supplements → sleep score table above the
  /// trusted-signals grid. Default on.
  static let correlationsShowSupplements = "septena.correlations.showSupplements"
  /// Whether to show the "Not enough data yet" collapsed section
  /// below the exploratory grid. Default off.
  static let correlationsShowInsufficient = "septena.correlations.showInsufficient"
  /// Master toggle for fasting tracking. When on, the nutrition tile
  /// morphs into a live fasting timer once the state machine detects a
  /// fasting window, and the nutrition heatmap may show fasting hours
  /// per day (see `nutritionHeatmapMetric`). Off → no fasting UI.
  static let nutritionTrackFasting = "septena.nutrition.trackFasting"
  /// Which metric the nutrition heatmap encodes per cell. Either
  /// "protein" (default) or "fasting". Persistent preference; not
  /// state-based — the heatmap is historical, so the choice doesn't
  /// flip with current fasting state.
  static let nutritionHeatmapMetric = "septena.nutrition.heatmapMetric"
  /// User-selected Home Screen Quick Actions, stored as comma-separated
  /// section keys (max 4). Applied to `UIApplication.shared.shortcutItems`
  /// at launch and whenever the selection changes.
  static let quickActionKeys = "septena.quickActions.keys"
  /// Where the Tasks tile opens to from the homepage. Other section tiles
  /// open as a bottom-sheet drawer; Tasks historically jumped straight to
  /// the Tasks tab. Default `drawer` so Tasks matches the other sections;
  /// users who prefer landing on the full Tasks tab can flip it.
  static let tasksOpenIn      = "septena.tasks.openIn"
  /// Whether the Tasks lists weave in the day's calendar events — the day's
  /// agenda at the top of Today and under each Upcoming day, Things-style.
  /// Absent → on (events only ever show once calendar access is granted in
  /// Settings → Integrations, so the default can't surprise-prompt). Read by
  /// `TaskListView`.
  static let tasksShowCalendarEvents = "septena.tasks.showCalendarEvents"
  /// Master switch for the per-log "commit flourish" animations (the
  /// `CommitMotion` / `LogCommitOverlay` celebrations that play when you log
  /// something). Absent → on. Off suppresses every logging animation
  /// app-wide; the commit haptic + VoiceOver confirmation still fire, exactly
  /// like Reduce Motion. Read by `CommitFlourish` and `LogCommitOverlay`.
  static let loggingAnimationsEnabled = "septena.ui.loggingAnimations"
  /// Whether the user is a paying *supporter*. The whole app is free — this
  /// flag unlocks NOTHING functional; it only drives cosmetics (the avatar
  /// foil ring and the "Supporter" badge). It's a local @AppStorage *mirror*
  /// of the real StoreKit entitlement: `SupportStore` recomputes ownership
  /// from `Transaction.currentEntitlements` and writes it here, so every
  /// cosmetic reader stays truth-backed without knowing about StoreKit. (Key
  /// string kept for continuity with existing installs.)
  static let plusUnlocked     = "septena.plus.unlocked"
  /// One-time gate for the "earned moment" support prompt (shown once, ever,
  /// after a milestone once the user is well-established). Local-only.
  static let supportMomentShown = "septena.support.momentShown"
  /// macOS-only: run an in-process loopback MCP server so a local Claude Code
  /// instance can read/write Septena without the hosted gateway. Off by
  /// default. The key strings live in SeptenaCore (`MCPDefaultsKey`) so the
  /// `LocalMCPServer` and this facade can't drift.
  static let localMcpEnabled  = MCPDefaultsKey.enabled
  /// macOS-only: bearer token Claude Code sends to the local MCP server.
  static let localMcpToken    = MCPDefaultsKey.token
  /// Whole-app privacy lock: require Face ID / Touch ID / device passcode to
  /// reopen Septena after it's been backgrounded past the grace window.
  /// Local-only @AppStorage — the lock is a per-device privacy gate, not
  /// synced account data (each device opts in on its own). Read by `AppLock`.
  static let appLockEnabled      = "septena.security.appLock"
  /// Seconds the app may sit backgrounded before the lock re-arms. 0 =
  /// immediately. Absent → 60. Read by `AppLock`.
  static let appLockGraceSeconds = "septena.security.appLockGrace"
}

/// Where a homepage tap on the Tasks tile lands. `drawer` shows today's
/// tasks as a bottom-sheet (matches every other section); `tab` switches
/// the tab bar to the full Tasks surface.
enum TasksOpenMode: String, CaseIterable, Identifiable {
  case drawer, tab
  var id: String { rawValue }
  var label: String {
    switch self {
    case .drawer: return String(localized: "Drawer", comment: "Tasks-tile open mode")
    case .tab:    return String(localized: "Tasks tab", comment: "Tasks-tile open mode")
    }
  }
}

enum NutritionHeatmapMetric: String, CaseIterable, Identifiable {
  case protein, fasting
  var id: String { rawValue }
  var label: String { self == .protein ? String(localized: "Protein", comment: "Nutrition heatmap metric") : String(localized: "Fasting hours", comment: "Nutrition heatmap metric") }
}

enum AppIconOption: String, CaseIterable, Identifiable {
  case `default` = "AppIcon"
  case red       = "AppIconRed"
  case orange    = "AppIconOrange"
  case yellow    = "AppIconYellow"
  case green     = "AppIconGreen"
  case cyan      = "AppIconCyan"
  case blue      = "AppIconBlue"
  case purple    = "AppIconPurple"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .default: return String(localized: "Default", comment: "App icon color")
    case .red:     return String(localized: "Red", comment: "App icon color")
    case .orange:  return String(localized: "Orange", comment: "App icon color")
    case .yellow:  return String(localized: "Yellow", comment: "App icon color")
    case .green:   return String(localized: "Green", comment: "App icon color")
    case .cyan:    return String(localized: "Cyan", comment: "App icon color")
    case .blue:    return String(localized: "Blue", comment: "App icon color")
    case .purple:  return String(localized: "Purple", comment: "App icon color")
    }
  }

  var alternateIconName: String? {
    self == .default ? nil : rawValue
  }

  var background: Color {
    background(forDarkMode: false)
  }

  func background(forDarkMode isDarkMode: Bool) -> Color {
    if isDarkMode {
      return .clear
    }
    switch self {
    case .default: return .white
    case .red:     return parseHexColor("#ef4444")
    case .orange:  return parseHexColor("#f97316")
    case .yellow:  return parseHexColor("#eab308")
    case .green:   return parseHexColor("#22c55e")
    case .cyan:    return parseHexColor("#06b6d4")
    case .blue:    return parseHexColor("#3b82f6")
    case .purple:  return parseHexColor("#8b5cf6")
    }
  }

  var dotColors: [Color] {
    dotColors(forDarkMode: false)
  }

  func dotColors(forDarkMode isDarkMode: Bool) -> [Color] {
    if isDarkMode {
      switch self {
      case .default:
        return [
          parseHexColor("#ef4444"),
          parseHexColor("#f97316"),
          parseHexColor("#eab308"),
          parseHexColor("#22c55e"),
          parseHexColor("#06b6d4"),
          parseHexColor("#3b82f6"),
          parseHexColor("#8b5cf6"),
        ]
      case .red:
        return Array(repeating: parseHexColor("#ef4444"), count: 7)
      case .orange:
        return Array(repeating: parseHexColor("#f97316"), count: 7)
      case .yellow:
        return Array(repeating: parseHexColor("#eab308"), count: 7)
      case .green:
        return Array(repeating: parseHexColor("#22c55e"), count: 7)
      case .cyan:
        return Array(repeating: parseHexColor("#06b6d4"), count: 7)
      case .blue:
        return Array(repeating: parseHexColor("#3b82f6"), count: 7)
      case .purple:
        return Array(repeating: parseHexColor("#8b5cf6"), count: 7)
      }
    }
    switch self {
    case .default:
      return [
        parseHexColor("#ef4444"),
        parseHexColor("#f97316"),
        parseHexColor("#eab308"),
        parseHexColor("#22c55e"),
        parseHexColor("#06b6d4"),
        parseHexColor("#3b82f6"),
        parseHexColor("#8b5cf6"),
      ]
    default:
      return Array(repeating: .white, count: 7)
    }
  }

  #if os(iOS)
  static var current: AppIconOption {
    guard let name = UIApplication.shared.alternateIconName else { return .default }
    return AppIconOption(rawValue: name) ?? .default
  }
  #endif
}

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
  }

  /// Synchronous, local-only welcome suppression for established accounts: if
  /// the welcome hasn't been completed and there's no marker yet but the local
  /// store already holds the user's data, set the device-local flag so the gate
  /// never shows the welcome on the first frame. Pure flag write — no context
  /// mutation, no network (safe to call from `paintFromCache` during init).
  func adoptWelcomeFlagIfEstablished(context: ModelContext) {
    guard !UserDefaults.standard.bool(forKey: SettingsKey.welcomeCompleted),
          serverSettings?.onboardedAt == nil,
          accountHasExistingContent(context: context) else { return }
    UserDefaults.standard.set(true, forKey: SettingsKey.welcomeCompleted)
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
    guard accountHasExistingContent(context: context) else { return }
    markOnboardingComplete(now: now, context: context, engine: engine)
  }

  /// Whether the account shows any sign of prior use — used only to decide
  /// whether to grandfather past the welcome. A truly fresh account has none
  /// of these; an established one trips on the first probe. Section
  /// customization (a saved order) counts too, so a setup-but-never-logged
  /// account isn't re-onboarded.
  private func accountHasExistingContent(context: ModelContext) -> Bool {
    if !(serverSettings?.sectionOrder?.isEmpty ?? true) { return true }
    if !(serverSettings?.welcomeName?.isEmpty ?? true) { return true }

    func any<T: PersistentModel>(_ type: T.Type) -> Bool {
      var d = FetchDescriptor<T>()
      d.fetchLimit = 1
      return ((try? context.fetchCount(d)) ?? 0) > 0
    }
    return any(TaskEntity.self)
      || any(HabitDefinitionEntity.self)
      || any(SupplementDefinitionEntity.self)
      || any(GoalEntity.self)
      || any(NutritionEntryEntity.self)
      || any(ExerciseEntryEntity.self)
      || any(ChoreDefinitionEntity.self)
      || any(GutEventEntity.self)
      || any(MoodEventEntity.self)
      || any(SymptomEventEntity.self)
      || any(MedicationDoseEventEntity.self)
      || any(IntakeEventEntity.self)
      || any(GroceryItemEntity.self)
      || any(ActivityDayEntity.self)
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

  func refresh() async {
    serverLoading = true
    defer { serverLoading = false }
    let context = LocalStore.shared.container.mainContext

    // Every source below is local. Settings / sections are CloudKit-
    // mirrored via SettingsEntity / SectionEntity; chores / beans /
    // strains / session-types ride on their own CK entities; macros
    // live in NSUbiquitousKeyValueStore.
    if let mirroredSettings = SettingsMirror.loadSettings(context: context) {
      serverSettings = mirroredSettings
      ResponseCache.save(mirroredSettings, forKey: CacheKey.serverSettings)
      HealthKitBridge.shared.syncSettings = mirroredSettings.hkSync ?? HKSyncSettings()
    }
    let mirroredSections = SettingsMirror.loadSections(context: context)
    if !mirroredSections.isEmpty {
      sections = mirroredSections
      ResponseCache.save(mirroredSections, forKey: CacheKey.sections)
    }

    let macs: MacrosConfig? = NutritionPrefs.loadMacrosConfig()
    let st: [SessionTypeConfig]? = ChecklistMirror.loadSessionTypes(context: context)
    let ch: [ChoreItem]? = ChecklistMirror.loadChores(context: context)
    if let macs { macros = macs; ResponseCache.save(macs, forKey: CacheKey.macros) }
    if let st { sessionTypes = st; ResponseCache.save(st, forKey: CacheKey.sessionTypes) }
    if let ch { chores = ch; ResponseCache.save(ch, forKey: CacheKey.chores) }
  }
}

// MARK: - Sheet root

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  // `store` resolves section titles for the navigation bar; section reorder and
  // writes now live in the leaf panes (SectionsSettingsPane / SectionDetailPane),
  // so SettingsView no longer needs modelContext or the CK engine directly.
  @Environment(SettingsStore.self) private var store
  #if os(macOS)
  // Settings runs in its own (reused) window on macOS; this drives the
  // deep-link → pane sync in the macOS branch of `body`.
  @Environment(NavigationState.self) private var nav
  #endif
  @State private var selection: SettingsDestination?
  /// iPhone-only navigation path. Seeded from `initialDestination` so the
  /// sheet can open already pushed to a specific pane (e.g. a section's
  /// settings, deep-linked from its drawer) with a back-chevron to the
  /// settings list. Unused on macOS/iPad, which deep-link via `selection`.
  @State private var path: [SettingsDestination]
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var preferredCompactColumn: NavigationSplitViewColumn = .detail

  /// Open straight to a destination, or `nil` for the historical default
  /// (sidebar list on iPhone, `.general` detail on macOS/iPad). The
  /// "Customize <Section>" footer in `SectionDrawer` passes `.section(key)`.
  init(initialDestination: SettingsDestination? = nil) {
    _selection = State(initialValue: initialDestination ?? .sections)
    _path = State(initialValue: initialDestination.map { [$0] } ?? [])
  }

  /// Sidebar entries. Static cases for app-wide settings; `section(key)`
  /// for per-section rows resolved against `SectionManifest` + the live
  /// `store.sections` list.
  enum SettingsDestination: Hashable {
    case account
    // Root rows (Apple-style intent groups), in sidebar order.
    case sections        // collapsed per-section list (absorbs Manage Sections)
    case home            // homepage: layout, timeline, welcome, insights
    case notifications   // promoted to root
    case connectionsAI   // AI reach + Claude/MCP + app/service integrations
    case sharingData     // practitioner reports + import/export
    case privacy
    case feedback        // roadmap + community profile + testimonial
    case about
    case whatsNew        // release notes, reached from About
    case advanced        // dev + diagnostics, reached from About
    // Sub-panes reached from the hubs above.
    case general         // time of day, app icon, quick actions, animations
    case claudeAI        // unified AI reach + Claude gateway + local MCP + skills
    case connections     // Apple + service integrations (was Integrations)
    case data            // import / export (was Import & Export)
    case reports         // practitioner reports — scoped shareable section bundles
    case layout, correlations, timeOfDay
    case nextFeed        // Next list: suggestions, carry-over, per-section visibility
    case quickActions, appIcon
    case skills, localMcp, motionGallery, dataTools
    case support
    case communityProfile   // public username / display name / bio (community Worker)
    case communityRoadmap   // feature-request board (community Worker)
    case communityTestimonial // one-per-user testimonial (community Worker)
    case milestonePreview   // DEBUG bench: fire each milestone celebration
    case siriShortcuts
    case section(String)
  }

  var body: some View {
    #if os(iOS)
    // Presented as a drawer: a grab handle on top, swipe-down to dismiss, no
    // explicit close button (the user prefers the tab-on-top affordance over a
    // "Done" toolbar item). The drag indicator lives here so every call site
    // that presents SettingsView in a sheet gets it for free.
    NavigationStack(path: $path) {
      sidebarList
        .navigationTitle("Settings")
        .navigationDestination(for: SettingsDestination.self) { dest in
          pane(for: dest)
            .navigationTitle(title(for: dest))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    .presentationDragIndicator(.visible)
    #else
    NavigationSplitView(columnVisibility: $columnVisibility,
                        preferredCompactColumn: $preferredCompactColumn) {
      sidebarList(selection: $selection)
        .navigationTitle("Settings")
        // The sidebar is always shown — Settings is a fixed-size window with
        // only seven root rows, so the collapse affordance just invited an
        // awkward detail-only state. Drop the toolbar toggle entirely.
        .toolbar(removing: .sidebarToggle)
        // ...and pin the column so the divider can't be dragged at all: the
        // window is a fixed 820×600, so a resizable/collapsible sidebar only
        // let the user throw the proportions off. min == ideal == max leaves
        // the divider no range to drag, which also blocks the fold-away.
        .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 220)
    } detail: {
      NavigationStack {
        let dest = selection ?? .sections
        pane(for: dest)
          .navigationTitle(title(for: dest))
          // The hub panes (Home, Sections, Connections & AI, …) push their
          // sub-panes via `NavigationLink(value:)`; the detail column needs
          // its own resolver for those to open (the sidebar only drives the
          // root `selection`).
          .navigationDestination(for: SettingsDestination.self) { sub in
            pane(for: sub)
              .navigationTitle(title(for: sub))
          }
      }
    }
    // Fixed sheet size on macOS. With only minimums the sheet grew and
    // shrank to fit each pane's intrinsic content height, so navigating
    // between a short pane (Privacy) and a tall one (App Icon grid) made
    // the whole window jump. A stable frame lets the Form/List scroll
    // internally instead — matching the fixed-frame QuickFind / AddInfo
    // sheets.
    .frame(width: 820, height: 600)
    // No "Done" button on macOS: Settings is its own window (see App.swift),
    // so the split view fills the whole frame and the window's traffic
    // lights close it. Escape closes it too. A `.toolbar` confirmationAction
    // would instead render a detached button band below the split view,
    // rounding the columns off above it and leaving a dead gap.
    .onExitCommand { dismiss() }
    // The window is reused across opens, so seed the pane from the contextual
    // deep-link target ("Customize <Section>", the Insights gear) and clear
    // it when the window closes so the next plain open lands on the root.
    .onChange(of: nav.settingsDestination) { _, dest in
      if let dest { selection = dest }
    }
    .onDisappear { nav.settingsDestination = nil }
    #endif
  }

  // The root sidebar is a short, fixed list of intent groups (Apple's iOS-18
  // model). Per-section rows and intake trackers no longer live here — they
  // moved one level down into the Sections pane (and, for trackers, the Intake
  // section's own detail), so the root stays scannable regardless of how many
  // sections the user has enabled.
  #if os(iOS)
  @ViewBuilder
  private var sidebarList: some View {
    List {
      SwiftUI.Section {
        NavigationLink(value: SettingsDestination.account) {
          IdentityHeaderRow()
        }
      }
      SwiftUI.Section {
        ForEach(staticDestinations, id: \.self) { dest in
          NavigationLink(value: dest) { staticRow(dest) }
        }
      }
      // About sits on its own, below Feedback — a utility row (gray disc
      // tile) set apart by the section break, not mixed in with the
      // accent-colored intent groups.
      SwiftUI.Section {
        NavigationLink(value: SettingsDestination.about) { aboutRow }
      }
    }
    .scrollContentBackground(.hidden)
    .background(SettingsTopGradient())
  }
  #else
  @ViewBuilder
  private func sidebarList(selection: Binding<SettingsDestination?>) -> some View {
    List(selection: selection) {
      SwiftUI.Section {
        IdentityHeaderRow().tag(SettingsDestination.account)
      }
      SwiftUI.Section {
        ForEach(staticDestinations, id: \.self) { dest in
          staticRow(dest).tag(dest)
        }
      }
      // About on its own, below Feedback — gray disc tile, set apart.
      SwiftUI.Section {
        aboutRow.tag(SettingsDestination.about)
      }
    }
  }
  #endif

  private var staticDestinations: [SettingsDestination] {
    // Seven intent groups. The profile card above this list is destination 0;
    // About/Advanced live under Account so utility pages don't consume root
    // slots, and the former General controls sit inside Home.
    [.sections, .home, .notifications, .connectionsAI,
     .sharingData, .privacy, .feedback]
  }

  private func staticRow(_ dest: SettingsDestination) -> some View {
    Label {
      Text(title(for: dest))
    } icon: {
      #if os(macOS)
      ColoredGlyph(icon: icon(for: dest), color: tint(for: dest), size: 20, glyphRatio: 0.48)
      #else
      ColoredGlyph(icon: icon(for: dest), color: tint(for: dest), size: 29, glyphRatio: 0.38)
      #endif
    }
  }

  /// The About row, shared by both sidebars: the Septena disc tile (gray,
  /// utility) plus the "About" label. Sized to match the platform's static
  /// rows (29pt on iOS, 20pt on macOS).
  private var aboutRow: some View {
    Label {
      Text(title(for: .about))
    } icon: {
      #if os(macOS)
      SeptenaDiscTile(size: 20)
      #else
      SeptenaDiscTile(size: 29)
      #endif
    }
  }

  private func sectionIcon(for key: String) -> String {
    if let m = SectionManifest.byKey[key] { return m.iconSymbol }
    return "circle.fill"
  }

  private func title(for dest: SettingsDestination) -> String {
    switch dest {
    case .account:      return "Account"
    case .sections:     return "Sections"
    case .home:         return "Home"
    case .connectionsAI: return "Connections & AI"
    case .sharingData:  return "Sharing & Data"
    case .general:      return "General"
    case .claudeAI:     return "AI"
    case .quickActions: return "Quick Actions"
    case .appIcon:      return "App Icon"
    case .layout:       return "Layout"
    case .correlations: return "Insights"
    case .timeOfDay:    return "Time of Day"
    case .nextFeed:     return "Next"
    case .notifications: return "Notifications"
    case .connections:  return "Connected Apps"
    case .data:         return "Import & Export"
    case .reports:      return "Practitioner Reports"
    case .support:      return "Support"
    case .communityProfile: return "Public Profile"
    case .communityRoadmap: return "Roadmap"
    case .communityTestimonial: return "Testimonial"
    case .skills:       return "MCP Skills"
    case .siriShortcuts: return "Siri & Shortcuts"
    case .privacy:      return "Privacy"
    case .feedback:     return "Feedback"
    case .about:        return "About"
    case .whatsNew:     return "What's New"
    case .advanced:     return "Advanced"
    case .dataTools:    return "Data Tools"
    case .motionGallery: return "Motion Gallery"
    case .milestonePreview: return "Milestones (preview)"
    case .localMcp:     return "MCP Server"
    case .section(let key):
      return SectionManifest.displayLabel(
        key: key,
        stored: store.sections.first(where: { $0.key == key })?.label ?? "")
    }
  }

  // Icon + tint helpers feed the root sidebar rows; sub-panes carry their
  // own Label glyphs at their navigation links.
  private func icon(for dest: SettingsDestination) -> String {
    switch dest {
    case .account:      return "person.crop.circle"
    case .sections:     return "square.grid.2x2"
    case .home:         return "house"
    case .connectionsAI: return "brain.head.profile"
    case .sharingData:  return "square.and.arrow.up"
    case .general:      return "slider.horizontal.3"
    case .claudeAI:     return "brain.head.profile"
    case .quickActions: return "bolt"
    case .appIcon:      return "app.badge"
    case .layout:       return "square.grid.2x2"
    case .correlations: return "chart.dots.scatter"
    case .timeOfDay:    return "clock"
    case .nextFeed:     return "arrow.forward.circle"
    case .notifications: return "bell.badge"
    case .connections:  return "app.connected.to.app.below.fill"
    case .data:         return "externaldrive"
    case .reports:      return "chart.bar.doc.horizontal"
    case .support:      return "lifepreserver"
    case .communityProfile: return "person.text.rectangle"
    case .communityRoadmap: return "map"
    case .communityTestimonial: return "quote.bubble"
    case .skills:       return "book.closed"
    case .siriShortcuts: return "mic"
    case .privacy:      return "hand.raised"
    case .feedback:     return "bubble.left.and.bubble.right"
    case .about:        return "info.circle"
    case .whatsNew:     return "megaphone"
    case .advanced:     return "wrench.and.screwdriver"
    case .dataTools:    return "stethoscope"
    case .motionGallery: return "wand.and.rays"
    case .milestonePreview: return "flag.checkered"
    case .localMcp:     return "server.rack"
    case .section:      return "circle.fill"
    }
  }

  /// The app's 7 accent colors — the Septena app-icon rainbow (same set
  /// as `AppIconOption`'s discs). The app-wide settings rows cycle
  /// through these in `staticDestinations` order instead of carrying
  /// ad-hoc per-row tints, so the palette stays on-brand and consistent.
  private static let accentPalette: [Color] = [
    parseHexColor("#ef4444"), // red
    parseHexColor("#f97316"), // orange
    parseHexColor("#eab308"), // yellow
    parseHexColor("#22c55e"), // green
    parseHexColor("#06b6d4"), // cyan
    parseHexColor("#3b82f6"), // blue
    parseHexColor("#8b5cf6"), // purple
  ]

  private func tint(for dest: SettingsDestination) -> Color {
    guard let idx = staticDestinations.firstIndex(of: dest) else { return .gray }
    return Self.accentPalette[idx % Self.accentPalette.count]
  }

  @ViewBuilder
  private func pane(for dest: SettingsDestination) -> some View {
    switch dest {
    case .account:           AccountSettingsPane()
    case .sections:          SectionsSettingsPane()
    case .home:              HomeSettingsPane()
    case .connectionsAI:     ConnectionsAISettingsPane()
    case .sharingData:       SharingDataSettingsPane()
    case .general:           GeneralSettingsPane()
    case .claudeAI:          ClaudeAISettingsPane()
    case .quickActions:      QuickActionsSettingsPane()
    case .appIcon:           AppIconSettingsPane()
    case .layout:            LayoutSettingsPane()
    case .correlations:      CorrelationsSettingsPane()
    case .timeOfDay:         TimeOfDaySettingsPane()
    case .nextFeed:          NextSettingsPane()
    case .notifications:     NotificationsOverviewPane()
    case .connections:       IntegrationsSettingsPane()
    case .data:              ImportExportSettingsPane(mode: .full)
    case .reports:           ReportsSettingsPane()
    case .support:           SupportSettingsPane()
    case .communityProfile:  CommunityProfilePane()
    case .communityRoadmap:  CommunityRoadmapPane()
    case .communityTestimonial: CommunityTestimonialPane()
    case .dataTools:         ImportExportSettingsPane(mode: .dataTools)
    case .skills:            SkillsSettingsPane()
    case .siriShortcuts:     SiriShortcutsSettingsPane()
    case .privacy:           PrivacySettingsPane()
    case .feedback:          FeedbackSettingsPane()
    case .about:             AboutSettingsPane()
    case .whatsNew:          ChangelogList()
    case .advanced:          AdvancedSettingsPane()
    case .motionGallery:     MotionGalleryPane()
    case .milestonePreview:  MilestonePreviewPane()
    #if os(macOS)
    case .localMcp:          LocalMCPSettingsPane()
    #else
    case .localMcp:          MCPServerUnavailablePane()
    #endif
    case .section(let key):  SectionDetailPane(sectionKey: key)
    }
  }
}

/// The Settings-row icon for the About page: the seven Septena discs in
/// white on a neutral gray tile, matching `ColoredGlyph`'s shape and sheen
/// (white glyph on a saturated fill) so it sits flush with the colored rows
/// above it. Gray (not a brand accent) marks About as a utility row, while
/// the white discs keep it unmistakably the app's own mark. Disc placement
/// reuses the shared `SeptenaPlus` constants so the emblem can't drift.
struct SeptenaDiscTile: View {
  var size: CGFloat = 29
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
    let gray = Color(white: colorScheme == .dark ? 0.32 : 0.55)
    ZStack {
      shape.fill(gray)
      shape.fill(
        LinearGradient(
          colors: [Color.white.opacity(0.26), .clear, Color.black.opacity(0.07)],
          startPoint: .top, endPoint: .bottom
        )
      )
      ForEach(Array(SeptenaPlus.discCenters.enumerated()), id: \.offset) { index, center in
        Circle()
          .fill(.white)
          .frame(width: size * 0.168, height: size * 0.168)
          .position(x: size * center.x, y: size * center.y)
      }
    }
    .frame(width: size, height: size)
  }
}

/// Resolved sidebar row for a section — combines the static manifest
/// (icon, defaults) with the live server overrides (label, accent).
struct SectionEntry: Identifiable, Hashable {
  let manifest: SectionManifest
  let server: SectionConfig
  var id: String { manifest.key }
  var key: String { manifest.key }
  /// Installed `SectionEntity.title` wins; manifest default is the
  /// fallback when the user hasn't customized the label (or the local
  /// mirror hasn't hydrated yet).
  var label: String {
    SectionManifest.displayLabel(key: manifest.key, stored: server.label)
  }
  /// Accent comes from the user's `SectionEntity.color`. No catalog
  /// default — `parseHexColor` already returns neutral gray for empty
  /// or unparseable strings, which is the right fallback when the user
  /// hasn't picked a color yet.
  var accent: Color { parseHexColor(server.color) }
  /// User has turned this section off. The row stays in the sidebar but
  /// renders muted so it's clear the section isn't active.
  var isEnabled: Bool { server.isEnabled }
}

/// Soft top-down luminance wash behind the Settings list — the same
/// subtle lift Apple's Settings.app draws under the title. A near-white
/// (or, in dark mode, a faint white) band fades into the grouped
/// background over the first ~300pt, so the top of the list reads a touch
/// brighter without changing the rest of the surface.
private struct SettingsTopGradient: View {
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    ZStack(alignment: .top) {
      Theme.groupedBackground
      LinearGradient(
        colors: [scheme == .dark ? Color.white.opacity(0.06)
                                 : Color.white.opacity(0.9),
                 .clear],
        startPoint: .top, endPoint: .bottom
      )
      .frame(height: 300)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .ignoresSafeArea()
  }
}
