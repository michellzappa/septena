// GENERATED FILE — DO NOT EDIT BY HAND.
// Sources: registry/{entities,rules,icons,tokens,capabilities,settings,destinations,actions,surfaces,plans}.json
// Regenerate: node scripts/gen-registries.mjs

import Foundation

/// Registry copy lookup (ADR 0020). The key is the English text, so the
/// string catalog's translations apply. `registry/l10n/<lang>.json` holds
/// the translations; the generator writes them into `Localizable.xcstrings`.
enum RegistryL10n {
  private static let missing = "\u{1}registry-l10n-missing"

  /// The localized text for `key`, or `english` when no table has it.
  static func t(_ key: String, english: String? = nil) -> String {
    let value = Bundle.main.localizedString(forKey: key, value: missing, table: nil)
    return value == missing ? (english ?? key) : value
  }

  /// A template with `%@` / `%lld` placeholders.
  static func format(_ key: String, english: String, args: [CVarArg]) -> String {
    String(format: t(key, english: english), locale: Locale.current, arguments: args)
  }

  /// A plural template. The catalog's plural variations pick the form; with
  /// no table, English `one` / `other` stands in.
  static func plural(_ key: String, count: Int, one: String?, other: String, args: [CVarArg]) -> String {
    let value = Bundle.main.localizedString(forKey: key, value: missing, table: nil)
    let fmt = value == missing ? (count == 1 ? (one ?? other) : other) : value
    return String(format: fmt, locale: Locale.current, arguments: args)
  }
}

/// Wire schema size and count limits shared with the backend (`registry/entities.json`).
enum RegistryEntityLimits {
  static let textMax: Int = 2000
  static let notesMax: Int = 100000
  static let stampMax: Int = 40
  static let maxAttachmentBytes: Int64 = 26214400
  static let maxOpsPerPush: Int = 500
  static let maxPull: Int = 1000
  static let maxChecklistItemsPerTask: Int = 200
  static let maxTagsPerTask: Int = 20
  static let tagNameMax: Int = 64
  static let maxSubtasks: Int = 500
  static let maxArtifactRefs: Int = 100
  static let turnProviderMax: Int = 32
  static let turnQuestionMax: Int = 10000
  static let turnOptionMax: Int = 500
  static let turnMaxOptions: Int = 20
  static let turnChosenMax: Int = 500
  static let turnOtherTextMax: Int = 10000
  static let turnNoteMax: Int = 100000
}

/// Wire schema regex strings shared with the backend (`registry/entities.json`).
enum RegistryEntityPatterns {
  static let id = "^[A-Za-z0-9._:-]{1,128}$"
  static let clientOpId = "^[A-Za-z0-9_-]{8,64}$"
  static let day = "^\\d{4}-\\d{2}-\\d{2}$"
  static let stamp = "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}"
}

/// Canonical enum wire strings shared with the backend (`registry/entities.json`).
enum RegistryEntityEnums {
  static let taskStatus: [String] = ["open", "done", "cancelled"]
  static let taskSource: [String] = ["app", "mcp"]
  static let projectStatus: [String] = ["active", "done", "cancelled"]
  static let taskKind: [String] = ["heading"]
  static let recurrenceUnit: [String] = ["day", "week", "month", "year"]
  static let reminderMode: [String] = ["floating", "fixed"]
  static let convoAssignee: [String] = ["me", "local", "claude"]
  static let convoEndState: [String] = ["agent_done", "human_done", "agent_assisted_done", "needs_verify", "decomposed", "reminder_set", "promoted_to_today", "wont_do", "open"]
  static let convoHandoffActionType: [String] = ["open_url", "compose", "call", "none"]
  static let convoTurnRole: [String] = ["user", "provider"]
  static let convoTurnStep: [String] = ["confirm", "ground", "scope", "decide", "work"]
  static let telemetryLevel: [String] = ["none", "minimal", "balanced", "full"]
  static let appearanceMode: [String] = ["system", "light", "dark"]
  static let accentColor: [String] = ["colorful", "tamarillo", "persimmon", "yuzu", "carambola", "acai", "pitaya", "jabuticaba"]
  static let appIconFinish: [String] = ["obsidian", "ceramic", "framed"]
  static let appIconColor: [String] = ["auto", "persimmon", "haskap", "tamarillo", "yuzu", "carambola", "acai", "pitaya", "mono"]
  static let canvasTexture: [String] = ["none", "topography", "fieldMatrix", "stippleDrift", "causticGlass", "ridges", "washiPaper"]
  static let textureMotion: [String] = ["still", "slowDrift"]
  static let entityNames: [String] = ["task", "area", "project", "attachment", "checklistItem", "tag", "convo", "setting"]
  static let deletableEntities: [String] = ["task", "area", "project", "attachment", "checklistItem", "tag"]
}

/// Canonical conversation turn fields shared with the backend (`registry/entities.json`).
enum RegistryTurnFields {
  static let all: Set<String> = ["role", "step", "provider", "confidence", "question", "options", "chosen", "otherText", "inReplyTo", "note", "ts"]
}

/// Domain thresholds and retention constants shared across platforms (`registry/rules.json`).
enum RegistryRules {
  static let cueDecayDays: Int = 7
  static let fadeWindowDays: Int = 14
  static let fadeGraceDays: Int = 1
  static let fadeMinOpacity: Double = 0.55
  static let fadeSweepWeekday: Int = 1
  static let recentlyDeletedDays: Int = 30
  static let upcomingCalendarDays: Int = 30
  static let toastDurationSeconds: Int = 7
  static let deleteGraceSeconds: Int = 120
}

/// Semantic icon ID → SF Symbol lookup (`registry/icons.json`).
enum RegistryIcons {
  static let sfSymbols: [String: String] = [
    "onboarding.welcome": "sparkles",
    "onboarding.devices": "laptopcomputer.and.iphone",
    "onboarding.agent": "bubble.left.and.text.bubble.right",
    "onboarding.notes": "note.text",
    "onboarding.account": "person.crop.circle",
    "onboarding.move_in": "tray.and.arrow.down",
    "onboarding.things": "checkmark.square",
    "onboarding.fresh": "plus.circle",
    "onboarding.done": "checkmark.circle.fill",
    "list.today": "sun.max.fill",
    "list.inbox": "tray.full",
    "list.review": "eye",
    "list.agent": "sparkles",
    "agent.queued": "clock",
    "agent.working": "ellipsis.circle",
    "agent.your_turn": "questionmark.bubble",
    "agent.done": "checkmark.circle",
    "list.upcoming": "calendar",
    "list.repeating": "arrow.clockwise",
    "list.anytime": "rectangle.stack.fill",
    "list.logbook": "checkmark",
    "list.faded": "circle.dashed",
    "list.starred": "star.fill",
    "list.recently_deleted": "trash",
    "place.area": "folder",
    "place.project": "number",
    "place.section": "text.alignleft",
    "action.edit_details": "info.circle",
    "action.rename": "pencil",
    "action.copy": "doc.on.doc",
    "action.paste": "doc.on.clipboard",
    "action.duplicate": "plus.square.on.square",
    "action.complete": "checkmark.circle",
    "action.cancel": "xmark.circle",
    "action.delete": "trash",
    "action.let_go": "wind",
    "action.restore": "arrow.uturn.backward",
    "action.today_add": "sun.max.fill",
    "action.today_remove": "sun.min",
    "action.schedule": "calendar",
    "action.when": "calendar",
    "action.deadline": "flag",
    "action.clear_schedule": "calendar.badge.minus",
    "action.move": "folder",
    "action.more": "ellipsis",
    "action.repeat": "arrow.clockwise",
    "action.repeat_pause": "pause.circle",
    "action.repeat_resume": "play.circle",
    "action.repeat_next_copy": "plus.circle",
    "action.move_section": "text.append",
    "action.move_up": "chevron.up",
    "action.move_down": "chevron.down",
    "action.add": "plus",
    "action.search": "magnifyingglass",
    "action.sidebar": "sidebar.leading",
    "action.notes": "text.alignleft",
    "action.discuss": "bubble.left.and.bubble.right",
    "action.attachment": "paperclip",
    "action.checklist": "checklist",
    "action.tag": "tag",
    "action.reminder": "bell",
    "action.star": "star",
    "settings.account": "person.crop.circle",
    "settings.sign_in_approval": "person.badge.key",
    "auth.device": "laptopcomputer.and.iphone",
    "settings.general": "slider.horizontal.3",
    "settings.tasks": "checklist",
    "settings.ai_agents": "sparkles",
    "settings.claude": "bubble.left.and.text.bubble.right",
    "settings.connections_ai": "brain.head.profile",
    "settings.connections": "link",
    "settings.data": "square.and.arrow.up",
    "settings.privacy": "hand.raised",
    "settings.about": "info.circle",
    "settings.advanced": "wrench.and.screwdriver",
    "settings.skills": "book.closed",
    "settings.diagnostics": "stethoscope",
    "settings.appearance": "paintpalette",
    "settings.calendar": "calendar",
    "settings.reminders": "checklist",
    "settings.import": "square.and.arrow.down",
    "settings.backend": "arrow.up.doc",
    "settings.animations": "party.popper",
    "settings.feedback": "paperplane",
    "settings.paste": "doc.on.clipboard",
    "settings.companion_app": "arrow.up.forward.app",
    "settings.plus": "plus.circle.fill",
    "plans.free": "iphone",
    "plans.history": "clock.arrow.circlepath",
    "notice.sign_in": "person.crop.circle.badge.exclamationmark",
    "notice.rolled_in": "arrow.down.circle",
    "notice.get_started": "sparkles",
    "notice.fade_intro": "circle.lefthalf.filled",
    "convo.needs_you": "circle.fill",
    "convo.working": "circle.fill",
    "convo.done": "checkmark.circle.fill",
    "convo.wont_do": "minus.circle",
    "notice.weekly_sweep": "circle.dashed",
    "action.text_size": "textformat.size",
    "action.window": "macwindow",
    "action.sidebar_counts": "number",
  ]

  static func sfSymbol(for id: String) -> String {
    sfSymbols[id] ?? "circle"
  }
}

/// Exotic-fruit app accent descriptor (`registry/tokens.json`, ADR 0019).
struct RegistryFruitAccent: Sendable, Hashable, Identifiable {
  let id: String
  let name: String
  let origin: String
  let lightHex: String
  let darkHex: String
  let checkLightHex: String
  let checkDarkHex: String
  let multicolor: Bool
}

/// Procedural header-wash texture descriptor (`registry/tokens.json`, ADR 0019).
struct RegistryTextureOption: Sendable, Hashable, Identifiable {
  let id: String
  let name: String
  let tag: String
}

/// Shared numeric and palette design tokens (`registry/tokens.json`).
enum RegistryTokens {
  enum Selection {
    static let emphasizedAlphaLight: Double = 0.22
    static let emphasizedAlphaDark: Double = 0.34
    static let unemphasizedAlphaLight: Double = 0.1
    static let unemphasizedAlphaDark: Double = 0.14
    static let chipSelectedFillOpacity: Double = 0.22
    static let pointerHoverOpacity: Double = 0.012
  }
  enum Radii {
    static let card: Double = 22
    static let small: Double = 6
    static let transientSurface: Double = 12
  }
  enum Spacing {
    static let xs: Double = 4
    static let sm: Double = 8
    static let md: Double = 12
    static let lg: Double = 16
    static let pageGutter: Double = 20
    static let pageTop: Double = 12
  }
  enum DesktopColumn {
    static let marginFraction: Double = 0.1
    static let minInset: Double = 10
    static let maxInset: Double = 220
    static let verticalInset: Double = 48
    static let titleBarGap: Double = 20
  }
  static let accentPalette: [String] = ["#ef4444", "#f97316", "#f59e0b", "#eab308", "#84cc16", "#22c55e", "#10b981", "#14b8a6", "#06b6d4", "#0ea5e9", "#3b82f6", "#6366f1", "#8b5cf6", "#a855f7", "#ec4899", "#f43f5e"]
  static let fruitAccents: [RegistryFruitAccent] = [
    RegistryFruitAccent(id: "colorful", name: RegistryL10n.t("Colorful"), origin: "Default · Blue + semantic", lightHex: "#007AFF", darkHex: "#0A84FF", checkLightHex: "#FFFFFF", checkDarkHex: "#FFFFFF", multicolor: true),
    RegistryFruitAccent(id: "tamarillo", name: RegistryL10n.t("Tamarillo"), origin: "Andes · Crimson", lightHex: "#D6333F", darkHex: "#FF5C67", checkLightHex: "#FFFFFF", checkDarkHex: "#FFFFFF", multicolor: false),
    RegistryFruitAccent(id: "persimmon", name: RegistryL10n.t("Persimmon"), origin: "East Asia · Vermilion", lightHex: "#E05212", darkHex: "#FF7738", checkLightHex: "#FFFFFF", checkDarkHex: "#FFFFFF", multicolor: false),
    RegistryFruitAccent(id: "yuzu", name: RegistryL10n.t("Yuzu"), origin: "Japan · Citrus gold", lightHex: "#C28500", darkHex: "#F2BF2C", checkLightHex: "#FFFFFF", checkDarkHex: "#141518", multicolor: false),
    RegistryFruitAccent(id: "carambola", name: RegistryL10n.t("Carambola"), origin: "SE Asia · Starfruit", lightHex: "#5B8C00", darkHex: "#9EE034", checkLightHex: "#FFFFFF", checkDarkHex: "#141518", multicolor: false),
    RegistryFruitAccent(id: "acai", name: RegistryL10n.t("Açaí"), origin: "Amazon · Indigo", lightHex: "#6544D6", darkHex: "#9B82FF", checkLightHex: "#FFFFFF", checkDarkHex: "#FFFFFF", multicolor: false),
    RegistryFruitAccent(id: "pitaya", name: RegistryL10n.t("Pitaya"), origin: "Mesoamerica · Dragonfruit", lightHex: "#D4266C", darkHex: "#FF5C9B", checkLightHex: "#FFFFFF", checkDarkHex: "#FFFFFF", multicolor: false),
    RegistryFruitAccent(id: "jabuticaba", name: RegistryL10n.t("Jabuticaba"), origin: "Brazil · Obsidian ink", lightHex: "#27272E", darkHex: "#E4E4EA", checkLightHex: "#FFFFFF", checkDarkHex: "#141518", multicolor: false),
  ]
  static let textures: [RegistryTextureOption] = [
    RegistryTextureOption(id: "none", name: RegistryL10n.t("Pure Canvas"), tag: RegistryL10n.t("Baseline")),
    RegistryTextureOption(id: "topography", name: RegistryL10n.t("Topography"), tag: RegistryL10n.t("Height Map")),
    RegistryTextureOption(id: "fieldMatrix", name: RegistryL10n.t("Field Matrix"), tag: RegistryL10n.t("Industrial")),
    RegistryTextureOption(id: "stippleDrift", name: RegistryL10n.t("Stipple Drift"), tag: RegistryL10n.t("Print / Ink")),
    RegistryTextureOption(id: "causticGlass", name: RegistryL10n.t("Caustic Glass"), tag: RegistryL10n.t("Optical")),
    RegistryTextureOption(id: "ridges", name: RegistryL10n.t("Ridge Lines"), tag: RegistryL10n.t("Elevation")),
    RegistryTextureOption(id: "washiPaper", name: RegistryL10n.t("Washi Paper"), tag: RegistryL10n.t("Tactile")),
  ]
  static let textScaleFactors: [Int: Double] = [
    -2: 0.85,
    -1: 0.92,
    0: 1,
    1: 1.1,
    2: 1.2,
  ]
}

/// Desktop Settings sidebar tab descriptor (`registry/settings.json`).
struct RegistrySettingsTab: Sendable, Hashable, Identifiable {
  let id: String
  let title: String
  let iconId: String
  let sfSymbol: String
  let group: String
  let paletteSlot: Int?
  let featureId: String
  /// The tab shows on `platform` when its capability ships (ADR 0015).
  func applies(to platform: String) -> Bool { RegistryCapabilities.isAvailable(featureId, on: platform) }
}

/// Choice option descriptor for enum/bounded settings (`registry/settings.json`).
struct RegistrySettingsOption: Sendable, Hashable, Identifiable {
  let value: String
  let title: String
  var id: String { value }
}

/// One item in a Settings root group or page section (`registry/settings.json`).
struct RegistrySettingsItem: Sendable, Hashable, Identifiable {
  let kind: String
  let key: String?
  let page: String?
  let surface: String?
  let label: String?
  let detail: String?
  let iconId: String?
  let sfSymbol: String?
  let statusKey: String?
  let desktopInline: Bool
  let visibility: String
  let platforms: [String]?
  let featureId: String?
  var id: String { "\(kind):\(key ?? page ?? surface ?? label ?? "item")" }
  /// The item shows on `platform`: listed there and its capability ships (ADR 0015).
  func applies(to platform: String) -> Bool { (platforms?.contains(platform) ?? true) && featureId.map { RegistryCapabilities.isAvailable($0, on: platform) } != false }
}

/// One root-level group in mobile Settings (`registry/settings.json`).
struct RegistrySettingsGroup: Sendable, Hashable, Identifiable {
  let id: String
  let header: String?
  let mobilePresentation: String
  let desktopTab: String?
  let items: [RegistrySettingsItem]
}

/// One section inside a pushed Settings page (`registry/settings.json`).
struct RegistrySettingsSection: Sendable, Hashable, Identifiable {
  let id: String
  let header: String?
  let footer: String?
  let platforms: [String]?
  let items: [RegistrySettingsItem]
  func applies(to platform: String) -> Bool { platforms?.contains(platform) ?? true }
}

