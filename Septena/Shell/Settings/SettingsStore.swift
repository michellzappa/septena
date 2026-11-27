import SwiftUI
import SwiftData

// The settings mirror cache — extracted from SettingsView.swift so both
// shells compile it (Septask injects it for the profile name
// and What's New; docs/SEPTASK.md). No view types referenced.

// MARK: - Store
//
// One Observable holding the in-memory view of the user's settings,
// hydrated from the synced-settings blob via SettingsMirror. Local prefs continue to live as @AppStorage
// at use sites — they're already shared through the SettingsKey constants
// and don't need wrapping.

@MainActor
@Observable
final class SettingsStore {
  var serverSettings: AppSettings? = nil
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
  /// first frame uses the user's saved settings.
  init() {
    paintFromCache()
    // Septask's settings arrive with the task-backend pull, not a CloudKit
    // batch: reload, then copy the synced values into the device-local
    // mirrors the views read. Inbound only (`engine: nil` pushes nothing).
    settingsPulledObserver = NotificationCenter.default.addObserver(
      forName: .septaskSettingsPulled, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        let context = LocalStore.shared.container.mainContext
        self.reloadFromMirror(context: context)
        self.reconcileWelcomeName(context: context, engine: nil)
        self.reconcileHiddenCalendars(context: context, engine: nil)
        SettingsMirror.reconcileFadeEnabled(publish: false)
      }
    }
  }

  @ObservationIgnored private var settingsPulledObserver: NSObjectProtocol?

  private enum CacheKey {
    static let serverSettings = "settings.serverSettings"
  }

  /// Synchronous read of the last-known settings, at app launch.
  func paintFromCache() {
    let context = LocalStore.shared.container.mainContext
    if let v = SettingsMirror.loadSettings(context: context) {
      serverSettings = v
    } else if let v = ResponseCache.load(AppSettings.self, forKey: CacheKey.serverSettings) {
      serverSettings = v
    }
    // Adopt a synced welcome name cached in the local mirror so the
    // first frame's greeting is right. No engine here (init context), so the
    // local→cloud migration leg is deferred to the launch reconcile.
    reconcileWelcomeName(context: context, engine: nil)
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

  /// Reload settings from the local mirror. Called after every pull and on
  /// `.septenaDataChanged`.
  func reloadFromMirror(context: ModelContext) {
    if let v = SettingsMirror.loadSettings(context: context) {
      serverSettings = v
      ResponseCache.save(v, forKey: CacheKey.serverSettings)
    }
  }

  /// Update the synced welcome name and push it to CloudKit, and to the
  /// task backend. The local `welcomeName` @AppStorage key
  /// (read by `WelcomeHeader`) is written at the edit site, so both the
  /// synced payload and the local mirror stay in lockstep.
  func setWelcomeName(_ name: String, context: ModelContext, engine: CKEngine?) {
    guard (serverSettings?.welcomeName ?? "") != name else { return }
    var s = serverSettings ?? AppSettings()
    s.welcomeName = name
    serverSettings = s
    SettingsMirror.upsert(settings: s, context: context, engine: engine)
  }

  /// "Pause all agents". Synced account-wide; the task backend enforces it.
  var agentsPaused: Bool { serverSettings?.agentsPaused == true }

  func setAgentsPaused(_ paused: Bool, context: ModelContext, engine: CKEngine?) {
    guard agentsPaused != paused else { return }
    var s = serverSettings ?? AppSettings()
    s.agentsPaused = paused
    serverSettings = s
    SettingsMirror.upsert(settings: s, context: context, engine: engine)
  }

  /// Global agent comment notification mode (#743–#745). Synced account-wide.
  var agentCommentNotifications: String {
    serverSettings?.agentCommentNotifications ?? RegistrySettings.Defaults.agentCommentNotifications
  }

  func setAgentCommentNotifications(_ mode: String, context: ModelContext, engine: CKEngine?) {
    guard agentCommentNotifications != mode else { return }
    var s = serverSettings ?? AppSettings()
    s.agentCommentNotifications = mode
    serverSettings = s
    SettingsMirror.upsert(settings: s, context: context, engine: engine)
  }

  /// Per-agent notification override keyed by display name; nil means use the global default.
  func agentNotificationOverride(for agentName: String) -> String? {
    serverSettings?.agentCommentNotificationsByAgent?[agentName]
  }

  func setAgentNotificationOverride(_ mode: String?, for agentName: String,
                                    context: ModelContext, engine: CKEngine?) {
    var overrides = serverSettings?.agentCommentNotificationsByAgent ?? [:]
    let next = mode?.isEmpty == true ? nil : mode
    guard overrides[agentName] != next else { return }
    if let next {
      overrides[agentName] = next
    } else {
      overrides.removeValue(forKey: agentName)
    }
    var s = serverSettings ?? AppSettings()
    s.agentCommentNotificationsByAgent = overrides
    serverSettings = s
    SettingsMirror.upsert(settings: s, context: context, engine: engine)
  }

  /// Show or hide one calendar (by `EKCalendar.title`) from the day timeline /
  /// Next feed. Writes `CalendarBridge`'s local cache (the authority EventKit
  /// fetches filter on) AND the CloudKit-synced `calendarHiddenTitles` payload,
  /// so the selection follows the user across devices. Mirrors the
  /// `setWelcomeName` write shape.
  func setCalendarHidden(_ hidden: Bool, title: String,
                         context: ModelContext, engine: CKEngine?) {
    var titles = CalendarBridge.shared.hiddenCalendarTitles
    if hidden { titles.insert(title) } else { titles.remove(title) }
    let sorted = titles.sorted()
    guard serverSettings?.calendarHiddenTitles != sorted else { return }
    CalendarBridge.shared.hiddenCalendarTitles = titles
    var s = serverSettings ?? AppSettings()
    s.calendarHiddenTitles = sorted
    serverSettings = s
    SettingsMirror.upsert(settings: s, context: context, engine: engine)
  }

  /// Reconcile the synced hidden-calendar selection with `CalendarBridge`'s
  /// local cache. Same inbound/outbound shape as `reconcileWelcomeName`:
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
    var s = serverSettings ?? AppSettings()
    s.calendarHiddenTitles = local.sorted()
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
    var s = serverSettings ?? AppSettings()
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

  func refresh(today: String) async {
    serverLoading = true
    defer { serverLoading = false }
    let context = LocalStore.shared.container.mainContext

    reloadFromMirror(context: context)
  }
}
