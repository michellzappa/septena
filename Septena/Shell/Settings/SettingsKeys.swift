// Device-local settings keys (@AppStorage / UserDefaults). Extracted from
// SettingsView.swift so shells that don't compile the full Settings surface
// (Septask) can still read the shared keys — see docs/SEPTASK.md.

import Foundation

// MARK: - Default keys

enum SettingsKey {
  static let badgeShowOverdue = "septena.badge.showOverdue"
  /// Master switch for local-notification nudges. Same string as
  /// `LocalNotificationScheduler.masterKey`. Absent → on (granting the
  /// permission prompt is the opt-in); flipping it off withdraws every
  /// pending nudge on the next reconcile.
  static let notificationsEnabled = "septena.notify.enabled"
  static let todayShowCompleted = "septena.today.showCompleted"
  /// Whether Today groups open tasks under area / project headers. Absent → on
  /// (grouped). Off → a single flat list under Inbox with list name as each
  /// row's subtitle, sorted by due urgency (`SeptenaTask.compareNextPageOrder`).
  /// Read by `TaskListView` and `TasksDestinationView`.
  static let todayGroupByList = "septena.today.groupByList"
  /// Whether the AppKit shell's sidebar shows its trailing count badges.
  /// Absent → on. Currently read only by `SeptaskKitSidebarController`
  /// (View ▸ Show Sidebar Counts) — kept in the shared registry rather than
  /// local to that file on the chance the SwiftUI sidebar wants the same
  /// toggle later.
  static let septaskSidebarCounts = "septena.septask.sidebarCounts"
  /// `Node.key`s of the AppKit sidebar's folded-shut areas (a `[String]`).
  /// Device-local view state, deliberately not synced — which areas you keep
  /// open is a per-window habit, not account data. NSOutlineView tracks
  /// expansion by item identity and the sidebar rebuilds its nodes on every
  /// data change, so this is what makes a fold survive the next refresh.
  static let septaskSidebarCollapsed = "septena.septask.sidebarCollapsed"
  /// Device-local mirror of whether the AppKit shell's inspector pane is open.
  /// The pane itself is an `NSSplitViewItem`, which a SwiftUI `Commands` body
  /// cannot observe — so `SeptaskKitWindowController` writes this on every
  /// open and close and View ▸ Show/Hide Info titles itself from it. The
  /// window always builds with the pane collapsed and resets this to false,
  /// so it never survives a launch as a stale `true`.
  static let septaskInspectorVisible = "septena.septask.inspectorVisible"
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
  /// Legacy on/off consent toggle for anonymous aggregate usage telemetry,
  /// superseded by the graded `telemetryLevel`. Still defined because
  /// `TelemetryClient.currentLevel()` honors a pre-levels value once, on upgrade.
  static let shareUsageData   = "septena.privacy.shareUsageData"
  /// Device-local mirror of `AppSettings.telemetryLevel` (a
  /// `TelemetryClient.TelemetryLevel` raw value). Same key string as
  /// `TelemetryClient.levelKey` so the actor's synchronous gating read and the
  /// Privacy pane's `@AppStorage` binding stay in lockstep; kept in sync with
  /// the CloudKit-synced payload by `SettingsStore.reconcileTelemetryLevel`.
  static let telemetryLevel   = TelemetryClient.levelKey
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
  /// Whether open Today tasks deepen their checkbox tint the longer they sit
  /// on Today undone (`SeptenaTask.todayTenureFill` → `TaskCheckbox.tenureFill`).
  /// Absent → on. Read by `TaskCheckboxModel`.
  static let tasksShowAging = "septena.tasks.showAging"
  /// Whether the on-device classifier suggests where to file inbox tasks
  /// (`SuggestionEngine` → inbox chips, context-menu "Move to…", composer
  /// "Suggested list" chip). Absent → on. Read by `TaskListView` / composer.
  static let tasksFilingSuggestions = "septena.tasks.filingSuggestions"
  /// Tasks sidebar column visibility on push-navigation surfaces (iPad
  /// regular / macOS). Persisted locally so ⌘/ and the system sidebar
  /// controls survive relaunch. Raw values: `all`, `detailOnly`.
  static let tasksSidebarVisibility = "septena.tasks.sidebarVisibility"
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
  /// Whole-app privacy lock: require Face ID / Touch ID / device passcode to
  /// reopen Septena after it's been backgrounded past the grace window.
  /// Local-only @AppStorage — the lock is a per-device privacy gate, not
  /// synced account data (each device opts in on its own). Read by `AppLock`.
  static let appLockEnabled      = "septena.security.appLock"
  /// Seconds the app may sit backgrounded before the lock re-arms. 0 =
  /// immediately. Absent → 60. Read by `AppLock`.
  static let appLockGraceSeconds = "septena.security.appLockGrace"
  /// App-wide text-size step, a signed `TextSizeStep` raw value (−2…+2).
  /// Offsets the OS Dynamic Type setting rather than replacing it (see
  /// `TextSizeScale.swift`). Absent → 0 → text follows the system size
  /// unchanged. Device-local, like the other display preferences; read by the
  /// `.septenaTextSize()` root modifier in both app targets.
  static let textSizeStep = "septena.display.textSizeStep"
}