/// One depth-1 or depth-2 Settings page (`registry/settings.json`).
struct RegistrySettingsPage: Sendable, Hashable, Identifiable {
  let id: String
  let title: String
  let iconId: String
  let sfSymbol: String
  let depth: Int
  let platforms: [String]?
  let featureId: String
  let sections: [RegistrySettingsSection]
  /// The page shows on `platform`: listed there and its capability ships (ADR 0015).
  func applies(to platform: String) -> Bool { (platforms?.contains(platform) ?? true) && RegistryCapabilities.isAvailable(featureId, on: platform) }
}

/// Unified task-app settings keys, defaults, synced-key list, and taxonomy (`registry/settings.json`).
enum RegistrySettings {
  static let syncedKeys: [String] = ["welcomeName", "telemetryLevel", "calendarHiddenTitles", "rolledInDismissedOn", "homeTimezone", "agentsPaused", "getStartedDismissed", "getStartedSteps", "onboardedAt", "accentColor", "canvasTexture", "textureIntensity", "textureMotion", "smartListOrder", "smartListHidden", "smartListPlacement"]

  enum StorageKey {
    static let welcomeName = "septena.homepage.welcomeName"
    static let telemetryLevel = "septena.privacy.telemetryLevel"
    static let rolledInDismissedOn = "septena.newTodos.dismissedDate"
    static let accentColor = "septena.appearance.accentColor"
    static let canvasTexture = "septena.appearance.canvasTexture"
    static let textureIntensity = "septena.appearance.textureIntensity"
    static let textureMotion = "septena.appearance.textureMotion"
    static let smartListOrder = "septena.sidebar.smartListOrder"
    static let smartListHidden = "septena.sidebar.smartListHidden"
    static let smartListPlacement = "septena.sidebar.smartListPlacement"
    static let appearanceMode = "septena.appearance.mode"
    static let syncTheme = "septena.appearance.syncTheme"
    static let appIconFinish = "septena.appearance.appIconFinish"
    static let appIconColor = "septena.appearance.appIconColor"
    static let todayShowCompleted = "septena.today.showCompleted"
    static let todayGroupByList = "septena.today.groupByList"
    static let tasksShowAging = "septena.tasks.showAging"
    static let tasksShowFaded = "septena.tasks.showFaded"
    static let tasksTitleLines = "septena.tasks.titleLines"
    static let tasksSwipeLeadingAction = "septena.tasks.swipeLeadingAction"
    static let tasksFilingSuggestions = "septena.tasks.filingSuggestions"
    static let tasksShowCalendarEvents = "septena.tasks.showCalendarEvents"
    static let badgeShowOverdue = "septena.badge.showOverdue"
    static let loggingAnimationsEnabled = "septena.ui.loggingAnimations"
    static let textSizeStep = "septena.display.textSizeStep"
    static let sidebarCounts = "septena.septask.sidebarCounts"
    static let aiMode = "septena.ai.mode"
    static let diagnosticsEnabled = "septask.diagnostics.enabled"
    static let showModelLabels = "septena.ai.showModelTags"
    static let pccRoutingEnabled = "septena.ai.pccRoutingEnabled"
    static let pccReasoning = "septena.ai.pccReasoning"
  }

  enum Defaults {
    static let welcomeName: String = ""
    static let telemetryLevel: String = "balanced"
    static let agentsPaused: Bool = false
    static let getStartedDismissed: Bool = false
    static let accentColor: String = "colorful"
    static let canvasTexture: String = "none"
    static let textureIntensity: Int = 55
    static let textureMotion: String = "still"
    static let appearanceMode: String = "system"
    static let syncTheme: Bool = true
    static let appIconFinish: String = "obsidian"
    static let appIconColor: String = "auto"
    static let todayShowCompleted: Bool = true
    static let todayGroupByList: Bool = true
    static let tasksShowAging: Bool = true
    static let tasksShowFaded: Bool = true
    static let tasksTitleLines: Int = 2
    static let tasksSwipeLeadingAction: String = "today"
    static let tasksFilingSuggestions: Bool = true
    static let tasksShowCalendarEvents: Bool = true
    static let badgeShowOverdue: Bool = false
    static let loggingAnimationsEnabled: Bool = true
    static let textSizeStep: Int = 0
    static let sidebarCounts: Bool = true
    static let aiMode: String = "auto"
    static let diagnosticsEnabled: Bool = false
    static let showModelLabels: Bool = true
    static let pccRoutingEnabled: Bool = false
    static let pccReasoning: String = "balanced"
  }

  enum TabID {
    static let account = "account"
    static let general = "general"
    static let aiAgents = "ai_agents"
    static let connectionsData = "connections_data"
    static let privacy = "privacy"
    static let about = "about"
  }

  enum PageID {
    static let account = "account"
    static let plus = "plus"
    static let claudePairing = "claude_pairing"
    static let aiPreferences = "ai_preferences"
    static let calendar = "calendar"
    static let reminders = "reminders"
    static let importExport = "import_export"
    static let privacy = "privacy"
    static let about = "about"
    static let advanced = "advanced"
    static let smartLists = "smart_lists"
  }

  static let optionsByKey: [String: [RegistrySettingsOption]] = [
    "tasksTitleLines": [RegistrySettingsOption(value: "1", title: RegistryL10n.t("One")), RegistrySettingsOption(value: "2", title: RegistryL10n.t("Two")), RegistrySettingsOption(value: "3", title: RegistryL10n.t("Three"))],
    "tasksSwipeLeadingAction": [RegistrySettingsOption(value: "today", title: RegistryL10n.t("Today")), RegistrySettingsOption(value: "schedule", title: RegistryL10n.t("Schedule")), RegistrySettingsOption(value: "move", title: RegistryL10n.t("Move")), RegistrySettingsOption(value: "star", title: RegistryL10n.t("Star")), RegistrySettingsOption(value: "complete", title: RegistryL10n.t("Complete")), RegistrySettingsOption(value: "none", title: RegistryL10n.t("Off"))],
    "aiMode": [RegistrySettingsOption(value: "onDeviceOnly", title: RegistryL10n.t("On-device only")), RegistrySettingsOption(value: "auto", title: RegistryL10n.t("Automatic")), RegistrySettingsOption(value: "useMyClaude", title: RegistryL10n.t("Use my Claude"))],
    "pccReasoning": [RegistrySettingsOption(value: "light", title: RegistryL10n.t("Light")), RegistrySettingsOption(value: "balanced", title: RegistryL10n.t("Balanced")), RegistrySettingsOption(value: "thorough", title: RegistryL10n.t("Thorough"))],
  ]

  static let desktopTabs: [RegistrySettingsTab] = [
    RegistrySettingsTab(id: "account", title: RegistryL10n.t("Account"), iconId: "settings.account", sfSymbol: "person.crop.circle", group: "identity", paletteSlot: nil, featureId: "sync.backend"),
    RegistrySettingsTab(id: "general", title: RegistryL10n.t("General"), iconId: "settings.general", sfSymbol: "slider.horizontal.3", group: "main", paletteSlot: 0, featureId: "lists.today"),
    RegistrySettingsTab(id: "ai_agents", title: RegistryL10n.t("AI & Agents"), iconId: "settings.ai_agents", sfSymbol: "sparkles", group: "main", paletteSlot: 4, featureId: "ai.reach-dial"),
    RegistrySettingsTab(id: "connections_data", title: RegistryL10n.t("Connections & Data"), iconId: "settings.connections", sfSymbol: "link", group: "main", paletteSlot: 5, featureId: "sync.backend"),
    RegistrySettingsTab(id: "privacy", title: RegistryL10n.t("Privacy"), iconId: "settings.privacy", sfSymbol: "hand.raised", group: "main", paletteSlot: 6, featureId: "settings.display"),
    RegistrySettingsTab(id: "about", title: RegistryL10n.t("About"), iconId: "settings.about", sfSymbol: "info.circle", group: "about", paletteSlot: nil, featureId: "settings.display"),
  ]

  static let rootGroups: [RegistrySettingsGroup] = [
    RegistrySettingsGroup(id: "account_root", header: nil, mobilePresentation: "card", desktopTab: "account", items: [
      RegistrySettingsItem(kind: "pageLink", key: nil, page: "account", surface: "account_profile_card", label: RegistryL10n.t("Account"), detail: nil, iconId: "settings.account", sfSymbol: "person.crop.circle", statusKey: "syncStatus", desktopInline: false, visibility: "always", platforms: nil, featureId: "sync.backend"),
    ]),
    RegistrySettingsGroup(id: "ai_agents_root", header: RegistryL10n.t("AI & Agents"), mobilePresentation: "inline", desktopTab: "ai_agents", items: [
      RegistrySettingsItem(kind: "pageLink", key: nil, page: "claude_pairing", surface: nil, label: RegistryL10n.t("Connect Claude"), detail: nil, iconId: "settings.claude", sfSymbol: "bubble.left.and.text.bubble.right", statusKey: "claudeStatus", desktopInline: true, visibility: "always", platforms: nil, featureId: "agents.connector"),
      RegistrySettingsItem(kind: "setting", key: "agentsPaused", page: nil, surface: nil, label: RegistryL10n.t("Pause all agents"), detail: RegistryL10n.t("While paused, no agent can start or work on a task."), iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "signedIn", platforms: nil, featureId: "agents.stop-pause"),
      RegistrySettingsItem(kind: "pageLink", key: nil, page: "ai_preferences", surface: nil, label: RegistryL10n.t("AI Preferences"), detail: nil, iconId: "settings.ai_agents", sfSymbol: "sparkles", statusKey: "aiMode", desktopInline: true, visibility: "always", platforms: nil, featureId: "ai.reach-dial"),
    ]),
    RegistrySettingsGroup(id: "connections_data_root", header: RegistryL10n.t("Connections & Data"), mobilePresentation: "inline", desktopTab: "connections_data", items: [
      RegistrySettingsItem(kind: "pageLink", key: nil, page: "calendar", surface: nil, label: RegistryL10n.t("Calendar"), detail: nil, iconId: "settings.calendar", sfSymbol: "calendar", statusKey: "calendarStatus", desktopInline: false, visibility: "always", platforms: nil, featureId: "calendar.events"),
      RegistrySettingsItem(kind: "pageLink", key: nil, page: "reminders", surface: nil, label: RegistryL10n.t("Reminders"), detail: nil, iconId: "settings.reminders", sfSymbol: "checklist", statusKey: "remindersStatus", desktopInline: false, visibility: "always", platforms: ["ios", "ipados", "macos"], featureId: "import.reminders"),
      RegistrySettingsItem(kind: "pageLink", key: nil, page: "import_export", surface: nil, label: RegistryL10n.t("Import & Export"), detail: nil, iconId: "settings.data", sfSymbol: "square.and.arrow.up", statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "sync.backend"),
    ]),
    RegistrySettingsGroup(id: "lists_root", header: RegistryL10n.t("Lists"), mobilePresentation: "inline", desktopTab: "general", items: [
      RegistrySettingsItem(kind: "pageLink", key: nil, page: "smart_lists", surface: nil, label: RegistryL10n.t("Smart Lists"), detail: nil, iconId: "list.today", sfSymbol: "sun.max.fill", statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "settings.display"),
      RegistrySettingsItem(kind: "setting", key: "todayGroupByList", page: nil, surface: nil, label: RegistryL10n.t("Group Today by list"), detail: RegistryL10n.t("When off, tasks appear in one list with their project or area underneath."), iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "lists.today"),
      RegistrySettingsItem(kind: "setting", key: "todayShowCompleted", page: nil, surface: nil, label: RegistryL10n.t("Show completed tasks"), detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "lists.today"),
      RegistrySettingsItem(kind: "setting", key: "tasksShowAging", page: nil, surface: nil, label: RegistryL10n.t("Fade inactive tasks"), detail: RegistryL10n.t("Tasks without activity for 14 days fade out and move to Faded."), iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "task.aging"),
      RegistrySettingsItem(kind: "setting", key: "tasksShowFaded", page: nil, surface: nil, label: RegistryL10n.t("Show faded tasks"), detail: RegistryL10n.t("Show faded tasks in projects and areas."), iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "task.aging"),
      RegistrySettingsItem(kind: "setting", key: "tasksFilingSuggestions", page: nil, surface: nil, label: RegistryL10n.t("Suggest where to file"), detail: RegistryL10n.t("Learn where you usually file similar tasks."), iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "edit.filing-suggestion"),
      RegistrySettingsItem(kind: "setting", key: "badgeShowOverdue", page: nil, surface: nil, label: RegistryL10n.t("Overdue app icon badge"), detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "settings.display"),
    ]),
    RegistrySettingsGroup(id: "appearance_root", header: RegistryL10n.t("Appearance"), mobilePresentation: "inline", desktopTab: "general", items: [
      RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "accent_color", label: RegistryL10n.t("Accent"), detail: nil, iconId: "settings.appearance", sfSymbol: "paintpalette", statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "settings.display"),
      RegistrySettingsItem(kind: "setting", key: "textSizeStep", page: nil, surface: nil, label: RegistryL10n.t("Text Size"), detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "settings.display"),
      RegistrySettingsItem(kind: "setting", key: "tasksTitleLines", page: nil, surface: nil, label: RegistryL10n.t("Title lines"), detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: ["ios", "ipados", "android"], featureId: "settings.display"),
      RegistrySettingsItem(kind: "setting", key: "tasksSwipeLeadingAction", page: nil, surface: nil, label: RegistryL10n.t("Swipe right"), detail: RegistryL10n.t("Swipe left on a task to select multiple tasks. Swipe right runs this quick action."), iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: ["ios", "ipados"], featureId: "settings.display"),
      RegistrySettingsItem(kind: "setting", key: "loggingAnimationsEnabled", page: nil, surface: nil, label: RegistryL10n.t("Completion animations"), detail: nil, iconId: "settings.animations", sfSymbol: "party.popper", statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "settings.display"),
    ]),
    RegistrySettingsGroup(id: "meta_root", header: nil, mobilePresentation: "inline", desktopTab: nil, items: [
      RegistrySettingsItem(kind: "pageLink", key: nil, page: "privacy", surface: nil, label: RegistryL10n.t("Privacy"), detail: nil, iconId: "settings.privacy", sfSymbol: "hand.raised", statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "settings.display"),
      RegistrySettingsItem(kind: "pageLink", key: nil, page: "about", surface: nil, label: RegistryL10n.t("About"), detail: nil, iconId: "settings.about", sfSymbol: "info.circle", statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "settings.display"),
    ]),
  ]

  static let pages: [RegistrySettingsPage] = [
    RegistrySettingsPage(id: "account", title: RegistryL10n.t("Account"), iconId: "settings.account", sfSymbol: "person.crop.circle", depth: 1, platforms: nil, featureId: "sync.backend", sections: [
      RegistrySettingsSection(id: "profile", header: nil, footer: RegistryL10n.t("Your name stays on this device, and syncs when you sign in."), platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "account_profile_editor", label: RegistryL10n.t("Your name"), detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "sync.backend"),
      ]),
      RegistrySettingsSection(id: "plan", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "pageLink", key: nil, page: "plus", surface: nil, label: RegistryL10n.t("Septena Plus"), detail: nil, iconId: "settings.plus", sfSymbol: "plus.circle.fill", statusKey: "planStatus", desktopInline: false, visibility: "always", platforms: nil, featureId: "sync.backend"),
      ]),
      RegistrySettingsSection(id: "sync", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "sync_account_status", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "sync.backend"),
      ]),
      RegistrySettingsSection(id: "sign_in_approval", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "sign_in_approval", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "signedIn", platforms: nil, featureId: "sync.backend"),
      ]),
      RegistrySettingsSection(id: "delete_account", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "delete_account", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "signedIn", platforms: nil, featureId: "account.delete"),
      ]),
    ]),
    RegistrySettingsPage(id: "plus", title: RegistryL10n.t("Septena Plus"), iconId: "settings.plus", sfSymbol: "plus.circle.fill", depth: 2, platforms: nil, featureId: "sync.backend", sections: [
      RegistrySettingsSection(id: "offer", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "plus_offer", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "sync.backend"),
      ]),
    ]),
    RegistrySettingsPage(id: "claude_pairing", title: RegistryL10n.t("Connect Claude"), iconId: "settings.claude", sfSymbol: "bubble.left.and.text.bubble.right", depth: 1, platforms: nil, featureId: "agents.connector", sections: [
      RegistrySettingsSection(id: "connector", header: RegistryL10n.t("Connect Claude"), footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "claude_connector", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "agents.connector"),
      ]),
    ]),
    RegistrySettingsPage(id: "ai_preferences", title: RegistryL10n.t("AI Preferences"), iconId: "settings.ai_agents", sfSymbol: "sparkles", depth: 1, platforms: nil, featureId: "ai.reach-dial", sections: [
      RegistrySettingsSection(id: "on_device", header: RegistryL10n.t("AI on this device"), footer: nil, platforms: ["ios", "ipados", "macos"], items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "apple_intelligence_status", label: RegistryL10n.t("Apple Intelligence"), detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: ["ios", "ipados", "macos"], featureId: "ai.reach-dial"),
      ]),
      RegistrySettingsSection(id: "reach", header: RegistryL10n.t("Where AI runs"), footer: RegistryL10n.t("Septena never runs AI on your data and never reads it. The intelligence is your own (Apple on-device, Private Cloud Compute, or your Claude). This only sets where requests may run."), platforms: nil, items: [
        RegistrySettingsItem(kind: "setting", key: "aiMode", page: nil, surface: nil, label: RegistryL10n.t("AI Mode"), detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "ai.reach-dial"),
      ]),
      RegistrySettingsSection(id: "explainer", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "ai_explainer", label: RegistryL10n.t("How AI helps with your tasks"), detail: nil, iconId: "settings.about", sfSymbol: "info.circle", statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "ai.reach-dial"),
      ]),
    ]),
    RegistrySettingsPage(id: "calendar", title: RegistryL10n.t("Calendar"), iconId: "settings.calendar", sfSymbol: "calendar", depth: 1, platforms: nil, featureId: "calendar.events", sections: [
      RegistrySettingsSection(id: "calendars", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "calendar_detail", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "calendar.events"),
      ]),
    ]),
    RegistrySettingsPage(id: "reminders", title: RegistryL10n.t("Reminders"), iconId: "settings.reminders", sfSymbol: "checklist", depth: 1, platforms: ["ios", "ipados", "macos"], featureId: "import.reminders", sections: [
      RegistrySettingsSection(id: "reminders", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "reminders_inbox", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: ["ios", "ipados", "macos"], featureId: "import.reminders"),
      ]),
    ]),
    RegistrySettingsPage(id: "import_export", title: RegistryL10n.t("Import & Export"), iconId: "settings.data", sfSymbol: "square.and.arrow.up", depth: 1, platforms: nil, featureId: "sync.backend", sections: [
      RegistrySettingsSection(id: "move_in", header: RegistryL10n.t("Move from another app"), footer: RegistryL10n.t("Septena copies your areas, projects and tasks. The other app is not changed, and you can undo an import."), platforms: ["ios", "ipados", "macos"], items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "things_import", label: RegistryL10n.t("Import from Things"), detail: nil, iconId: "settings.import", sfSymbol: "square.and.arrow.down", statusKey: nil, desktopInline: false, visibility: "always", platforms: ["ios", "ipados", "macos"], featureId: "import.things"),
      ]),
      RegistrySettingsSection(id: "transfer", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "import_export", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "sync.backend"),
      ]),
    ]),
    RegistrySettingsPage(id: "privacy", title: RegistryL10n.t("Privacy"), iconId: "settings.privacy", sfSymbol: "hand.raised", depth: 1, platforms: nil, featureId: "settings.display", sections: [
      RegistrySettingsSection(id: "data_locality", header: RegistryL10n.t("Your data"), footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "privacy_explainer", label: nil, detail: RegistryL10n.t("Your tasks, areas, projects, and conversations stay on this device until you sign in. When signed in, they sync through Septena’s private server at api.septena.app, encrypted at rest (not end-to-end, so connected agents can read them when you choose). AI on your device stays on your device. Connect Claude under AI & Agents."), iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "settings.display"),
      ]),
      RegistrySettingsSection(id: "telemetry", header: RegistryL10n.t("Anonymous usage data"), footer: RegistryL10n.t("Your task text and titles are never sent through analytics. This setting syncs across your devices."), platforms: nil, items: [
        RegistrySettingsItem(kind: "setting", key: "telemetryLevel", page: nil, surface: nil, label: RegistryL10n.t("Usage data"), detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "settings.display"),
      ]),
    ]),
    RegistrySettingsPage(id: "about", title: RegistryL10n.t("About"), iconId: "settings.about", sfSymbol: "info.circle", depth: 1, platforms: nil, featureId: "settings.display", sections: [
      RegistrySettingsSection(id: "version", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "about_header", label: RegistryL10n.t("Tasks that think with you"), detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "settings.display"),
      ]),
      RegistrySettingsSection(id: "actions", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "check_updates", label: RegistryL10n.t("Check for Updates…"), detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: ["macos", "windows"], featureId: "mac.updates"),
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "reset_get_started", label: RegistryL10n.t("Show Get Started Again"), detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "settings.display"),
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "reset_first_run", label: RegistryL10n.t("Show Welcome Again"), detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "onboarding.first-run"),
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "send_feedback", label: RegistryL10n.t("Send feedback"), detail: nil, iconId: "settings.feedback", sfSymbol: "paperplane", statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "settings.display"),
      ]),
      RegistrySettingsSection(id: "companion", header: RegistryL10n.t("Septena Life"), footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "septena_life_link", label: RegistryL10n.t("Open Septena Life"), detail: RegistryL10n.t("Septena Life is the companion app for habits, training, food, sleep, mood, and health."), iconId: "settings.companion_app", sfSymbol: "arrow.up.forward.app", statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "settings.display"),
      ]),
      RegistrySettingsSection(id: "advanced_link", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "pageLink", key: nil, page: "advanced", surface: nil, label: RegistryL10n.t("Advanced"), detail: nil, iconId: "settings.advanced", sfSymbol: "wrench.and.screwdriver", statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "settings.display"),
      ]),
    ]),
    RegistrySettingsPage(id: "advanced", title: RegistryL10n.t("Advanced"), iconId: "settings.advanced", sfSymbol: "wrench.and.screwdriver", depth: 2, platforms: nil, featureId: "settings.display", sections: [
      RegistrySettingsSection(id: "agent_tools", header: RegistryL10n.t("Agent tools"), footer: RegistryL10n.t("The brief that teaches a model how to use your tasks through the connection (tools, conventions, and examples)."), platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "mcp_skills", label: RegistryL10n.t("MCP Skills"), detail: nil, iconId: "settings.skills", sfSymbol: "book.closed", statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "agents.connector"),
      ]),
      RegistrySettingsSection(id: "diagnostics", header: RegistryL10n.t("Diagnostics"), footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "sync_diagnostics", label: RegistryL10n.t("Sync & storage diagnostics"), detail: RegistryL10n.t("Changes the server refused appear here, newest first. The server kept its own version of each."), iconId: "settings.diagnostics", sfSymbol: "stethoscope", statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "sync.backend"),
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "diagnostics_weekly", label: RegistryL10n.t("Optional product diagnostics"), detail: RegistryL10n.t("An opt-in weekly summary that helps improve Septena. You don't need it for updates, sync, or support."), iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "settings.display"),
      ]),
      RegistrySettingsSection(id: "data_tools", header: RegistryL10n.t("Data tools"), footer: RegistryL10n.t("Paste raw Septena JSON directly from the clipboard to restore or merge records."), platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "paste_json_import", label: RegistryL10n.t("Paste JSON Backup…"), detail: nil, iconId: "settings.paste", sfSymbol: "doc.on.clipboard", statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "sync.backend"),
      ]),
      RegistrySettingsSection(id: "beta_ai", header: RegistryL10n.t("AI diagnostics"), footer: nil, platforms: ["ios", "ipados", "macos"], items: [
        RegistrySettingsItem(kind: "setting", key: "showModelLabels", page: nil, surface: nil, label: RegistryL10n.t("Show model labels"), detail: RegistryL10n.t("Show which model answered next to each AI reply."), iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "ai.reach-dial"),
        RegistrySettingsItem(kind: "setting", key: "pccRoutingEnabled", page: nil, surface: nil, label: RegistryL10n.t("Use Private Cloud Compute"), detail: RegistryL10n.t("Requires the PCC entitlement. Without it, requests fail and fall back on-device."), iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "minAppleOS27", platforms: nil, featureId: "ai.reach-dial"),
        RegistrySettingsItem(kind: "setting", key: "pccReasoning", page: nil, surface: nil, label: RegistryL10n.t("Private Cloud Compute reasoning"), detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "minAppleOS27", platforms: nil, featureId: "ai.reach-dial"),
      ]),
    ]),
    RegistrySettingsPage(id: "smart_lists", title: RegistryL10n.t("Smart Lists"), iconId: "list.today", sfSymbol: "sun.max.fill", depth: 1, platforms: nil, featureId: "settings.display", sections: [
      RegistrySettingsSection(id: "smart_lists", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "smart_lists_editor", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil, featureId: "settings.display"),
      ]),
    ]),
  ]

  static let pageById: [String: RegistrySettingsPage] = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })
  static let tabById: [String: RegistrySettingsTab] = Dictionary(uniqueKeysWithValues: desktopTabs.map { ($0.id, $0) })
  private static let allItems: [RegistrySettingsItem] = rootGroups.flatMap(\.items) + pages.flatMap { $0.sections.flatMap(\.items) }
  /// Item by `surface` id (custom surfaces and the account card link).
  static let itemBySurface: [String: RegistrySettingsItem] = Dictionary(allItems.compactMap { i in i.surface.map { ($0, i) } }, uniquingKeysWith: { a, _ in a })
  /// `setting` item by settings key.
  static let itemByKey: [String: RegistrySettingsItem] = Dictionary(allItems.compactMap { i in i.kind == "setting" ? i.key.map { ($0, i) } : nil }, uniquingKeysWith: { a, _ in a })
  /// Section `id` on page `page`.
  static func section(_ id: String, page: String) -> RegistrySettingsSection? { pageById[page]?.sections.first { $0.id == id } }
  /// Label of a surface item; the surface id when the registry has none.
  static func label(surface: String) -> String { itemBySurface[surface]?.label ?? surface }
  /// Label of a setting item; the key when the registry has none.
  static func label(key: String) -> String { itemByKey[key]?.label ?? key }
  static func aboutHeaderDetail(version: String) -> String { RegistryL10n.format("Version %@", english: "Version %@", args: [version]) }
}

