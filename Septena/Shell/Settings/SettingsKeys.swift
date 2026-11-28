// Device-local settings keys (@AppStorage / UserDefaults). Extracted from
// SettingsView.swift so shells that don't compile the full Settings surface
// (Septena) can still read the shared keys — see docs/SEPTASK.md.

import Foundation

// MARK: - Default keys

enum SettingsKey {
  static let badgeShowOverdue = RegistrySettings.StorageKey.badgeShowOverdue
  static let todayShowCompleted = RegistrySettings.StorageKey.todayShowCompleted
  /// Whether Today groups open tasks under area / project headers. Absent → on
  /// (grouped). Off → a single flat list under Inbox with list name as each
  /// row's subtitle, sorted by due urgency (`SeptenaTask.compareNextPageOrder`).
  /// Read by `TaskListView` and `TasksDestinationView`.
  static let todayGroupByList = RegistrySettings.StorageKey.todayGroupByList
  /// Whether the AppKit shell's sidebar shows its trailing count badges.
  /// Absent → on. Currently read only by `SeptaskKitSidebarController`
  /// (View ▸ Show Sidebar Counts) — kept in the shared registry rather than
  /// local to that file on the chance the SwiftUI sidebar wants the same
  /// toggle later.
  static let septaskSidebarCounts = RegistrySettings.StorageKey.sidebarCounts
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
  /// Where tasks, areas, projects, attachments and conversations sync on this
  /// device: `cloudkit` (absent) or `backend` (api.septena.app). Stored in the
  /// shared app-group defaults (`SeptenaAppGroup.defaults`), not `.standard`:
  /// Septena Life and Septena share one SwiftData store, so Septena Life must see the
  /// value to freeze the CloudKit task types. Only Septena writes it: it
  /// writes `backend` at every launch (`TaskStoreMode.markDeviceBackend`),
  /// since Septena is backend-only. Septena itself never reads it. See
  /// `TaskStoreMode`.
  static let taskStoreMode = "septena.taskStore.mode"
  /// Device-local dev override: forces the welcome to present even on an
  /// established account, surviving relaunch, so the first-run flow can be
  /// re-tested without wiping the app. Set by Settings ▸ About ▸ Advanced
  /// ("Reset first-run welcome"); cleared when the welcome is completed.
  /// Never set in normal use, so the gate behaves exactly as before.
  static let welcomeForce = "septena.welcome.force"
  /// Optional first name used to personalise the homepage welcome greeting.
  /// Local-only (@AppStorage); not synced to CloudKit.
  static let welcomeName = RegistrySettings.StorageKey.welcomeName
  /// Whether the Tasks lists weave in the day's calendar events — the day's
  /// agenda at the top of Today and under each Upcoming day, Things-style.
  /// Absent → on (events only ever show once calendar access is granted in
  /// Settings → Integrations, so the default can't surprise-prompt). Read by
  /// `TaskListView`.
  static let tasksShowCalendarEvents = RegistrySettings.StorageKey.tasksShowCalendarEvents
  /// Whether open Today tasks fade the longer they sit on Today undone
  /// (`SeptenaTask.todayTenureFill` → `TaskFade.rowOpacity`).
  /// Absent → on. Read by `TaskCheckboxModel`.
  static let tasksShowAging = RegistrySettings.StorageKey.tasksShowAging
  /// Whether faded tasks appear as a collapsible faded section inside
  /// projects and areas. Absent → on. Read by `TaskListView` and
  /// `SeptaskKitTaskListController`.
  static let tasksShowFaded = RegistrySettings.StorageKey.tasksShowFaded
  /// How many lines a task row's title may occupy before it truncates, on
  /// iPhone / iPad. 1 = the old single line, 2 = the default, 3 = long titles
  /// stay readable at the cost of taller rows. Absent → 2. Read by `TaskRow`.
  /// iOS only: the AppKit rows are a fixed-height table (`SeptaskKitTheme.rowHeight`)
  /// where titles truncate by design.
  static let tasksTitleLines = RegistrySettings.StorageKey.tasksTitleLines
  /// Whether the on-device classifier suggests where to file inbox tasks
  /// (`SuggestionEngine` → inbox chips, context-menu "Move to…", composer
  /// "Suggested list" chip). Absent → on. Read by `TaskListView` / composer.
  static let tasksFilingSuggestions = RegistrySettings.StorageKey.tasksFilingSuggestions
  /// Tasks sidebar column visibility on push-navigation surfaces (iPad
  /// regular / macOS). Persisted locally so ⌘/ and the system sidebar
  /// controls survive relaunch. Raw values: `all`, `detailOnly`.
  static let tasksSidebarVisibility = "septena.tasks.sidebarVisibility"
  /// Master switch for the per-log "commit flourish" animations (the
  /// `CommitMotion` / `LogCommitOverlay` celebrations that play when you log
  /// something). Absent → on. Off suppresses every logging animation
  /// app-wide; the commit haptic + VoiceOver confirmation still fire, exactly
  /// like Reduce Motion. Read by `CommitFlourish` and `LogCommitOverlay`.
  static let loggingAnimationsEnabled = RegistrySettings.StorageKey.loggingAnimationsEnabled
  /// Toggle for the Inbox zero header animation on Today
  /// (`docs/INBOX_ZERO_MOTION_SPEC.md`, #298). Device-local, default on.
  /// Independent of `loggingAnimationsEnabled`: off stops the header symbol
  /// effects and the extra haptic while keeping the VoiceOver announcement.
  static let inboxZeroMotionEnabled = RegistrySettings.StorageKey.inboxZeroMotionEnabled
  /// Whether the user is a paying *supporter*. The whole app is free — this
  /// flag unlocks NOTHING functional; it only drives cosmetics (the avatar
  /// foil ring and the "Supporter" badge). It's a local @AppStorage *mirror*
  /// of the real StoreKit entitlement: `SupportStore` recomputes ownership
  /// from `Transaction.currentEntitlements` and writes it here, so every
  /// cosmetic reader stays truth-backed without knowing about StoreKit. (Key
  /// string kept for continuity with existing installs.)
  static let plusUnlocked     = "septena.plus.unlocked"
  /// Whole-app privacy lock: require Face ID / Touch ID / device passcode to
  /// reopen Septena after it's been backgrounded past the grace window.
  /// Local-only @AppStorage — the lock is a per-device privacy gate, not
  /// synced account data (each device opts in on its own). Read by `AppLock`.
  static let appLockEnabled      = "septena.security.appLock"
  /// App-wide text-size step, a signed `TextSizeStep` raw value (−2…+2).
  /// Offsets the OS Dynamic Type setting rather than replacing it (see
  /// `TextSizeScale.swift`). Absent → 0 → text follows the system size
  /// unchanged. Device-local, like the other display preferences; read by the
  /// `.septenaTextSize()` root modifier in both app targets.
  static let textSizeStep = RegistrySettings.StorageKey.textSizeStep
}
