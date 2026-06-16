import SwiftUI
import SwiftData
import EventKit
import CloudKit
import CoreLocation
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
  /// Device-local dev override: forces the welcome to present even on an
  /// established account, surviving relaunch, so the first-run flow can be
  /// re-tested without wiping the app. Set by Settings ▸ About ▸ Advanced
  /// ("Reset first-run welcome"); cleared when the welcome is completed.
  /// Never set in normal use, so the gate behaves exactly as before.
  static let welcomeForce = "septena.welcome.force"
  /// Consent toggle for anonymous aggregate usage analytics (Plausible).
  /// Same key string is referenced by `PlausibleClient.consentKey` so the
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
  /// Whether the time-of-day wheels open focused on today (default) or on the
  /// trailing 7-day overlay. Same literal as `TimeOfDayWheel.windowDefaultsKey`
  /// — tapping a wheel writes this same key, so the setting stays in sync.
  static let wheelTodayOnly = "timeOfDayWheel.todayOnly"
  /// Optional first name used to personalise the homepage welcome greeting.
  /// Local-only (@AppStorage); not synced to CloudKit.
  static let welcomeName = "septena.homepage.welcomeName"
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
  /// Master switch for the per-log "commit flourish" animations (the
  /// `CommitMotion` / `LogCommitOverlay` celebrations that play when you log
  /// something). Absent → on. Off suppresses every logging animation
  /// app-wide; the commit haptic + VoiceOver confirmation still fire, exactly
  /// like Reduce Motion. Read by `CommitFlourish` and `LogCommitOverlay`.
  static let loggingAnimationsEnabled = "septena.ui.loggingAnimations"
  /// Mock entitlement flag for the (not-yet-real) Septena+ membership.
  /// Local-only @AppStorage — there's no StoreKit / IAP yet, so this is
  /// flipped by the in-app "mock unlock" toggle in the paywall. Gates the
  /// Correlations homepage layout; turning it off re-locks Plus features.
  static let plusUnlocked     = "septena.plus.unlocked"
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
    case general         // time of day, app icon, quick actions, animations
    case claudeAI        // unified AI reach + Claude gateway + local MCP + skills
    case connections     // Apple + service integrations (was Integrations)
    case privacy
    case data            // import / export (was Import & Export)
    case reports         // practitioner reports — scoped shareable section bundles
    case about
    case advanced        // dev + diagnostics, reached from About
    // Sub-panes reached from the hubs above.
    case layout, correlations, timeOfDay
    case quickActions, appIcon
    case skills, localMcp, motionGallery, dataTools
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
        // only ten root rows, so the collapse affordance just invited an
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
          // The hub panes (Home, Sections, Claude & AI, …) push their
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
    }
  }
  #endif

  private var staticDestinations: [SettingsDestination] {
    // Nine intent groups, Apple-style. Local MCP folds into Claude & AI;
    // Advanced folds into About — neither is a root row.
    [.sections, .home, .notifications, .general, .claudeAI,
     .connections, .privacy, .data, .reports, .about]
  }

  private func staticRow(_ dest: SettingsDestination) -> some View {
    Label {
      Text(title(for: dest))
    } icon: {
      #if os(macOS)
      ColoredGlyph(icon: icon(for: dest), color: tint(for: dest), size: 20, glyphRatio: 0.38)
      #else
      ColoredGlyph(icon: icon(for: dest), color: tint(for: dest), size: 29, glyphRatio: 0.38)
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
    case .general:      return "General"
    case .claudeAI:     return "Claude & AI"
    case .quickActions: return "Quick Actions"
    case .appIcon:      return "App Icon"
    case .layout:       return "Layout"
    case .correlations: return "Insights"
    case .timeOfDay:    return "Time of Day"
    case .notifications: return "Notifications"
    case .connections:  return "Connections"
    case .data:         return "Data"
    case .reports:      return "Reports"
    case .skills:       return "Skills"
    case .siriShortcuts: return "Siri & Shortcuts"
    case .privacy:      return "Privacy"
    case .about:        return "About"
    case .advanced:     return "Advanced"
    case .dataTools:    return "Data Tools"
    case .motionGallery: return "Motion Gallery"
    case .milestonePreview: return "Milestones (preview)"
    case .localMcp:     return "Local MCP Server"
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
    case .general:      return "slider.horizontal.3"
    case .claudeAI:     return "brain.head.profile"
    case .quickActions: return "bolt"
    case .appIcon:      return "app.badge"
    case .layout:       return "square.grid.2x2"
    case .correlations: return "chart.dots.scatter"
    case .timeOfDay:    return "clock"
    case .notifications: return "bell.badge"
    case .connections:  return "app.connected.to.app.below.fill"
    case .data:         return "externaldrive"
    case .reports:      return "chart.bar.doc.horizontal"
    case .skills:       return "book.closed"
    case .siriShortcuts: return "mic"
    case .privacy:      return "hand.raised"
    case .about:        return "info.circle"
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
    case .general:           GeneralSettingsPane()
    case .claudeAI:          ClaudeAISettingsPane()
    case .quickActions:      QuickActionsSettingsPane()
    case .appIcon:           AppIconSettingsPane()
    case .layout:            LayoutSettingsPane()
    case .correlations:      CorrelationsSettingsPane()
    case .timeOfDay:         TimeOfDaySettingsPane()
    case .notifications:     NotificationsOverviewPane()
    case .connections:       IntegrationsSettingsPane()
    case .data:              ImportExportSettingsPane(mode: .full)
    case .reports:           ReportsSettingsPane()
    case .dataTools:         ImportExportSettingsPane(mode: .dataTools)
    case .skills:            SkillsSettingsPane()
    case .siriShortcuts:     SiriShortcutsSettingsPane()
    case .privacy:           PrivacySettingsPane()
    case .about:             AboutSettingsPane()
    case .advanced:          AdvancedSettingsPane()
    case .motionGallery:     MotionGalleryPane()
    case .milestonePreview:  MilestonePreviewPane()
    #if os(macOS)
    case .localMcp:          LocalMCPSettingsPane()
    #else
    case .localMcp:          EmptyView()   // folded into Claude & AI; macOS-only
    #endif
    case .section(let key):  SectionDetailPane(sectionKey: key)
    }
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

// MARK: - Privacy
//
// One toggle (anonymous Plausible screen-view analytics) plus a plain-
// language disclosure of exactly what is and isn't sent. The toggle is
// the same UserDefault key the actor reads, so flipping it takes effect
// on the next screen view — no app restart needed.

struct PrivacySettingsPane: View {
  @AppStorage(SettingsKey.shareUsageData) private var share: Bool = true
  @AppStorage(SettingsKey.appLockEnabled) private var appLockEnabled: Bool = false
  @AppStorage(SettingsKey.appLockGraceSeconds) private var appLockGrace: Int = 60

  var body: some View {
    Form {
      Section {
        Toggle(AppLock.requireActionLabel, isOn: $appLockEnabled)
          .disabled(!AppLock.isAvailable)
        if appLockEnabled {
          Picker("Lock after", selection: $appLockGrace) {
            Text("Immediately").tag(0)
            Text("After 1 minute").tag(60)
            Text("After 5 minutes").tag(300)
          }
        }
      } header: {
        Text("App Lock")
      } footer: {
        Text(AppLock.isAvailable
             ? "Asks for \(AppLock.biometryLabel) or your passcode when you reopen Septena. Your data is already protected by your device passcode — this adds a gate in front of the app itself, for when the phone is unlocked and handed over."
             : "Set up \(AppLock.biometryLabel) or a device passcode in Settings to use App Lock.")
      }

      Section {
        Toggle("Share anonymous usage data", isOn: $share)
      } footer: {
        Text("Helps us understand which features people use, so we improve the right things.")
      }

      Section("What is sent") {
        bullet("Which screens you open (e.g. \"Nutrition\", \"Sleep\")")
        bullet("App version, build, and platform (iOS or macOS)")
      }

      Section("What is never sent") {
        bullet("Anything you log — food, intake, supplements, sleep, mood, notes. None of it leaves your device through analytics.")
        bullet("Any identifier that links events to you, or links today's session to yesterday's.")
        bullet("Your IP address. The analytics provider uses it briefly to derive your country, then discards it.")
      }

      Section {
        EmptyView()
      } footer: {
        VStack(alignment: .leading, spacing: 8) {
          Text("Analytics is provided by Plausible Analytics (EU-hosted, cookie-free).")
          Link("plausible.io/privacy",
               destination: URL(string: "https://plausible.io/privacy")!)
            .font(.callout)
        }
      }
    }
    .formStyle(.grouped)
  }

  private func bullet(_ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("•").foregroundStyle(.secondary)
      Text(text).foregroundStyle(.primary)
    }
  }
}

// MARK: - Home (homepage configuration)

/// Everything that shapes the home tab, pulled out of the old "Customize"
/// junk drawer: how it renders (Layout, Insights), the greeting (Welcome),
/// and the day view.
struct HomeSettingsPane: View {
  @AppStorage(SettingsKey.homepageDayView)
  private var dayViewRaw: String = DayViewStyle.dial.rawValue
  @AppStorage(SettingsKey.wheelWakingDay)
  private var wakingDay: Bool = true
  @AppStorage(SettingsKey.wheelTodayOnly)
  private var wheelTodayOnly: Bool = true