/// Canonical smart-list metadata (`registry/destinations.json`).
struct RegistryDestination: Sendable, Hashable, Identifiable {
  let id: String
  let navigationKey: String
  let serverView: String
  let title: String
  let iconId: String
  let sfSymbol: String
  let sidebarSection: String
  let visibility: String
  let canHide: Bool
  let canMoveSection: Bool
  let shortcutKeycaps: [String]?
  let emptyTitle: String
  let emptyDetail: String
  let featureId: String
  /// The list shows on `platform` when its capability ships (ADR 0015).
  func applies(to platform: String) -> Bool { RegistryCapabilities.isAvailable(featureId, on: platform) }
}

/// One ordered section of a grouped smart list (`groups` in destinations.json).
struct RegistryDestinationGroup: Sendable, Hashable, Identifiable {
  let id: String
  let title: String
  let iconId: String
  let sfSymbol: String
}

enum RegistryDestinations {
  static let viewAliases: [String: String] = [
    "someday": "anytime",
    "unscheduled": "anytime",
    "triage": "inbox",
  ]

  static let all: [RegistryDestination] = [
    RegistryDestination(id: "inbox", navigationKey: "triage", serverView: "triage", title: RegistryL10n.t("Inbox"), iconId: "list.inbox", sfSymbol: "tray.full", sidebarSection: "top", visibility: "todayBand", canHide: false, canMoveSection: false, shortcutKeycaps: nil, emptyTitle: RegistryL10n.t("Inbox is empty"), emptyDetail: RegistryL10n.t("New tasks wait at the top of Today until you schedule or file them."), featureId: "lists.inbox"),
    RegistryDestination(id: "today", navigationKey: "today", serverView: "today", title: RegistryL10n.t("Today"), iconId: "list.today", sfSymbol: "sun.max.fill", sidebarSection: "top", visibility: "always", canHide: false, canMoveSection: false, shortcutKeycaps: ["⌘", "1"], emptyTitle: RegistryL10n.t("Nothing on Today"), emptyDetail: RegistryL10n.t("Add a task or move one here when you want to work on it today."), featureId: "lists.today"),
    RegistryDestination(id: "review", navigationKey: "review", serverView: "all", title: RegistryL10n.t("Review"), iconId: "list.review", sfSymbol: "eye", sidebarSection: "top", visibility: "whenNonEmpty", canHide: true, canMoveSection: true, shortcutKeycaps: nil, emptyTitle: RegistryL10n.t("Nothing to review"), emptyDetail: RegistryL10n.t("Work an agent finished appears here so you can check and accept it."), featureId: "lists.review"),
    RegistryDestination(id: "agent", navigationKey: "agent", serverView: "all", title: RegistryL10n.t("Agent"), iconId: "list.agent", sfSymbol: "sparkles", sidebarSection: "top", visibility: "whenNonEmpty", canHide: true, canMoveSection: true, shortcutKeycaps: nil, emptyTitle: RegistryL10n.t("No agent work"), emptyDetail: RegistryL10n.t("Tasks you assign to Claude appear here, grouped by where the work stands."), featureId: "lists.agent"),
    RegistryDestination(id: "upcoming", navigationKey: "upcoming", serverView: "upcoming", title: RegistryL10n.t("Upcoming"), iconId: "list.upcoming", sfSymbol: "calendar", sidebarSection: "top", visibility: "always", canHide: true, canMoveSection: true, shortcutKeycaps: ["⌘", "2"], emptyTitle: RegistryL10n.t("Nothing upcoming"), emptyDetail: RegistryL10n.t("Tasks with a future When or Deadline date appear here."), featureId: "lists.upcoming"),
    RegistryDestination(id: "repeating", navigationKey: "repeating", serverView: "all", title: RegistryL10n.t("Repeating"), iconId: "list.repeating", sfSymbol: "arrow.clockwise", sidebarSection: "top", visibility: "always", canHide: true, canMoveSection: true, shortcutKeycaps: nil, emptyTitle: RegistryL10n.t("No repeating tasks"), emptyDetail: RegistryL10n.t("Give any task a Repeat rule and it will show up here."), featureId: "lists.repeating"),
    RegistryDestination(id: "anytime", navigationKey: "unscheduled", serverView: "unscheduled", title: RegistryL10n.t("Anytime"), iconId: "list.anytime", sfSymbol: "rectangle.stack.fill", sidebarSection: "top", visibility: "always", canHide: true, canMoveSection: true, shortcutKeycaps: ["⌘", "3"], emptyTitle: RegistryL10n.t("Nothing in Anytime"), emptyDetail: RegistryL10n.t("Open tasks without a date live here."), featureId: "lists.anytime"),
    RegistryDestination(id: "logbook", navigationKey: "logbook", serverView: "logbook", title: RegistryL10n.t("Logbook"), iconId: "list.logbook", sfSymbol: "checkmark", sidebarSection: "bottom", visibility: "always", canHide: true, canMoveSection: true, shortcutKeycaps: ["⌘", "4"], emptyTitle: RegistryL10n.t("Logbook is empty"), emptyDetail: RegistryL10n.t("Tasks you complete or let go end up here."), featureId: "lists.logbook"),
    RegistryDestination(id: "starred", navigationKey: "starred", serverView: "all", title: RegistryL10n.t("Starred"), iconId: "list.starred", sfSymbol: "star.fill", sidebarSection: "top", visibility: "whenNonEmpty", canHide: true, canMoveSection: true, shortcutKeycaps: nil, emptyTitle: RegistryL10n.t("No Starred Tasks"), emptyDetail: RegistryL10n.t("Star important tasks to keep them one tap away."), featureId: "lists.starred"),
    RegistryDestination(id: "faded", navigationKey: "faded", serverView: "all", title: RegistryL10n.t("Faded"), iconId: "list.faded", sfSymbol: "circle.dashed", sidebarSection: "bottom", visibility: "whenNonEmpty", canHide: true, canMoveSection: true, shortcutKeycaps: nil, emptyTitle: RegistryL10n.t("No Faded Tasks"), emptyDetail: RegistryL10n.t("Undated tasks without activity for 14 days appear here until you keep them or let them go."), featureId: "lists.faded"),
    RegistryDestination(id: "recentlyDeleted", navigationKey: "recentlyDeleted", serverView: "all", title: RegistryL10n.t("Recently Deleted"), iconId: "list.recently_deleted", sfSymbol: "trash", sidebarSection: "bottom", visibility: "whenNonEmpty", canHide: true, canMoveSection: true, shortcutKeycaps: nil, emptyTitle: RegistryL10n.t("No Recently Deleted Tasks"), emptyDetail: RegistryL10n.t("Septena keeps deleted tasks here for 30 days, then deletes them for good."), featureId: "lists.recently-deleted"),
  ]

  static let byId: [String: RegistryDestination] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
  static let byNavigationKey: [String: RegistryDestination] = Dictionary(uniqueKeysWithValues: all.map { ($0.navigationKey, $0) })

  /// Ordered row groups per destination id (`groups` in destinations.json).
  static let groups: [String: [RegistryDestinationGroup]] = [
    "agent": [
      RegistryDestinationGroup(id: "queued", title: RegistryL10n.t("Queued"), iconId: "agent.queued", sfSymbol: "clock"),
      RegistryDestinationGroup(id: "working", title: RegistryL10n.t("Working"), iconId: "agent.working", sfSymbol: "ellipsis.circle"),
      RegistryDestinationGroup(id: "yourTurn", title: RegistryL10n.t("Your turn"), iconId: "agent.your_turn", sfSymbol: "questionmark.bubble"),
      RegistryDestinationGroup(id: "review", title: RegistryL10n.t("Review"), iconId: "list.review", sfSymbol: "eye"),
      RegistryDestinationGroup(id: "done", title: RegistryL10n.t("Done"), iconId: "agent.done", sfSymbol: "checkmark.circle"),
    ],
  ]

  /// Empty state for a list with no copy of its own (`genericEmptyState`).
  enum GenericEmpty {
    static let title: String = RegistryL10n.t("Nothing here yet")
    static let detail: String = RegistryL10n.t("Type above to add your first task.")
    static let pointerDetail: String = RegistryL10n.t("Click + or double-click below to add a task.")
    static let touchDetail: String = RegistryL10n.t("Tap + to add a task.")
    static let syncingTitle: String = RegistryL10n.t("Syncing…")
  }
}

/// Generated shortcut-sheet entry (`registry/actions.json`).
struct RegistryShortcutEntry: Sendable, Hashable, Identifiable {
  let id: String
  let label: String
  let keycaps: [String]
  let excludePlatforms: [String]
}

