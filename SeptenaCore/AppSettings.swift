import Foundation

// MARK: - Settings
//
// Mirror of the webapp's AppSettings shape but trimmed to the fields the
// iOS client actually reads today. Anything we don't decode just gets
// ignored — the server stays authoritative; we don't round-trip writes
// for sections we haven't built UIs for yet.

struct AppTimeSettings: Codable, Hashable {
  let homeTimezone: String
  let travelMode: String?
  let travelTimezone: String?

  enum CodingKeys: String, CodingKey {
    case homeTimezone   = "home_timezone"
    case travelMode     = "travel_mode"
    case travelTimezone = "travel_timezone"
  }
}

struct AppSettings: Codable {
  var time: AppTimeSettings?
  /// The user's name, for the greeting. Synced so the user's name
  /// follows them across their own devices; also mirrored into the
  /// `welcomeName` @AppStorage key that `WelcomeHeader` reads locally.
  /// Defaulted so the existing memberwise-init call sites stay source-stable.
  var welcomeName: String? = nil

  /// The day the "N rolled into today" banner was last dismissed, as an ISO
  /// `yyyy-MM-dd` string. Synced because the banner reports one fact about the
  /// ACCOUNT ("these tasks rolled over"), not about a device — dismissing it on
  /// the Mac and meeting it again on the phone is the same notice twice. The
  /// device-local `septena.newTodos.dismissedDate` UserDefaults key stays as
  /// the instant, offline-safe mirror; reads take the LATER of the two so a
  /// stale synced value can never un-dismiss today's banner. Nil → never
  /// dismissed. Defaulted so the existing memberwise-init call sites stay
  /// source-stable.
  var rolledInDismissedOn: String? = nil

  /// "Pause all agents" (docs/TASK_FACTORY_SPEC.md §10). While true the task
  /// backend refuses every agent claim. Account-wide, so a pause on one device
  /// holds on all of them. Nil → not paused.
  var agentsPaused: Bool? = nil

  /// "Get started" checklist (Septask): true once dismissed or every step is
  /// complete, synced so finishing onboarding on one device hides it on all
  /// other devices too. Nil → not dismissed.
  var getStartedDismissed: Bool? = nil

  /// "Get started" checklist steps completed (raw `TaskNoticeStep.ID` values),
  /// synced across devices so progress carries over. Nil → none recorded.
  var getStartedSteps: [String]? = nil

  /// Upsell moments (`registry/plans.json` `upsells` ids) this account has
  /// seen. Each one shows once per account; synced so a second device does
  /// not repeat it (docs/SYNC_SUBSCRIPTION_SPEC.md §7.1). Nil → none seen.
  var upsellsSeen: [String]? = nil

  /// Appearance customization (ADR 0019 / docs/CUSTOMIZATION_SPEC.md). Synced
  /// across devices when device-local `syncTheme` is enabled.
  var accentColor: String? = nil
  var canvasTexture: String? = nil
  var textureIntensity: Int? = nil
  var textureMotion: String? = nil

  /// Per-account special smart-list sidebar customization (registry/destinations.json).
  /// `smartListOrder` is ORDERING ONLY (never membership): any registry
  /// destination absent from here appends in canonical `sidebarOrder`.
  /// `smartListHidden` lists canonical destination IDs explicitly hidden by the
  /// user (destinations with `canHide == false`, e.g. `today`, are never hidden).
  var smartListOrder: [String]? = nil
  var smartListHidden: [String]? = nil
  /// Optional per-destination placement override ("top" | "bottom") keyed by
  /// canonical destination ID. Absent IDs fall back to `registry/destinations.json`.
  var smartListPlacement: [String: String]? = nil

  /// When the first-run welcome (section picker + chained onboarding) was
  /// completed. The durable, cross-device "this account has been welcomed"
  /// marker: synced so a returning user's *new* device never re-shows the
  /// welcome once their data syncs in. Mirrored into the device-local
  /// `SettingsKey.welcomeCompleted` @AppStorage key that the welcome gate
  /// reads for an instant, offline-safe decision. Nil → not yet onboarded.
  /// Defaulted so the existing memberwise-init call sites stay source-stable.
  var onboardedAt: Date? = nil

  /// Graded analytics privacy level (`TelemetryClient.TelemetryLevel` raw value:
  /// "none" | "minimal" | "balanced" | "full"). Synced so the user's privacy
  /// choice follows them across their own devices; also mirrored into the
  /// `septena.privacy.telemetryLevel` @AppStorage key that `TelemetryClient`
  /// reads synchronously to gate what it sends. Nil → not yet chosen (the
  /// device falls back to its local mirror / legacy flag / `.balanced` default).
  /// Defaulted so existing settings payloads decode cleanly. See [[project_versioning_changelog]].
  var telemetryLevel: String? = nil

  /// Calendars the user has hidden from the day timeline / Next feed, stored by
  /// `EKCalendar.title` (NOT `calendarIdentifier`, which EventKit assigns
  /// per-store and is not stable across devices — see [[project_tasks_calendar_events]]).
  /// Title-based matching is what makes "set it up once, applies everywhere"
  /// work: the same iCloud calendar resolves by name on every device. Synced so
  /// the selection follows the user; mirrored into `CalendarBridge`'s local
  /// UserDefaults cache (the offline-safe authority EventKit fetches filter on).
  /// Nil → nothing hidden yet. Defaulted so existing payloads decode cleanly.
  var calendarHiddenTitles: [String]? = nil

  // Every field needs a case. A defaulted property without one compiles, but
  // the synced blob drops it (#434). `SyncedSettingsTests` checks the keys.
  enum CodingKeys: String, CodingKey {
    case time
    case welcomeName = "welcome_name"
    case rolledInDismissedOn = "rolled_in_dismissed_on"
    case agentsPaused = "agents_paused"
    case getStartedDismissed = "get_started_dismissed"
    case getStartedSteps = "get_started_steps"
    case upsellsSeen = "upsells_seen"
    case onboardedAt = "onboarded_at"
    case telemetryLevel = "telemetry_level"
    case calendarHiddenTitles = "calendar_hidden_titles"
    case accentColor = "accent_color"
    case canvasTexture = "canvas_texture"
    case textureIntensity = "texture_intensity"
    case textureMotion = "texture_motion"
    case smartListOrder = "smart_list_order"
    case smartListHidden = "smart_list_hidden"
    case smartListPlacement = "smart_list_placement"
  }
}