  var body: some View {
    Form {
      Section {
        NavigationLink(value: SettingsView.SettingsDestination.layout) {
          Label("Layout", systemImage: "square.grid.2x2")
        }
        NavigationLink(value: SettingsView.SettingsDestination.correlations) {
          Label("Insights", systemImage: "chart.dots.scatter")
        }
      } footer: {
        Text("Layout picks how the homepage renders — Histogram, Sparkline, Heatmap, Rings, or Wheel. Insights tunes the cross-section correlation explorer.")
      }

      Section {
        Picker(selection: Binding(
          get: { DayViewStyle(rawValue: dayViewRaw) ?? .dial },
          set: { dayViewRaw = $0.rawValue }
        )) {
          ForEach(DayViewStyle.allCases) { style in
            Label(style.label, systemImage: style.icon).tag(style)
          }
        } label: {
          Text("Day view")
        }
        .pickerStyle(.inline)
        .labelsHidden()
      } header: {
        Text("Day view")
      } footer: {
        Text("Shows today at a glance, above the layout. Dial is a 24-hour clock with your logs as dots and sleep as an arc, lit by the real sunrise and sunset for your time zone — no location needed. Timeline shows the same day as a horizontal strip.")
      }

      Section {
        Toggle(isOn: $wakingDay) {
          Label("Start day at wake", systemImage: "sunrise")
        }
        Toggle(isOn: Binding(get: { !wheelTodayOnly },
                             set: { wheelTodayOnly = !$0 })) {
          Label("Open on the full week", systemImage: "calendar")
        }
      } header: {
        Text("Day dial")
      } footer: {
        Text("Start day at wake rolls the dial over when you wake rather than at midnight, so a late night stays on the same day. Open on the full week starts on the last 7 days instead of today — tap any wheel to switch.")
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - General (app behavior)

/// The small, honest catch-all Apple keeps too: time boundaries, the app icon,
/// Home Screen quick actions, and the logging-animation switch. Notifications
/// graduated to its own root row; homepage settings moved to Home.
struct GeneralSettingsPane: View {
  @AppStorage(SettingsKey.loggingAnimationsEnabled)
  private var loggingAnimationsEnabled: Bool = true

  var body: some View {
    Form {
      Section {
        NavigationLink(value: SettingsView.SettingsDestination.timeOfDay) {
          Label("Time of Day", systemImage: "clock")
        }
      } footer: {
        Text("Set when morning, afternoon, and evening begin — used across Habits, Supplements, the “Now” marker, and the greeting.")
      }

      #if os(iOS)
      Section {
        NavigationLink(value: SettingsView.SettingsDestination.quickActions) {
          Label("Quick Actions", systemImage: "bolt")
        }
      } footer: {
        Text("Choose up to 4 sections to surface when you long-press the app icon on the Home Screen.")
      }
      #endif

      Section {
        NavigationLink(value: SettingsView.SettingsDestination.appIcon) {
          Label("App Icon", systemImage: "app.badge")
        }
      }

      Section {
        Toggle(isOn: $loggingAnimationsEnabled) {
          Label("Logging animations", systemImage: "party.popper")
        }
      } footer: {
        Text("The little celebration that plays when you log something — confetti, ripples, a streak landing — and the checkbox feels when you check things off. Off keeps the confirming haptic but skips the motion. Reduce Motion always overrides this.")
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - Time of Day submenu
//
// Lets the user move the two boundaries that split the day into Morning /
// Afternoon / Evening. The values write straight through to the App Group
// mirror `DayBucket` reads (so Habits, Supplements, the "Now" marker, the
// Next list, and the welcome greeting all shift at once) and up to the
// CloudKit-synced `AppSettings`.

struct TimeOfDaySettingsPane: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(CKEngine.self) private var ckEngine
  @Environment(SettingsStore.self) private var store

  @State private var morningEnd = DayBucketCutoffs.default.morningEnd
  @State private var afternoonEnd = DayBucketCutoffs.default.afternoonEnd
  @State private var loaded = false

  var body: some View {
    Form {
      Section {
        Picker(selection: $morningEnd) {
          ForEach(1...22, id: \.self) { Text(hourLabel($0)).tag($0) }
        } label: {
          Label("Morning ends", systemImage: DayBucket.morning.icon)
        }
        Picker(selection: $afternoonEnd) {
          ForEach((morningEnd + 1)...23, id: \.self) { Text(hourLabel($0)).tag($0) }
        } label: {
          Label("Afternoon ends", systemImage: DayBucket.afternoon.icon)
        }
      } footer: {
        Text("Set when each part of your day begins. These boundaries drive the Morning / Afternoon / Evening groups in Habits and Supplements, the “Now” marker, what the Next list surfaces, and the welcome greeting.")
      }

      Section("Your day") {
        bucketRow(.morning, start: hourLabel(0), end: hourLabel(morningEnd))
        bucketRow(.afternoon, start: hourLabel(morningEnd), end: hourLabel(afternoonEnd))
        bucketRow(.evening, start: hourLabel(afternoonEnd), end: hourLabel(0))
      }

      Section {
        Button("Reset to default") { apply(.default) }
          .disabled(morningEnd == DayBucketCutoffs.default.morningEnd
                    && afternoonEnd == DayBucketCutoffs.default.afternoonEnd)
      } footer: {
        Text("Default: morning until \(hourLabel(DayBucketCutoffs.default.morningEnd)), afternoon until \(hourLabel(DayBucketCutoffs.default.afternoonEnd)).")
      }
    }
    .formStyle(.grouped)
    .onAppear {
      let c = store.dayBucketCutoffs
      morningEnd = c.morningEnd
      afternoonEnd = c.afternoonEnd
      loaded = true
    }
    .onChange(of: morningEnd) { _, newMorning in
      if afternoonEnd <= newMorning { afternoonEnd = newMorning + 1 }
      persist()
    }
    .onChange(of: afternoonEnd) { _, _ in persist() }
  }

  private func bucketRow(_ b: DayBucket, start: String, end: String) -> some View {
    HStack {
      Label(b.title, systemImage: b.icon)
      Spacer()
      Text("\(start) – \(end)")
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
  }

  private func apply(_ c: DayBucketCutoffs) {
    morningEnd = c.morningEnd
    afternoonEnd = c.afternoonEnd
    // The onChange handlers fire from these mutations and persist.
  }

  private func persist() {
    guard loaded else { return }
    store.setDayBucketCutoffs(morningEnd: morningEnd, afternoonEnd: afternoonEnd,
                              context: modelContext, engine: ckEngine)
  }

  /// Localized short time for a whole hour (0–23), e.g. "12:00 PM" or "17:00"
  /// depending on the user's locale.
  private func hourLabel(_ h: Int) -> String {
    let cal = Calendar.current
    let base = cal.startOfDay(for: .now)
    let date = cal.date(byAdding: .hour, value: h, to: base) ?? base
    return date.formatted(date: .omitted, time: .shortened)
  }
}

// MARK: - Layout submenu
//
// Picker for the homepage renderer, plus one generic example
// (icon + label, no data) showing what the selected mode looks like.
// Example is mode-styled — Tile card / Sparkline row / Heatmap row.

struct LayoutSettingsPane: View {
  @AppStorage(SettingsKey.homepageLayout)
  private var homepageLayoutRaw: String = HomepageLayoutMode.tiles.rawValue

  private var current: HomepageLayoutMode {
    HomepageLayoutMode(rawValue: homepageLayoutRaw) ?? .tiles
  }

  private var binding: Binding<HomepageLayoutMode> {
    Binding(
      get: { HomepageLayoutMode(rawValue: homepageLayoutRaw) ?? .tiles },
      set: { homepageLayoutRaw = $0.rawValue }
    )
  }

  var body: some View {
    let current = self.current
    Form {
      Section {
        Picker(selection: binding) {
          ForEach(HomepageLayoutMode.allCases) { mode in
            Label {
              HStack {
                Text(mode.title)
                Spacer()
                if !mode.isImplemented {
                  Text("Coming soon")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
              }
            } icon: {
              Image(systemName: mode.icon)
            }
            .tag(mode)
          }
        } label: {
          EmptyView()
        }
        .labelsHidden()
        #if os(iOS)
        .pickerStyle(.inline)
        #endif
      } footer: {
        Text(current.summary)
      }

      Section {
        LayoutPreviewExample(mode: current)
          .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
      } header: {
        Text("Example")
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - Insights submenu
//
// Tunes the Insights correlation explorer (the `InsightsDestinationView`
// grid) — time window, section filter, and which extra sections
// (supplements table / insufficient-data fold-out) render below the
// trusted + exploratory grids.

struct CorrelationsSettingsPane: View {
  @AppStorage(SettingsKey.correlationsWindowDays)
  private var windowDays: Int = 365
  @AppStorage(SettingsKey.correlationsSectionFilter)
  private var sectionFilter: String = "all"
  @AppStorage(SettingsKey.correlationsShowSupplements)
  private var showSupplements: Bool = true
  @AppStorage(SettingsKey.correlationsShowInsufficient)
  private var showInsufficient: Bool = false

  private let sectionOptions: [(key: String, label: String)] = [
    ("all",         "All"),
    ("habits",      "Habits"),
    ("supplements", "Supplements"),
    ("training",    "Training"),
    ("nutrition",   "Nutrition"),
    ("intake",      "Intake"),
    ("gut",         "Gut"),
    ("sleep",       "Sleep"),
  ]

  var body: some View {
    Form {
      Section {
        Picker("Time window", selection: $windowDays) {
          Text("30 days").tag(30)
          Text("90 days").tag(90)
          Text("6 months").tag(180)
          Text("1 year").tag(365)
          Text("2 years").tag(730)
        }
        Picker("Section filter", selection: $sectionFilter) {
          ForEach(sectionOptions, id: \.key) { Text($0.label).tag($0.key) }
        }
      } footer: {
        Text("Window sets how far back to look for patterns. Section filter narrows which relationships appear — a pairing shows if either section matches.")
      }

      Section {
        Toggle("Show Supplements → Sleep table", isOn: $showSupplements)
        Toggle("Show insufficient-data section", isOn: $showInsufficient)
      } footer: {
        Text("Relationships with fewer than \(CorrelationEngine.minN) overlapping days are too sparse to chart, but listed here so you can see what's almost ready.")
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - App Icon submenu

struct AppIconSettingsPane: View {
  #if os(iOS)
  @State private var selectedIcon: AppIconOption = .current
  @State private var iconError: String? = nil
  @State private var iconChangeInFlight = false
  #endif

  var body: some View {
    Form {
      #if os(iOS)
      if UIApplication.shared.supportsAlternateIcons {
        appIconSection
      } else {
        Section {
          Text("App icon selection isn’t available on this device.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      #else
      Section {
        Text("App icon selection is available on the iPhone and iPad app.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      #endif
    }
    .formStyle(.grouped)
    #if os(iOS)
    .onAppear { selectedIcon = .current }
    .alert("Couldn’t Change App Icon", isPresented: Binding(
      get: { iconError != nil },
      set: { if !$0 { iconError = nil } }
    )) {
      Button("OK", role: .cancel) { iconError = nil }
    } message: {
      Text(iconError ?? "Please try again.")
    }
    #endif
  }

  #if os(iOS)
  private var appIconSection: some View {
    Section {
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 14) {
          AppIconPreview(option: selectedIcon, size: 62)
          VStack(alignment: .leading, spacing: 3) {
            Text("Current Icon")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(selectedIcon.title)
              .font(.septenaCardTitle)
            if selectedIcon == .default {
              Text("The original multicolor icon.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else {
              Text("Light mode uses a \(selectedIcon.title.lowercased()) background with white discs. Dark mode uses transparent artwork so the system background shows through behind \(selectedIcon.title.lowercased()) discs.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
          }
          Spacer()
        }

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 12)], spacing: 12) {
          ForEach(AppIconOption.allCases) { option in
            Button {
              selectIcon(option)
            } label: {
              AppIconChoiceCard(option: option,
                                isSelected: option == selectedIcon,
                                isDisabled: iconChangeInFlight)
            }
            .buttonStyle(.plain)
            .disabled(iconChangeInFlight)
          }
        }
      }
      .padding(.vertical, 4)
    } footer: {
      Text("iOS shows a confirmation prompt each time you switch icons.")
    }
  }

  private func selectIcon(_ option: AppIconOption) {
    guard option != selectedIcon, !iconChangeInFlight else { return }
    iconChangeInFlight = true
    UIApplication.shared.setAlternateIconName(option.alternateIconName) { error in
      DispatchQueue.main.async {
        iconChangeInFlight = false
        if let error {
          selectedIcon = .current
          iconError = error.localizedDescription
        } else {
          selectedIcon = option
        }
      }
    }
  }
  #endif
}

// MARK: - Layout preview
//
// One generic example rendered with the real homepage components
// (`ModuleTile`, `DenseHomepageView`, `HeatmapHomepageView`) populated
// with deterministic fake data — so the preview matches what the
// homepage actually draws, not a hand-rolled approximation.

private enum LayoutPreviewSample {
  /// Deterministic 90-day series shared by all three renderers — the
  /// tile's 7-day histogram is just `bars90.suffix(7)`, the sparkline
  /// and heatmap consume the full 90-day window. Values span 1…7 so
  /// every day is visible (no all-zero gaps in the 7-day strip) while
  /// still covering enough range for the heatmap to bucket into all
  /// five levels.
  static let bars90: [Int] = (0..<90).map { i in
    let phase = Double(i) * 0.42
    let v = 4.0 + 2.6 * sin(phase) + 1.2 * sin(phase * 0.31)
    return max(1, Int(v.rounded()))
  }

  /// Trailing 7-day window of `bars90` — same source data, just sliced.
  static let bars7: [Int] = Array(bars90.suffix(7))
  static let accent: Color = .green

  static let domainData = HomepageDomainData(
    domain: .habits,
    title: "Habits",
    accent: accent,
    headline: "5 of 7 today",
    headlineStats: [
      .init(label: "Today",   value: "5"),
      .init(label: "Skipped", value: "1"),
    ],
    progress: .init(label: "Today's progress", current: 5, target: 7),
    history: .bars(bars90),
    tap: .openSheet(.habits)
  )
}

private struct LayoutPreviewExample: View {
  let mode: HomepageLayoutMode

  var body: some View {
    Group {
      switch mode {
      case .tiles:
        ModuleTile(
          title: "Habits",
          accent: LayoutPreviewSample.accent,
          stats: [
            .init(label: "Today",   value: "5"),
            .init(label: "Skipped", value: "1"),
          ],
          progress: .init(
            label: "Today's progress",
            current: 5,
            target: 7
          ),
          history: .init(label: "7-day adherence", values: LayoutPreviewSample.bars7)
        )
      case .dense:
        DenseHomepageView(
          items: [LayoutPreviewSample.domainData],
          onTap: { _ in },
          menuContent: { _ in EmptyView() }
        )
      case .heatmap:
        HeatmapHomepageView(
          items: [LayoutPreviewSample.domainData],
          onTap: { _ in },
          menuContent: { _ in EmptyView() }
        )
      case .rings:
        RingsHomepageView(
          items: [LayoutPreviewSample.domainData],
          onTap: { _ in },
          menuContent: { _ in EmptyView() }
        )
      }
    }
    .allowsHitTesting(false)
  }
}

/// Static stand-in for the Septena+ multi-coach roster, used as the paywall
/// hero. Illustrative only — three example coaches as section-tinted cards —
/// so the value reads at a glance without faking a live screen.
private struct CoachesPreviewExample: View {
  private struct Coach: Identifiable {
    let id: String
    let name: String
    let role: String
    let icon: String
    let color: Color
  }

  private let coaches: [Coach] = [
    .init(id: "strength", name: "Strength Coach",
          role: "Plans your next session from recent lifts",
          icon: "figure.strengthtraining.traditional", color: .orange),
    .init(id: "sleep", name: "Sleep Coach",
          role: "Nudges your wind-down toward your target",
          icon: "bed.double", color: .indigo),
    .init(id: "nutrition", name: "Nutrition Coach",
          role: "Keeps macros honest against your goals",
          icon: "fork.knife", color: .yellow),
  ]

  var body: some View {
    VStack(spacing: 10) {
      ForEach(coaches) { coach in
        HStack(spacing: 12) {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(coach.color.opacity(0.16))
            .frame(width: 40, height: 40)
            .overlay(
              Image(systemName: coach.icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(coach.color)
            )
          VStack(alignment: .leading, spacing: 2) {
            Text(coach.name).font(.subheadline.weight(.semibold))
            Text(coach.role)
              .font(.caption).foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer(minLength: 0)
        }
        .padding(12)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardSurface)
        )
      }
    }
  }
}

// MARK: - Septena+ (mock membership)
//
// First pass at a paid tier. There's no StoreKit / receipt validation
// yet — `SettingsKey.plusUnlocked` is a local @AppStorage flag flipped by
// the in-app "mock unlock" toggle. When real IAP lands, that key becomes
// the entitlement check and the paywall's unlock action calls into
// StoreKit instead of just setting the flag.

/// One sellable Septena+ benefit. The paywall renders the list straight
/// from `SeptenaPlus.features`, so adding a perk is a one-line append
/// here — no paywall surgery. Keep `id` stable; a future real-IAP build
/// can map it to an entitlement / destination.
struct SeptenaPlusFeature: Identifiable {
  let id: String
  let icon: String      // SF Symbol
  let title: String
  let detail: String
}

enum SeptenaPlus {
  static let name = "Septena+"

  // MARK: Premium finish — "Obsidian + disc medallion"
  //
  // The rainbow is the *free* app's identity (the seven sections). The
  // membership is its refined, contained form: a dark graphite surface
  // carrying a single champagne-foil accent, with the spectrum distilled
  // into a small precise medallion (`SeptenaDiscMark`) — a jewel you earn,
  // never a gradient smeared across text. Restraint reads as premium;
  // maximalism reads as free.

  /// Deep graphite "ink" surface. Fixed dark in both appearances — like a
  /// metal membership card, it shouldn't dissolve into a light background.
  static let ink = LinearGradient(
    colors: [parseHexColor("#33353B"), parseHexColor("#17181B")],
    startPoint: .top, endPoint: .bottom
  )

  /// Champagne-gold foil — the single Plus accent. Warm, to sit with the
  /// app's New York serif. Used flat for fills/strokes…
  static let foil = parseHexColor("#C9A86A")
  /// …and as a metallic sweep for rims and the avatar ring.
  static let foilGradient = LinearGradient(
    colors: [parseHexColor("#E7D29A"), parseHexColor("#C9A86A"), parseHexColor("#9C7E45")],
    startPoint: .topLeading, endPoint: .bottomTrailing
  )

  /// Canonical seven-disc palette (red → orange → yellow → green → cyan →
  /// blue → purple) — the only place the spectrum survives, inside the
  /// medallion.
  static let discColors: [Color] = [
    parseHexColor("#ef4444"), parseHexColor("#f97316"), parseHexColor("#eab308"),
    parseHexColor("#22c55e"), parseHexColor("#06b6d4"), parseHexColor("#3b82f6"),
    parseHexColor("#8b5cf6"),
  ]

  /// Heptagonal disc placement (unit square), shared with `AppIconPreview`
  /// so the emblem and the home-screen icon stay one mark.
  static let discCenters: [CGPoint] = [
    CGPoint(x: 0.50, y: 0.2235), CGPoint(x: 0.7171, y: 0.3256),
    CGPoint(x: 0.7709, y: 0.5631), CGPoint(x: 0.6206, y: 0.7505),
    CGPoint(x: 0.3794, y: 0.7505), CGPoint(x: 0.2291, y: 0.5631),
    CGPoint(x: 0.2829, y: 0.3256),
  ]

  /// The membership's perks, in display order. Septena+ is the multi-coach
  /// tier: the free app gives everyone one on-device coach over their goals
  /// and data; the membership unlocks a roster of focused coaches. Everything
  /// else — Insights, correlations, app icons — is free.
  static let features: [SeptenaPlusFeature] = [
    .init(id: "coachRoster",
          icon: "person.2",
          title: "A roster of coaches",
          detail: "Go beyond the single built-in coach. Add focused coaches — strength, sleep, nutrition, and more — each with its own voice and intent."),
    .init(id: "coachFocus",
          icon: "scope",
          title: "Each one stays in its lane",
          detail: "Every coach reasons over only the sections it needs, so its guidance stays sharp and on-topic instead of one generalist spreading thin."),
    .init(id: "coachPrivate",
          icon: "lock.shield",
          title: "Private and on-device",
          detail: "Coaches run on Apple Intelligence, on your device — the same private foundation as the rest of Septena. Nothing leaves your phone."),
  ]
}

/// The Septena mark as a contained jewel — the seven discs in their
/// canonical colors on a graphite plate with a hairline foil rim. This is
/// the premium emblem for Septena+: the rainbow distilled into an object
/// you earn, never smeared as a wash. Size-parametrized so it works inline
/// (a badge dot) and as a paywall hero.
struct SeptenaDiscMark: View {
  var size: CGFloat = 44

  var body: some View {
    let corner = size * 0.232
    ZStack {
      RoundedRectangle(cornerRadius: corner, style: .continuous)
        .fill(SeptenaPlus.ink)
      ForEach(Array(SeptenaPlus.discCenters.enumerated()), id: \.offset) { index, center in
        Circle()
          .fill(SeptenaPlus.discColors[index])
          .frame(width: size * 0.176, height: size * 0.176)
          .position(x: size * center.x, y: size * center.y)
      }
    }
    .frame(width: size, height: size)
    .overlay(
      RoundedRectangle(cornerRadius: corner, style: .continuous)
        .strokeBorder(SeptenaPlus.foilGradient, lineWidth: max(0.6, size * 0.022))
    )
    .shadow(color: .black.opacity(0.28), radius: size * 0.11, y: size * 0.045)
  }
}

/// Flighty-style feature row — a tinted rounded-square glyph chip with a
/// title + detail. Reusable wherever the membership perks are listed.
struct SeptenaPlusFeatureRow: View {
  let feature: SeptenaPlusFeature

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(SeptenaPlus.ink)
        .frame(width: 38, height: 38)
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(SeptenaPlus.foil.opacity(0.28), lineWidth: 0.75)
        )
        .overlay(
          Image(systemName: feature.icon)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(SeptenaPlus.foilGradient)
        )
      VStack(alignment: .leading, spacing: 3) {
        Text(feature.title)
          .font(.subheadline.weight(.semibold))
        Text(feature.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
  }
}

/// Compact "Septena+" pill used to mark Plus-gated rows in the picker.
/// Ink capsule with a champagne-foil hairline and a foil "+", so it reads
/// as a small pressed-metal plate rather than a colorful sticker.
struct SeptenaPlusBadge: View {
  var body: some View {
    (Text("Septena").foregroundStyle(.white)
      + Text("+").foregroundStyle(SeptenaPlus.foil))
      .font(.caption2.weight(.bold))
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(SeptenaPlus.ink, in: Capsule())
      .overlay(Capsule().strokeBorder(SeptenaPlus.foil.opacity(0.5), lineWidth: 0.75))
  }
}

/// Mock paywall for the Septena+ upgrade. Shows the multi-coach roster
/// preview as the hero, the value bullets, and a clearly labelled mock
/// unlock toggle (no purchase is made). `onUnlock` flips the entitlement.
struct SeptenaPlusPaywall: View {
  @Environment(\.dismiss) private var dismiss
  let onUnlock: () -> Void

  @State private var mockOn = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          header
          previewHero
          VStack(alignment: .leading, spacing: 18) {
            ForEach(SeptenaPlus.features) { feature in
              SeptenaPlusFeatureRow(feature: feature)
            }
          }
          unlockCard
        }
        .padding(20)
      }
      .background(Theme.groupedBackground.ignoresSafeArea())
      .navigationTitle(SeptenaPlus.name)
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Not now") { dismiss() }
        }
      }
    }
    #if os(macOS)
    .frame(width: 500, height: 640)
    #endif
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 14) {
      SeptenaDiscMark(size: 56)
      VStack(alignment: .leading, spacing: 6) {
        SeptenaPlusBadge()
        Text("Your team of coaches")
          .font(.title2.weight(.semibold))
        Text("The free app gives you one on-device coach. Septena+ turns that into a roster — focused coaches for the parts of your life you're working on.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var previewHero: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("YOUR COACHES")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.top, 12)
      CoachesPreviewExample()
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .allowsHitTesting(false)
    }
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Theme.groupedBackground)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
    )
  }

  private var unlockCard: some View {
    Toggle(isOn: $mockOn) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Unlock \(SeptenaPlus.name)")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.white)
        Text("Mock unlock. No purchase happens yet.")
          .font(.caption).foregroundStyle(.white.opacity(0.6))
      }
    }
    .tint(SeptenaPlus.foil)
    .onChange(of: mockOn) { _, on in
      if on { onUnlock() }
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(SeptenaPlus.ink)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(SeptenaPlus.foil.opacity(0.3), lineWidth: 0.75)
    )
  }
}

// MARK: - Identity (profile header + Account pane)
//
// Apple's Settings.app shows an Apple-ID card at the top of the list. We
// can't read the real iCloud avatar or name (no public API for either),
// so we render the standard substitute: a monogram avatar built from the
// user's given name (`welcomeName`, already CloudKit-synced) with the
// Septena+ status attached to that identity — a rainbow ring on the
// avatar plus a badge. The card pushes to `AccountSettingsPane`, the home
// for name, membership, and iCloud sync state.

/// Circular monogram avatar. Initials over a neutral fill; a Septena+
/// member gets the seven-color rainbow ring so the plan reads as part of
/// who they are, not a buried setting.
struct ProfileAvatar: View {
  let name: String
  let isPlus: Bool
  var size: CGFloat = 56

  private var initials: String {
    let words = name.trimmingCharacters(in: .whitespaces).split(separator: " ")
    // A single short token is almost certainly typed-in initials ("MZ",
    // "abc") — show it verbatim. A longer single name → its first letter.
    // Multi-word → first letter of the first two words.
    if words.count <= 1 {
      let token = words.first.map(String.init) ?? ""
      return (token.count <= 3 ? token : String(token.prefix(1))).uppercased()
    }
    return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
  }

  var body: some View {
    ZStack {
      Circle().fill(Color.secondary.opacity(0.18))
      if initials.isEmpty {
        Image(systemName: "person.fill")
          .font(.system(size: size * 0.46))
          .foregroundStyle(.secondary)
      } else {
        Text(initials)
          .font(.system(size: size * 0.4, weight: .semibold))
          .foregroundStyle(.primary)
      }
    }
    .frame(width: size, height: size)
    .overlay {
      if isPlus {
        Circle().inset(by: -3).strokeBorder(SeptenaPlus.foilGradient, lineWidth: 2)
      }
    }
  }
}

/// Top-of-Settings identity row (avatar + name + plan). The enclosing
/// `NavigationLink` supplies the disclosure chevron.
struct IdentityHeaderRow: View {
  @AppStorage(SettingsKey.welcomeName) private var welcomeName: String = ""
  @AppStorage(SettingsKey.plusUnlocked) private var plusUnlocked: Bool = false

  var body: some View {
    HStack(spacing: 14) {
      ProfileAvatar(name: welcomeName, isPlus: plusUnlocked, size: 56)
      VStack(alignment: .leading, spacing: 3) {
        Text(welcomeName.isEmpty ? "Your Profile" : welcomeName)
          .font(.title3.weight(.semibold))
          .foregroundStyle(.primary)
        if plusUnlocked {
          SeptenaPlusBadge()
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 8)
  }
}

/// The "Apple ID" analogue: name + avatar, membership (with the mock
/// unlock/relock toggle), and iCloud sync state — since there's no
/// Septena account, identity *is* the Apple ID / iCloud.
struct AccountSettingsPane: View {
  @AppStorage(SettingsKey.welcomeName) private var welcomeName: String = ""
  @AppStorage(SettingsKey.plusUnlocked) private var plusUnlocked: Bool = false
  @State private var showPaywall = false
  @Environment(\.modelContext) private var modelContext
  @Environment(CKEngine.self) private var ckEngine
  @Environment(SettingsStore.self) private var store

  var body: some View {
    Form {
      Section {
        HStack(spacing: 16) {
          ProfileAvatar(name: welcomeName, isPlus: plusUnlocked, size: 64)
          VStack(alignment: .leading, spacing: 4) {
            TextField("Your name", text: $welcomeName)
              .font(.title2.weight(.semibold))
              .textContentType(.givenName)
              #if os(iOS)
              .textInputAutocapitalization(.words)
              #endif
              .onChange(of: welcomeName) { _, newValue in
                store.setWelcomeName(newValue, context: modelContext, engine: ckEngine)
              }
            if plusUnlocked {
              SeptenaPlusBadge()
            }
          }
        }
        .padding(.vertical, 6)
      } footer: {
        Text("Your name personalizes the home greeting and this profile. It syncs across your devices via iCloud.")
      }

      membershipSection

      Section {
        HStack {
          Label("Sync", systemImage: iCloudStatus.symbol)
          Spacer()
          Text(iCloudStatus.text).foregroundStyle(.secondary)
        }
      } header: {
        Text("iCloud")
      } footer: {
        Text("Septena keeps everything in your private iCloud — there's no separate Septena account. Your data and membership are tied to your Apple ID.")
      }
    }
    .formStyle(.grouped)
    .sheet(isPresented: $showPaywall) {
      SeptenaPlusPaywall {
        plusUnlocked = true
        showPaywall = false
      }
    }
  }

  @ViewBuilder
  private var membershipSection: some View {
    if plusUnlocked {
      Section {
        ForEach(SeptenaPlus.features) { feature in
          SeptenaPlusFeatureRow(feature: feature)
        }
      } header: {
        Text("Your Septena+ perks")
      }
      Section {
        Toggle(isOn: $plusUnlocked) {
          Label {
            Text("Septena+ membership")
          } icon: {
            Image(systemName: "checkmark.seal.fill")
              .foregroundStyle(SeptenaPlus.foilGradient)
          }
        }
      } footer: {
        Text("Mock membership for testing — no purchase is made. Turn this off to re-lock Septena+ features.")
      }
    } else {
      Section {
        Button {
          showPaywall = true
        } label: {
          HStack(spacing: 14) {
            SeptenaDiscMark(size: 30)
            VStack(alignment: .leading, spacing: 2) {
              Text("Upgrade to \(SeptenaPlus.name)")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
              Text("A roster of focused, on-device coaches.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.tertiary)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      } header: {
        Text("Membership")
      }
    }
  }

  /// Friendly label for the live CloudKit account state (`CKEngine`
  /// publishes `accountStatus`). Keeps the iCloud row honest rather than
  /// claiming "synced" unconditionally.
  private var iCloudStatus: (text: String, symbol: String) {
    switch ckEngine.accountStatus {
    case .available:              return ("Active", "checkmark.icloud.fill")
    case .noAccount:              return ("No iCloud account", "exclamationmark.icloud.fill")
    case .restricted:             return ("Restricted", "xmark.icloud.fill")
    case .temporarilyUnavailable: return ("Temporarily unavailable", "exclamationmark.icloud.fill")
    default:                      return ("Checking…", "icloud")
    }
  }
}

private struct AppIconPreview: View {
  @Environment(\.colorScheme) private var colorScheme
  let option: AppIconOption
  let size: CGFloat

  var body: some View {
    let isDarkMode = colorScheme == .dark
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.223, style: .continuous)
        .fill(option.background(forDarkMode: isDarkMode))
      ForEach(Array(SeptenaPlus.discCenters.enumerated()), id: \.offset) { index, center in
        Circle()
          .fill(option.dotColors(forDarkMode: isDarkMode)[index])
          .frame(width: size * 0.182, height: size * 0.182)
          .position(x: size * center.x, y: size * center.y)
      }
    }
    .frame(width: size, height: size)
    .overlay(
      RoundedRectangle(cornerRadius: size * 0.223, style: .continuous)
        .stroke(Color.black.opacity(isDarkMode ? 0.12 : (option == .default ? 0.07 : 0.09)), lineWidth: 0.8)
    )
    .shadow(color: .black.opacity(0.10), radius: 4, y: 2)
  }
}

#if os(iOS)
private struct AppIconChoiceCard: View {
  let option: AppIconOption
  let isSelected: Bool
  let isDisabled: Bool

  var body: some View {
    VStack(spacing: 8) {
      ZStack(alignment: .topTrailing) {
        AppIconPreview(option: option, size: 64)
        if isSelected {
          Image(systemName: "checkmark.circle.fill")
            .scaledFont(size: 18, weight: .semibold)
            .foregroundStyle(.white, .green)
            .shadow(color: .black.opacity(0.16), radius: 4, y: 1)
            .offset(x: 5, y: -5)
        }
      }
      Text(option.title)
        .font(.footnote.weight(isSelected ? .semibold : .regular))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.9)
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 10)
    .padding(.vertical, 10)
    .background(cardBackground)
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(isSelected ? option.background.opacity(option == .default ? 0.18 : 0.92)
                           : Color.primary.opacity(0.08),
                lineWidth: isSelected ? 2 : 1)
    )
    .opacity(isDisabled ? 0.7 : 1)
    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private var cardBackground: some ShapeStyle {
    isSelected
      ? AnyShapeStyle(option.background.opacity(option == .default ? 0.08 : 0.16))
      : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground))
  }
}
#endif

// MARK: - Quick Actions
//
// Multi-select pane (capped at 4) that picks which sections appear in the
// Home Screen long-press menu. Persists as a comma-separated list of
// section keys in UserDefaults; on every change, `QuickActionsApplier`
// rebuilds `UIApplication.shared.shortcutItems` to match. Listing is
// driven by `store.sections` filtered to enabled rows so disabled
// sections can never be picked.

struct QuickActionsSettingsPane: View {
  @Environment(SettingsStore.self) private var store
  @AppStorage(SettingsKey.quickActionKeys) private var stored: String = ""

  private static let limit = 4

  private var selected: [String] {
    stored.split(separator: ",")
      .map { String($0) }
      .filter { !$0.isEmpty }
  }

  private var availableEntries: [(manifest: SectionManifest, accent: Color)] {
    let order = store.serverSettings?.sectionOrder ?? store.sections.map(\.key)
    let configByKey = Dictionary(uniqueKeysWithValues: store.sections.map { ($0.key, $0) })
    return order.compactMap { key -> (SectionManifest, Color)? in
      guard let manifest = SectionManifest.byKey[key],
            let config = configByKey[key],
            config.isEnabled,
            manifest.supportsDashboard,
            WeekDestination(rawValue: key) != nil else { return nil }
      return (manifest, parseHexColor(config.color))
    }
  }

  var body: some View {
    Form {
      Section {
        ForEach(availableEntries, id: \.manifest.key) { entry in
          row(for: entry.manifest, accent: entry.accent)
        }
      } header: {
        HStack {
          Text("Sections")
          Spacer()
          Text("\(selected.count) / \(Self.limit)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      } footer: {
        Text("Pick up to \(Self.limit) sections. Each one becomes a shortcut in the Home Screen long-press menu, opening directly into that section.")
      }
    }
    .formStyle(.grouped)
  }

  @ViewBuilder
  private func row(for manifest: SectionManifest, accent: Color) -> some View {
    let isSelected = selected.contains(manifest.key)
    let isAtLimit = selected.count >= Self.limit
    Button {
      toggle(manifest.key)
    } label: {
      HStack(spacing: 12) {
        ColoredGlyph(icon: manifest.iconSymbol, color: accent, size: 22)
        VStack(alignment: .leading, spacing: 1) {
          let serverLabel = store.sections.first(where: { $0.key == manifest.key })?.label ?? ""
          Text(SectionManifest.displayLabel(key: manifest.key, stored: serverLabel))
            .foregroundStyle(.primary)
          if !manifest.shortDescription.isEmpty {
            Text(manifest.shortDescription)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!isSelected && isAtLimit)
    .opacity(!isSelected && isAtLimit ? 0.5 : 1)
  }

  private func toggle(_ key: String) {
    var current = selected
    if let idx = current.firstIndex(of: key) {
      current.remove(at: idx)
    } else {
      guard current.count < Self.limit else { return }
      current.append(key)
    }
    stored = current.joined(separator: ",")
    #if os(iOS)
    QuickActionsApplier.apply()
    #endif
  }
}

// MARK: - Motion Gallery
//
// A test surface for the commit-motion vocabulary: fire every log
// flourish (and its matched haptic) on demand, tune intensity / accent,
// and feel how each primitive reads. Uses the SAME renderers and haptics
// a real log site plays (`CommitFlourish` / `IgnitionView` /
// `CommitMotion.hapticSpec`) — so what you feel here is what ships.
// Reduce Motion still suppresses the visual centrally; the haptic fires.

struct MotionGalleryPane: View {
  @State private var intensity: Double = 1.0
  @State private var accentID: String = MotionGalleryPane.accents[0].id
  @State private var streak: Int = 30
  @State private var current: Demo = .burst
  @State private var trigger: Int = 0
  /// Live per-row state for the checkbox-feel demos below.
  @State private var feelDone: [String: Bool] = [:]

  /// One live checkbox per `CheckFeel` — the checkbox-local vocabulary the
  /// checkable rows use instead of canvas flourishes.
  private struct FeelDemo: Identifiable {
    let id: String
    let feel: CheckFeel
    let title: String
    let subtitle: String
  }
  private static let feelDemos: [FeelDemo] = [
    .init(id: "stamp", feel: .stamp, title: "Stamp",
          subtitle: "Tasks — crisp stamp + one pulse ring"),
    .init(id: "echo", feel: .echo, title: "Echo",
          subtitle: "Habits — the pulse answers itself: one more mark on the streak"),
    .init(id: "drop", feel: .drop, title: "Drop",
          subtitle: "Supplements — the fill falls in, lands with a soft splash"),
    .init(id: "tuck", feel: .tuck, title: "Tuck",
          subtitle: "Chores — stamps, dips, files the ring down the pile"),
  ]

  private var accent: Color {
    Self.accents.first { $0.id == accentID }?.color ?? .green
  }

  /// One row per thing the gallery can fire: the seven `CommitMotion`
  /// primitives plus `.ignition` (a sibling `LogCommitStyle`, not a
  /// CommitMotion — the habit-streak milestone).
  private enum Demo: String, CaseIterable, Identifiable {
    case burst, snap, bloom, sink, ripple, arc, fill, ignition
    var id: String { rawValue }

    /// The CommitMotion this row plays, or nil for `.ignition`.
    var motion: CommitMotion? {
      switch self {
      case .burst:    return .burst
      case .snap:     return .snap
      case .bloom:    return .bloom
      case .sink:     return .sink
      case .ripple:   return .ripple
      case .arc:      return .arc
      case .fill:     return .fill
      case .ignition: return nil
      }
    }

    var title: String {
      switch self {
      case .burst:    return "Burst"
      case .snap:     return "Snap"
      case .bloom:    return "Bloom"
      case .sink:     return "Sink"
      case .ripple:   return "Ripple"
      case .arc:      return "Arc"
      case .fill:     return "Fill"
      case .ignition: return "Ignition"
      }
    }

    var subtitle: String {
      switch self {
      case .burst:    return "Confetti — celebratory (Mood HAP, groceries)"
      case .snap:     return "Ring + flash — releasing tension (Mood HAN)"
      case .bloom:    return "Soft swell — settling (intake, training session)"
      case .sink:     return "Quiet dot — acknowledgment (Mood LAN, gut)"
      case .ripple:   return "Full-screen sonar — intake log, training PR payoff"
      case .arc:      return "Comet arc — day cleared (last Today task)"
      case .fill:     return "Full-page flood — target logs (hydration, nutrition)"
      case .ignition: return "Rings + streak number — milestone (7/30/100/365)"
      }
    }
  }

  private struct AccentChoice: Identifiable {
    let id: String
    let color: Color
  }
  private static let accents: [AccentChoice] = [
    .init(id: "green",  color: parseHexColor("#22c55e")),
    .init(id: "blue",   color: parseHexColor("#3b82f6")),
    .init(id: "orange", color: parseHexColor("#f97316")),
    .init(id: "purple", color: parseHexColor("#8b5cf6")),
    .init(id: "red",    color: parseHexColor("#ef4444")),
    .init(id: "cyan",   color: parseHexColor("#06b6d4")),
  ]

  var body: some View {
    Form {
      Section {
        ForEach(Demo.allCases) { demo in
          Button { fire(demo) } label: { row(demo) }
            .buttonStyle(.plain)
        }
      } header: {
        Text("Tap to play")
      } footer: {
        Text("Each row fires the same renderer and haptic a real log uses. Under Reduce Motion the visual is suppressed (by design) — you'll still feel the haptic.")
      }

      // Checkable rows celebrate at the checkbox, never on the canvas —
      // checking things off is the app's highest-frequency action. Each
      // type has its own feel (see `CheckFeel`); these are live primitives.
      Section {
        ForEach(Self.feelDemos) { demo in
          HStack(spacing: 12) {
            TaskCheckbox(tint: accent,
                         isDone: feelDone[demo.id] ?? false,
                         feel: demo.feel,
                         ignoresUserPreference: true,
                         onToggle: {
                           let next = !(feelDone[demo.id] ?? false)
                           feelDone[demo.id] = next
                           if next {
                             Haptics.play(demo.feel.hapticSpec())
                           } else {
                             Haptics.tap()
                           }
                         })
            VStack(alignment: .leading, spacing: 2) {
              Text(demo.title).foregroundStyle(.primary)
              Text(demo.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
          }
        }
      } header: {
        Text("Checkbox feels")
      } footer: {
        Text("Checkable rows celebrate at the box — four feels separated by rhythm: one beat, two spaced beats, fall-then-thud, thud-then-close — each with a CoreHaptics pattern timed to its visual. The canvas is reserved for at-most-once-a-day moments: clearing your last Today task (Arc), habit streak milestones (Ignition), and finishing a training session (Ripple on a PR, Bloom otherwise).")
      }

      Section("Accent") {
        HStack(spacing: 12) {
          ForEach(Self.accents) { choice in
            Button {
              accentID = choice.id
              fire(current)
            } label: {
              Circle()
                .fill(choice.color)
                .frame(width: 28, height: 28)
                .overlay(
                  Circle()
                    .strokeBorder(Color.primary.opacity(accentID == choice.id ? 0.9 : 0), lineWidth: 2)
                    .padding(-3)
                )
            }
            .buttonStyle(.plain)
          }
          Spacer()
        }
        .padding(.vertical, 2)
      }

      Section {
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text("Intensity")
            Spacer()
            Text(String(format: "%.2f", intensity))
              .font(.callout.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          Slider(value: $intensity, in: 0.5...1.5)
        }
        Stepper("Streak: \(streak) days", value: $streak, in: 1...365)
      } header: {
        Text("Parameters")
      } footer: {
        Text("Intensity scales each motion's loudness — sink ignores it on purpose. Streak drives the Ignition milestone number.")
      }
    }
    .formStyle(.grouped)
    .overlay { flourishOverlay }
  }

  @ViewBuilder
  private var flourishOverlay: some View {
    if current == .ignition {
      IgnitionView(accent: accent, streak: streak, trigger: trigger)
        .allowsHitTesting(false)
    } else if let motion = current.motion {
      // The gallery exists to feel motions on demand, so it bypasses the
      // global "Logging animations" opt-out (Reduce Motion still applies).
      CommitFlourish(motion: motion, accent: accent, intensity: intensity,
                     trigger: trigger, ignoresUserPreference: true)
    }
  }

  private func row(_ demo: Demo) -> some View {
    HStack(spacing: 12) {
      Circle()
        .fill(accent.opacity(0.18))
        .frame(width: 30, height: 30)
        .overlay(Image(systemName: "play.fill").font(.caption).foregroundStyle(accent))
      VStack(alignment: .leading, spacing: 2) {
        Text(demo.title).foregroundStyle(.primary)
        Text(demo.subtitle).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
    }
    .contentShape(Rectangle())
  }

  private func fire(_ demo: Demo) {
    current = demo
    if let motion = demo.motion {
      Haptics.play(motion.hapticSpec(intensity: intensity))
    } else {
      Haptics.success()  // ignition keeps the milestone success haptic
    }
    trigger += 1
  }
}

// MARK: - Section detail
//
// One pane per section, addressed by stable key. Identity (icon, label,
// color, description) comes from the local `SectionManifest`; the user's
// installed `SectionEntity` (label/color) overrides the defaults when
// present. Per-key content below uses cached catalog data from
// `SettingsStore` — intake catalogs, etc. Sections
// without catalog data show identity only. Tasks is special-cased to
// host the local task prefs (badge, today, sort) that used to live in
// a top-level Tasks pane.

// MARK: - Palette

struct PaletteSwatch: Identifiable {
  let id: String
  let label: String
  let hex: String
}

let sectionPalette: [PaletteSwatch] = [
  // Bright row — Tailwind 500
  .init(id: "red",        label: String(localized: "Red", comment: "Accent color"),        hex: "#ef4444"),
  .init(id: "orange",     label: String(localized: "Orange", comment: "Accent color"),     hex: "#f97316"),
  .init(id: "amber",      label: String(localized: "Amber", comment: "Accent color"),      hex: "#f59e0b"),
  .init(id: "yellow",     label: String(localized: "Yellow", comment: "Accent color"),     hex: "#eab308"),
  .init(id: "lime",       label: String(localized: "Lime", comment: "Accent color"),       hex: "#84cc16"),
  .init(id: "green",      label: String(localized: "Green", comment: "Accent color"),      hex: "#22c55e"),
  .init(id: "emerald",    label: String(localized: "Emerald", comment: "Accent color"),    hex: "#10b981"),
  .init(id: "teal",       label: String(localized: "Teal", comment: "Accent color"),       hex: "#14b8a6"),
  .init(id: "cyan",       label: String(localized: "Cyan", comment: "Accent color"),       hex: "#06b6d4"),
  .init(id: "sky",        label: String(localized: "Sky", comment: "Accent color"),        hex: "#0ea5e9"),
  .init(id: "blue",       label: String(localized: "Blue", comment: "Accent color"),       hex: "#3b82f6"),
  .init(id: "indigo",     label: String(localized: "Indigo", comment: "Accent color"),     hex: "#6366f1"),
  .init(id: "violet",     label: String(localized: "Violet", comment: "Accent color"),     hex: "#8b5cf6"),
  .init(id: "purple",     label: String(localized: "Purple", comment: "Accent color"),     hex: "#a855f7"),
  .init(id: "pink",       label: String(localized: "Pink", comment: "Accent color"),       hex: "#ec4899"),
  .init(id: "rose",       label: String(localized: "Rose", comment: "Accent color"),       hex: "#f43f5e"),
  // Earth row — Tailwind 700/800 warm hues
  .init(id: "terracotta", label: "Terracotta", hex: "#9a3412"),
  .init(id: "brown",      label: "Brown",      hex: "#b45309"),
  .init(id: "mustard",    label: "Mustard",    hex: "#854d0e"),
  .init(id: "olive",      label: "Olive",      hex: "#3f6212"),
  .init(id: "taupe",      label: "Taupe",      hex: "#78716c"),
  .init(id: "espresso",   label: "Espresso",   hex: "#44403c"),
]

struct PaletteSwatchGrid: View {
  let selectedHex: String
  let onSelect: (String) -> Void

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 8)

  var body: some View {
    LazyVGrid(columns: columns, spacing: 8) {
      ForEach(sectionPalette) { swatch in
        let color = parseHexColor(swatch.hex)
        let isSelected = selectedHex.lowercased() == swatch.hex.lowercased()
        Button {
          onSelect(swatch.hex)
        } label: {
          Circle()
            .fill(color)
            .frame(width: 28, height: 28)
            .overlay(
              Circle()
                .strokeBorder(Color.primary.opacity(isSelected ? 0.9 : 0), lineWidth: 2)
                .padding(isSelected ? -3 : 0)
            )
            .overlay(
              Circle()
              #if canImport(UIKit)
                .strokeBorder(Color(UIColor.systemBackground), lineWidth: isSelected ? 2 : 0)
              #else
                .strokeBorder(Color(NSColor.windowBackgroundColor), lineWidth: isSelected ? 2 : 0)
              #endif
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(swatch.label)
      }
    }
    .padding(.vertical, 4)
  }
}

// MARK: - Sections pane (collapsed app-style list)

/// The single "Sections" pane — Apple's iOS-18 "Apps" move. Every installed
/// section in the user's saved order; tap a row to open its detail page (color,
/// enabled, Show in Next, per-section settings). Drag to reorder, which drives
/// the dashboard and sidebar order. Disabled sections stay in the list (muted,
/// "Off") so they can be re-enabled from their detail page. The per-section
/// enable toggle — and its onboarding-on-enable flow — now lives in
/// `SectionDetailPane`, so there is one enable path instead of two.
struct SectionsSettingsPane: View {
  @Environment(SettingsStore.self) private var store
  @Environment(\.modelContext) private var modelContext
  @Environment(CKEngine.self) private var ckEngine

  /// Installed sections in the user's saved order, with newly seeded sections
  /// (not yet in `sectionOrder`) appended. Includes disabled sections.
  private var entries: [SectionEntry] {
    let installedByKey = Dictionary(uniqueKeysWithValues: store.sections.map { ($0.key, $0) })
    let order = store.serverSettings?.sectionOrder ?? store.sections.map(\.key)
    let seen = Set(order)
    let trailing = store.sections.map(\.key).filter { !seen.contains($0) }
    var emitted = Set<String>()
    return (order + trailing).compactMap { key in
      guard emitted.insert(key).inserted,
            let manifest = SectionManifest.byKey[key],
            // Manage Sections lists data-logging life domains only.
            // App-functions (Coach/goals) register for their machinery — MCP
            // tools, the Coach destination, section-tagged goals — but aren't
            // life domains, so they're excluded here.
            manifest.kind == .loggingDomain,
            let installed = installedByKey[key] else { return nil }
      return SectionEntry(manifest: manifest, server: installed)
    }
  }

  /// Active sections, in saved order — the reorderable group.
  private var enabledEntries: [SectionEntry] { entries.filter(\.isEnabled) }
  /// Disabled sections — listed below, statically (their order doesn't drive
  /// any surface, and reordering an off section reads as noise).
  private var disabledEntries: [SectionEntry] { entries.filter { !$0.isEnabled } }

  var body: some View {
    Form {
      Section {
        ForEach(enabledEntries) { entry in
          NavigationLink(value: SettingsView.SettingsDestination.section(entry.key)) {
            row(for: entry)
          }
        }
        .onMove { from, to in
          var keys = enabledEntries.map(\.key)
          keys.move(fromOffsets: from, toOffset: to)
          store.applySectionOrder(enabledOrder: keys,
                                  context: modelContext, engine: ckEngine)
        }
      } footer: {
        Text("Tap a section to set its color, turn it on or off, and tune what it tracks. Drag to reorder how sections appear across the app.")
      }

      if !disabledEntries.isEmpty {
        Section {
          ForEach(disabledEntries) { entry in
            NavigationLink(value: SettingsView.SettingsDestination.section(entry.key)) {
              row(for: entry)
            }
          }
        } header: {
          Text("Off")
        } footer: {
          Text("Turned-off sections disappear from the home tab but keep all their data. Turn one back on anytime.")
        }
      }
    }
    .formStyle(.grouped)
    #if os(iOS)
    .toolbar { EditButton() }
    #endif
  }

  private func row(for entry: SectionEntry) -> some View {
    HStack(spacing: 12) {
      SectionGlyph(icon: entry.manifest.iconSymbol, accent: entry.accent,
                   size: 29, glyphRatio: 0.38)
        .opacity(entry.isEnabled ? 1 : 0.4)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.label)
          .foregroundStyle(entry.isEnabled ? .primary : .secondary)
        if !entry.manifest.shortDescription.isEmpty {
          Text(entry.manifest.shortDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
    }
  }
}

// MARK: - Section detail pane

struct SectionDetailPane: View {
  @Environment(SettingsStore.self) private var store
  @Environment(\.modelContext) private var modelContext
  @Environment(CKEngine.self) private var ckEngine
  @Environment(SectionTheme.self) private var theme
  let sectionKey: String
  @State private var showingColorPicker = false
  /// Drives the starter-onboarding sheet when the user flips Enabled on for a
  /// section whose plugin offers one. Moved here from the old Manage Sections
  /// pane so there is a single enable path.
  @State private var pendingOnboarding = false
  // showingSupplementSheet moved into SupplementsPlugin's detailPaneContent.

  // Per-section preferences and sheets now live inside each plugin's
  // detailPaneContent view, where they're only constructed when that
  // section's page is showing. No more app-wide @AppStorage bindings
  // declared up here for sections this pane doesn't always render.

  private var manifest: SectionManifest? { SectionManifest.byKey[sectionKey] }
  private var server: SectionConfig? {
    store.sections.first(where: { $0.key == sectionKey })
  }
  private var label: String {
    SectionManifest.displayLabel(key: sectionKey, stored: server?.label ?? "")
  }
  private var accent: Color {
    parseHexColor(server?.color ?? "")
  }

  /// Background of a grouped-form row — used as the gap color between the
  /// swatch's rainbow ring and its colored center, so the ring stays
  /// visually detached on both platforms.
  private var rowBackgroundColor: Color {
    #if canImport(UIKit)
    Color(uiColor: .secondarySystemGroupedBackground)
    #else
    Color(nsColor: .windowBackgroundColor)
    #endif
  }

  var body: some View {
    Form {
      identitySection
      sectionSpecific
      // Contextual "Ask Siri" tip for this section's primary log action.
      // Centralized here (not per-plugin) so all 13 sections are covered in
      // one place; iOS-only, renders nothing for sections without an action.
      sectionSiriTip(forKey: sectionKey)
      skillAndDataSection
    }
    .formStyle(.grouped)
    .sheet(isPresented: $pendingOnboarding) { onboardingSheet.macSheetFrame() }
  }

  /// The section plugin's starter-onboarding view, shown when enabling a
  /// section that offers one. Completion writes hasOnboarded + enabled.
  @ViewBuilder
  private var onboardingSheet: some View {
    if let plugin = SectionRegistry.plugin(forKey: sectionKey),
       let view = plugin.onboarding(complete: { completeOnboarding() }) {
      view
    } else {
      Text("No onboarding available.").padding()
    }
  }

  private func completeOnboarding() {
    SettingsMirror.setSectionHasOnboarded(sectionKey, hasOnboarded: true,
                                          context: modelContext, engine: ckEngine)
    SettingsMirror.setSectionEnabled(sectionKey, enabled: true,
                                     context: modelContext, engine: ckEngine)
    // Reload from the mirror (not a hand-patched map) so the accent that
    // `setSectionEnabled` auto-assigned is reflected, then repaint the theme
    // so the section's tile shows that color instead of gray.
    store.sections = SettingsMirror.loadSections(context: modelContext)
    theme.paintFromCache()
    pendingOnboarding = false
  }

  /// Bottom-of-page row, shared by every section. Two entries:
  ///   • Section Skill — navigates to the per-section MCP brief.
  ///   • Export Data   — ShareLink with a JSON snapshot of this section.
  /// Both are conditional: skill only shows if `SectionSkill.byKey[key]`
  /// exists; export only shows if this key is in `exportableSectionKeys`
  /// (resolved against ImportExportService).
  @ViewBuilder
  private var skillAndDataSection: some View {
    Section {
      if SectionSkill.resolve(sectionKey) != nil {
        NavigationLink {
          SectionSkillView(sectionKey: sectionKey)
        } label: {
          Label("Section Skill", systemImage: "book.closed")
        }
      }
      sectionExportRow
    } header: {
      Text("Skill & Data")
    } footer: {
      Text("Section Skill tells Claude how to use this section when you connect it. Export downloads every record in this section as JSON.")
    }
  }

  @ViewBuilder
  private var sectionExportRow: some View {
    // Serialize lazily — ExportFile carries the closure, so the section's
    // records are fetched + encoded only when the share sheet pulls them, not
    // on every render of this pane.
    let key = sectionKey
    let filename = "septena-\(key)-\(ImportExportService.todayStamp).json"
    ShareLink(item: ExportFile(suggestedName: filename) {
                try ImportExportService.exportSection(key)
              },
              preview: SharePreview(filename, image: Image(systemName: "square.and.arrow.up"))) {
      HStack {
        Label("Export Data", systemImage: "square.and.arrow.up")
          .foregroundStyle(.primary)
        Spacer()
      }
    }
  }

  @ViewBuilder
  private var identitySection: some View {
    Section {
      HStack(spacing: 12) {
        Text(label).foregroundStyle(.primary)
        Spacer()
        colorSwatchButton
      }
      enabledRow
      showInTodayRow
      showInSpotlightRow
    } footer: {
      if let m = manifest, !m.shortDescription.isEmpty {
        Text(m.shortDescription)
      }
    }
  }

  /// Trailing-aligned, circular color swatch wrapped in the conic
  /// rainbow ring iOS's system `ColorPicker` well uses — the
  /// unmistakable "tap to change the color" affordance. The current
  /// section color fills the center; a thin gap in the row's background
  /// separates it from the ring so the ring reads as a ring, not a
  /// border. (We keep our own curated palette popover rather than the
  /// system picker, so the ring is hand-rolled.)
  @ViewBuilder
  private var colorSwatchButton: some View {
    Button {
      showingColorPicker.toggle()
    } label: {
      ZStack {
        Circle()
          .fill(AngularGradient(
            gradient: Gradient(colors: [.red, .orange, .yellow, .green,
                                        .cyan, .blue, .purple, .red]),
            center: .center))
        Circle()
          .fill(rowBackgroundColor)
          .padding(2)
        Circle()
          .fill(accent)
          .padding(4)
      }
      .frame(width: 26, height: 26)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Section color")
    .popover(isPresented: $showingColorPicker, arrowEdge: .trailing) {
      PaletteSwatchGrid(selectedHex: server?.color ?? "") { hex in
        updateColor(hex)
        showingColorPicker = false
      }
      .padding(12)
      .presentationCompactAdaptation(.popover)
    }
  }

  /// Per-section opt-out for the Next timeline. Only shown for sections
  /// the manifest marks as `appearsInToday` — others have nothing to
  /// gate, so the toggle would be confusing.
  @ViewBuilder
  private var showInTodayRow: some View {
    if let m = manifest, m.appearsInToday {
      Toggle(isOn: Binding(
        get: { server?.showInToday ?? true },
        set: { setShowInToday($0) }
      )) {
        VStack(alignment: .leading, spacing: 1) {
          Text("Show in Next")
          Text("Include this section's entries in the Next timeline.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func setShowInToday(_ value: Bool) {
    SettingsMirror.setSectionShowInToday(sectionKey,
                                         showInToday: value,
                                         context: modelContext,
                                         engine: ckEngine)
    store.sections = store.sections.map { config in
      config.key == sectionKey
        ? SectionConfig(key: config.key,
                        label: config.label,
                        color: config.color,
                        isEnabled: config.isEnabled,
                        showInToday: value,
                        showInSpotlight: config.showInSpotlight,
                        hasOnboarded: config.hasOnboarded)
        : config
    }
  }

  /// Per-section opt-out for Spotlight / Siri / Apple Intelligence. Shown only
  /// for sections that actually contribute entities to the index, so a
  /// read-only section (Sleep, GitHub, Insights) doesn't show a dead toggle.
  /// Default on — Septena exposes everything unless the user opts out here.
  @ViewBuilder
  private var showInSpotlightRow: some View {
    if SpotlightIndexer.indexableSectionKeys.contains(sectionKey) {
      Toggle(isOn: Binding(
        get: { server?.showInSpotlight ?? true },
        set: { setShowInSpotlight($0) }
      )) {
        VStack(alignment: .leading, spacing: 1) {
          Text("Show in Spotlight & Siri")
          Text("Let Siri and Apple Intelligence find this section's entries in search.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func setShowInSpotlight(_ value: Bool) {
    SettingsMirror.setSectionShowInSpotlight(sectionKey,
                                             showInSpotlight: value,
                                             context: modelContext,
                                             engine: ckEngine)
    store.sections = store.sections.map { config in
      config.key == sectionKey
        ? SectionConfig(key: config.key,
                        label: config.label,
                        color: config.color,
                        isEnabled: config.isEnabled,
                        showInToday: config.showInToday,
                        showInSpotlight: value,
                        hasOnboarded: config.hasOnboarded)
        : config
    }
  }

  /// Master enabled toggle. Hidden for `.always` sections (e.g. Tasks).
  /// Disabling hides the section from the dashboard, sidebar, and every
  /// other surface that filters on `isEnabled` — but never deletes data
  /// or the SectionEntity row, so customizations survive a toggle.
  @ViewBuilder
  private var enabledRow: some View {
    if let m = manifest, m.canDisable {
      Toggle(isOn: Binding(
        get: { server?.isEnabled ?? true },
        set: { setEnabled($0) }
      )) {
        VStack(alignment: .leading, spacing: 1) {
          Text("Enabled")
          Text("Hides this section everywhere. Your data and customizations stay.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    } else if manifest != nil {
      HStack {
        Text("Always on")
        Spacer()
        Text("Required")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func setEnabled(_ enabled: Bool) {
    // Off → on for a section whose plugin offers starter onboarding (and that
    // hasn't been onboarded yet, or opts into re-presenting): route through the
    // sheet, which does the enable + hasOnboarded write on completion.
    if enabled,
       let config = server, !config.isEnabled,
       let plugin = SectionRegistry.plugin(forKey: sectionKey),
       plugin.onboarding(complete: {}) != nil,
       (!config.hasOnboarded || plugin.alwaysShowOnboarding) {
      pendingOnboarding = true
      return
    }

    SettingsMirror.setSectionEnabled(sectionKey,
                                     enabled: enabled,
                                     context: modelContext,
                                     engine: ckEngine)
    #if os(iOS)
    // Refresh App Shortcut suggestions so this section's items leave / re-enter
    // Siri + Spotlight in step with its enabled state.
    SeptenaShortcuts.updateAppShortcutParameters()
    #endif
    // Reload from the mirror so an accent auto-assigned on first enable is
    // reflected, then repaint the theme so the tile isn't gray.
    store.sections = SettingsMirror.loadSections(context: modelContext)
    theme.paintFromCache()
  }

  private func updateColor(_ hex: String) {
    let descriptor = FetchDescriptor<SectionEntity>(
      predicate: #Predicate { $0.id == sectionKey }
    )
    guard let entity = try? modelContext.fetch(descriptor).first else { return }
    entity.color = hex
    entity.updatedAt = .now
    try? modelContext.save()
    ckEngine.noteSectionChange(id: sectionKey)
    store.sections = store.sections.map { config in
      config.key == sectionKey
        ? SectionConfig(key: config.key,
                        label: config.label,
                        color: hex,
                        isEnabled: config.isEnabled,
                        showInToday: config.showInToday,
                        showInSpotlight: config.showInSpotlight,
                        hasOnboarded: config.hasOnboarded)
        : config
    }
    // Repaint the in-memory accent cache so the dashboard and section
    // views recolor immediately — no wait for the next theme.refresh().
    theme.setColor(hex, for: sectionKey)
  }

  /// Per-key content. Tasks gets local prefs; the rest pull cached
  /// catalog data from `SettingsStore`. Unknown / un-cataloged keys
  /// fall through to identity-only.
  /// Section-specific content is plugin-driven. Each migrated plugin
  /// returns one or more `Section { ... }` blocks via `detailPaneContent`;
  /// sections without a plugin or without a detail-pane override
  /// render no extra content (identity row + onboarding trigger only).
  @ViewBuilder
  private var sectionSpecific: some View {
    if let view = SectionRegistry.plugin(forKey: sectionKey)?.detailPaneContent() {
      view
    }
    // Manifest-driven: any plugin that declares notification descriptors
    // gets a "Notifications" section here automatically — no per-plugin edit.
    SectionNotificationToggles(sectionKey: sectionKey)
  }

  // All per-section detail content now lives in the corresponding
  // plugin's `detailPaneContent()` view. Sections without an override
  // render the identity row + onboarding trigger only. See e.g.
  // CaffeineDetailContent / TasksDetailContent / NutritionDetailContent.
}

// MARK: - Per-section notification toggles
//
// Renders one "Notifications" Section listing every `NotificationDescriptor`
// the section's plugin declares. Toggles write the descriptor's UserDefaults
// key, which posts `didChangeNotification` → `LocalNotificationScheduler`
// reconciles. Sections with no descriptors render nothing.

struct SectionNotificationToggles: View {
  let sectionKey: String

  private var descriptors: [NotificationDescriptor] {
    SectionRegistry.plugin(forKey: sectionKey)?.notificationDescriptors ?? []
  }

  var body: some View {
    if !descriptors.isEmpty {
      Section {
        ForEach(descriptors) { descriptor in
          NotificationToggleRow(descriptor: descriptor)
        }
      } header: {
        Label("Notifications", systemImage: "bell.badge")
      } footer: {
        Text("Nudges fire around when you usually log this, and stay quiet once it’s done for the day.")
      }
    }
  }
}

private struct NotificationToggleRow: View {
  let descriptor: NotificationDescriptor
  @State private var isOn: Bool

  init(descriptor: NotificationDescriptor) {
    self.descriptor = descriptor
    let stored = UserDefaults.standard.object(forKey: descriptor.defaultsKey) as? Bool
    _isOn = State(initialValue: stored ?? descriptor.defaultEnabled)
  }

  var body: some View {
    Toggle(descriptor.title, isOn: Binding(
      get: { isOn },
      set: { newValue in
        isOn = newValue
        UserDefaults.standard.set(newValue, forKey: descriptor.defaultsKey)
      }
    ))
  }
}

// MARK: - Unified notifications overview
//
// One screen listing every nudge across all sections and when it's set to
// fire — the answer to "what will notify me, and when?". The schedule comes
// straight from `LocalNotificationScheduler.overview` (the same gates the
// real scheduler applies), so this can't drift from what actually fires.
// Each row deep-links to its section's settings, where the nudge can be
// toggled. Reached from Customize → Scheduled Notifications.

struct NotificationsOverviewPane: View {
  @Environment(SettingsStore.self) private var store
  @Environment(\.modelContext) private var modelContext
  @AppStorage(SettingsKey.notificationsEnabled) private var notificationsEnabled: Bool = true
  @AppStorage(ClaudeGatewayProvider.connectionNudgeKey) private var claudeNudgeEnabled: Bool = true
  @State private var items: [NotificationOverviewItem] = []

  /// On and firing today, earliest first.
  private var live: [NotificationOverviewItem] {
    items.filter(\.isLive).sorted { minutes($0.state) < minutes($1.state) }
  }
  /// On, but suppressed right now (already logged / nothing pending, or held
  /// out of quiet hours).
  private var resting: [NotificationOverviewItem] {
    items.filter {
      switch $0.state {
      case .idle, .quietHours: return true
      default: return false
      }
    }
  }
  /// Turned off — this nudge, or its whole section.
  private var off: [NotificationOverviewItem] {
    items.filter {
      switch $0.state {
      case .off, .sectionOff: return true
      default: return false
      }
    }
  }

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $notificationsEnabled) {
          Label("Notifications", systemImage: "bell.badge")
        }
      } footer: {
        Text("The master switch. Each nudge fires around when you usually log it and goes quiet once it's marked for the day.")
      }

      if notificationsEnabled {
        Section {
          Toggle(isOn: $claudeNudgeEnabled) {
            Label("Keep Claude connected", systemImage: "antenna.radiowaves.left.and.right")
          }
        } header: {
          Label("Connections", systemImage: "link")
        } footer: {
          Text("Nudges you to refresh the Claude connection just before its ~8-hour session expires, so Claude keeps reading your data without you reconnecting from claude.ai. Only fires while Claude is connected.")
        }

        if !live.isEmpty {
          Section {
            ForEach(live) { row(for: $0) }
          } header: {
            Label("Coming Up Today", systemImage: "clock")
          }
        }

        if !resting.isEmpty {
          Section {
            ForEach(resting) { row(for: $0) }
          } header: {
            Label("Quiet Right Now", systemImage: "moon.zzz")
          } footer: {
            Text("On, but nothing to nudge about right now — today's done, nothing's pending, or it's quiet hours.")
          }
        }

        if !off.isEmpty {
          Section {
            ForEach(off) { row(for: $0) }
          } header: {
            Label("Off", systemImage: "bell.slash")
          }
        }

        if items.isEmpty {
          Section {
            Text("No sections offer reminders yet.")
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .formStyle(.grouped)
    .onAppear(perform: reload)
    // Opening this pane is the opt-in: request OS notification permission now
    // (no-op unless the master switch is on and the status is still
    // `.notDetermined`). We deliberately do NOT ask at launch — only here,
    // when the user has navigated to Notifications because they want them.
    .task { await requestPermissionIfWanted() }
    .onChange(of: notificationsEnabled) { _, on in
      if on { Task { await LocalNotificationScheduler.shared.requestAuthorizationIfNeeded() } }
    }
    // Toggling a nudge writes UserDefaults; logging data posts a data-change.
    // Both can change what's scheduled, so re-read on either.
    .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in reload() }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in reload() }
  }

  /// Ask for notification permission only when the user has the master switch
  /// on (the default) — i.e. they want nudges. `requestAuthorizationIfNeeded`
  /// itself no-ops unless the OS status is `.notDetermined`, so re-visits don't
  /// re-prompt.
  private func requestPermissionIfWanted() async {
    guard notificationsEnabled else { return }
    await LocalNotificationScheduler.shared.requestAuthorizationIfNeeded()
  }

  private func reload() {
    items = LocalNotificationScheduler.shared.overview(context: modelContext)
  }

  @ViewBuilder
  private func row(for item: NotificationOverviewItem) -> some View {
    let p = presentation(for: item.sectionKey)
    NavigationLink(value: SettingsView.SettingsDestination.section(item.sectionKey)) {
      HStack(spacing: 12) {
        SectionGlyph(icon: p.icon, accent: p.accent, size: 29, glyphRatio: 0.38)
        VStack(alignment: .leading, spacing: 2) {
          Text(item.title)
          Text(p.label)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        trailing(for: item.state)
      }
    }
  }

  @ViewBuilder
  private func trailing(for state: NotificationOverviewItem.State) -> some View {
    switch state {
    case let .scheduled(hour, minute):
      Text(timeLabel(hour, minute))
        .font(.callout.weight(.medium))
        .foregroundStyle(.primary)
        .monospacedDigit()
    case let .quietHours(hour, minute):
      Text("\(timeLabel(hour, minute)) · quiet")
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    case .idle:
      Text("Quiet")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .off:
      Text("Off")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .sectionOff:
      Text("Section off")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .masterOff:
      EmptyView()
    }
  }

  /// Resolve a section's display label, accent, and icon the same way the
  /// sidebar and `SectionDetailPane` do — live override first, manifest
  /// default as fallback.
  private func presentation(for key: String) -> (label: String, accent: Color, icon: String) {
    let server = store.sections.first(where: { $0.key == key })
    let manifest = SectionManifest.byKey[key]
    let serverLabel = server?.label ?? ""
    let label = SectionManifest.displayLabel(key: key, stored: serverLabel)
    return (label, parseHexColor(server?.color ?? ""), manifest?.iconSymbol ?? "circle.fill")
  }

  private func minutes(_ state: NotificationOverviewItem.State) -> Int {
    switch state {
    case let .scheduled(hour, minute): return hour * 60 + minute
    default: return Int.max
    }
  }

  private func timeLabel(_ hour: Int, _ minute: Int) -> String {
    var comps = DateComponents()
    comps.hour = hour
    comps.minute = minute
    let date = Calendar.current.date(from: comps) ?? Date()
    return date.formatted(date: .omitted, time: .shortened)
  }
}

// MARK: - Macro tiles editor
//
// Reorderable / toggleable / recolorable list of nutrition macro tiles.
// Persists through `NutritionPrefsWriter.saveTilePrefs` which writes to
// `AppSettings.nutrition.macroTiles` and queues a CloudKit push.
//
// Local @State is the source of truth while the sheet is open — the writer
// fires on every change so other devices see the edit immediately. We don't
// re-sync from `store.serverSettings` while editing; that would cause a row
// to jump back if a CK push round-trips during a drag.

struct MacroTilesEditor: View {
  @Environment(\.modelContext) private var modelContext

  @State private var prefs: [MacroTilePref]

  init(initialPrefs: [MacroTilePref]) {
    _prefs = State(initialValue: initialPrefs)
  }

  var body: some View {
    Section {
      ForEach($prefs) { $pref in
        MacroTileRow(pref: $pref, onChange: persist)
      }
      .onMove { indices, newOffset in
        prefs.move(fromOffsets: indices, toOffset: newOffset)
        persist()
      }
    } header: {
      HStack {
        Text("Macro tiles")
        Spacer()
        Button("Reset") {
          prefs = MacroCatalog.defaultTilePrefs()
          persist()
        }
        .font(.caption)
      }
    } footer: {
      Text("Drag to reorder. Toggle to show or hide a tile on the Nutrition dashboard. Tap a swatch to change its color.")
    }
    // Drag handles are off by default in a Form; flip edit mode on so the user
    // can reorder without having to hunt for an Edit button. iOS-only API.
    #if os(iOS)
    .environment(\.editMode, .constant(.active))
    #endif
  }

  private func persist() {
    NutritionPrefsWriter.saveTilePrefs(
      prefs,
      context: modelContext,
      engine: SeptenaServices.shared.ckEngine)
  }
}

private struct MacroTileRow: View {
  @Binding var pref: MacroTilePref
  var onChange: () -> Void
  @State private var showingPicker = false

  /// Hex currently stored for this tile, falling back to the catalog default.
  private var currentHex: String {
    pref.colorHex ?? MacroCatalog.byID[pref.id]?.defaultColorHex ?? ""
  }

  var body: some View {
    let macro = MacroCatalog.byID[pref.id]
    HStack(spacing: 12) {
      // Shared 22-color grid, same picker the sections and trackers use, so
      // macro tiles draw from the one curated palette rather than the OS
      // full-spectrum well.
      Button {
        showingPicker.toggle()
      } label: {
        Circle()
          .fill(AdaptiveColor.adaptive(currentHex) ?? .gray)
          .frame(width: 26, height: 26)
          .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Tile color")
      .popover(isPresented: $showingPicker, arrowEdge: .leading) {
        PaletteSwatchGrid(selectedHex: currentHex) { hex in
          pref.colorHex = hex
          onChange()
          showingPicker = false
        }
        .padding(12)
        .presentationCompactAdaptation(.popover)
      }

      VStack(alignment: .leading, spacing: 1) {
        Text(macro?.label ?? pref.id)
          .font(.body)
        if let unit = macro?.unit, !unit.isEmpty {
          Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
      }

      Spacer()

      Toggle("", isOn: Binding(
        get: { pref.visible },
        set: { pref.visible = $0; onChange() }
      ))
      .labelsHidden()
    }
  }
}

/// Adaptive parse of a section/swatch color token, used for *display* of
/// curated swatches and the current section accent. Routes through the shared
/// `AdaptiveColor` resolver (handles "#rrggbb"/rgb()/hsl() and the dark-mode
/// lift); falls back to gray on unparseable input.
private func parseHexColor(_ s: String) -> Color {
  AdaptiveColor.adaptive(s) ?? .gray
}

// MARK: - Integrations
//
// Native iOS access states for the frameworks Septena reaches outside the
// FastAPI proxy: Reminders + Calendar (EventKit), Apple Health (HealthKit),
// and Photos (PhotoKit). The Reminders row pushes to a detail screen with
// source-list picker + auto-import controls when access is granted; the
// others push to a detail screen showing access state and a grant/fix path.

struct IntegrationsSettingsPane: View {
  @State private var remindersBridge = RemindersBridge.shared
  @State private var calendarBridge = CalendarBridge.shared
  @State private var healthBridge = HealthKitBridge.shared
  @State private var ouraProvider = OuraProvider.shared
  @State private var withingsProvider = WithingsProvider.shared
  @State private var githubProvider = GitHubProvider.shared
  @State private var photosBridge = PhotosBridge.shared
  var body: some View {
    Form {
      Section {
        NavigationLink {
          RemindersInboxDetail()
            .navigationTitle("Reminders")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } label: {
          stateRow(title: "Reminders",
                   systemImage: "checklist",
                   state: remindersAccessLabel,
                   isGranted: remindersBridge.access == .granted)
        }

        NavigationLink {
          CalendarDetail()
            .navigationTitle("Calendar")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } label: {
          stateRow(title: "Calendar",
                   systemImage: "calendar",
                   state: calendarAccessLabel,
                   isGranted: calendarBridge.access == .granted)
        }

        NavigationLink {
          AppleHealthDetail()
            .navigationTitle("Apple Health")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } label: {
          stateRow(title: "Apple Health",
                   systemImage: "heart.text.square",
                   state: healthAccessLabel,
                   isGranted: healthBridge.access == .granted)
        }

        // Photos — used to attach thumbnails to nutrition (meal) entries.
        // Access is requested lazily by the picker too, but surfacing it
        // here gives denied users a fix path (and a way to grant up front).
        NavigationLink {
          PhotosDetail()
            .navigationTitle("Photos")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } label: {
          stateRow(title: "Photos",
                   systemImage: "photo",
                   state: photosAccessLabel,
                   isGranted: photosBridge.access == .granted)
        }

        // Siri & Shortcuts — Apple system integration; grouped here with
        // the other Apple ones rather than as a top-level Settings row.
        NavigationLink {
          SiriShortcutsSettingsPane()
            .navigationTitle("Siri & Shortcuts")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } label: {
          Label("Siri & Shortcuts", systemImage: "mic")
            .foregroundStyle(.primary)
        }

      } header: {
        Text("Apple")
      } footer: {
        Text("Grant access here, or manage permissions in iOS Settings → Privacy.")
      }

      Section {
        // Oura — direct iOS client (Personal Access Token). Replaces the
        // old FastAPI proxy at /api/health/oura.
        NavigationLink {
          OuraIntegrationDetail()
            .navigationTitle("Oura")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } label: {
          stateRow(title: "Oura",
                   systemImage: "circle.circle",
                   state: ouraProvider.hasToken ? "Connected" : "Grant",
                   isGranted: ouraProvider.hasToken)
        }

        // Withings — direct iOS client (OAuth2). Replaces the old
        // FastAPI proxy at /api/health/withings.
        NavigationLink {
          WithingsIntegrationDetail()
            .navigationTitle("Withings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } label: {
          stateRow(title: "Withings",
                   systemImage: "scalemass",
                   state: withingsProvider.hasTokens ? "Connected" : "Connect",
                   isGranted: withingsProvider.hasTokens)
        }

        // GitHub — read-only contribution calendar via the GraphQL API.
        // Per-device token (Keychain); nothing syncs to CloudKit.
        NavigationLink {
          GitHubIntegrationDetail()
            .navigationTitle("GitHub")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } label: {
          stateRow(title: "GitHub",
                   systemImage: "chevron.left.forwardslash.chevron.right",
                   state: githubProvider.hasToken ? "Connected" : "Connect",
                   isGranted: githubProvider.hasToken)
        }

      } header: {
        Text("Services")
      } footer: {
        Text("Claude moved to its own pane — see Claude & AI for the hosted gateway and local MCP server.")
      }
    }
    .formStyle(.grouped)
  }

  private func stateRow(title: String,
                        systemImage: String,
                        state: String,
                        isGranted: Bool) -> some View {
    HStack {
      Label(title, systemImage: systemImage)
        .foregroundStyle(.primary)
      Spacer()
      Text(state)
        .font(.subheadline)
        .foregroundStyle(isGranted ? Color.green : .secondary)
    }
  }

  @ViewBuilder
  private func grantButton(title: String,
                           systemImage: String,
                           state: String,
                           isGranted: Bool,
                           canRequest: Bool,
                           onTap: @escaping () -> Void) -> some View {
    if canRequest {
      Button(action: onTap) {
        stateRow(title: title, systemImage: systemImage, state: state, isGranted: isGranted)
      }
      .buttonStyle(.plain)
    } else {
      stateRow(title: title, systemImage: systemImage, state: state, isGranted: isGranted)
    }
  }

  private var remindersAccessLabel: String {
    switch remindersBridge.access {
    case .granted:       return "Granted"
    case .writeOnly:     return "Write-only"
    case .denied:        return "Denied"
    case .notDetermined: return "Grant"
    }
  }

  private var calendarAccessLabel: String {
    switch calendarBridge.access {
    case .granted:       return "Granted"
    case .writeOnly:     return "Write-only"
    case .denied:        return "Denied"
    case .notDetermined: return "Grant"
    }
  }

  private var healthAccessLabel: String {
    guard healthBridge.isAvailable else { return "Not available" }
    switch healthBridge.access {
    case .granted:       return "Granted"
    case .denied:        return "Denied"
    case .notDetermined: return "Grant"
    }
  }

  private var photosAccessLabel: String {
    switch photosBridge.access {
    case .granted:       return "Granted"
    case .denied:        return "Denied"
    case .notDetermined: return "Grant"
    }
  }
}

// MARK: - Apple Health Detail

/// Full-screen integration settings for Apple Health. Shown after tapping the
/// Apple Health row in Integrations. Handles the initial grant request and
/// per-section write toggles — each toggle syncs through CloudKit so the
/// user's preference follows them across devices.
struct AppleHealthDetail: View {
  @Environment(\.modelContext)    private var modelContext
  @Environment(CKEngine.self)     private var ckEngine
  @Environment(SettingsStore.self) private var store
  @State private var healthBridge = HealthKitBridge.shared

  private var rows: [(label: String, icon: String, kind: HealthKitBridge.WritableKind)] {
    [
      ("Mood",                  "face.smiling",                          .mood),
      ("Nutrition & Hydration", "fork.knife",                            .nutrition),
    ]
  }

  /// True when at least one writable category was denied in the permission
  /// sheet — drives the "some categories are off" advisory.
  private var anyDenied: Bool {
    rows.contains { healthBridge.shareStatus($0.kind) == .denied }
  }

  var body: some View {
    Form {
      // ── Connection ─────────────────────────────────────────────────────
      Section {
        if !healthBridge.isAvailable {
          Label("Apple Health is not available on this device.",
                systemImage: "heart.slash")
            .foregroundStyle(.secondary)
        } else if healthBridge.hasRequestedWrite {
          Label("Connected", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        } else {
          Button {
            Task { _ = await healthBridge.requestAccess() }
          } label: {
            Label("Connect Apple Health", systemImage: "heart.text.square")
          }
        }
      } footer: {
        Text("Septena writes your logged data to Apple Health so it appears alongside data from your other apps and devices.")
      }

      // ── Write Toggles (shown once the user has been through the sheet) ───
      if healthBridge.isAvailable && healthBridge.hasRequestedWrite {
        Section {
          ForEach(rows, id: \.kind) { row in
            toggleRow(row.label, row.icon, row.kind)
          }
        } header: {
          Text("Write to Health")
        } footer: {
          if anyDenied {
            Text("Some categories are turned off in Apple Health. To allow them, open Health → Profile → Apps → Septena. New entries are sent going forward — existing ones aren't back-filled.")
          } else {
            Text("New entries you log in Septena will be sent to Apple Health. Existing entries are not back-filled.")
          }
        }
      }
    }
    .navigationTitle("Apple Health")
    // Re-request on every visit so any write types added since the user's
    // last authorization are picked up immediately. HealthKit only shows a
    // sheet for types not yet resolved — no-ops if everything is already
    // decided. Always refresh status afterward so denials render correctly.
    .task {
      if healthBridge.isAvailable {
        _ = await healthBridge.requestAccess()
        healthBridge.refreshShareStatuses()
      }
    }
  }

  /// One row in the write-toggles section. Enabled when the category is
  /// authorized; when denied, the toggle is disabled and a caption explains
  /// that Apple Health is blocking it (so the failure is never silent).
  @ViewBuilder
  private func toggleRow(_ title: String, _ icon: String,
                         _ kind: HealthKitBridge.WritableKind) -> some View {
    let status = healthBridge.shareStatus(kind)
    if status != .unavailable {
      Toggle(isOn: syncBinding(kind)) {
        VStack(alignment: .leading, spacing: 2) {
          Label(title, systemImage: icon)
          if status == .denied {
            Text("Turned off in Apple Health")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .disabled(status != .authorized)
    }
  }

  private func keyPath(for kind: HealthKitBridge.WritableKind) -> WritableKeyPath<HKSyncSettings, Bool> {
    switch kind {
    case .mood:      return \.mood
    case .nutrition: return \.nutrition
    }
  }

  /// Binding that reads/writes one field of `HKSyncSettings` through the
  /// CloudKit-backed `AppSettings`. Falls back to `true` (all-on default)
  /// when no settings are stored yet.
  private func syncBinding(_ kind: HealthKitBridge.WritableKind) -> Binding<Bool> {
    let keyPath = keyPath(for: kind)
    return Binding {
      store.serverSettings?.hkSync?[keyPath: keyPath] ?? true
    } set: { newValue in
      var s = store.serverSettings ?? AppSettings(sectionOrder: nil, targets: nil,
                                                  units: nil, time: nil, theme: nil,
                                                  eink: nil, nutrition: nil, hkSync: nil)
      var hk = s.hkSync ?? HKSyncSettings()
      hk[keyPath: keyPath] = newValue
      s.hkSync = hk
      store.serverSettings = s
      HealthKitBridge.shared.syncSettings = hk
      SettingsMirror.upsert(settings: s, context: modelContext, engine: ckEngine)
    }
  }
}

// MARK: - Reminders → Inbox detail
//
// Reached from Integrations → Reminders. Permission grant + source list
// + auto-import all live here, since this is where the user actually
// configures the Reminders → Septena Inbox bridge.

private struct RemindersInboxDetail: View {
  @State private var bridge = RemindersBridge.shared
  @State private var access: RemindersBridge.Access = .notDetermined
  @State private var lists: [EKCalendar] = []
  @State private var selectedID: String?

  var body: some View {
    Form {
      Section {
        Text("Pick a Reminders list. Its pending items show in your Inbox; tap to import (originals are removed from Reminders).")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      switch access {
      case .notDetermined:
        Section {
          Button("Grant Access to Reminders") {
            Task {
              _ = await bridge.requestAccess()
              refresh()
            }
          }
        }
      case .denied, .writeOnly:
        Section {
          Text(access == .writeOnly
               ? "Septena has write-only access. Enable Full Access in Settings → Privacy → Reminders."
               : "Reminders access is denied. Enable it in Settings → Privacy → Reminders.")
            .font(.callout)
        }
      case .granted:
        Section("Source list") {
          pickerRow(title: "None", tint: nil, id: nil)
          ForEach(lists, id: \.calendarIdentifier) { cal in
            pickerRow(title: cal.title,
                      tint: Color(cgColor: cal.cgColor),
                      id: cal.calendarIdentifier)
          }
        }

        Section {
          Toggle("Auto-import new reminders", isOn: Binding(
            get: { bridge.autoImport },
            set: { bridge.autoImport = $0 }
          ))
          .disabled(bridge.sourceListID == nil)
        } footer: {
          Text("When on, pending items in the source list import automatically and are removed from Reminders. Runs on app launch and whenever Reminders changes.")
        }

        if !bridge.recentImports.isEmpty {
          Section("Recent auto-imports") {
            ForEach(bridge.recentImports.prefix(10)) { entry in
              autoImportRow(entry)
            }
            Button("Clear log", role: .destructive) {
              bridge.recentImports = []
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .onAppear(perform: refresh)
  }

  @ViewBuilder
  private func autoImportRow(_ entry: AutoImportLogEntry) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(entry.succeeded ? Color.green : Color.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.title)
          .foregroundStyle(.primary)
          .lineLimit(2)
        HStack(spacing: 6) {
          Text(relativeDate(entry.importedAt))
            .font(.caption)
            .foregroundStyle(.secondary)
          if let err = entry.error {
            Text("· \(err)")
              .font(.caption)
              .foregroundStyle(.orange)
              .lineLimit(1)
          }
        }
      }
      Spacer()
    }
  }

  private func relativeDate(_ d: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: d, relativeTo: Date())
  }

  @ViewBuilder
  private func pickerRow(title: String, tint: Color?, id: String?) -> some View {
    Button {
      bridge.sourceListID = id
      selectedID = id
    } label: {
      HStack(spacing: 10) {
        if let tint {
          Circle().fill(tint).frame(width: 10, height: 10)
        } else {
          Circle().stroke(.secondary, lineWidth: 1).frame(width: 10, height: 10)
        }
        Text(title).foregroundStyle(.primary)
        Spacer()
        if selectedID == id {
          Image(systemName: "checkmark")
            .scaledFont(size: 13, weight: .semibold)
            .foregroundStyle(.tint)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func refresh() {
    access = bridge.access
    if access == .granted {
      lists = bridge.reminderLists()
      selectedID = bridge.sourceListID
    }
  }
}

// MARK: - Calendar detail
//
// Reached from Integrations → Calendar. Lists every event calendar EventKit
// exposes and lets the user toggle visibility per source. Hidden calendars
// drop out of CalendarBridge's fetch helpers, so both the day timeline and
// the Next page stop showing those events.

private struct CalendarDetail: View {
  @State private var bridge = CalendarBridge.shared
  @State private var access: CalendarBridge.Access = .notDetermined
  @State private var calendars: [EKCalendar] = []

  var body: some View {
    Form {
      Section {
        Text("Pick which calendars contribute events to your day timeline and Next page. Hidden calendars stay untouched in iOS Calendar.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      switch access {
      case .notDetermined:
        Section {
          Button("Grant Access to Calendar") {
            Task {
              _ = await bridge.requestAccess()
              refresh()
            }
          }
        }
      case .denied, .writeOnly:
        Section {
          Text(access == .writeOnly
               ? "Septena has write-only access. Enable Full Access in Settings → Privacy → Calendars."
               : "Calendar access is denied. Enable it in Settings → Privacy → Calendars.")
            .font(.callout)
        }
      case .granted:
        if calendars.isEmpty {
          Section {
            Text("No calendars found.")
              .foregroundStyle(.secondary)
          }
        } else {
          Section("Calendars") {
            ForEach(calendars, id: \.calendarIdentifier) { cal in
              calendarRow(cal)
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .onAppear(perform: refresh)
  }

  private func calendarRow(_ cal: EKCalendar) -> some View {
    Toggle(isOn: Binding(
      get: { !bridge.isHidden(cal) },
      set: { bridge.setHidden(!$0, for: cal) }
    )) {
      HStack(spacing: 10) {
        Circle()
          .fill(Color(cgColor: cal.cgColor))
          .frame(width: 10, height: 10)
        VStack(alignment: .leading, spacing: 2) {
          Text(cal.title)
            .foregroundStyle(.primary)
          if let source = cal.source?.title, !source.isEmpty {
            Text(source)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private func refresh() {
    access = bridge.access
    if access == .granted {
      calendars = bridge.allCalendars()
    }
  }
}

// MARK: - Photos Detail
//
// Photo access is used to attach thumbnails to nutrition (meal) entries.
// When access is denied, meal thumbnails silently fall back to a
// placeholder — this screen explains why and points to iOS Settings.
private struct PhotosDetail: View {
  @State private var bridge = PhotosBridge.shared
  @State private var access: PhotosBridge.Access = .notDetermined

  var body: some View {
    Form {
      Section {
        Text("Septena attaches photos to your meal entries and shows their thumbnails in your nutrition log. Photos stay on your device.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      switch access {
      case .notDetermined:
        Section {
          Button("Grant Access to Photos") {
            Task {
              _ = await bridge.requestAccess()
              refresh()
            }
          }
        }
      case .denied:
        Section {
          Text("Photo access is denied. Enable it in Settings → Privacy → Photos. Meal thumbnails won't show until then.")
            .font(.callout)
        }
      case .granted:
        Section {
          Label("Connected", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        }
      }
    }
    .formStyle(.grouped)
    .onAppear(perform: refresh)
  }

  private func refresh() {
    access = bridge.access
  }
}

// Oura → Personal Access Token entry. The user pastes a token from
// cloud.ouraring.com/personal-access-tokens; OuraProvider stores it in
// Keychain. Test button does a 1-day fetchHistory round-trip so the
// user gets immediate confirmation the token works.
private struct OuraIntegrationDetail: View {
  @State private var provider = OuraProvider.shared
  @State private var draft: String = ""
  @State private var testing = false
  @State private var lastResult: String? = nil

  var body: some View {
    Form {
      Section {
        SecureField("Personal Access Token", text: $draft)
          #if os(iOS)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          #endif
        HStack {
          Button("Save") {
            provider.setToken(draft)
            draft = ""
            lastResult = nil
            // Kick off a full one-year backfill so the user's history
            // lands in SwiftData + CloudKit immediately, not after the
            // next dashboard visit.
            Task { await runBackfill() }
          }
          .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Spacer()
          if provider.hasToken {
            Button("Remove", role: .destructive) {
              provider.clearToken()
              lastResult = nil
            }
          }
        }
      } header: {
        Text("Token")
      } footer: {
        VStack(alignment: .leading, spacing: 6) {
          Text("Create a Personal Access Token at cloud.ouraring.com/personal-access-tokens, then paste it here. Tokens stay on this device (Keychain) and are never sent to any Septena server.")
          Link("Open Oura tokens page",
               destination: URL(string: "https://cloud.ouraring.com/personal-access-tokens")!)
            .font(.callout)
        }
      }

      Section {
        HStack {
          Label("Status", systemImage: "circle.circle")
          Spacer()
          Text(provider.hasToken ? "Connected" : "Not configured")
            .foregroundStyle(provider.hasToken ? .green : .secondary)
        }
        Button {
          Task { await runTest() }
        } label: {
          HStack {
            Label("Test connection", systemImage: "checkmark.seal")
            Spacer()
            if testing { ProgressView().controlSize(.small) }
          }
        }
        .disabled(!provider.hasToken || testing)
        if let lastResult {
          Text(lastResult)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }

  private func runTest() async {
    testing = true
    defer { testing = false }
    do {
      let rows = try await provider.fetchHistory(days: 7)
      let withScore = rows.compactMap(\.sleepScore).count
      lastResult = "OK — \(rows.count) days fetched, \(withScore) with a sleep score."
    } catch {
      lastResult = "Failed: \(error.localizedDescription)"
    }
  }

  private func runBackfill() async {
    testing = true
    defer { testing = false }
    lastResult = "Backfilling last 365 days…"
    do {
      let rows = try await provider.fetchHistory(days: 365)
      let withScore = rows.compactMap(\.sleepScore).count
      lastResult = "Backfill complete — \(rows.count) nights, \(withScore) with a sleep score. Syncing to iCloud."
    } catch {
      lastResult = "Backfill failed: \(error.localizedDescription)"
    }
  }
}

// GitHub → personal access token entry. The user pastes a token with the
// `read:user` scope from github.com/settings/tokens; GitHubProvider stores
// it in Keychain (never CloudKit, never a Septena server). Test button does
// a contributions round-trip so the user gets immediate confirmation.
private struct GitHubIntegrationDetail: View {
  @State private var provider = GitHubProvider.shared
  @State private var draft: String = ""
  @State private var testing = false
  @State private var lastResult: String? = nil

  var body: some View {
    Form {
      Section {
        SecureField("Access Token", text: $draft)
          #if os(iOS)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          #endif
        HStack {
          Button("Save") {
            provider.setToken(draft)
            draft = ""
            lastResult = nil
            // Immediately validate so the user sees the token works (and
            // warms the dashboard cache via the destination's own fetch).
            Task { await runTest() }
          }
          .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Spacer()
          if provider.hasToken {
            Button("Remove", role: .destructive) {
              provider.clearToken()
              lastResult = nil
            }
          }
        }
      } header: {
        Text("Token")
      } footer: {
        VStack(alignment: .leading, spacing: 6) {
          Text("Create a personal access token with the read:user scope at github.com/settings/tokens, then paste it here. Tokens stay on this device (Keychain) and are never sent to any Septena server.")
          Link("Open GitHub tokens page",
               destination: URL(string: "https://github.com/settings/tokens")!)
            .font(.callout)
        }
      }

      Section {
        HStack {
          Label("Status", systemImage: "chevron.left.forwardslash.chevron.right")
          Spacer()
          Text(provider.hasToken ? "Connected" : "Not configured")
            .foregroundStyle(provider.hasToken ? .green : .secondary)
        }
        Button {
          Task { await runTest() }
        } label: {
          HStack {
            Label("Test connection", systemImage: "checkmark.seal")
            Spacer()
            if testing { ProgressView().controlSize(.small) }
          }
        }
        .disabled(!provider.hasToken || testing)
        if let lastResult {
          Text(lastResult)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }

  private func runTest() async {
    testing = true
    defer { testing = false }
    do {
      let c = try await provider.fetchContributions(days: 365)
      lastResult = "OK — \(c.total) contributions for @\(c.login) in the last year."
    } catch {
      lastResult = "Failed: \(error.localizedDescription)"
    }
  }
}

// MARK: - Claude Gateway Detail

/// Connect / status / disconnect for the Septena MCP gateway. "Connect"
/// mints a CloudKit Web Services token and pushes it to mcp.septena.app;
/// the app then re-mints on foreground so Claude keeps working without
/// the user re-authorizing every ~8h. The gateway holds only the rotating
/// token, never the user's data.
struct ClaudeGatewayDetail: View {
  @State private var provider = ClaudeGatewayProvider.shared
  @State private var urlCopied = false

  /// The exact custom-connector address Claude expects (the JSON-RPC MCP
  /// transport endpoint). NOT the bare domain — Claude needs the `/mcp` path.
  private static let connectorURL = "https://mcp.septena.app/mcp"

  var body: some View {
    Form {
      Section {
        if provider.isEnabled {
          Button("Disconnect", role: .destructive) {
            provider.disconnect()
          }
        } else {
          Button("Connect Claude") {
            Task { await provider.connect() }
          }
        }
      } footer: {
        Text("Connecting lets Claude (at claude.ai or in the Claude app) read and write your Septena data via the MCP connector. Your data stays in iCloud — the gateway only relays a short-lived access token, which this app refreshes automatically. Use the address below to add the connector in Claude.")
      }

      Section {
        Button {
          SkillCopy.copy(Self.connectorURL)
          withAnimation { urlCopied = true }
          Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation { urlCopied = false }
          }
        } label: {
          HStack(spacing: 12) {
            Image(systemName: "link").font(.body).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
              Text("Connector address")
              Text(Self.connectorURL)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: urlCopied ? "checkmark.circle.fill" : "doc.on.doc")
              .foregroundStyle(urlCopied ? .green : .secondary)
          }
        }
        .buttonStyle(.plain)
      } header: {
        Text("Add to Claude")
      } footer: {
        Text("In Claude — claude.ai → Settings → Connectors, or the Claude app — add a custom connector and paste this address. You'll be asked to sign in with your Apple ID once to authorize access to your private iCloud data.")
      }

      if provider.isEnabled {
        Section {
          HStack {
            Label("Status", systemImage: "antenna.radiowaves.left.and.right")
            Spacer()
            Text(provider.needsReauth ? "Reconnect needed" : (provider.lastError == nil ? "Connected" : "Needs attention"))
              .foregroundStyle(provider.needsReauth || provider.lastError != nil ? .orange : .green)
          }
          if let last = provider.lastRefreshAt {
            ClaudeConnectionTimer(lastRefreshAt: last, dueAt: provider.nudgeFireDate)
          } else {
            HStack {
              Label("Last authenticated", systemImage: "clock.arrow.circlepath")
              Spacer()
              Text("Never").foregroundStyle(.secondary)
            }
          }
          Button {
            Task { await provider.refreshNow() }
          } label: {
            HStack {
              Label("Reauthenticate", systemImage: "lock.rotation")
              Spacer()
              if provider.isRefreshing { ProgressView().controlSize(.small) }
            }
          }
          .disabled(provider.isRefreshing)
          if let err = provider.lastError {
            Text(err)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } header: {
          Text("Connection")
        }
      }

      Section {
        explainerRow(icon: "link",
                     title: "A small relay",
                     text: "Claude talks to Septena through a connector at mcp.septena.app. Add it in Claude (claude.ai or the Claude app) using that address.")
        explainerRow(icon: "lock.icloud",
                     title: "Your data stays private",
                     text: "Reads and writes go straight to your own private iCloud database. The relay never stores your data — it only passes a short-lived access token through.")
        explainerRow(icon: "text.bubble",
                     title: "Ask in plain language",
                     text: "Claude can read and log your tasks, habits, supplements, meals, training and more, just by you asking.")
        explainerRow(icon: "arrow.triangle.2.circlepath",
                     title: "Syncs everywhere",
                     text: "Anything Claude logs shows up across all your devices automatically.")
      } header: {
        Text("How it works")
      } footer: {
        Text("Good to know: Apple only issues short-lived keys for private iCloud data — a few hours, with no server-side renewal. So Septena refreshes the connection automatically when you open the app, and the “Keep Claude connected” reminder nudges you before it lapses. If it does lapse, Claude simply asks you to open Septena to refresh — you won't need to reconnect from claude.ai, and it resumes on its own. Refreshing happens on iPhone and Mac only, not the watch.")
      }
    }
    .formStyle(.grouped)
  }

  @ViewBuilder
  private func explainerRow(icon: String, title: String, text: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon)
        .font(.body)
        .foregroundStyle(.secondary)
        .frame(width: 24, alignment: .center)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.subheadline.weight(.medium))
        Text(text).font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
  }
}

// Live "time since last connected" + countdown to the auto-refresh horizon.
// `TimelineView` ticks the labels without any manual timer; it stops when the
// pane is offscreen. The "due" line keys off `nudgeFireDate` (lastRefreshAt +
// ~7h) — the same horizon that flips `needsReauth` and arms the reconnect
// nudge — so the number the user sees here matches what the app acts on.
private struct ClaudeConnectionTimer: View {
  let lastRefreshAt: Date
  let dueAt: Date?

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { ctx in
      let now = ctx.date
      HStack(alignment: .firstTextBaseline) {
        Label("Connected", systemImage: "clock.arrow.circlepath")
        Spacer()
        VStack(alignment: .trailing, spacing: 2) {
          Text("\(Self.compact(now.timeIntervalSince(lastRefreshAt))) ago")
            .foregroundStyle(.secondary)
            .monospacedDigit()
          dueLine(now: now)
        }
      }
    }
  }

  @ViewBuilder
  private func dueLine(now: Date) -> some View {
    if let dueAt {
      let remaining = dueAt.timeIntervalSince(now)
      if remaining > 0 {
        Text("auto-refresh in \(Self.compact(remaining))")
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      } else {
        Text("refresh recommended")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
  }

  /// "2h 14m", "46m 03s", "12s" — drops to finer units as the value shrinks so
  /// the trailing digits visibly tick.
  static func compact(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return String(format: "%dm %02ds", m, s) }
    return "\(s)s"
  }
}

// Withings → OAuth2 connect / backfill / disconnect. "Connect" opens
// ASWebAuthenticationSession against account.withings.com; the returned
// code is exchanged for access + refresh tokens stored in Keychain.
// Backfill pulls the last 365 days into SwiftData + CloudKit so other
// devices pick them up via CKSyncEngine.
private struct WithingsIntegrationDetail: View {
  @State private var provider = WithingsProvider.shared
  @State private var working = false
  @State private var lastResult: String? = nil

  var body: some View {
    Form {
      if !provider.isConfigured {
        Section {
          Text("Withings app credentials are not configured.")
            .foregroundStyle(.secondary)
        } footer: {
          Text("Register a Withings dev app at developer.withings.com (Public Health Data API), then add your client_id and client_secret to Config/Secrets.xcconfig (copy it from Config/Secrets.example.xcconfig) and rebuild. The redirect URI should be septena://withings/callback.")
        }
      }

      Section {
        HStack {
          Label("Status", systemImage: "scalemass")
          Spacer()
          Text(provider.hasTokens ? "Connected" : "Not connected")
            .foregroundStyle(provider.hasTokens ? .green : .secondary)
        }

        if provider.hasTokens {
          Button {
            Task { await runBackfill() }
          } label: {
            HStack {
              Label("Backfill last 365 days", systemImage: "arrow.clockwise")
              Spacer()
              if working { ProgressView().controlSize(.small) }
            }
          }
          .disabled(working)
          Button("Disconnect", role: .destructive) {
            provider.disconnect()
            lastResult = nil
          }
          .disabled(working)
        } else {
          Button {
            Task { await runConnect() }
          } label: {
            HStack {
              Label("Connect Withings", systemImage: "link")
              Spacer()
              if working { ProgressView().controlSize(.small) }
            }
          }
          .disabled(!provider.isConfigured || working)
        }

        if let lastResult {
          Text(lastResult)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } footer: {
        Text("Tokens live in this device's Keychain and never leave it. Weigh-ins sync to your other devices via iCloud.")
      }
    }
    .formStyle(.grouped)
  }

  private func runConnect() async {
    working = true
    defer { working = false }
    lastResult = "Opening Withings sign-in…"
    do {
      try await provider.connect()
      lastResult = "Connected. Backfilling last 365 days…"
      let rows = try await provider.fetchHistory(days: 365)
      lastResult = "Connected — \(rows.count) days fetched. Syncing to iCloud."
    } catch {
      lastResult = "Failed: \(error.localizedDescription)"
    }
  }

  private func runBackfill() async {
    working = true
    defer { working = false }
    lastResult = "Backfilling last 365 days…"
    do {
      let rows = try await provider.fetchHistory(days: 365)
      lastResult = "Backfill complete — \(rows.count) days, syncing to iCloud."
    } catch {
      lastResult = "Backfill failed: \(error.localizedDescription)"
    }
  }
}

// MARK: - About

struct AboutSettingsPane: View {
  private var version: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
  }
  private var build: String {
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
  }

  var body: some View {
    Form {
      Section {
        VStack(alignment: .center, spacing: 14) {
          AppIconPreview(option: .default, size: 72)
            .padding(.top, 4)
          VStack(spacing: 4) {
            Text("Septena")
              .font(.septenaWordmark)
            Text("One app for every corner of your life")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
          }
          Text("Version \(version) (\(build))")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .listRowBackground(Color.clear)
      }

      Section {
        Text("Septena keeps the everyday things you track in one place: tasks, habits, what you eat, how you sleep. It syncs across your devices over iCloud and stays yours alone — and it's open source, so you can read exactly how it handles your data.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Section("Links") {
        outboundLink("Website", destination: "https://septena.app", icon: "globe")
        outboundLink("Telegram", destination: "https://t.me/septena_app", icon: "paperplane")
        outboundLink("Feedback", destination: "mailto:mz@envisioning.com", icon: "envelope")
        outboundLink("Source code", destination: "https://github.com/septena/septena", icon: "chevron.left.forwardslash.chevron.right")
        outboundLink("License", destination: "https://opensource.org/licenses/MIT", icon: "doc.text")
      }

      Section {
        infoRow("Platform", platformLabel)
      }

      Section {
        NavigationLink(value: SettingsView.SettingsDestination.advanced) {
          Label("Advanced", systemImage: "wrench.and.screwdriver")
        }
      } footer: {
        Text("Developer and recovery tools. Safe to ignore in normal use.")
      }
    }
    .formStyle(.grouped)
  }

  private var platformLabel: String {
    #if os(macOS)
    return "macOS"
    #else
    return "iOS · iPadOS"
    #endif
  }

  private func outboundLink(_ title: String, destination: String, icon: String) -> some View {
    Link(destination: URL(string: destination)!) {
      HStack {
        Label(title, systemImage: icon)
          .foregroundStyle(.primary)
        Spacer()
        Image(systemName: "arrow.up.right")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
  }

  private func infoRow(_ label: String, _ value: String) -> some View {
    HStack {
      Text(label)
      Spacer()
      Text(value)
        .foregroundStyle(.secondary)
        .font(.callout.monospacedDigit())
    }
  }
}

// MARK: - Advanced (developer + diagnostics)

/// The one quiet door, reached from About, for surfaces that aren't part of the
/// everyday consumer flow: the motion test bench, data recovery tools, and the
/// macOS reasoning-provider override. Keeps the main panes App-Store clean
/// without deleting tools the developer (and the occasional power user) needs.
struct AdvancedSettingsPane: View {
  @Environment(SettingsStore.self) private var store
  #if os(macOS)
  @AppStorage(AIPolicy.devForceProviderKey) private var devForce = ""
  #endif
  @State private var welcomeReset = false

  var body: some View {
    Form {
      Section {
        NavigationLink(value: SettingsView.SettingsDestination.motionGallery) {
          Label("Motion Gallery", systemImage: "wand.and.rays")
        }
        NavigationLink(value: SettingsView.SettingsDestination.dataTools) {
          Label("Data Tools", systemImage: "stethoscope")
        }
        #if DEBUG
        NavigationLink(value: SettingsView.SettingsDestination.milestonePreview) {
          Label("Milestones (preview)", systemImage: "flag.checkered")
        }
        #endif
      } header: {
        Text("Diagnostics")
      } footer: {
        Text("Motion Gallery tunes the logging flourishes. Data Tools re-pulls records from CloudKit and generates LLM import prompts.")
      }

      Section {
        Button {
          store.resetWelcomeForTesting()
          welcomeReset = true
        } label: {
          Label("Reset first-run welcome", systemImage: "arrow.counterclockwise")
        }
      } header: {
        Text("Onboarding")
      } footer: {
        Text(welcomeReset
             ? "The welcome will appear over the app now, and on relaunch until you complete it. Only this device is affected."
             : "Re-shows the first-run welcome (section picker + section intros) on this device, for testing. Doesn't change your data or your other devices.")
      }

      #if os(macOS)
      Section {
        Picker("Force provider", selection: $devForce) {
          Text("Off (use the AI mode)").tag("")
          ForEach(AIProviderKind.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
        }
      } header: {
        Text("AI provider override")
      } footer: {
        Text("Pins every reasoning step to one provider — for testing only. Leave Off in normal use.")
      }
      #endif
    }
    .formStyle(.grouped)
  }
}

// MARK: - Milestone preview bench
//
// Fires each milestone celebration on demand through the SAME tiering a real
// crossing uses (`MilestonePresenter.style(for:)`), rendered in a local
// overlay so it's visible inside Settings. No store writes, no detection —
// pure "what does this celebration look like." The synthetic milestones are
// constructed in-memory and never inserted into a ModelContext.
struct MilestonePreviewPane: View {
  @Environment(SectionTheme.self) private var theme
  @State private var style: LogCommitStyle?
  @State private var trigger = 0

  /// One row per distinct celebration the presenter can produce. Values
  /// mirror what the detectors write so the labels read realistically.
  private struct Sample: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let make: () -> GoalMilestoneEntity
  }

  private static func milestone(scope: String, kind: String, rungKey: String,
                                label: String, value: Double) -> GoalMilestoneEntity {
    GoalMilestoneEntity(id: "preview|\(rungKey)", goalID: nil, scope: scope,
                        kind: kind, rungKey: rungKey, label: label,
                        value: value, occurredAt: .now, celebrated: true)
  }

  private let samples: [Sample] = [
    .init(id: "streak", title: "Streak rung",
          subtitle: "Habit hits a 30-day streak → Ignition",
          make: { milestone(scope: "habit:demo", kind: "streak",
                            rungKey: "streak:30", label: "Meditate: 30-day streak",
                            value: 30) }),
    .init(id: "pr", title: "Training PR",
          subtitle: "Heaviest-ever set → milestone card",
          make: { milestone(scope: "exercise:bench-press", kind: "pr",
                            rungKey: "pr:100", label: "Bench Press PR: 100 kg",
                            value: 100) }),
    .init(id: "target", title: "Goal target reached",
          subtitle: "Smoothed value crosses the target → milestone card",
          make: { milestone(scope: "goal:demo", kind: "rung",
                            rungKey: "target", label: "Target reached: 74 kg",
                            value: 74) }),
    .init(id: "held30", title: "Held 30 days",
          subtitle: "Maintenance — stayed on target a month → milestone card",
          make: { milestone(scope: "goal:demo", kind: "rung",
                            rungKey: "held30", label: "Held 74 kg for 30 days",
                            value: 74) }),
    .init(id: "rung", title: "Intermediate rung",
          subtitle: "Per-kg grid rung → quiet burst",
          make: { milestone(scope: "goal:demo", kind: "rung",
                            rungKey: "lvl:78", label: "Trailing average crossed 78 kg",
                            value: 78) }),
    .init(id: "xp", title: "Volume XP",
          subtitle: "Lifetime-tonnage rung → quiet burst",
          make: { milestone(scope: "training.volume", kind: "xp",
                            rungKey: "xp:50t", label: "Lifetime volume: 50 tonnes",
                            value: 50000) }),
  ]

  var body: some View {
    Form {
      Section {
        ForEach(samples) { sample in
          Button { fire(sample) } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(sample.title).foregroundStyle(.primary)
              Text(sample.subtitle).font(.caption).foregroundStyle(.secondary)
            }
          }
          .buttonStyle(.plain)
        }
      } header: {
        Text("Tap to play")
      } footer: {
        Text("Each fires the real MilestonePresenter tiering — streaks and goal target/held get the full card, intermediate rungs and XP get the quiet burst. Under Reduce Motion the visual is suppressed by design.")
      }
    }
    .formStyle(.grouped)
    .overlay {
      if let style {
        LogCommitStyleView(style: style, trigger: trigger)
          .allowsHitTesting(false)
      }
    }
  }

  private func fire(_ sample: Sample) {
    style = MilestonePresenter.style(for: sample.make(), theme: theme)
    trigger &+= 1
    Haptics.success()
  }
}

// MARK: - Shared pane helpers

private func row(_ label: String, _ value: String) -> some View {
  HStack {
    Text(label)
    Spacer()
    Text(value)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.trailing)
  }
}

// MARK: - Import & Export
//
// One pane for getting data in and out of Septena. Export produces a
// stable JSON envelope per section (and an "Everything" bundle); import
// parses the same envelope, validates it against the local schema, and
// previews per-table counts before any writes land. The JSON format is
// designed to round-trip — anything exported here is a valid import.
//
// Envelope shape (stable, versioned):
//   {
//     "septena_export_version": 1,
//     "section": "<section key>" | "all",
//     "exported_at": "<ISO-8601>",
//     "app_version": "<CFBundleShortVersionString> (<CFBundleVersion>)",
//     "tables": {
//        "<table_name>": [ { ...record... }, ... ],
//        ...
//     }
//   }
//
// Sections that aren't backed by exportable local entities (e.g.
// `activity`, `sleep`) are skipped — Import/Export only lists what it
// can actually produce.

import UniformTypeIdentifiers

// MARK: - Skills

/// Top-level Skills page. Lists every section that has an MCP skill brief,
/// plus a "Connection" row at top showing the universal preamble. Each row
/// navigates to a `SectionSkillView`.
///
/// Skills are static content (defined in `SectionSkill.all`); this pane
/// just renders them. To add a section, edit `SectionSkill.swift`.
struct SkillsSettingsPane: View {
  @Environment(SettingsStore.self) private var store

  /// Show section skills in the user's actual sidebar order when possible,
  /// falling back to the catalog order in `SectionSkill.all`. Skills for
  /// sections the user doesn't have installed are still shown — they're
  /// informational, and someone evaluating which sections to enable
  /// benefits from previewing the skill content.
  private var orderedKeys: [String] {
    let order = store.serverSettings?.sectionOrder ?? []
    let known = SectionSkill.allKnownKeys
    let head  = order.filter { known.contains($0) }
    let rest  = known.subtracting(head).sorted()
    return head + rest
  }

  var body: some View {
    Form {
      Section {
        NavigationLink {
          SkillPreambleView()
        } label: {
          Label("Connection & conventions", systemImage: "antenna.radiowaves.left.and.right")
        }
      } header: {
        Text("MCP")
      } footer: {
        Text("Connect Claude or another MCP client to mcp.septena.app to read and write your Septena data. The brief below is what the model needs to know to use the connection well.")
      }

      Section {
        ForEach(orderedKeys, id: \.self) { key in
          if let skill = SectionSkill.resolve(key) {
            NavigationLink {
              SectionSkillView(sectionKey: key)
            } label: {
              skillRowLabel(for: key, skill: skill)
            }
          }
        }
      } header: {
        Text("Section skills")
      } footer: {
        Text("Each brief teaches a model how to use one section through the MCP — tools available, conventions, examples.")
      }

      Section {
        Button {
          SkillCopy.copy(SectionRegistry.fullSkillMarkdown())
          showCopiedToast = true
        } label: {
          Label("Copy MCP gateway brief", systemImage: "doc.on.doc")
        }
      } header: {
        Text("Gateway sync")
      } footer: {
        Text("Copies the preamble + every section's brief as one Markdown document. Paste into septena-mcp-gateway/skill.md so the LLM-facing catalog can't drift from the plugin definitions in this app.")
      }
    }
    .formStyle(.grouped)
    .overlay(alignment: .bottom) {
      if showCopiedToast {
        Text("Copied")
          .font(.callout)
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
          .background(.thinMaterial, in: Capsule())
          .padding(.bottom, 24)
          .transition(.opacity)
          .task {
            try? await Task.sleep(for: .seconds(1.4))
            showCopiedToast = false
          }
      }
    }
    .animation(.snappy, value: showCopiedToast)
  }

  @State private var showCopiedToast = false

  @ViewBuilder
  private func skillRowLabel(for key: String, skill: SectionSkill) -> some View {
    let entry = store.sections.first(where: { $0.key == key })
    let label = SectionManifest.displayLabel(key: key, stored: entry?.label ?? "")
    let color = parseHexColor(entry?.color ?? "")
    HStack(spacing: 12) {
      ColoredGlyph(icon: skillSectionIcon(key: key), color: color, size: 22)
      VStack(alignment: .leading, spacing: 1) {
        Text(label).foregroundStyle(.primary)
        Text(skill.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }

  private func skillSectionIcon(key: String) -> String {
    return SectionManifest.byKey[key]?.iconSymbol ?? "circle.fill"
  }
}

/// Per-section skill detail. Reused by both the Skills top-level pane
/// (via SkillsSettingsPane) and the bottom of each section's settings
/// page (via SectionDetailPane.skillAndDataSection).
struct SectionSkillView: View {
  @Environment(SettingsStore.self) private var store
  let sectionKey: String

  private var skill: SectionSkill? { SectionSkill.resolve(sectionKey) }
  private var label: String {
    SectionManifest.displayLabel(
      key: sectionKey,
      stored: store.sections.first(where: { $0.key == sectionKey })?.label ?? "")
  }

  var body: some View {
    Form {
      if let skill {
        Section {
          Text(skill.summary)
            .font(.callout)
            .foregroundStyle(.primary)
        } header: {
          Text("\(label) skill")
        }

        Section("Tools") {
          ForEach(skill.tools, id: \.name) { tool in
            VStack(alignment: .leading, spacing: 3) {
              Text(tool.name)
                .font(.callout.monospaced())
                .foregroundStyle(.primary)
              Text(tool.blurb)
                .font(.caption)
                .foregroundStyle(.secondary)
              if let inputs = tool.inputs {
                Text(inputs)
                  .font(.caption2.monospaced())
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
              }
            }
            .padding(.vertical, 3)
          }
        }

        Section("Conventions & examples") {
          Text(.init(skill.body))
            .font(.callout)
            .foregroundStyle(.primary)
            .textSelection(.enabled)
        }

        Section {
          Button {
            SkillCopy.copy(skill.fullMarkdown)
          } label: {
            Label("Copy full skill", systemImage: "doc.on.doc")
          }
          ShareLink(item: skill.fullMarkdown) {
            Label("Share…", systemImage: "square.and.arrow.up")
          }
        } footer: {
          Text("The copied text includes the connection preamble + this section's brief — paste it into an MCP client's system prompt or a Claude conversation to teach it how to use the section.")
        }
      } else {
        Section {
          Label("No skill yet", systemImage: "questionmark.circle")
            .foregroundStyle(.secondary)
        } footer: {
          Text("This section doesn't yet have MCP tools. A skill will appear here when it does.")
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("\(label) skill")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
  }
}

/// Connection preamble shown above all section skills. Static content
/// pulled from `SectionSkill.preamble`.
struct SkillPreambleView: View {
  var body: some View {
    Form {
      Section {
        MCPConnectionDiagram()
      } footer: {
        Text("Your data stays in your private iCloud. Connecting an AI just opens a door into it — one you control and can revoke.")
      }
      Section {
        Text(.init(SectionSkill.preamble))
          .font(.callout)
          .textSelection(.enabled)
      }
      Section {
        Button {
          SkillCopy.copy(SectionSkill.preamble)
        } label: {
          Label("Copy preamble", systemImage: "doc.on.doc")
        }
        ShareLink(item: SectionSkill.preamble) {
          Label("Share…", systemImage: "square.and.arrow.up")
        }
      } footer: {
        Text("Universal conventions every section relies on. Each section skill below extends this.")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Connection & conventions")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
  }
}

/// Tiny cross-platform pasteboard wrapper. Lives at file scope so all
/// skill views (and the per-section detail pane footer) share one impl.
private enum SkillCopy {
  static func copy(_ text: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = text
    #elseif canImport(AppKit)
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
    #endif
  }
}

private let importExportEnvelopeVersion = 1

/// Sections the exporter understands today. Order matches the Settings
/// sidebar.
private let exportableSectionKeys: [String] = [
  "tasks", "training", "nutrition", "habits", "chores",
  "supplements", "groceries", "gut", "intake",
]

struct ImportExportSettingsPane: View {
  /// Which face of this pane to render. `.full` is the everyday "Data" pane
  /// (export / import / format reference); `.dataTools` is the power-user
  /// surface (CloudKit repair + LLM schema prompts) that lives under
  /// About ▸ Advanced. Both share one struct so the import/export state and
  /// helpers aren't duplicated.
  enum Mode { case full, dataTools }
  var mode: Mode = .full

  @Environment(SettingsStore.self) private var store
  @Environment(CKEngine.self) private var ckEngine
  @State private var exportError: String? = nil
  @State private var importDoc: ImportExportEnvelope? = nil
  @State private var importMessage: String? = nil
  @State private var importIsError: Bool = false
  @State private var showingPaste = false
  @State private var showingFilePicker = false
  @State private var pasteBuffer: String = ""
  @State private var repairState: RepairState = .idle

  enum RepairState: Equatable {
    case idle
    case running
    case success(recordCount: Int, typeCount: Int)
    case failure(message: String)
  }

  var body: some View {
    Form {
      switch mode {
      case .full:
        exportSection
        importSection
        formatSection
      case .dataTools:
        repairSection
        schemaPromptsSection
      }
    }
    .formStyle(.grouped)
    .sheet(isPresented: $showingPaste) {
      pasteSheet
    }
    .fileImporter(isPresented: $showingFilePicker,
                  allowedContentTypes: [.json],
                  allowsMultipleSelection: false) { result in
      handleFileImport(result)
    }
  }

  // MARK: Export

  @ViewBuilder
  private var exportSection: some View {
    Section {
      exportRow(label: "Everything",
                systemImage: "tray.full",
                fileBase: "septena-export") {
        try ImportExportService.exportAll()
      }
      ForEach(exportableSectionKeys, id: \.self) { key in
        exportRow(label: sectionLabel(for: key),
                  systemImage: sectionGlyph(for: key),
                  fileBase: "septena-\(key)") {
          try ImportExportService.exportSection(key)
        }
      }
    } header: {
      Text("Export")
    } footer: {
      Text("JSON dumps of every record in the local store. Use these as a backup, to move to another device, or to feed into other tools.")
    }
  }

  @ViewBuilder
  private func exportRow(label: String,
                         systemImage: String,
                         fileBase: String,
                         build: @escaping () throws -> Data) -> some View {
    // Serialize lazily — the JSON blob is built only when the user actually
    // invokes the share sheet (ExportFile carries the closure, not the data).
    // Building eagerly here meant every body re-render of the Data pane ran a
    // full SwiftData fetch + JSON encode for all ~10 exports on the main
    // thread, which is why this pane loaded far slower than the others.
    let filename = "\(fileBase)-\(ImportExportService.todayStamp).json"
    ShareLink(item: ExportFile(suggestedName: filename, build: build),
              preview: SharePreview(filename, image: Image(systemName: systemImage))) {
      HStack {
        Label(label, systemImage: systemImage)
          .foregroundStyle(.primary)
        Spacer()
        Image(systemName: "square.and.arrow.up")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: Import

  @ViewBuilder
  private var importSection: some View {
    Section {
      Button {
        showingFilePicker = true
      } label: {
        Label("Choose JSON file…", systemImage: "doc.badge.plus")
      }
      Button {
        pasteBuffer = ""
        importMessage = nil
        importIsError = false
        showingPaste = true
      } label: {
        Label("Paste JSON…", systemImage: "doc.on.clipboard")
      }

      if let doc = importDoc {
        importPreview(doc)
      } else if let msg = importMessage {
        Label(msg, systemImage: importIsError ? "exclamationmark.triangle" : "checkmark.circle")
          .foregroundStyle(importIsError ? .red : .green)
          .font(.callout)
      }
    } header: {
      Text("Import")
    } footer: {
      Text("Provide JSON in the Septena export format. Records are merged by id — existing rows update in place, new rows are inserted. Definition tables (habits, supplements, chores, beans, grocery items) apply now; event/log tables preview only in this build.")
    }
  }

  @ViewBuilder
  private func importPreview(_ doc: ImportExportEnvelope) -> some View {
    let sectionName = doc.section == "all"
      ? "Everything"
      : sectionLabel(for: doc.section)
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Loaded — \(sectionName)", systemImage: "checkmark.seal")
          .foregroundStyle(.green)
        Spacer()
        Button("Clear", role: .destructive) {
          importDoc = nil
          importMessage = nil
        }
        .buttonStyle(.borderless)
        .font(.caption)
      }
      if let ts = doc.exportedAt {
        Text("Exported \(ts)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Divider()
      ForEach(doc.tables.keys.sorted(), id: \.self) { table in
        HStack {
          Text(table)
            .font(.callout.monospaced())
          Spacer()
          Text("\(doc.tables[table]?.count ?? 0) rows")
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      Divider()
      HStack {
        Spacer()
        Button {
          applyImport(doc)
        } label: {
          Label("Apply", systemImage: "tray.and.arrow.down")
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
      }
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private var pasteSheet: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 8) {
        Text("Paste a Septena JSON export below.")
          .font(.callout)
          .foregroundStyle(.secondary)
        TextEditor(text: $pasteBuffer)
          .font(.body.monospaced())
          .frame(minHeight: 240)
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .strokeBorder(.secondary.opacity(0.2))
          )
        if importIsError, let msg = importMessage {
          Text(msg).font(.callout).foregroundStyle(.red)
        }
      }
      .padding()
      .navigationTitle("Paste JSON")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { showingPaste = false }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Load") {
            handlePaste(pasteBuffer)
          }
          .disabled(pasteBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
  }

  // MARK: Schema prompts
  //
  // One copyable LLM prompt per section. Paste the prompt into Claude /
  // ChatGPT / etc. along with whatever source data you have (CSV, journal
  // entries, freeform notes) and the model produces a JSON envelope that
  // round-trips through this importer. The schema is generated from the
  // same field list the exporter uses, so the prompt is always in sync.

  // MARK: Repair

  // One-shot re-pull for records whose history may be missing locally
  // because CKSyncEngine's incremental fetch token advanced past records
  // the device couldn't yet decode (a record type arrived while this
  // device was running a build without the matching arm in
  // `applyFetchedRecord` — it happened with nutrition, then again with
  // intake). `fetchAllRecords` does a fresh nil-token zone replay so
  // every live record is redelivered regardless of the engine
  // checkpoint, and the absorb path upserts idempotently. Whole-zone on
  // purpose: a per-type picker would just recreate this bug for the
  // next record type.
  @ViewBuilder
  private var repairSection: some View {
    Section {
      Button {
        Task { await repairFromCloudKit() }
      } label: {
        HStack {
          Label("Repair data from CloudKit", systemImage: "stethoscope")
          Spacer()
          switch repairState {
          case .idle:
            EmptyView()
          case .running:
            ProgressView().controlSize(.small)
          case .success(let records, let types):
            Text("\(records) records · \(types) types")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          case .failure:
            Image(systemName: "exclamationmark.triangle")
              .foregroundStyle(.orange)
          }
        }
      }
      .disabled(repairState == .running)
      if case .failure(let message) = repairState {
        Text(message)
          .font(.caption)
          .foregroundStyle(.red)
      }
    } header: {
      Text("Repair")
    } footer: {
      Text("Re-pulls every record in this account's CloudKit zone and merges it into the local store. Use if a section's history looks empty on this device even though the data exists on another one. Cloud truth wins for any record that differs locally.")
    }
  }

  private func repairFromCloudKit() async {
    repairState = .running
    do {
      let records = try await ckEngine.fetchAllRecords()
      for record in records {
        ckEngine.applyFetchedRecord?(record)
      }
      ckEngine.applyDidFinishBatch?(true)
      let types = Set(records.map(\.recordType)).count
      repairState = .success(recordCount: records.count, typeCount: types)
    } catch {
      repairState = .failure(message: error.localizedDescription)
    }
  }

  @ViewBuilder
  private var schemaPromptsSection: some View {
    Section {
      ForEach(exportableSectionKeys, id: \.self) { key in
        schemaPromptRow(for: key)
      }
    } header: {
      Text("Schema prompts")
    } footer: {
      Text("Copy a prompt and paste it into an LLM along with the source data you want to import. The model returns JSON that pastes straight into Import above.")
    }
  }

  @ViewBuilder
  private func schemaPromptRow(for key: String) -> some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 8) {
        Text(ImportExportService.schemaPrompt(for: key))
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        Button {
          copyToPasteboard(ImportExportService.schemaPrompt(for: key))
        } label: {
          Label("Copy prompt", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
      }
      .padding(.vertical, 4)
    } label: {
      Label(sectionLabel(for: key), systemImage: sectionGlyph(for: key))
    }
  }

  private func copyToPasteboard(_ text: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = text
    #elseif canImport(AppKit)
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
    #endif
  }

  // MARK: Format reference

  @ViewBuilder
  private var formatSection: some View {
    Section {
      DisclosureGroup("Envelope") {
        Text(ImportExportService.envelopeReference)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    } header: {
      Text("Format")
    } footer: {
      Text("Format version \(importExportEnvelopeVersion). The exporter above produces files that round-trip through this importer unchanged.")
    }
  }

  // MARK: Handlers

  private func handlePaste(_ text: String) {
    do {
      importDoc = try ImportExportService.parseEnvelope(Data(text.utf8))
      importMessage = nil
      importIsError = false
      showingPaste = false
    } catch {
      importMessage = error.localizedDescription
      importIsError = true
    }
  }

  private func handleFileImport(_ result: Result<[URL], Error>) {
    importMessage = nil
    importIsError = false
    importDoc = nil
    switch result {
    case .success(let urls):
      guard let url = urls.first else { return }
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      do {
        importDoc = try ImportExportService.parseEnvelope(try Data(contentsOf: url))
      } catch {
        importMessage = error.localizedDescription
        importIsError = true
      }
    case .failure(let error):
      importMessage = error.localizedDescription
      importIsError = true
    }
  }

  private func applyImport(_ doc: ImportExportEnvelope) {
    do {
      let result = try ImportExportService.apply(doc)
      importDoc = nil
      importMessage = "Imported \(result.applied) row\(result.applied == 1 ? "" : "s"); skipped \(result.skipped) (unsupported table\(result.skipped == 1 ? "" : "s"))."
      importIsError = false
    } catch {
      importMessage = error.localizedDescription
      importIsError = true
    }
  }

  // MARK: Helpers

  private func sectionLabel(for key: String) -> String {
    SectionManifest.displayLabel(
      key: key,
      stored: store.sections.first(where: { $0.key == key })?.label ?? "")
  }

  private func sectionGlyph(for key: String) -> String {
    if let m = SectionManifest.byKey[key] { return m.iconSymbol }
    return "circle.fill"
  }

}

// MARK: - ShareLink payload

private struct ExportFile: Transferable {
  let suggestedName: String
  /// Deferred serializer. Held instead of the bytes so the (expensive,
  /// main-context) export only runs when the share sheet actually pulls the
  /// representation — not on every render of the row.
  let build: () throws -> Data

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: .json) { item in
      // The build touches `mainContext`; hop to the main actor to run it.
      try await MainActor.run { try item.build() }
    }
    .suggestedFileName { $0.suggestedName }
  }
}

// MARK: - Parsed envelope

struct ImportExportEnvelope {
  let version: Int
  let section: String
  let exportedAt: String?
  let appVersion: String?
  let tables: [String: [[String: Any]]]
}

// MARK: - Service
//
// Pure functions: build a JSON `Data` blob for a given section (or all),
// or parse an inbound `Data` blob into an `ImportExportEnvelope`. No UI
// state — the pane drives it.

enum ImportExportService {
  enum ImportError: LocalizedError {
    case notJSON
    case missingEnvelope
    case unsupportedVersion(Int)
    case unsupportedSection(String)
    case malformed(String)

    var errorDescription: String? {
      switch self {
      case .notJSON: return "File isn't valid JSON."
      case .missingEnvelope: return "Missing Septena export envelope (septena_export_version / section / tables)."
      case .unsupportedVersion(let v): return "Export version \(v) is newer than this build understands."
      case .unsupportedSection(let s): return "Unknown section: \(s)."
      case .malformed(let m): return m
      }
    }
  }

  static var todayStamp: String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: .now)
  }

  /// Skill-style LLM prompt for one section. Self-contained: states the
  /// goal, the exact envelope shape to produce, and every field expected
  /// in every table (with type + required/optional). Designed to be
  /// copy-pasted into Claude / ChatGPT with arbitrary source data
  /// appended underneath.
  @MainActor
  static func schemaPrompt(for sectionKey: String) -> String {
    let sectionLabel = SectionManifest.byKey[sectionKey]?.defaultLabel
      ?? sectionKey.capitalized
    let tables = schemaTables(for: sectionKey)
    var out = """
    # Septena \(sectionLabel) Import

    You convert source data into a JSON document that Septena's Settings → Import & Export pane can apply.

    ## Output

    Return **only** the JSON below — no commentary, no markdown fences. Wrap your records in this envelope verbatim, substituting only `tables`:

    ```
    {
      "septena_export_version": 1,
      "section": "\(sectionKey)",
      "exported_at": "<current ISO-8601 timestamp>",
      "tables": {
    """
    for (i, t) in tables.enumerated() {
      let comma = (i == tables.count - 1) ? "" : ","
      out += "\n    \"\(t.name)\": [ … ]\(comma)"
    }
    out += """

      }
    }
    ```

    ## Tables

    """
    for t in tables {
      out += "\n### `\(t.name)` — \(t.purpose)\n"
      for f in t.fields {
        let req = f.required ? "**required**" : "optional"
        let note = f.note.map { " — \($0)" } ?? ""
        out += "- `\(f.name)` (\(f.type), \(req))\(note)\n"
      }
    }
    out += """

    ## Rules
    - `id` is a stable string; reuse the same id to update an existing row, choose a new one to insert.
    - Dates: `YYYY-MM-DD`. Times: `HH:MM`. Timestamps: ISO-8601 (e.g. `2026-05-24T08:30:00Z`).
    - Omit optional fields you don't have rather than sending `null`.
    - Skip any record you can't confidently map; partial data is better than fabricated data.

    ## Source data
    <paste your source data below this line>
    """
    return out
  }

  /// Table schemas exposed to the prompt builder. Kept in sync with the
  /// entity → dict mappers above; if you add a field there, add it here.
  @MainActor
  private static func schemaTables(for sectionKey: String) -> [SchemaTable] {
    // Every section now lives in its plugin's exportContribution. If
    // the lookup fails, the section either doesn't exist or doesn't
    // participate in import/export — return [] so the prompt builder
    // emits an empty schema block instead of crashing.
    return SectionRegistry.plugin(forKey: sectionKey)?.exportContribution?.tables ?? []
  }

  // SchemaTable / SchemaField hoisted to top-level types (see end of
  // file) so plugin files can declare their own export contribution
  // without needing to reach into ImportExportService's nesting.

  static let envelopeReference = """
{
  "septena_export_version": 1,
  "section": "tasks" | "training" | … | "all",
  "exported_at": "<ISO-8601>",
  "app_version": "<short> (<build>)",
  "tables": {
    "task":    [{ "id": …, "title": …, … }],
    "project": [...],
    …
  }
}
"""

  // MARK: Build

  @MainActor
  static func exportAll() throws -> Data {
    var tables: [String: [[String: Any]]] = [:]
    for key in exportableSectionKeys {
      let sectionTables = try collectTables(for: key)
      for (k, v) in sectionTables { tables[k] = v }
    }
    return try encode(section: "all", tables: tables)
  }

  @MainActor
  static func exportSection(_ key: String) throws -> Data {
    let tables = try collectTables(for: key)
    return try encode(section: key, tables: tables)
  }

  @MainActor
  private static func collectTables(for key: String) throws -> [String: [[String: Any]]] {
    let ctx = LocalStore.shared.container.mainContext
    guard let contribution = SectionRegistry.plugin(forKey: key)?.exportContribution else {
      throw ImportError.unsupportedSection(key)
    }
    return try contribution.collect(ctx)
  }

  // fetchAll helper retired — plugins do their own ctx.fetch calls
  // inside their exportContribution.collect closures.

  private static func encode(section: String,
                             tables: [String: [[String: Any]]]) throws -> Data {
    let envelope: [String: Any] = [
      "septena_export_version": importExportEnvelopeVersion,
      "section": section,
      "exported_at": ISO8601DateFormatter().string(from: .now),
      "app_version": appVersion(),
      "tables": tables,
    ]
    return try JSONSerialization.data(withJSONObject: envelope,
                                      options: [.prettyPrinted, .sortedKeys])
  }

  private static func appVersion() -> String {
    let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    return "\(v) (\(b))"
  }

  // MARK: Parse

  static func parseEnvelope(_ data: Data) throws -> ImportExportEnvelope {
    let raw: Any
    do {
      raw = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
      throw ImportError.notJSON
    }
    guard let dict = raw as? [String: Any],
          let version = dict["septena_export_version"] as? Int,
          let section = dict["section"] as? String,
          let tablesRaw = dict["tables"] as? [String: Any]
    else { throw ImportError.missingEnvelope }
    if version > importExportEnvelopeVersion {
      throw ImportError.unsupportedVersion(version)
    }
    var typed: [String: [[String: Any]]] = [:]
    for (table, rows) in tablesRaw {
      guard let rows = rows as? [[String: Any]] else {
        throw ImportError.malformed("Table '\(table)' is not an array of objects.")
      }
      typed[table] = rows
    }
    return ImportExportEnvelope(
      version: version,
      section: section,
      exportedAt: dict["exported_at"] as? String,
      appVersion: dict["app_version"] as? String,
      tables: typed
    )
  }

  // MARK: Apply
  //
  // v1 limits write-back to the simple, idempotent definition rows that
  // are pure upserts by id and have a `noteXChange(id:)` on `CKEngine`.
  // Event/log rows (nutrition entries, caffeine events, training entries,
  // etc.) route through dedicated mutators that handle recurrence,
  // summaries, and CK fan-out — those land in a follow-up. Unsupported
  // tables are counted toward `skipped` so the user sees what landed.

  struct ApplyResult {
    var applied: Int
    var skipped: Int
  }

  @MainActor
  static func apply(_ doc: ImportExportEnvelope) throws -> ApplyResult {
    let ctx = LocalStore.shared.container.mainContext
    let engine = SeptenaServices.shared.ckEngine
    var applied = 0
    var skipped = 0
    for (table, rows) in doc.tables {
      switch table {
      case "habitDefinition":
        for r in rows { try upsertHabitDefinition(r, ctx: ctx, engine: engine); applied += 1 }
      case "supplementDefinition":
        for r in rows { try upsertSupplementDefinition(r, ctx: ctx, engine: engine); applied += 1 }
      case "choreDefinition":
        for r in rows { try upsertChoreDefinition(r, ctx: ctx, engine: engine); applied += 1 }
      case "groceryCategory":
        for r in rows { try upsertGroceryCategory(r, ctx: ctx, engine: engine); applied += 1 }
      case "groceryItem":
        for r in rows { try upsertGroceryItem(r, ctx: ctx, engine: engine); applied += 1 }
      default:
        skipped += rows.count
      }
    }
    try ctx.save()
    return ApplyResult(applied: applied, skipped: skipped)
  }
}

// MARK: - Entity → dict mappers


// Internal (not private) so plugin export-contribution helpers in
// sibling files can reuse the same compaction + ISO-date primitives.
func isoDate(_ d: Date) -> String {
  ISO8601DateFormatter().string(from: d)
}

/// Strips nil values so the JSON stays compact and `JSONSerialization`
/// doesn't trip on `Any?`.
func compact(_ dict: [String: Any?]) -> [String: Any] {
  var out: [String: Any] = [:]
  for (k, v) in dict {
    guard let v else { continue }
    out[k] = v
  }
  return out
}

// MARK: - Upserts (definition tables only)

@MainActor
private func upsertHabitDefinition(_ r: [String: Any],
                                   ctx: ModelContext,
                                   engine: CKEngine) throws {
  guard let id = r["id"] as? String,
        let title = r["title"] as? String,
        let bucket = r["bucket"] as? String
  else { throw ImportExportService.ImportError.malformed("habitDefinition row missing id/title/bucket") }
  let existing = try ctx.fetch(FetchDescriptor<HabitDefinitionEntity>(
    predicate: #Predicate { $0.id == id })).first
  let e = existing ?? HabitDefinitionEntity(id: id, title: title, bucket: bucket)
  if existing == nil { ctx.insert(e) }
  e.title = title
  e.bucket = bucket
  e.emoji = r["emoji"] as? String
  e.sortIndex = r["sortIndex"] as? Int ?? 0
  e.updatedAt = .now
  engine.noteHabitDefinitionChange(id: id)
}

@MainActor
private func upsertSupplementDefinition(_ r: [String: Any],
                                        ctx: ModelContext,
                                        engine: CKEngine) throws {
  guard let id = r["id"] as? String, let title = r["title"] as? String
  else { throw ImportExportService.ImportError.malformed("supplementDefinition row missing id/title") }
  let existing = try ctx.fetch(FetchDescriptor<SupplementDefinitionEntity>(
    predicate: #Predicate { $0.id == id })).first
  let e = existing ?? SupplementDefinitionEntity(id: id, title: title)
  if existing == nil { ctx.insert(e) }
  e.title = title
  e.emoji = r["emoji"] as? String
  e.bucket = r["bucket"] as? String
  e.sortIndex = r["sortIndex"] as? Int ?? 0
  e.updatedAt = .now
  engine.noteSupplementDefinitionChange(id: id)
}

@MainActor
private func upsertChoreDefinition(_ r: [String: Any],
                                   ctx: ModelContext,
                                   engine: CKEngine) throws {
  guard let id = r["id"] as? String,
        let title = r["title"] as? String,
        let cadence = r["cadenceDays"] as? Int
  else { throw ImportExportService.ImportError.malformed("choreDefinition row missing id/title/cadenceDays") }
  let existing = try ctx.fetch(FetchDescriptor<ChoreDefinitionEntity>(
    predicate: #Predicate { $0.id == id })).first
  let e = existing ?? ChoreDefinitionEntity(id: id, title: title, cadenceDays: cadence)
  if existing == nil { ctx.insert(e) }
  e.title = title
  e.cadenceDays = cadence
  e.emoji = r["emoji"] as? String
  e.sortIndex = r["sortIndex"] as? Int ?? 0
  e.updatedAt = .now
  engine.noteChoreDefinitionChange(id: id)
}

@MainActor
private func upsertGroceryCategory(_ r: [String: Any],
                                   ctx: ModelContext,
                                   engine: CKEngine) throws {
  guard let id = r["id"] as? String, let name = r["name"] as? String
  else { throw ImportExportService.ImportError.malformed("groceryCategory row missing id/name") }
  let existing = try ctx.fetch(FetchDescriptor<GroceryCategoryEntity>(
    predicate: #Predicate { $0.id == id })).first
  let e = existing ?? GroceryCategoryEntity(id: id, name: name)
  if existing == nil { ctx.insert(e) }
  e.name = name
  e.sortIndex = r["sortIndex"] as? Int ?? 0
  e.updatedAt = .now
  engine.noteGroceryCategoryChange(id: id)
}

@MainActor
private func upsertGroceryItem(_ r: [String: Any],
                               ctx: ModelContext,
                               engine: CKEngine) throws {
  guard let id = r["id"] as? String,
        let name = r["name"] as? String,
        let category = r["category"] as? String
  else { throw ImportExportService.ImportError.malformed("groceryItem row missing id/name/category") }
  let existing = try ctx.fetch(FetchDescriptor<GroceryItemEntity>(
    predicate: #Predicate { $0.id == id })).first
  let e = existing ?? GroceryItemEntity(id: id, name: name, category: category)
  if existing == nil { ctx.insert(e) }
  e.name = name
  e.category = category
  e.emoji = r["emoji"] as? String ?? ""
  e.low = r["low"] as? Bool ?? false
  e.lastBought = r["lastBought"] as? String
  e.sortIndex = r["sortIndex"] as? Int ?? 0
  e.updatedAt = .now
  engine.noteGroceryItemChange(id: id)
}

// MARK: - Export schema types (top-level)
//
// Hoisted out of ImportExportService so plugin files can reference
// them when declaring per-section export contributions.

struct SchemaTable {
  let name: String
  let purpose: String
  let fields: [SchemaField]
}

struct SchemaField {
  let name: String
  let type: String
  let required: Bool
  let note: String?
  static func req(_ name: String, _ type: String, _ note: String? = nil) -> SchemaField {
    SchemaField(name: name, type: type, required: true, note: note)
  }
  static func opt(_ name: String, _ type: String, _ note: String? = nil) -> SchemaField {
    SchemaField(name: name, type: type, required: false, note: note)
  }
}

/// Per-section export contribution. A plugin returns this if it wants
/// to participate in Settings → Import & Export and the schema-prompt
/// generator. `tables` declares the JSON shape; `collect` returns a
/// freshly-built `[tableName: [row]]` dictionary for the user's data.
struct SectionExportContribution {
  let tables: [SchemaTable]
  let collect: @MainActor (ModelContext) throws -> [String: [[String: Any]]]
}