/// A platform-neutral shortcut (`primary` is ⌘ on Apple, Ctrl elsewhere).
struct RegistryShortcut: Sendable, Hashable {
  let key: String
  let modifiers: [String]
  let keycaps: [String]
  let excludePlatforms: [String]
  /// Extra bindings for the same action (a menu item shows only one).
  var alternates: [RegistryShortcut] = []
}

/// Where an action applies (`availability` in `registry/actions.json`).
/// Empty `platforms` means every platform.
struct RegistryActionAvailability: Sendable, Hashable {
  let selection: String
  let platforms: [String]
  let excludeDestinations: [String]
  let onlyDestinations: [String]
  let requiresRecurrence: Bool
  /// The action's capability (`featureId`); a menu hides it where it does not ship.
  let featureId: String
}

/// One item in a context menu or menu-bar menu (`registry/actions.json`).
/// `kind` is `action`, `destination`, `submenu`, `divider` or `slot` (the shell fills a slot).
struct RegistryMenuItem: Sendable, Hashable, Identifiable {
  let kind: String
  let id: String
  let title: String?
  let sfSymbol: String?
  let items: [RegistryMenuItem]
}

/// One menu-bar menu. `system` names the platform menu it merges into (app, file, view, help).
struct RegistryMenu: Sendable, Hashable, Identifiable {
  let id: String
  let title: String
  let system: String?
  let items: [RegistryMenuItem]
}

enum RegistryActions {
  static let titles: [String: String] = [
    "task.editDetails": RegistryL10n.t("Edit Details…"),
    "task.toggleInfo": RegistryL10n.t("Show Info"),
    "task.copy": RegistryL10n.t("Copy"),
    "task.duplicate": RegistryL10n.t("Duplicate"),
    "task.toggleComplete": RegistryL10n.t("Mark as Complete"),
    "task.cancel": RegistryL10n.t("Cancel Task"),
    "task.toggleToday": RegistryL10n.t("Toggle Today"),
    "task.toggleStar": RegistryL10n.t("Toggle Star"),
    "task.tags": RegistryL10n.t("Tags…"),
    "task.addChecklistItem": RegistryL10n.t("Add Checklist Item"),
    "task.when": RegistryL10n.t("When…"),
    "task.deadline": RegistryL10n.t("Deadline…"),
    "task.reminder": RegistryL10n.t("Reminder…"),
    "task.move": RegistryL10n.t("Move…"),
    "task.moveSuggested": RegistryL10n.t("Move to Suggested List"),
    "task.clearSchedule": RegistryL10n.t("Clear When"),
    "task.repeat": RegistryL10n.t("Repeat…"),
    "task.pauseResumeRepeat": RegistryL10n.t("Pause Repeat"),
    "task.createNextCopy": RegistryL10n.t("Create Next Copy"),
    "task.delete": RegistryL10n.t("Delete"),
    "task.restore": RegistryL10n.t("Restore"),
    "task.deletePermanently": RegistryL10n.t("Delete Permanently"),
    "task.keepFaded": RegistryL10n.t("Keep"),
    "task.letGoFaded": RegistryL10n.t("Let Go"),
    "area.newProject": RegistryL10n.t("New Project in Area"),
    "area.rename": RegistryL10n.t("Rename"),
    "area.moveUp": RegistryL10n.t("Move Up"),
    "area.moveDown": RegistryL10n.t("Move Down"),
    "area.delete": RegistryL10n.t("Delete Area"),
    "project.rename": RegistryL10n.t("Rename"),
    "project.moveUp": RegistryL10n.t("Move Up"),
    "project.moveDown": RegistryL10n.t("Move Down"),
    "project.markDone": RegistryL10n.t("Mark Done"),
    "project.cancel": RegistryL10n.t("Cancel Project"),
    "project.delete": RegistryL10n.t("Delete Project"),
    "logged.clear": RegistryL10n.t("Clear Logged…"),
    "sidebar.newArea": RegistryL10n.t("New Area"),
    "sidebar.newProject": RegistryL10n.t("New Project"),
    "section.new": RegistryL10n.t("New Section"),
    "section.newTask": RegistryL10n.t("New Task in Section"),
    "section.rename": RegistryL10n.t("Rename"),
    "section.delete": RegistryL10n.t("Delete Section"),
    "notice.openStep": RegistryL10n.t("Open"),
    "notice.toggleStep": RegistryL10n.t("Mark as Done"),
    "notice.hideGetStarted": RegistryL10n.t("Hide Get Started"),
    "app.newTask": RegistryL10n.t("New Task"),
    "app.quickAdd": RegistryL10n.t("Quick Add…"),
    "app.quickEntry": RegistryL10n.t("Quick Entry"),
    "app.quickFind": RegistryL10n.t("Quick Find…"),
    "app.toggleSidebar": RegistryL10n.t("Show / Hide Sidebar"),
    "app.settings": RegistryL10n.t("Settings…"),
    "app.keyboardShortcuts": RegistryL10n.t("Keyboard Shortcuts"),
    "app.toggleSidebarCounts": RegistryL10n.t("Show Sidebar Counts"),
    "app.textSizeIncrease": RegistryL10n.t("Increase Text Size"),
    "app.textSizeDecrease": RegistryL10n.t("Decrease Text Size"),
    "app.textSizeReset": RegistryL10n.t("Reset Text Size"),
    "app.septenaWindow": RegistryL10n.t("Septena Window"),
    "app.classicWindow": RegistryL10n.t("Classic Window"),
  ]

  static let sfSymbols: [String: String] = [
    "task.editDetails": "info.circle",
    "task.toggleInfo": "info.circle",
    "task.copy": "doc.on.doc",
    "task.duplicate": "plus.square.on.square",
    "task.toggleComplete": "checkmark.circle",
    "task.cancel": "xmark.circle",
    "task.toggleToday": "sun.max.fill",
    "task.toggleStar": "star",
    "task.tags": "tag",
    "task.addChecklistItem": "checklist",
    "task.when": "calendar",
    "task.deadline": "flag",
    "task.reminder": "bell",
    "task.move": "folder",
    "task.moveSuggested": "folder",
    "task.clearSchedule": "calendar.badge.minus",
    "task.repeat": "arrow.clockwise",
    "task.pauseResumeRepeat": "pause.circle",
    "task.createNextCopy": "plus.circle",
    "task.delete": "trash",
    "task.restore": "arrow.uturn.backward",
    "task.deletePermanently": "trash",
    "task.keepFaded": "arrow.uturn.backward",
    "task.letGoFaded": "wind",
    "area.newProject": "plus",
    "area.rename": "pencil",
    "area.moveUp": "chevron.up",
    "area.moveDown": "chevron.down",
    "area.delete": "trash",
    "project.rename": "pencil",
    "project.moveUp": "chevron.up",
    "project.moveDown": "chevron.down",
    "project.markDone": "checkmark.circle",
    "project.cancel": "xmark.circle",
    "project.delete": "trash",
    "logged.clear": "trash",
    "sidebar.newArea": "plus",
    "sidebar.newProject": "plus",
    "section.new": "plus",
    "section.newTask": "plus",
    "section.rename": "pencil",
    "section.delete": "trash",
    "notice.openStep": "info.circle",
    "notice.toggleStep": "checkmark.circle",
    "notice.hideGetStarted": "xmark.circle",
    "app.newTask": "plus",
    "app.quickAdd": "plus",
    "app.quickEntry": "plus",
    "app.quickFind": "magnifyingglass",
    "app.toggleSidebar": "sidebar.leading",
    "app.settings": "checklist",
    "app.keyboardShortcuts": "info.circle",
    "app.toggleSidebarCounts": "number",
    "app.textSizeIncrease": "textformat.size",
    "app.textSizeDecrease": "textformat.size",
    "app.textSizeReset": "textformat.size",
    "app.septenaWindow": "macwindow",
    "app.classicWindow": "macwindow",
  ]

  /// Other titles of an action: `desktopTitle`, `activeTitle` (state on), `pluralTitle`, `addTitle`, `removeTitle`, `shortTitle` (swipe buttons).
  static let alternateTitles: [String: [String: String]] = [
    "task.editDetails": ["desktopTitle": RegistryL10n.t("Rename")],
    "task.toggleInfo": ["activeTitle": RegistryL10n.t("Hide Info")],
    "task.duplicate": ["pluralTitle": RegistryL10n.t("Duplicate Tasks")],
    "task.cancel": ["pluralTitle": RegistryL10n.t("Cancel Tasks")],
    "task.toggleToday": ["addTitle": RegistryL10n.t("Move to Today"), "removeTitle": RegistryL10n.t("Remove from Today"), "shortTitle": RegistryL10n.t("Today")],
    "task.toggleStar": ["addTitle": RegistryL10n.t("Star"), "removeTitle": RegistryL10n.t("Remove Star")],
    "task.when": ["shortTitle": RegistryL10n.t("Schedule")],
    "task.reminder": ["addTitle": RegistryL10n.t("Add Reminder…")],
    "task.move": ["pluralTitle": RegistryL10n.t("Move Tasks"), "shortTitle": RegistryL10n.t("Move")],
    "task.pauseResumeRepeat": ["activeTitle": RegistryL10n.t("Resume Repeat")],
    "task.delete": ["pluralTitle": RegistryL10n.t("Delete Tasks")],
    "notice.toggleStep": ["activeTitle": RegistryL10n.t("Mark as Not Done")],
    "app.toggleSidebar": ["addTitle": RegistryL10n.t("Show Sidebar"), "removeTitle": RegistryL10n.t("Hide Sidebar")],
    "app.toggleSidebarCounts": ["activeTitle": RegistryL10n.t("Hide Sidebar Counts")],
  ]

  static let shortcuts: [String: RegistryShortcut] = [
    "task.editDetails": RegistryShortcut(key: "r", modifiers: ["primary"], keycaps: ["⌘", "R"], excludePlatforms: []),
    "task.toggleInfo": RegistryShortcut(key: "i", modifiers: ["primary", "alt"], keycaps: ["⌥", "⌘", "I"], excludePlatforms: []),
    "task.copy": RegistryShortcut(key: "c", modifiers: ["primary"], keycaps: ["⌘", "C"], excludePlatforms: []),
    "task.duplicate": RegistryShortcut(key: "d", modifiers: ["primary"], keycaps: ["⌘", "D"], excludePlatforms: []),
    "task.toggleComplete": RegistryShortcut(key: "k", modifiers: ["primary"], keycaps: ["⌘", "K"], excludePlatforms: []),
    "task.cancel": RegistryShortcut(key: "k", modifiers: ["primary", "alt"], keycaps: ["⌥", "⌘", "K"], excludePlatforms: []),
    "task.toggleToday": RegistryShortcut(key: "t", modifiers: ["primary"], keycaps: ["⌘", "T"], excludePlatforms: []),
    "task.toggleStar": RegistryShortcut(key: "s", modifiers: ["primary", "alt"], keycaps: ["⌥", "⌘", "S"], excludePlatforms: []),
    "task.tags": RegistryShortcut(key: "t", modifiers: ["primary", "shift"], keycaps: ["⇧", "⌘", "T"], excludePlatforms: []),
    "task.addChecklistItem": RegistryShortcut(key: "c", modifiers: ["primary", "shift"], keycaps: ["⇧", "⌘", "C"], excludePlatforms: []),
    "task.when": RegistryShortcut(key: "s", modifiers: ["primary"], keycaps: ["⌘", "S"], excludePlatforms: []),
    "task.deadline": RegistryShortcut(key: "d", modifiers: ["primary", "shift"], keycaps: ["⇧", "⌘", "D"], excludePlatforms: []),
    "task.reminder": RegistryShortcut(key: "r", modifiers: ["primary", "alt"], keycaps: ["⌥", "⌘", "R"], excludePlatforms: []),
    "task.move": RegistryShortcut(key: "m", modifiers: ["primary", "shift"], keycaps: ["⇧", "⌘", "M"], excludePlatforms: [], alternates: [RegistryShortcut(key: "m", modifiers: ["primary"], keycaps: ["⌘", "M"], excludePlatforms: [])]),
    "task.moveSuggested": RegistryShortcut(key: "m", modifiers: ["primary", "alt"], keycaps: ["⌥", "⌘", "M"], excludePlatforms: []),
    "task.clearSchedule": RegistryShortcut(key: ".", modifiers: ["primary", "shift"], keycaps: ["⇧", "⌘", "."], excludePlatforms: []),
    "task.delete": RegistryShortcut(key: "delete", modifiers: ["primary"], keycaps: ["⌘", "⌫"], excludePlatforms: []),
    "task.deletePermanently": RegistryShortcut(key: "delete", modifiers: ["primary"], keycaps: ["⌘", "⌫"], excludePlatforms: []),
    "section.rename": RegistryShortcut(key: "r", modifiers: ["primary"], keycaps: ["⌘", "R"], excludePlatforms: []),
    "notice.toggleStep": RegistryShortcut(key: "k", modifiers: ["primary"], keycaps: ["⌘", "K"], excludePlatforms: []),
    "app.newTask": RegistryShortcut(key: "n", modifiers: ["primary"], keycaps: ["⌘", "N"], excludePlatforms: []),
    "app.quickAdd": RegistryShortcut(key: "i", modifiers: ["primary"], keycaps: ["⌘", "I"], excludePlatforms: []),
    "app.quickEntry": RegistryShortcut(key: "space", modifiers: ["ctrl", "alt"], keycaps: ["⌃", "⌥", "space"], excludePlatforms: []),
    "app.quickFind": RegistryShortcut(key: "f", modifiers: ["primary", "shift"], keycaps: ["⇧", "⌘", "F"], excludePlatforms: []),
    "app.toggleSidebar": RegistryShortcut(key: "s", modifiers: ["ctrl", "primary"], keycaps: ["⌃", "⌘", "S"], excludePlatforms: ["ios", "ipados"]),
    "app.settings": RegistryShortcut(key: ",", modifiers: ["primary"], keycaps: ["⌘", ","], excludePlatforms: []),
    "app.keyboardShortcuts": RegistryShortcut(key: "/", modifiers: ["primary", "shift"], keycaps: ["⇧", "⌘", "/"], excludePlatforms: []),
    "app.textSizeIncrease": RegistryShortcut(key: "+", modifiers: ["primary"], keycaps: ["⌘", "+"], excludePlatforms: []),
    "app.textSizeDecrease": RegistryShortcut(key: "-", modifiers: ["primary"], keycaps: ["⌘", "-"], excludePlatforms: []),
    "app.textSizeReset": RegistryShortcut(key: "0", modifiers: ["primary"], keycaps: ["⌘", "0"], excludePlatforms: []),
  ]

  /// Actions whose `role` is `destructive` (red in menus and swipes).
  static let destructive: Set<String> = [
    "task.delete",
    "task.deletePermanently",
    "area.delete",
    "project.delete",
    "logged.clear",
    "section.delete",
  ]

  static let availability: [String: RegistryActionAvailability] = [
    "task.editDetails": RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: ["recentlyDeleted"], onlyDestinations: [], requiresRecurrence: false, featureId: "lists.today"),
    "task.toggleInfo": RegistryActionAvailability(selection: "any", platforms: ["macos", "web", "windows"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "mac.keyboard"),
    "task.copy": RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "lists.today"),
    "task.duplicate": RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: ["recentlyDeleted"], onlyDestinations: [], requiresRecurrence: false, featureId: "lists.today"),
    "task.toggleComplete": RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: ["recentlyDeleted"], onlyDestinations: [], requiresRecurrence: false, featureId: "lists.today"),
    "task.cancel": RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: ["recentlyDeleted"], onlyDestinations: [], requiresRecurrence: false, featureId: "lists.today"),
    "task.toggleToday": RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: ["recentlyDeleted"], onlyDestinations: [], requiresRecurrence: false, featureId: "lists.today"),
    "task.toggleStar": RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: ["recentlyDeleted"], onlyDestinations: [], requiresRecurrence: false, featureId: "lists.starred"),
    "task.tags": RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: ["recentlyDeleted"], onlyDestinations: [], requiresRecurrence: false, featureId: "task.tags"),
    "task.addChecklistItem": RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: ["recentlyDeleted"], onlyDestinations: [], requiresRecurrence: false, featureId: "task.checklists"),
    "task.when": RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: ["recentlyDeleted"], onlyDestinations: [], requiresRecurrence: false, featureId: "task.when-deadline"),
    "task.deadline": RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: ["recentlyDeleted"], onlyDestinations: [], requiresRecurrence: false, featureId: "task.when-deadline"),
    "task.reminder": RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: ["recentlyDeleted"], onlyDestinations: [], requiresRecurrence: false, featureId: "task.alerts"),
    "task.move": RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: ["recentlyDeleted"], onlyDestinations: [], requiresRecurrence: false, featureId: "places.projects"),
    "task.moveSuggested": RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: ["logbook", "recentlyDeleted"], onlyDestinations: [], requiresRecurrence: false, featureId: "edit.filing-suggestion"),
    "task.clearSchedule": RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: ["recentlyDeleted"], onlyDestinations: [], requiresRecurrence: false, featureId: "task.when-deadline"),
    "task.repeat": RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: ["recentlyDeleted"], onlyDestinations: [], requiresRecurrence: false, featureId: "task.repeat"),
    "task.pauseResumeRepeat": RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: ["recentlyDeleted"], onlyDestinations: [], requiresRecurrence: true, featureId: "task.repeat"),
    "task.createNextCopy": RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: ["recentlyDeleted"], onlyDestinations: [], requiresRecurrence: true, featureId: "task.repeat"),
    "task.delete": RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: ["recentlyDeleted"], onlyDestinations: [], requiresRecurrence: false, featureId: "lists.recently-deleted"),
    "task.restore": RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: [], onlyDestinations: ["recentlyDeleted"], requiresRecurrence: false, featureId: "lists.recently-deleted"),
    "task.deletePermanently": RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: [], onlyDestinations: ["recentlyDeleted"], requiresRecurrence: false, featureId: "lists.recently-deleted"),
    "task.keepFaded": RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: [], onlyDestinations: ["faded"], requiresRecurrence: false, featureId: "fade.sweep"),
    "task.letGoFaded": RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: [], onlyDestinations: ["faded"], requiresRecurrence: false, featureId: "fade.sweep"),
    "area.newProject": RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.projects"),
    "area.rename": RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.areas"),
    "area.moveUp": RegistryActionAvailability(selection: "single", platforms: ["ios", "ipados", "android"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.areas"),
    "area.moveDown": RegistryActionAvailability(selection: "single", platforms: ["ios", "ipados", "android"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.areas"),
    "area.delete": RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.areas"),
    "project.rename": RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.projects"),
    "project.moveUp": RegistryActionAvailability(selection: "single", platforms: ["ios", "ipados", "android"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.projects"),
    "project.moveDown": RegistryActionAvailability(selection: "single", platforms: ["ios", "ipados", "android"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.projects"),
    "project.markDone": RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.projects"),
    "project.cancel": RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.projects"),
    "project.delete": RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.projects"),
    "logged.clear": RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "lists.logbook"),
    "sidebar.newArea": RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.areas"),
    "sidebar.newProject": RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.projects"),
    "section.new": RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.sections"),
    "section.newTask": RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.sections"),
    "section.rename": RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.sections"),
    "section.delete": RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.sections"),
    "notice.openStep": RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "lists.today"),
    "notice.toggleStep": RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "lists.today"),
    "notice.hideGetStarted": RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "lists.today"),
    "app.newTask": RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "lists.today"),
    "app.quickAdd": RegistryActionAvailability(selection: "none", platforms: ["ios", "ipados", "web", "android"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "capture.quick-add"),
    "app.quickEntry": RegistryActionAvailability(selection: "none", platforms: ["macos", "windows"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "capture.quick-entry"),
    "app.quickFind": RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "find.quick-find"),
    "app.toggleSidebar": RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "mac.keyboard"),
    "app.settings": RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "settings.display"),
    "app.keyboardShortcuts": RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "mac.keyboard"),
    "app.toggleSidebarCounts": RegistryActionAvailability(selection: "none", platforms: ["macos", "ipados", "web", "windows"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "settings.display"),
    "app.textSizeIncrease": RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "settings.display"),
    "app.textSizeDecrease": RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "settings.display"),
    "app.textSizeReset": RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "settings.display"),
    "app.septenaWindow": RegistryActionAvailability(selection: "none", platforms: ["macos"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "mac.keyboard"),
    "app.classicWindow": RegistryActionAvailability(selection: "none", platforms: ["macos"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "mac.keyboard"),
  ]

  /// Swipe slots in screen order, left to right (`swipeActions`).
  static let swipeLeading: [String] = ["task.toggleToday", "task.when"]
  static let swipeTrailing: [String] = ["task.move", "task.delete"]

  static let contextMenus: [String: [RegistryMenuItem]] = [
    "task.row": [
      RegistryMenuItem(kind: "action", id: "task.editDetails", title: RegistryL10n.t("Edit Details…"), sfSymbol: "info.circle", items: []),
      RegistryMenuItem(kind: "action", id: "task.toggleInfo", title: RegistryL10n.t("Show Info"), sfSymbol: "info.circle", items: []),
      RegistryMenuItem(kind: "action", id: "task.duplicate", title: RegistryL10n.t("Duplicate"), sfSymbol: "plus.square.on.square", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.3", title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "submenu", id: "complete", title: RegistryL10n.t("Complete"), sfSymbol: "checkmark.circle", items: [RegistryMenuItem(kind: "action", id: "task.toggleComplete", title: RegistryL10n.t("Mark as Complete"), sfSymbol: "checkmark.circle", items: []), RegistryMenuItem(kind: "action", id: "task.cancel", title: RegistryL10n.t("Cancel Task"), sfSymbol: "xmark.circle", items: []), RegistryMenuItem(kind: "divider", id: "divider.2", title: nil, sfSymbol: nil, items: []), RegistryMenuItem(kind: "action", id: "task.delete", title: RegistryL10n.t("Delete"), sfSymbol: "trash", items: [])]),
      RegistryMenuItem(kind: "action", id: "task.toggleToday", title: RegistryL10n.t("Toggle Today"), sfSymbol: "sun.max.fill", items: []),
      RegistryMenuItem(kind: "action", id: "task.toggleStar", title: RegistryL10n.t("Toggle Star"), sfSymbol: "star", items: []),
      RegistryMenuItem(kind: "action", id: "task.tags", title: RegistryL10n.t("Tags…"), sfSymbol: "tag", items: []),
      RegistryMenuItem(kind: "submenu", id: "schedule", title: RegistryL10n.t("Schedule"), sfSymbol: "calendar", items: [RegistryMenuItem(kind: "action", id: "task.when", title: RegistryL10n.t("When…"), sfSymbol: "calendar", items: []), RegistryMenuItem(kind: "action", id: "task.deadline", title: RegistryL10n.t("Deadline…"), sfSymbol: "flag", items: []), RegistryMenuItem(kind: "action", id: "task.reminder", title: RegistryL10n.t("Reminder…"), sfSymbol: "bell", items: []), RegistryMenuItem(kind: "divider", id: "divider.3", title: nil, sfSymbol: nil, items: []), RegistryMenuItem(kind: "action", id: "task.clearSchedule", title: RegistryL10n.t("Clear When"), sfSymbol: "calendar.badge.minus", items: [])]),
      RegistryMenuItem(kind: "submenu", id: "move", title: RegistryL10n.t("Move"), sfSymbol: "folder", items: [RegistryMenuItem(kind: "slot", id: "moveDestinations", title: nil, sfSymbol: nil, items: []), RegistryMenuItem(kind: "divider", id: "divider.1", title: nil, sfSymbol: nil, items: []), RegistryMenuItem(kind: "action", id: "task.move", title: RegistryL10n.t("Move…"), sfSymbol: "folder", items: [])]),
      RegistryMenuItem(kind: "submenu", id: "moveToSection", title: RegistryL10n.t("Move to Section"), sfSymbol: "text.append", items: [RegistryMenuItem(kind: "slot", id: "sectionDestinations", title: nil, sfSymbol: nil, items: [])]),
      RegistryMenuItem(kind: "action", id: "task.repeat", title: RegistryL10n.t("Repeat…"), sfSymbol: "arrow.clockwise", items: []),
      RegistryMenuItem(kind: "action", id: "task.pauseResumeRepeat", title: RegistryL10n.t("Pause Repeat"), sfSymbol: "pause.circle", items: []),
      RegistryMenuItem(kind: "action", id: "task.createNextCopy", title: RegistryL10n.t("Create Next Copy"), sfSymbol: "plus.circle", items: []),
    ],
    "task.recentlyDeleted": [
      RegistryMenuItem(kind: "action", id: "task.restore", title: RegistryL10n.t("Restore"), sfSymbol: "arrow.uturn.backward", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.1", title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "task.deletePermanently", title: RegistryL10n.t("Delete Permanently"), sfSymbol: "trash", items: []),
    ],
    "task.faded": [
      RegistryMenuItem(kind: "action", id: "task.keepFaded", title: RegistryL10n.t("Keep"), sfSymbol: "arrow.uturn.backward", items: []),
      RegistryMenuItem(kind: "action", id: "task.letGoFaded", title: RegistryL10n.t("Let Go"), sfSymbol: "wind", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.2", title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "task.delete", title: RegistryL10n.t("Delete"), sfSymbol: "trash", items: []),
    ],
    "sidebar.area": [
      RegistryMenuItem(kind: "action", id: "area.newProject", title: RegistryL10n.t("New Project in Area"), sfSymbol: "plus", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.1", title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "area.rename", title: RegistryL10n.t("Rename"), sfSymbol: "pencil", items: []),
      RegistryMenuItem(kind: "action", id: "area.moveUp", title: RegistryL10n.t("Move Up"), sfSymbol: "chevron.up", items: []),
      RegistryMenuItem(kind: "action", id: "area.moveDown", title: RegistryL10n.t("Move Down"), sfSymbol: "chevron.down", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.5", title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "area.delete", title: RegistryL10n.t("Delete Area"), sfSymbol: "trash", items: []),
    ],
    "sidebar.project": [
      RegistryMenuItem(kind: "action", id: "project.rename", title: RegistryL10n.t("Rename"), sfSymbol: "pencil", items: []),
      RegistryMenuItem(kind: "action", id: "project.moveUp", title: RegistryL10n.t("Move Up"), sfSymbol: "chevron.up", items: []),
      RegistryMenuItem(kind: "action", id: "project.moveDown", title: RegistryL10n.t("Move Down"), sfSymbol: "chevron.down", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.3", title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "submenu", id: "moveToArea", title: RegistryL10n.t("Move to Area"), sfSymbol: "folder", items: [RegistryMenuItem(kind: "slot", id: "moveToAreaDestinations", title: nil, sfSymbol: nil, items: [])]),
      RegistryMenuItem(kind: "divider", id: "divider.5", title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "project.markDone", title: RegistryL10n.t("Mark Done"), sfSymbol: "checkmark.circle", items: []),
      RegistryMenuItem(kind: "action", id: "project.cancel", title: RegistryL10n.t("Cancel Project"), sfSymbol: "xmark.circle", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.8", title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "project.delete", title: RegistryL10n.t("Delete Project"), sfSymbol: "trash", items: []),
    ],
    "sidebar.empty": [
      RegistryMenuItem(kind: "action", id: "sidebar.newArea", title: RegistryL10n.t("New Area"), sfSymbol: "plus", items: []),
      RegistryMenuItem(kind: "action", id: "sidebar.newProject", title: RegistryL10n.t("New Project"), sfSymbol: "plus", items: []),
    ],
    "project.heading": [
      RegistryMenuItem(kind: "action", id: "section.rename", title: RegistryL10n.t("Rename"), sfSymbol: "pencil", items: []),
      RegistryMenuItem(kind: "action", id: "section.newTask", title: RegistryL10n.t("New Task in Section"), sfSymbol: "plus", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.2", title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "section.delete", title: RegistryL10n.t("Delete Section"), sfSymbol: "trash", items: []),
    ],
    "project.blankSpace": [
      RegistryMenuItem(kind: "action", id: "section.new", title: RegistryL10n.t("New Section"), sfSymbol: "plus", items: []),
    ],
    "scope.loggedFooter": [
      RegistryMenuItem(kind: "action", id: "logged.clear", title: RegistryL10n.t("Clear Logged…"), sfSymbol: "trash", items: []),
    ],
    "notice.getStartedStep": [
      RegistryMenuItem(kind: "action", id: "notice.openStep", title: RegistryL10n.t("Open"), sfSymbol: "info.circle", items: []),
      RegistryMenuItem(kind: "action", id: "notice.toggleStep", title: RegistryL10n.t("Mark as Done"), sfSymbol: "checkmark.circle", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.2", title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "notice.hideGetStarted", title: RegistryL10n.t("Hide Get Started"), sfSymbol: "xmark.circle", items: []),
    ],
  ]

  static let menuBar: [RegistryMenu] = [
    RegistryMenu(id: "app", title: RegistryL10n.t("Septena"), system: "app", items: [
      RegistryMenuItem(kind: "action", id: "app.settings", title: RegistryL10n.t("Settings…"), sfSymbol: "checklist", items: []),
    ]),
    RegistryMenu(id: "file", title: RegistryL10n.t("File"), system: "file", items: [
      RegistryMenuItem(kind: "action", id: "app.newTask", title: RegistryL10n.t("New Task"), sfSymbol: "plus", items: []),
      RegistryMenuItem(kind: "action", id: "app.quickAdd", title: RegistryL10n.t("Quick Add…"), sfSymbol: "plus", items: []),
    ]),
    RegistryMenu(id: "view", title: RegistryL10n.t("View"), system: "view", items: [
      RegistryMenuItem(kind: "action", id: "app.toggleSidebar", title: RegistryL10n.t("Show / Hide Sidebar"), sfSymbol: "sidebar.leading", items: []),
      RegistryMenuItem(kind: "action", id: "task.toggleInfo", title: RegistryL10n.t("Show Info"), sfSymbol: "info.circle", items: []),
      RegistryMenuItem(kind: "action", id: "app.toggleSidebarCounts", title: RegistryL10n.t("Show Sidebar Counts"), sfSymbol: "number", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.3", title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "submenu", id: "textSize", title: RegistryL10n.t("Text Size"), sfSymbol: "textformat.size", items: [RegistryMenuItem(kind: "slot", id: "textSizeSteps", title: nil, sfSymbol: nil, items: []), RegistryMenuItem(kind: "divider", id: "divider.1", title: nil, sfSymbol: nil, items: []), RegistryMenuItem(kind: "action", id: "app.textSizeIncrease", title: RegistryL10n.t("Increase Text Size"), sfSymbol: "textformat.size", items: []), RegistryMenuItem(kind: "action", id: "app.textSizeDecrease", title: RegistryL10n.t("Decrease Text Size"), sfSymbol: "textformat.size", items: []), RegistryMenuItem(kind: "action", id: "app.textSizeReset", title: RegistryL10n.t("Reset Text Size"), sfSymbol: "textformat.size", items: [])]),
    ]),
    RegistryMenu(id: "go", title: RegistryL10n.t("Go"), system: nil, items: [
      RegistryMenuItem(kind: "destination", id: "today", title: RegistryL10n.t("Today"), sfSymbol: "sun.max.fill", items: []),
      RegistryMenuItem(kind: "destination", id: "review", title: RegistryL10n.t("Review"), sfSymbol: "eye", items: []),
      RegistryMenuItem(kind: "destination", id: "agent", title: RegistryL10n.t("Agent"), sfSymbol: "sparkles", items: []),
      RegistryMenuItem(kind: "destination", id: "upcoming", title: RegistryL10n.t("Upcoming"), sfSymbol: "calendar", items: []),
      RegistryMenuItem(kind: "destination", id: "repeating", title: RegistryL10n.t("Repeating"), sfSymbol: "arrow.clockwise", items: []),
      RegistryMenuItem(kind: "destination", id: "anytime", title: RegistryL10n.t("Anytime"), sfSymbol: "rectangle.stack.fill", items: []),
      RegistryMenuItem(kind: "destination", id: "logbook", title: RegistryL10n.t("Logbook"), sfSymbol: "checkmark", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.7", title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "app.quickFind", title: RegistryL10n.t("Quick Find…"), sfSymbol: "magnifyingglass", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.9", title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "app.septenaWindow", title: RegistryL10n.t("Septena Window"), sfSymbol: "macwindow", items: []),
      RegistryMenuItem(kind: "action", id: "app.classicWindow", title: RegistryL10n.t("Classic Window"), sfSymbol: "macwindow", items: []),
      RegistryMenuItem(kind: "action", id: "app.quickEntry", title: RegistryL10n.t("Quick Entry"), sfSymbol: "plus", items: []),
    ]),
    RegistryMenu(id: "task", title: RegistryL10n.t("Task"), system: nil, items: [
      RegistryMenuItem(kind: "action", id: "sidebar.newProject", title: RegistryL10n.t("New Project"), sfSymbol: "plus", items: []),
      RegistryMenuItem(kind: "action", id: "sidebar.newArea", title: RegistryL10n.t("New Area"), sfSymbol: "plus", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.2", title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "task.editDetails", title: RegistryL10n.t("Rename"), sfSymbol: "info.circle", items: []),
      RegistryMenuItem(kind: "action", id: "task.duplicate", title: RegistryL10n.t("Duplicate"), sfSymbol: "plus.square.on.square", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.5", title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "submenu", id: "complete", title: RegistryL10n.t("Complete"), sfSymbol: "checkmark.circle", items: [RegistryMenuItem(kind: "action", id: "task.toggleComplete", title: RegistryL10n.t("Mark as Complete"), sfSymbol: "checkmark.circle", items: []), RegistryMenuItem(kind: "action", id: "task.cancel", title: RegistryL10n.t("Cancel Task"), sfSymbol: "xmark.circle", items: []), RegistryMenuItem(kind: "divider", id: "divider.2", title: nil, sfSymbol: nil, items: []), RegistryMenuItem(kind: "action", id: "task.delete", title: RegistryL10n.t("Delete"), sfSymbol: "trash", items: [])]),
      RegistryMenuItem(kind: "action", id: "task.toggleToday", title: RegistryL10n.t("Toggle Today"), sfSymbol: "sun.max.fill", items: []),
      RegistryMenuItem(kind: "action", id: "task.toggleStar", title: RegistryL10n.t("Toggle Star"), sfSymbol: "star", items: []),
      RegistryMenuItem(kind: "action", id: "task.tags", title: RegistryL10n.t("Tags…"), sfSymbol: "tag", items: []),
      RegistryMenuItem(kind: "action", id: "task.addChecklistItem", title: RegistryL10n.t("Add Checklist Item"), sfSymbol: "checklist", items: []),
      RegistryMenuItem(kind: "action", id: "task.when", title: RegistryL10n.t("When…"), sfSymbol: "calendar", items: []),
      RegistryMenuItem(kind: "action", id: "task.deadline", title: RegistryL10n.t("Deadline…"), sfSymbol: "flag", items: []),
      RegistryMenuItem(kind: "action", id: "task.reminder", title: RegistryL10n.t("Reminder…"), sfSymbol: "bell", items: []),
      RegistryMenuItem(kind: "action", id: "task.move", title: RegistryL10n.t("Move…"), sfSymbol: "folder", items: []),
      RegistryMenuItem(kind: "action", id: "task.clearSchedule", title: RegistryL10n.t("Clear When"), sfSymbol: "calendar.badge.minus", items: []),
      RegistryMenuItem(kind: "action", id: "task.repeat", title: RegistryL10n.t("Repeat…"), sfSymbol: "arrow.clockwise", items: []),
      RegistryMenuItem(kind: "action", id: "task.createNextCopy", title: RegistryL10n.t("Create Next Copy"), sfSymbol: "plus.circle", items: []),
    ]),
    RegistryMenu(id: "help", title: RegistryL10n.t("Help"), system: "help", items: [
      RegistryMenuItem(kind: "action", id: "app.keyboardShortcuts", title: RegistryL10n.t("Keyboard Shortcuts"), sfSymbol: "info.circle", items: []),
    ]),
  ]

  static let shortcutsGeneral: [RegistryShortcutEntry] = [
    RegistryShortcutEntry(id: "app.newTask", label: RegistryL10n.t("New Task"), keycaps: ["⌘", "N"], excludePlatforms: []),
    RegistryShortcutEntry(id: "app.quickAdd", label: RegistryL10n.t("Quick Add…"), keycaps: ["⌘", "I"], excludePlatforms: []),
    RegistryShortcutEntry(id: "app.quickFind", label: RegistryL10n.t("Quick Find…"), keycaps: ["⇧", "⌘", "F"], excludePlatforms: []),
    RegistryShortcutEntry(id: "app.toggleSidebar", label: RegistryL10n.t("Show / Hide Sidebar"), keycaps: ["⌃", "⌘", "S"], excludePlatforms: ["ios", "ipados"]),
    RegistryShortcutEntry(id: "app.settings", label: RegistryL10n.t("Settings…"), keycaps: ["⌘", ","], excludePlatforms: []),
    RegistryShortcutEntry(id: "app.keyboardShortcuts", label: RegistryL10n.t("Keyboard Shortcuts"), keycaps: ["⇧", "⌘", "/"], excludePlatforms: []),
  ]
  static let shortcutsTaskList: [RegistryShortcutEntry] = [
    RegistryShortcutEntry(id: "task.editDetails", label: RegistryL10n.t("Edit Details…"), keycaps: ["⌘", "R"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.toggleInfo", label: RegistryL10n.t("Show Info"), keycaps: ["⌥", "⌘", "I"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.copy", label: RegistryL10n.t("Copy"), keycaps: ["⌘", "C"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.duplicate", label: RegistryL10n.t("Duplicate"), keycaps: ["⌘", "D"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.toggleComplete", label: RegistryL10n.t("Mark as Complete"), keycaps: ["⌘", "K"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.cancel", label: RegistryL10n.t("Cancel Task"), keycaps: ["⌥", "⌘", "K"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.toggleToday", label: RegistryL10n.t("Toggle Today"), keycaps: ["⌘", "T"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.toggleStar", label: RegistryL10n.t("Toggle Star"), keycaps: ["⌥", "⌘", "S"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.tags", label: RegistryL10n.t("Tags…"), keycaps: ["⇧", "⌘", "T"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.addChecklistItem", label: RegistryL10n.t("Add Checklist Item"), keycaps: ["⇧", "⌘", "C"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.when", label: RegistryL10n.t("When…"), keycaps: ["⌘", "S"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.deadline", label: RegistryL10n.t("Deadline…"), keycaps: ["⇧", "⌘", "D"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.reminder", label: RegistryL10n.t("Reminder…"), keycaps: ["⌥", "⌘", "R"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.move", label: RegistryL10n.t("Move…"), keycaps: ["⇧", "⌘", "M"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.move.alt0", label: RegistryL10n.t("Move…"), keycaps: ["⌘", "M"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.moveSuggested", label: RegistryL10n.t("Move to Suggested List"), keycaps: ["⌥", "⌘", "M"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.clearSchedule", label: RegistryL10n.t("Clear When"), keycaps: ["⇧", "⌘", "."], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.delete", label: RegistryL10n.t("Delete"), keycaps: ["⌘", "⌫"], excludePlatforms: []),
  ]
}

/// One notice in a task list (`registry/surfaces.json` `notices`). A notice whose
/// title has a count gets a title function in `RegistryNotices` instead of `title`.
struct RegistryNotice: Sendable, Hashable, Identifiable {
  let id: String
  let kind: String
  let priority: Int
  let iconId: String
  let sfSymbol: String
  let dismissScope: String
  let dismissible: Bool
  let explainerSlot: Bool
  let featureId: String
  let title: String?
  let detail: String?
  /// Platform key (`ios`, `ipados`, `macos`, …) → detail that replaces `detail` there.
  let platformDetails: [String: String]
  let primaryTitle: String?
  let steps: [RegistryNoticeStep]
  func detail(for platform: String) -> String? { platformDetails[platform] ?? detail }
}

struct RegistryNoticeStep: Sendable, Hashable, Identifiable {
  let id: String
  let title: String
  let detail: String
  let platformDetails: [String: String]
  func detail(for platform: String) -> String { platformDetails[platform] ?? detail }
}

enum RegistryNotices {
  static let maxConcurrentExplainers: Int = 1
  /// The close button's title and accessibility label on every notice.
  static let dismissTitle: String = RegistryL10n.t("Dismiss")
  static let all: [RegistryNotice] = [
    RegistryNotice(id: "signIn", kind: "actionNeeded", priority: 0, iconId: "notice.sign_in", sfSymbol: "person.crop.circle.badge.exclamationmark", dismissScope: "device", dismissible: true, explainerSlot: false, featureId: "sync.backend", title: RegistryL10n.t("Not signed in"), detail: RegistryL10n.t("Your changes stay on this device until you sign in."), platformDetails: ["macos": RegistryL10n.t("Your changes stay on this Mac until you sign in."), "ipados": RegistryL10n.t("Your changes stay on this iPad until you sign in."), "ios": RegistryL10n.t("Your changes stay on this iPhone until you sign in.")], primaryTitle: RegistryL10n.t("Sign in…"), steps: []),
    RegistryNotice(id: "rolledIn", kind: "info", priority: 1, iconId: "notice.rolled_in", sfSymbol: "arrow.down.circle", dismissScope: "accountDay", dismissible: true, explainerSlot: false, featureId: "lists.today", title: nil, detail: nil, platformDetails: [:], primaryTitle: nil, steps: []),
    RegistryNotice(id: "getStarted", kind: "info", priority: 2, iconId: "notice.get_started", sfSymbol: "sparkles", dismissScope: "account", dismissible: true, explainerSlot: true, featureId: "lists.today", title: RegistryL10n.t("Get started with Septena"), detail: nil, platformDetails: [:], primaryTitle: nil, steps: [RegistryNoticeStep(id: "connectAI", title: RegistryL10n.t("Connect your agent"), detail: RegistryL10n.t("Let Claude or your own agent work your list"), platformDetails: [:]), RegistryNoticeStep(id: "importTasks", title: RegistryL10n.t("Bring in your tasks"), detail: RegistryL10n.t("Import from another app"), platformDetails: [:]), RegistryNoticeStep(id: "addTask", title: RegistryL10n.t("Add your first task"), detail: RegistryL10n.t("It lands in your Inbox until you schedule or file it"), platformDetails: ["macos": RegistryL10n.t("Or press ⌃⌥Space anywhere on your Mac")])]),
    RegistryNotice(id: "weeklySweep", kind: "info", priority: 3, iconId: "notice.weekly_sweep", sfSymbol: "circle.dashed", dismissScope: "accountWeek", dismissible: true, explainerSlot: false, featureId: "fade.sweep", title: nil, detail: nil, platformDetails: [:], primaryTitle: RegistryL10n.t("Sweep"), steps: []),
    RegistryNotice(id: "fadedPile", kind: "info", priority: 5, iconId: "notice.weekly_sweep", sfSymbol: "circle.dashed", dismissScope: "none", dismissible: false, explainerSlot: false, featureId: "lists.faded", title: RegistryL10n.t("Tasks without activity for 14 days"), detail: RegistryL10n.t("Open a task or choose Keep to bring it back, or sweep the list to let the rest go."), platformDetails: [:], primaryTitle: RegistryL10n.t("Sweep…"), steps: []),
    RegistryNotice(id: "fadeIntro", kind: "info", priority: 4, iconId: "notice.fade_intro", sfSymbol: "circle.lefthalf.filled", dismissScope: "device", dismissible: true, explainerSlot: true, featureId: "task.aging", title: RegistryL10n.t("Inactive tasks start to fade"), detail: RegistryL10n.t("Undated tasks fade after 14 days without activity and move to Faded. Open or edit a task to bring it back. You can turn this off in Settings."), platformDetails: [:], primaryTitle: nil, steps: []),
  ]
  static let byId: [String: RegistryNotice] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
  static func rolledInTitle(count: Int) -> String { RegistryL10n.plural("%lld tasks rolled into Today", count: count, one: "1 task rolled into Today", other: "%lld tasks rolled into Today", args: [count]) }
  static func weeklySweepTitle(count: Int) -> String { RegistryL10n.plural("%lld tasks faded this week", count: count, one: "1 task faded this week", other: "%lld tasks faded this week", args: [count]) }
}

/// Destructive and fork confirmation copy (`registry/surfaces.json` `prompts`).
struct RegistryPromptCopy: Sendable, Hashable {
  let id: String
  let title: String
  let message: String
  let confirmTitle: String?
  /// Fork prompts only: the choices, in order.
  let options: [RegistryPromptOption]
}

struct RegistryPromptOption: Sendable, Hashable, Identifiable {
  let id: String
  let title: String
}

/// A prompt that asks for a name (`registry/surfaces.json` `prompts.text`).
struct RegistryTextPrompt: Sendable, Hashable, Identifiable {
  let id: String
  let title: String
  let placeholder: String
  let confirmTitle: String
}

enum RegistryPrompts {
  static let cancelTitle: String = RegistryL10n.t("Cancel")
  static let errorTitle: String = RegistryL10n.t("Error")
  static let errorConfirmTitle: String = RegistryL10n.t("OK")
  /// Prompts with fixed copy. Prompts with counts or names are functions below.
  static let fixed: [String: RegistryPromptCopy] = [
    "deleteSection": RegistryPromptCopy(id: "deleteSection", title: RegistryL10n.t("Delete this section?"), message: RegistryL10n.t("Its tasks stay in the project."), confirmTitle: RegistryL10n.t("Delete Section"), options: []),
    "deleteAccount": RegistryPromptCopy(id: "deleteAccount", title: RegistryL10n.t("Delete Account?"), message: RegistryL10n.t("Your tasks, areas, projects, and conversations are erased from the server and this device."), confirmTitle: RegistryL10n.t("Delete Account"), options: []),
    "rescheduleFixedRepeat": RegistryPromptCopy(id: "rescheduleFixedRepeat", title: RegistryL10n.t("Reschedule repeating task?"), message: RegistryL10n.t("Move only this task, or update the repeating schedule to the new date?"), confirmTitle: nil, options: [RegistryPromptOption(id: "exception", title: RegistryL10n.t("Only This Task")), RegistryPromptOption(id: "updateRule", title: RegistryL10n.t("Update Schedule"))]),
  ]
  static let text: [String: RegistryTextPrompt] = [
    "newSection": RegistryTextPrompt(id: "newSection", title: RegistryL10n.t("New Section"), placeholder: RegistryL10n.t("Section name"), confirmTitle: RegistryL10n.t("Add")),
    "renameSection": RegistryTextPrompt(id: "renameSection", title: RegistryL10n.t("Rename Section"), placeholder: RegistryL10n.t("Section name"), confirmTitle: RegistryL10n.t("Rename")),
    "newArea": RegistryTextPrompt(id: "newArea", title: RegistryL10n.t("New Area"), placeholder: RegistryL10n.t("Area name"), confirmTitle: RegistryL10n.t("Create")),
    "renameArea": RegistryTextPrompt(id: "renameArea", title: RegistryL10n.t("Rename Area"), placeholder: RegistryL10n.t("Area name"), confirmTitle: RegistryL10n.t("Rename")),
    "newProject": RegistryTextPrompt(id: "newProject", title: RegistryL10n.t("New Project"), placeholder: RegistryL10n.t("Project name"), confirmTitle: RegistryL10n.t("Create")),
    "renameProject": RegistryTextPrompt(id: "renameProject", title: RegistryL10n.t("Rename Project"), placeholder: RegistryL10n.t("Project name"), confirmTitle: RegistryL10n.t("Rename")),
  ]
  static func tasksPhrase(count: Int) -> String { RegistryL10n.plural("%lld tasks", count: count, one: "1 task", other: "%lld tasks", args: [count]) }
  static func projectsPhrase(count: Int) -> String { RegistryL10n.plural("%lld projects", count: count, one: "1 project", other: "%lld projects", args: [count]) }
  static func deletePermanently(count: Int) -> RegistryPromptCopy {
    RegistryPromptCopy(id: "deletePermanently", title: RegistryL10n.plural("Delete %lld tasks permanently?", count: count, one: "Delete this task permanently?", other: "Delete %lld tasks permanently?", args: [count]), message: RegistryL10n.t("You can’t undo this."), confirmTitle: RegistryL10n.t("Delete Permanently"), options: [])
  }
  static func deleteArea(name: String, projects: Int, tasks: Int) -> RegistryPromptCopy {
    let name = name.isEmpty ? RegistryL10n.t("Area") : name
    let projectPhrase = projectsPhrase(count: projects)
    let taskPhrase = tasksPhrase(count: tasks)
    if projects == 0 && tasks == 0 { return RegistryPromptCopy(id: "deleteArea", title: RegistryL10n.format("Delete “%@”?", english: "Delete “%@”?", args: [name]), message: RegistryL10n.t("You can undo this."), confirmTitle: RegistryL10n.t("Delete"), options: []) }
    if projects == 0 { return RegistryPromptCopy(id: "deleteArea", title: RegistryL10n.format("Delete “%@” and its %@?", english: "Delete “%@” and its %@?", args: [name, taskPhrase]), message: RegistryL10n.t("The tasks move to Recently Deleted. You can undo this."), confirmTitle: RegistryL10n.t("Delete"), options: []) }
    if tasks == 0 { return RegistryPromptCopy(id: "deleteArea", title: RegistryL10n.format("Delete “%@” and its %@? (projects only)", english: "Delete “%@” and its %@?", args: [name, projectPhrase]), message: RegistryL10n.t("You can undo this."), confirmTitle: RegistryL10n.t("Delete"), options: []) }
    return RegistryPromptCopy(id: "deleteArea", title: RegistryL10n.format("Delete “%@”, its %@ and %@?", english: "Delete “%@”, its %@ and %@?", args: [name, projectPhrase, taskPhrase]), message: RegistryL10n.t("The tasks move to Recently Deleted. You can undo this."), confirmTitle: RegistryL10n.t("Delete"), options: [])
  }
  static func deleteProject(name: String, tasks: Int) -> RegistryPromptCopy {
    let name = name.isEmpty ? RegistryL10n.t("Project") : name
    let taskPhrase = tasksPhrase(count: tasks)
    if tasks == 0 { return RegistryPromptCopy(id: "deleteProject", title: RegistryL10n.format("Delete “%@”?", english: "Delete “%@”?", args: [name]), message: RegistryL10n.t("You can undo this."), confirmTitle: RegistryL10n.t("Delete"), options: []) }
    return RegistryPromptCopy(id: "deleteProject", title: RegistryL10n.format("Delete “%@” and its %@?", english: "Delete “%@” and its %@?", args: [name, taskPhrase]), message: RegistryL10n.t("The tasks move to Recently Deleted. You can undo this."), confirmTitle: RegistryL10n.t("Delete"), options: [])
  }
  static func clearLogged(count: Int, name: String) -> RegistryPromptCopy {
    RegistryPromptCopy(id: "clearLogged", title: RegistryL10n.plural("Clear %lld logged items from “%@”?", count: count, one: "Clear 1 logged item from “%2$@”?", other: "Clear %lld logged items from “%@”?", args: [count, name]), message: RegistryL10n.t("Cleared items move to Recently Deleted. You can undo this."), confirmTitle: RegistryL10n.t("Clear"), options: [])
  }
}

/// Snackbar copy (`registry/surfaces.json` `toasts`).
enum RegistryToasts {
  /// How long a snackbar stays (`registry/rules.json` `toastDurationSeconds`).
  static let durationSeconds: Double = Double(RegistryRules.toastDurationSeconds)
  static func deferred(date: String) -> String { RegistryL10n.format("Moved to %@ (When)", english: "Moved to %@", args: [date]) }
  static func moved(destination: String) -> String { RegistryL10n.format("Moved to %@", english: "Moved to %@", args: [destination]) }
  static func deletedSingle(title: String) -> String { title.isEmpty ? RegistryL10n.t("Task deleted") : RegistryL10n.format("“%@” deleted", english: "“%@” deleted", args: [title]) }
  static func deletedBulk(count: Int) -> String { RegistryL10n.plural("%lld tasks deleted", count: count, one: "Task deleted", other: "%lld tasks deleted", args: [count]) }
  static func movedBulk(count: Int, destination: String) -> String { RegistryL10n.plural("Moved %lld tasks to %@", count: count, one: "Moved to %2$@", other: "Moved %lld tasks to %@", args: [count, destination]) }
}

/// One task attribute (`registry/surfaces.json` `taskAttributes`): a composer
/// pill, an inspector row and a picker title. `surfaceTier` `field` is an
/// always-visible field (notes), not a pill. `chip` is a transient composer
/// chip shown only on a blank new task (Paste), not a pill. `editOnly` needs a saved task.
struct RegistryTaskAttribute: Sendable, Hashable, Identifiable {
  let id: String
  let label: String
  let iconId: String
  let sfSymbol: String
  let commitContract: String
  let surfaceTier: String
  let featureId: String
  let editOnly: Bool
  /// Pill text while the attribute's work runs (Discuss).
  let workingLabel: String?
  var isPill: Bool { surfaceTier == "inline" || surfaceTier == "popover" }
  /// The attribute shows on `platform` when its capability ships (ADR 0015).
  func applies(to platform: String) -> Bool { RegistryCapabilities.isAvailable(featureId, on: platform) }
}

enum RegistrySurfaces {
  static let taskAttributes: [RegistryTaskAttribute] = [
    RegistryTaskAttribute(id: "notes", label: RegistryL10n.t("Notes"), iconId: "action.notes", sfSymbol: "text.alignleft", commitContract: "closeCommits", surfaceTier: "field", featureId: "task.notes", editOnly: false, workingLabel: nil),
    RegistryTaskAttribute(id: "when", label: RegistryL10n.t("When"), iconId: "action.when", sfSymbol: "calendar", commitContract: "pickCommits", surfaceTier: "popover", featureId: "task.when-deadline", editOnly: false, workingLabel: nil),
    RegistryTaskAttribute(id: "deadline", label: RegistryL10n.t("Deadline"), iconId: "action.deadline", sfSymbol: "flag", commitContract: "pickCommits", surfaceTier: "popover", featureId: "task.when-deadline", editOnly: false, workingLabel: nil),
    RegistryTaskAttribute(id: "reminder", label: RegistryL10n.t("Remind"), iconId: "action.reminder", sfSymbol: "bell", commitContract: "pickCommits", surfaceTier: "popover", featureId: "task.alerts", editOnly: false, workingLabel: nil),
    RegistryTaskAttribute(id: "repeat", label: RegistryL10n.t("Repeat"), iconId: "action.repeat", sfSymbol: "arrow.clockwise", commitContract: "closeCommits", surfaceTier: "popover", featureId: "task.repeat", editOnly: false, workingLabel: nil),
    RegistryTaskAttribute(id: "star", label: RegistryL10n.t("Star"), iconId: "action.star", sfSymbol: "star", commitContract: "pickCommits", surfaceTier: "inline", featureId: "lists.starred", editOnly: false, workingLabel: nil),
    RegistryTaskAttribute(id: "list", label: RegistryL10n.t("List"), iconId: "action.move", sfSymbol: "folder", commitContract: "pickCommits", surfaceTier: "popover", featureId: "places.projects", editOnly: false, workingLabel: nil),
    RegistryTaskAttribute(id: "tags", label: RegistryL10n.t("Tags"), iconId: "action.tag", sfSymbol: "tag", commitContract: "pickCommits", surfaceTier: "popover", featureId: "task.tags", editOnly: true, workingLabel: nil),
    RegistryTaskAttribute(id: "checklist", label: RegistryL10n.t("Checklist"), iconId: "action.checklist", sfSymbol: "checklist", commitContract: "pickCommits", surfaceTier: "inline", featureId: "task.checklists", editOnly: true, workingLabel: nil),
    RegistryTaskAttribute(id: "attachments", label: RegistryL10n.t("Attachments"), iconId: "action.attachment", sfSymbol: "paperclip", commitContract: "pickCommits", surfaceTier: "inline", featureId: "task.attachments", editOnly: true, workingLabel: nil),
    RegistryTaskAttribute(id: "discuss", label: RegistryL10n.t("Discuss"), iconId: "action.discuss", sfSymbol: "bubble.left.and.bubble.right", commitContract: "closeCommits", surfaceTier: "inline", featureId: "ai.discuss", editOnly: true, workingLabel: RegistryL10n.t("Thinking…")),
    RegistryTaskAttribute(id: "paste", label: RegistryL10n.t("Paste"), iconId: "action.paste", sfSymbol: "doc.on.clipboard", commitContract: "pickCommits", surfaceTier: "chip", featureId: "capture.quick-entry", editOnly: false, workingLabel: nil),
  ]
  /// The pills that show on `platform`, in rail order (every attribute except
  /// fields and chips, whose capability ships there).
  static func taskAttributePills(on platform: String) -> [RegistryTaskAttribute] {
    taskAttributes.filter { $0.isPill && $0.applies(to: platform) }
  }
  /// The attribute with `id`. Traps on an unknown id: the ids are a closed set.
  static func taskAttribute(_ id: String) -> RegistryTaskAttribute {
    guard let a = taskAttributes.first(where: { $0.id == id }) else { preconditionFailure("unknown task attribute \(id)") }
    return a
  }
  /// Count text for a pill value (`countLabel`), or nil when the attribute has none.
  static func taskAttributeCount(_ id: String, count: Int) -> String? {
    switch id {
    case "tags": return RegistryL10n.plural("%lld tags", count: count, one: "%lld tag", other: "%lld tags", args: [count])
    case "attachments": return RegistryL10n.plural("%lld files", count: count, one: "%lld file", other: "%lld files", args: [count])
    default: return nil
    }
  }
}

/// One button in the first run. `action` is one of a closed set the client implements.
struct RegistryFirstRunButton: Sendable, Hashable {
  let title: String
  let action: String
}

struct RegistryFirstRunPoint: Sendable, Hashable {
  let icon: String
  let title: String
  let detail: String
}

struct RegistryFirstRunChoice: Sendable, Hashable, Identifiable {
  let id: String
  let icon: String
  let title: String
  let detail: String
  let action: String
  let platforms: [String]
}

/// One first-run step (`registry/surfaces.json` `firstRun.steps`). `kind` picks the view.
struct RegistryFirstRunStep: Sendable, Hashable, Identifiable {
  let id: String
  let kind: String
  let icon: String
  let title: String
  let body: String
  let footnote: String?
  let returningTitle: String?
  let returningBody: String?
  let skipWhen: String?
  let requires: String?
  let completesGetStartedStep: String?
  let points: [RegistryFirstRunPoint]
  let choices: [RegistryFirstRunChoice]
  let instructions: [String]
  let primary: RegistryFirstRunButton?
  let secondary: RegistryFirstRunButton?
  let tertiary: RegistryFirstRunButton?
  /// Replaces `secondary` once the step's work is done (paired, imported).
  let afterDone: RegistryFirstRunButton?
}

enum RegistryFirstRun {
  static let featureId: String = "onboarding.first-run"
  /// The synced setting that records a finished first run, so a second device skips it.
  static let completionSetting: String = "onboardedAt"
  static let setupPrompt: String = RegistryL10n.t("Set up Septena for me using https://septena.app/agents.md")
  static let firstPrompt: String = RegistryL10n.t("Set up my Septena areas, projects, and tasks by following https://api.septena.app/onboard.md")
  static let steps: [RegistryFirstRunStep] = [
    RegistryFirstRunStep(id: "welcome", kind: "intro", icon: "onboarding.welcome", title: RegistryL10n.t("Welcome to Septena"), body: RegistryL10n.t("Tasks that think with you."), footnote: nil, returningTitle: nil, returningBody: nil, skipWhen: nil, requires: nil, completesGetStartedStep: nil, points: [RegistryFirstRunPoint(icon: "onboarding.devices", title: RegistryL10n.t("On every device"), detail: RegistryL10n.t("Your tasks stay in step on iPhone, iPad and Mac.")), RegistryFirstRunPoint(icon: "onboarding.agent", title: RegistryL10n.t("Your agents do the work"), detail: RegistryL10n.t("You decide when it’s done.")), RegistryFirstRunPoint(icon: "onboarding.notes", title: RegistryL10n.t("Notes keep the context"), detail: RegistryL10n.t("Each project has notes, so you and Claude know what it’s for."))], choices: [], instructions: [], primary: RegistryFirstRunButton(title: RegistryL10n.t("Continue"), action: "next"), secondary: nil, tertiary: nil, afterDone: nil),
    RegistryFirstRunStep(id: "account", kind: "account", icon: "onboarding.account", title: RegistryL10n.t("Sign in to sync"), body: RegistryL10n.t("Sign in with Apple to keep your tasks on all your devices and to let Claude connect. Septena never sees your Apple password."), footnote: RegistryL10n.t("If you skip this, your tasks stay on this device until you sign in."), returningTitle: nil, returningBody: nil, skipWhen: "signedIn", requires: nil, completesGetStartedStep: nil, points: [], choices: [], instructions: [], primary: RegistryFirstRunButton(title: RegistryL10n.t("Sign in with Apple"), action: "signIn"), secondary: RegistryFirstRunButton(title: RegistryL10n.t("Not now"), action: "next"), tertiary: nil, afterDone: nil),
    RegistryFirstRunStep(id: "moveIn", kind: "choices", icon: "onboarding.move_in", title: RegistryL10n.t("Bring your tasks"), body: RegistryL10n.t("Start from the list you already have, or start empty."), footnote: nil, returningTitle: nil, returningBody: nil, skipWhen: nil, requires: nil, completesGetStartedStep: "importTasks", points: [], choices: [RegistryFirstRunChoice(id: "things", icon: "onboarding.things", title: RegistryL10n.t("From Things"), detail: RegistryL10n.t("Copies your areas, projects and tasks. Nothing in Things changes."), action: "importThings", platforms: ["ios", "ipados", "macos"]), RegistryFirstRunChoice(id: "reminders", icon: "settings.reminders", title: RegistryL10n.t("From Reminders"), detail: RegistryL10n.t("Pick a Reminders list. Each reminder you bring in moves to your Inbox, and Septena deletes it from Reminders."), action: "importReminders", platforms: ["ios", "ipados", "macos"]), RegistryFirstRunChoice(id: "fresh", icon: "onboarding.fresh", title: RegistryL10n.t("Start empty"), detail: RegistryL10n.t("Add tasks as they come up."), action: "next", platforms: ["ios", "ipados", "macos", "web", "android", "windows"])], instructions: [], primary: nil, secondary: nil, tertiary: nil, afterDone: nil),
    RegistryFirstRunStep(id: "connectClaude", kind: "connectAgent", icon: "settings.claude", title: RegistryL10n.t("Connect Claude"), body: RegistryL10n.t("Claude reads and changes your tasks through your Septena account. You decide which tasks it works on."), footnote: nil, returningTitle: nil, returningBody: nil, skipWhen: nil, requires: "signedIn", completesGetStartedStep: "connectAI", points: [], choices: [], instructions: [RegistryL10n.t("Copy the setup prompt and paste it into Claude."), RegistryL10n.t("When Claude shows a code, enter it below."), RegistryL10n.t("Paste the first prompt. Claude sets up your areas and projects with you.")], primary: RegistryFirstRunButton(title: RegistryL10n.t("Copy setup prompt"), action: "copySetupPrompt"), secondary: RegistryFirstRunButton(title: RegistryL10n.t("Later"), action: "next"), tertiary: RegistryFirstRunButton(title: RegistryL10n.t("Copy first prompt"), action: "copyFirstPrompt"), afterDone: RegistryFirstRunButton(title: RegistryL10n.t("Continue"), action: "next")),
    RegistryFirstRunStep(id: "done", kind: "finish", icon: "onboarding.done", title: RegistryL10n.t("You’re all set"), body: RegistryL10n.t("Today shows what to do now. Anything you skipped stays on the Get started list."), footnote: nil, returningTitle: RegistryL10n.t("Welcome back"), returningBody: RegistryL10n.t("This account is already set up. Your tasks are syncing to this device."), skipWhen: nil, requires: nil, completesGetStartedStep: nil, points: [], choices: [], instructions: [], primary: RegistryFirstRunButton(title: RegistryL10n.t("Open Today"), action: "finish"), secondary: nil, tertiary: nil, afterDone: nil),
  ]
}

/// One plan-comparison cell: a check, a dash, or text.
enum RegistryPlanCell: Sendable, Hashable {
  case included, notIncluded, text(String)
}

struct RegistryPlanPrice: Sendable, Hashable, Identifiable {
  let id: String
  let productId: String
  let amountMinor: Int
  let currency: String
  let interval: String
  let highlighted: Bool
  let label: String
  let detail: String
}

struct RegistryPlanCard: Sendable, Hashable, Identifiable {
  let id: String
  let title: String
  /// Registry icon id (icons.json).
  let icon: String
  let detail: String
  let points: [String]
  let footnote: String?
  let highlighted: Bool
}

struct RegistryPlanRow: Sendable, Hashable, Identifiable {
  let id: String
  let label: String
  let planned: Bool
  let device: RegistryPlanCell
  let account: RegistryPlanCell
  let plus: RegistryPlanCell
}

struct RegistryPlanOutcome: Sendable, Hashable, Identifiable {
  let id: String
  let icon: String
  let title: String
  let detail: String
  let rows: [RegistryPlanRow]
}

struct RegistryPlanNote: Sendable, Hashable, Identifiable {
  let id: String
  let title: String
  let detail: String
}

/// Plans and pricing (`registry/plans.json`). The site's /pricing page reads the same file.
enum RegistryPlans {
  static var name: String { RegistryL10n.t("Septena Plus") }
  static var shortName: String { RegistryL10n.t("Plus") }
  static var headline: String { RegistryL10n.t("Free on one device. Plus on all of them.") }
  static var subhead: String { RegistryL10n.t("Every task feature is free on the device you use. Plus syncs your list to all your devices and keeps its full history and files. It also lets your agents work without a daily cap.") }
  static let checkoutOpen = false
  static var checkoutNotice: String { RegistryL10n.t("Subscriptions open at App Store launch.") }
  static let trialDays = 14
  static var trialTitle: String { RegistryL10n.t("Every new account starts with 14 days of Plus") }
  static var trialDetail: String { RegistryL10n.t("You do not need a card. After 14 days the account becomes a free account, and your tasks stay where they are.") }
  static var priceFootnote: String { RegistryL10n.t("Prices include VAT where it applies. Outside the euro area, the App Store charges its matching local price.") }
  static var prices: [RegistryPlanPrice] { [
    RegistryPlanPrice(id: "annual", productId: "com.septena.tasks.sync.annual", amountMinor: 6000, currency: "EUR", interval: "year", highlighted: true, label: RegistryL10n.t("€60 a year"), detail: RegistryL10n.t("€5 a month. You save €24 against paying monthly.")),
    RegistryPlanPrice(id: "monthly", productId: "com.septena.tasks.sync.monthly", amountMinor: 700, currency: "EUR", interval: "month", highlighted: false, label: RegistryL10n.t("€7 a month"), detail: RegistryL10n.t("Cancel at any time.")),
  ] }
  static var cards: [RegistryPlanCard] { [
    RegistryPlanCard(id: "free", title: RegistryL10n.t("Free"), icon: "plans.free", detail: RegistryL10n.t("The full task app on one iPhone, iPad or Mac. You do not need an account."), points: [RegistryL10n.t("Today with its Inbox, Upcoming, Anytime, Faded and Logbook"), RegistryL10n.t("Areas, projects, sections, notes and attachments"), RegistryL10n.t("When dates, deadlines and repeats"), RegistryL10n.t("Task conversations with the on-device model"), RegistryL10n.t("Import from Things and Apple Reminders"), RegistryL10n.t("Export everything as plain JSON")], footnote: RegistryL10n.t("Sign in for a free account. The server then keeps a backup of that device, and you can try agents on real tasks."), highlighted: false),
    RegistryPlanCard(id: "plus", title: RegistryL10n.t("Septena Plus"), icon: "settings.plus", detail: RegistryL10n.t("Plus is the same app on every device, and nothing in it is capped."), points: [RegistryL10n.t("Live sync on every iPhone, iPad and Mac"), RegistryL10n.t("A year of change history, and a year to restore deleted tasks"), RegistryL10n.t("Files and images synced, up to 10 GB"), RegistryL10n.t("Your agents work your tasks without a daily cap"), RegistryL10n.t("Early builds on TestFlight")], footnote: RegistryL10n.t("Everything in Free is included."), highlighted: true),
  ] }
  static var outcomes: [RegistryPlanOutcome] { [
    RegistryPlanOutcome(id: "everywhere", icon: "onboarding.devices", title: RegistryL10n.t("Your list everywhere"), detail: RegistryL10n.t("The same tasks on your phone, tablet and Mac, updated as you type."), rows: [
      RegistryPlanRow(id: "devices", label: RegistryL10n.t("Devices"), planned: false, device: .text(RegistryL10n.t("1, not synced")), account: .text(RegistryL10n.t("1, backed up")), plus: .text(RegistryL10n.t("All your devices"))),
      RegistryPlanRow(id: "live", label: RegistryL10n.t("Sync speed"), planned: false, device: .notIncluded, account: .text(RegistryL10n.t("Every few minutes")), plus: .text(RegistryL10n.t("Live"))),
      RegistryPlanRow(id: "new_device", label: RegistryL10n.t("Move to a new device"), planned: false, device: .text(RegistryL10n.t("Export and import")), account: .included, plus: .included),
      RegistryPlanRow(id: "watch", label: RegistryL10n.t("Apple Watch through the server"), planned: false, device: .notIncluded, account: .notIncluded, plus: .included),
    ]),
    RegistryPlanOutcome(id: "nothing_lost", icon: "plans.history", title: RegistryL10n.t("Nothing lost"), detail: RegistryL10n.t("See who changed what and bring back what you deleted. Your files open on every device."), rows: [
      RegistryPlanRow(id: "history", label: RegistryL10n.t("Change history"), planned: false, device: .text(RegistryL10n.t("On this device")), account: .text(RegistryL10n.t("30 days")), plus: .text(RegistryL10n.t("365 days"))),
      RegistryPlanRow(id: "logbook", label: RegistryL10n.t("Logbook"), planned: false, device: .text(RegistryL10n.t("All")), account: .text(RegistryL10n.t("Last 90 days")), plus: .text(RegistryL10n.t("All"))),
      RegistryPlanRow(id: "deleted", label: RegistryL10n.t("Recently Deleted"), planned: false, device: .text(RegistryL10n.t("30 days")), account: .text(RegistryL10n.t("30 days")), plus: .text(RegistryL10n.t("365 days"))),
      RegistryPlanRow(id: "files", label: RegistryL10n.t("Files and images"), planned: false, device: .text(RegistryL10n.t("On this device")), account: .text(RegistryL10n.t("On the device that added them")), plus: .text(RegistryL10n.t("Synced, up to 10 GB"))),
      RegistryPlanRow(id: "export", label: RegistryL10n.t("Export as JSON"), planned: false, device: .included, account: .included, plus: .included),
    ]),
    RegistryPlanOutcome(id: "agents", icon: "onboarding.agent", title: RegistryL10n.t("Help that keeps working"), detail: RegistryL10n.t("Connect Claude or another agent to your list. It asks before it acts, and you can stop it at any time."), rows: [
      RegistryPlanRow(id: "connector", label: RegistryL10n.t("Claude connector"), planned: false, device: .text(RegistryL10n.t("Local server on the Mac")), account: .text(RegistryL10n.t("Reads, and 25 changes a day")), plus: .text(RegistryL10n.t("No daily cap"))),
      RegistryPlanRow(id: "runs", label: RegistryL10n.t("Agent runs"), planned: false, device: .notIncluded, account: .text(RegistryL10n.t("10 a month")), plus: .text(RegistryL10n.t("Within a monthly run budget"))),
      RegistryPlanRow(id: "share", label: RegistryL10n.t("Shared projects"), planned: true, device: .notIncluded, account: .text(RegistryL10n.t("Join")), plus: .text(RegistryL10n.t("Create and invite"))),
      RegistryPlanRow(id: "links", label: RegistryL10n.t("Linked projects (GitHub, Linear)"), planned: true, device: .notIncluded, account: .text(RegistryL10n.t("1")), plus: .text(RegistryL10n.t("No cap"))),
    ]),
  ] }
  static var promises: [RegistryPlanNote] { [
    RegistryPlanNote(id: "core_free", title: RegistryL10n.t("The task app stays free"), detail: RegistryL10n.t("Tasks, lists, projects and areas have no caps on any plan.")),
    RegistryPlanNote(id: "no_hostage", title: RegistryL10n.t("We never hold your data back"), detail: RegistryL10n.t("Export works on every plan. A limit hides older items. It never deletes them, and Plus shows them again.")),
    RegistryPlanNote(id: "cancel", title: RegistryL10n.t("Cancel at any time"), detail: RegistryL10n.t("Your account becomes a free account. Every device keeps its tasks, and the server keeps your synced copy for 12 months.")),
    RegistryPlanNote(id: "own_ai", title: RegistryL10n.t("You pay your AI provider, not us"), detail: RegistryL10n.t("Septena runs the sync server and the connector. When you connect Claude or another agent, its bill stays with that provider.")),
  ] }
  static var upsells: [RegistryPlanNote] { [
    RegistryPlanNote(id: "second_device", title: RegistryL10n.t("This device is not syncing"), detail: RegistryL10n.t("A free account syncs one device. Plus syncs all of them. You can also move your free account to this device.")),
    RegistryPlanNote(id: "history_edge", title: RegistryL10n.t("Older changes are hidden"), detail: RegistryL10n.t("A free account shows 30 days of history. Plus shows a full year.")),
    RegistryPlanNote(id: "file_elsewhere", title: RegistryL10n.t("This file is on another device"), detail: RegistryL10n.t("Plus syncs files and images to all your devices.")),
    RegistryPlanNote(id: "agent_runs", title: RegistryL10n.t("Agent runs resume on the 1st"), detail: RegistryL10n.t("Your free account used its 10 runs this month. The work waits for you. Plus runs it now.")),
    RegistryPlanNote(id: "connector_cap", title: RegistryL10n.t("Daily change limit reached"), detail: RegistryL10n.t("A free account allows 25 agent changes a day. Plus has no daily cap.")),
    RegistryPlanNote(id: "share_create", title: RegistryL10n.t("Sharing a project needs Plus"), detail: RegistryL10n.t("Anyone can join a shared project for free. Plus lets you create one and invite people.")),
    RegistryPlanNote(id: "trial_end", title: RegistryL10n.t("Your 14 days of Plus have ended"), detail: RegistryL10n.t("Your account is now a free account. One device keeps syncing. Your tasks on every device stay where they are.")),
  ] }
  static func upsell(_ id: String) -> RegistryPlanNote? { upsells.first { $0.id == id } }
  /// The paywall's Terms of Use and Privacy Policy links (App Review 3.1.2).
  static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
  static let privacyURL = URL(string: "https://septena.app/privacy")!

  enum Action {
    static var subscribe: String { RegistryL10n.t("Subscribe") }
    static var restore: String { RegistryL10n.t("Restore Purchases") }
    static var manage: String { RegistryL10n.t("Manage Subscription") }
    static var notNow: String { RegistryL10n.t("Not Now") }
    static var learnMore: String { RegistryL10n.t("See what Plus adds") }
  }

  enum Copy {
    static var yourPlan: String { RegistryL10n.t("Your plan") }
    static var planned: String { RegistryL10n.t("Planned") }
    static var included: String { RegistryL10n.t("Included") }
    static var notIncluded: String { RegistryL10n.t("Not included") }
  }

  enum Status {
    static var device: String { RegistryL10n.t("On this device") }
    static var free: String { RegistryL10n.t("Free account") }
    static var trial: String { RegistryL10n.t("Plus trial") }
    static var plus: String { RegistryL10n.t("Plus") }
    static func trialEnds(date: String) -> String { RegistryL10n.format("Plus trial until %@", english: "Plus trial until %@", args: [date]) }
    static func paidThrough(date: String) -> String { RegistryL10n.format("Plus through %@", english: "Plus through %@", args: [date]) }
  }

  enum Paywall {
    static var seePlus: String { RegistryL10n.t("See Plus") }
    static var startTrial: String { RegistryL10n.t("Try Plus free for 14 days") }
    static func trialStarted(date: String) -> String { RegistryL10n.format("Plus is on until %@.", english: "Plus is on until %@.", args: [date]) }
    static var trialBilling: String { RegistryL10n.t("If you subscribe during the trial, billing starts on the day you subscribe.") }
    static var welcomeBack: String { RegistryL10n.t("Welcome back") }
    static var cancelNote: String { RegistryL10n.t("You can cancel at any time in Settings.") }
    static var success: String { RegistryL10n.t("Plus is on. Your other devices start syncing.") }
    static var pending: String { RegistryL10n.t("Waiting for approval.") }
    static var serverRetry: String { RegistryL10n.t("Purchase received. Plus turns on when Septena reaches the server.") }
    static var failed: String { RegistryL10n.t("The purchase did not go through. Try again in a moment.") }
    static var ownedApple: String { RegistryL10n.t("You have Plus through the App Store.") }
    static var ownedWeb: String { RegistryL10n.t("You have Plus through the web. Manage it at septena.app.") }
    static var ownedGoogle: String { RegistryL10n.t("You have Plus through Google Play. Manage it in Google Play.") }
    static var ownedGrant: String { RegistryL10n.t("Plus is on for this account.") }
    static var buyOnIPhone: String { RegistryL10n.t("Subscribe in Septena on your iPhone or iPad. Plus then works on this Mac too.") }
    static var done: String { RegistryL10n.t("Done") }
  }
}

/// Canonical capability parity ledger (`registry/capabilities.json`, ADR 0013 / ADR 0015).
enum RegistryCapabilities {
  static let byPlatform: [String: [String: String]] = [
    "ios": ["lists.inbox": "ships", "lists.today": "ships", "lists.review": "ships", "lists.agent": "ships", "lists.upcoming": "ships", "lists.anytime": "ships", "lists.repeating": "ships", "lists.logbook": "ships", "lists.faded": "ships", "lists.starred": "ships", "lists.recently-deleted": "ships", "places.areas": "ships", "places.projects": "ships", "places.sections": "ships", "task.when-deadline": "ships", "task.repeat": "ships", "task.notes": "ships", "task.attachments": "ships", "task.history": "ships", "task.aging": "ships", "task.checklists": "ships", "task.tags": "ships", "task.alerts": "ships", "fade.sweep": "ships", "capture.quick-add": "ships", "capture.quick-entry": "not_applicable", "edit.filing-suggestion": "ships", "edit.undo": "ships", "edit.swipe-actions": "ships", "find.quick-find": "ships", "mac.keyboard": "not_applicable", "mac.updates": "not_applicable", "calendar.events": "ships", "import.reminders": "ships", "import.things": "ships", "ai.discuss": "ships", "ai.reach-dial": "ships", "agents.connector": "ships", "onboarding.first-run": "ships", "agents.stop-pause": "ships", "sync.backend": "ships", "account.delete": "ships", "settings.display": "ships"],
    "ipados": ["lists.inbox": "ships", "lists.today": "ships", "lists.review": "ships", "lists.agent": "ships", "lists.upcoming": "ships", "lists.anytime": "ships", "lists.repeating": "ships", "lists.logbook": "ships", "lists.faded": "ships", "lists.starred": "ships", "lists.recently-deleted": "ships", "places.areas": "ships", "places.projects": "ships", "places.sections": "ships", "task.when-deadline": "ships", "task.repeat": "ships", "task.notes": "ships", "task.attachments": "ships", "task.history": "ships", "task.aging": "ships", "task.checklists": "ships", "task.tags": "ships", "task.alerts": "ships", "fade.sweep": "ships", "capture.quick-add": "ships", "capture.quick-entry": "not_applicable", "edit.filing-suggestion": "ships", "edit.undo": "ships", "edit.swipe-actions": "ships", "find.quick-find": "ships", "mac.keyboard": "ships", "mac.updates": "not_applicable", "calendar.events": "ships", "import.reminders": "ships", "import.things": "ships", "ai.discuss": "ships", "ai.reach-dial": "ships", "agents.connector": "ships", "onboarding.first-run": "ships", "agents.stop-pause": "ships", "sync.backend": "ships", "account.delete": "ships", "settings.display": "ships"],
    "macos": ["lists.inbox": "ships", "lists.today": "ships", "lists.review": "ships", "lists.agent": "ships", "lists.upcoming": "ships", "lists.anytime": "ships", "lists.repeating": "ships", "lists.logbook": "ships", "lists.faded": "ships", "lists.starred": "ships", "lists.recently-deleted": "ships", "places.areas": "ships", "places.projects": "ships", "places.sections": "ships", "task.when-deadline": "ships", "task.repeat": "ships", "task.notes": "ships", "task.attachments": "partial", "task.history": "ships", "task.aging": "ships", "task.checklists": "ships", "task.tags": "ships", "task.alerts": "ships", "fade.sweep": "ships", "capture.quick-add": "not_applicable", "capture.quick-entry": "ships", "edit.filing-suggestion": "ships", "edit.undo": "ships", "edit.swipe-actions": "not_applicable", "find.quick-find": "ships", "mac.keyboard": "ships", "mac.updates": "ships", "calendar.events": "ships", "import.reminders": "ships", "import.things": "ships", "ai.discuss": "ships", "ai.reach-dial": "ships", "agents.connector": "ships", "onboarding.first-run": "ships", "agents.stop-pause": "ships", "sync.backend": "ships", "account.delete": "ships", "settings.display": "ships"],
    "web": ["lists.inbox": "planned", "lists.today": "planned", "lists.review": "planned", "lists.agent": "planned", "lists.upcoming": "planned", "lists.anytime": "planned", "lists.repeating": "planned", "lists.logbook": "planned", "lists.faded": "planned", "lists.starred": "planned", "lists.recently-deleted": "planned", "places.areas": "planned", "places.projects": "planned", "places.sections": "planned", "task.when-deadline": "planned", "task.repeat": "planned", "task.notes": "planned", "task.attachments": "planned", "task.history": "planned", "task.aging": "planned", "task.checklists": "planned", "task.tags": "planned", "task.alerts": "planned", "fade.sweep": "planned", "capture.quick-add": "planned", "capture.quick-entry": "not_applicable", "edit.filing-suggestion": "not_applicable", "edit.undo": "planned", "edit.swipe-actions": "not_applicable", "find.quick-find": "planned", "mac.keyboard": "planned", "mac.updates": "not_applicable", "calendar.events": "planned", "import.reminders": "not_applicable", "import.things": "not_applicable", "ai.discuss": "planned", "ai.reach-dial": "planned", "agents.connector": "planned", "onboarding.first-run": "planned", "agents.stop-pause": "planned", "sync.backend": "planned", "account.delete": "planned", "settings.display": "planned"],
    "android": ["lists.inbox": "planned", "lists.today": "planned", "lists.review": "planned", "lists.agent": "planned", "lists.upcoming": "planned", "lists.anytime": "planned", "lists.repeating": "planned", "lists.logbook": "planned", "lists.faded": "planned", "lists.starred": "planned", "lists.recently-deleted": "planned", "places.areas": "planned", "places.projects": "planned", "places.sections": "planned", "task.when-deadline": "planned", "task.repeat": "planned", "task.notes": "planned", "task.attachments": "planned", "task.history": "planned", "task.aging": "planned", "task.checklists": "planned", "task.tags": "planned", "task.alerts": "planned", "fade.sweep": "planned", "capture.quick-add": "planned", "capture.quick-entry": "not_applicable", "edit.filing-suggestion": "planned", "edit.undo": "planned", "edit.swipe-actions": "planned", "find.quick-find": "planned", "mac.keyboard": "planned", "mac.updates": "not_applicable", "calendar.events": "planned", "import.reminders": "not_applicable", "import.things": "not_applicable", "ai.discuss": "planned", "ai.reach-dial": "planned", "agents.connector": "planned", "onboarding.first-run": "planned", "agents.stop-pause": "planned", "sync.backend": "planned", "account.delete": "planned", "settings.display": "planned"],
    "windows": ["lists.inbox": "planned", "lists.today": "planned", "lists.review": "planned", "lists.agent": "planned", "lists.upcoming": "planned", "lists.anytime": "planned", "lists.repeating": "planned", "lists.logbook": "planned", "lists.faded": "planned", "lists.starred": "planned", "lists.recently-deleted": "planned", "places.areas": "planned", "places.projects": "planned", "places.sections": "planned", "task.when-deadline": "planned", "task.repeat": "planned", "task.notes": "planned", "task.attachments": "planned", "task.history": "planned", "task.aging": "planned", "task.checklists": "planned", "task.tags": "planned", "task.alerts": "planned", "fade.sweep": "planned", "capture.quick-add": "not_applicable", "capture.quick-entry": "planned", "edit.filing-suggestion": "planned", "edit.undo": "planned", "edit.swipe-actions": "not_applicable", "find.quick-find": "planned", "mac.keyboard": "planned", "mac.updates": "planned", "calendar.events": "planned", "import.reminders": "not_applicable", "import.things": "not_applicable", "ai.discuss": "planned", "ai.reach-dial": "planned", "agents.connector": "planned", "onboarding.first-run": "planned", "agents.stop-pause": "planned", "sync.backend": "planned", "account.delete": "planned", "settings.display": "planned"],
    "watchos": ["lists.inbox": "partial", "lists.today": "partial", "lists.review": "not_applicable", "lists.agent": "not_applicable", "lists.upcoming": "not_applicable", "lists.anytime": "not_applicable", "lists.repeating": "not_applicable", "lists.logbook": "not_applicable", "lists.faded": "not_applicable", "lists.starred": "not_applicable", "lists.recently-deleted": "not_applicable", "places.areas": "not_applicable", "places.projects": "not_applicable", "places.sections": "not_applicable", "task.when-deadline": "not_applicable", "task.repeat": "not_applicable", "task.notes": "not_applicable", "task.attachments": "not_applicable", "task.history": "not_applicable", "task.aging": "not_applicable", "task.checklists": "not_applicable", "task.tags": "not_applicable", "task.alerts": "not_applicable", "fade.sweep": "not_applicable", "capture.quick-add": "not_applicable", "capture.quick-entry": "not_applicable", "edit.filing-suggestion": "not_applicable", "edit.undo": "not_applicable", "edit.swipe-actions": "not_applicable", "find.quick-find": "not_applicable", "mac.keyboard": "not_applicable", "mac.updates": "not_applicable", "calendar.events": "not_applicable", "import.reminders": "not_applicable", "import.things": "not_applicable", "ai.discuss": "not_applicable", "ai.reach-dial": "not_applicable", "agents.connector": "not_applicable", "onboarding.first-run": "not_applicable", "agents.stop-pause": "not_applicable", "sync.backend": "planned", "account.delete": "not_applicable", "settings.display": "not_applicable"],
  ]

  /// `ships`, `partial`, `planned` or `not_applicable`; nil for an unknown platform or ID.
  static func status(_ featureId: String, on platform: String) -> String? {
    byPlatform[platform]?[featureId]
  }

  /// A surface for `featureId` renders on `platform` only when it ships there
  /// (fully or partly). Planned and not-applicable features show no dead UI (ADR 0015).
  static func isAvailable(_ featureId: String, on platform: String) -> Bool {
    switch status(featureId, on: platform) {
    case "ships", "partial": return true
    default: return false
    }
  }
}
