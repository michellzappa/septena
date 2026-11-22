// GENERATED FILE — DO NOT EDIT BY HAND.
// Sources: registry/{entities,rules,icons,tokens,capabilities,settings,destinations,actions,surfaces}.json
// Regenerate: node scripts/gen-registries.mjs

import Foundation

/// Wire schema size and count limits shared with the backend (`registry/entities.json`).
enum RegistryEntityLimits {
  static let textMax: Int = 2000
  static let notesMax: Int = 100000
  static let attachmentPointerMax: Int = 4000
  static let stampMax: Int = 40
  static let maxAttachmentBytes: Int64 = 26214400
  static let maxUserAttachmentBytes: Int64 = 2147483648
  static let maxOpsPerPush: Int = 500
  static let maxPull: Int = 1000
  static let maxChecklistItemsPerTask: Int = 200
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
  static let appIconFinish: [String] = ["obsidian", "ceramic", "framed", "stealth"]
  static let appIconColor: [String] = ["auto", "persimmon", "haskap", "tamarillo", "yuzu", "carambola", "acai", "pitaya", "mono"]
  static let canvasTexture: [String] = ["none", "topography", "fieldMatrix", "stippleDrift", "causticGlass", "ridges", "washiPaper"]
  static let textureMotion: [String] = ["still", "slowDrift"]
  static let entityNames: [String] = ["task", "area", "project", "attachment", "checklistItem", "convo", "setting"]
  static let deletableEntities: [String] = ["task", "area", "project", "attachment", "checklistItem"]
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
  static let agentRunBudget: Int = 5
  static let claimTtlDefaultSeconds: Int = 1800
  static let claimTtlMaxSeconds: Int = 14400
  static let tombstoneTtlDays: Int = 90
  static let clientOpTtlDays: Int = 30
  static let changeLogTtlDays: Int = 365
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
    "action.duplicate": "plus.square.on.square",
    "action.complete": "checkmark.circle",
    "action.cancel": "xmark.circle",
    "action.delete": "trash",
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
    "notice.sign_in": "person.crop.circle.badge.exclamationmark",
    "notice.rolled_in": "arrow.down.circle",
    "notice.get_started": "sparkles",
    "notice.fade_intro": "circle.lefthalf.filled",
    "convo.needs_you": "circle.fill",
    "convo.working": "circle.fill",
    "convo.done": "checkmark.circle.fill",
    "convo.wont_do": "minus.circle",
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
    RegistryFruitAccent(id: "colorful", name: "Colorful", origin: "Default · Blue + semantic", lightHex: "#007AFF", darkHex: "#0A84FF", checkLightHex: "#FFFFFF", checkDarkHex: "#FFFFFF", multicolor: true),
    RegistryFruitAccent(id: "tamarillo", name: "Tamarillo", origin: "Andes · Crimson", lightHex: "#D6333F", darkHex: "#FF5C67", checkLightHex: "#FFFFFF", checkDarkHex: "#FFFFFF", multicolor: false),
    RegistryFruitAccent(id: "persimmon", name: "Persimmon", origin: "East Asia · Vermilion", lightHex: "#E05212", darkHex: "#FF7738", checkLightHex: "#FFFFFF", checkDarkHex: "#FFFFFF", multicolor: false),
    RegistryFruitAccent(id: "yuzu", name: "Yuzu", origin: "Japan · Citrus gold", lightHex: "#C28500", darkHex: "#F2BF2C", checkLightHex: "#FFFFFF", checkDarkHex: "#141518", multicolor: false),
    RegistryFruitAccent(id: "carambola", name: "Carambola", origin: "SE Asia · Starfruit", lightHex: "#5B8C00", darkHex: "#9EE034", checkLightHex: "#FFFFFF", checkDarkHex: "#141518", multicolor: false),
    RegistryFruitAccent(id: "acai", name: "Açaí", origin: "Amazon · Indigo", lightHex: "#6544D6", darkHex: "#9B82FF", checkLightHex: "#FFFFFF", checkDarkHex: "#FFFFFF", multicolor: false),
    RegistryFruitAccent(id: "pitaya", name: "Pitaya", origin: "Mesoamerica · Dragonfruit", lightHex: "#D4266C", darkHex: "#FF5C9B", checkLightHex: "#FFFFFF", checkDarkHex: "#FFFFFF", multicolor: false),
    RegistryFruitAccent(id: "jabuticaba", name: "Jabuticaba", origin: "Brazil · Obsidian ink", lightHex: "#27272E", darkHex: "#E4E4EA", checkLightHex: "#FFFFFF", checkDarkHex: "#141518", multicolor: false),
  ]
  static let textures: [RegistryTextureOption] = [
    RegistryTextureOption(id: "none", name: "Pure Canvas", tag: "Baseline"),
    RegistryTextureOption(id: "topography", name: "Topography", tag: "Height Map"),
    RegistryTextureOption(id: "fieldMatrix", name: "Field Matrix", tag: "Industrial"),
    RegistryTextureOption(id: "stippleDrift", name: "Stipple Drift", tag: "Print / Ink"),
    RegistryTextureOption(id: "causticGlass", name: "Caustic Glass", tag: "Optical"),
    RegistryTextureOption(id: "ridges", name: "Ridge Lines", tag: "Elevation"),
    RegistryTextureOption(id: "washiPaper", name: "Washi Paper", tag: "Tactile"),
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
  var id: String { "\(kind):\(key ?? page ?? surface ?? label ?? "item")" }
  func applies(to platform: String) -> Bool { platforms?.contains(platform) ?? true }
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
  func applies(to platform: String) -> Bool { platforms?.contains(platform) ?? true }
}

/// Unified task-app settings keys, defaults, synced-key list, and taxonomy (`registry/settings.json`).
enum RegistrySettings {
  static let syncedKeys: [String] = ["welcomeName", "telemetryLevel", "calendarHiddenTitles", "rolledInDismissedOn", "homeTimezone", "agentsPaused", "getStartedDismissed", "getStartedSteps", "onboardedAt", "accentColor", "canvasTexture", "textureIntensity", "textureMotion", "smartListOrder", "smartListHidden"]

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
    static let appearanceMode = "septena.appearance.mode"
    static let syncTheme = "septena.appearance.syncTheme"
    static let appIconFinish = "septena.appearance.appIconFinish"
    static let appIconColor = "septena.appearance.appIconColor"
    static let todayShowCompleted = "septena.today.showCompleted"
    static let todayGroupByList = "septena.today.groupByList"
    static let tasksShowAging = "septena.tasks.showAging"
    static let tasksShowFaded = "septena.tasks.showFaded"
    static let tasksTitleLines = "septena.tasks.titleLines"
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
    "tasksTitleLines": [RegistrySettingsOption(value: "1", title: "One"), RegistrySettingsOption(value: "2", title: "Two"), RegistrySettingsOption(value: "3", title: "Three")],
    "aiMode": [RegistrySettingsOption(value: "onDeviceOnly", title: "On-device only"), RegistrySettingsOption(value: "auto", title: "Automatic"), RegistrySettingsOption(value: "useMyClaude", title: "Use my Claude")],
    "pccReasoning": [RegistrySettingsOption(value: "light", title: "Light"), RegistrySettingsOption(value: "balanced", title: "Balanced"), RegistrySettingsOption(value: "thorough", title: "Thorough")],
  ]

  static let desktopTabs: [RegistrySettingsTab] = [
    RegistrySettingsTab(id: "account", title: "Account", iconId: "settings.account", sfSymbol: "person.crop.circle", group: "identity", paletteSlot: nil, featureId: "sync.backend"),
    RegistrySettingsTab(id: "general", title: "General", iconId: "settings.general", sfSymbol: "slider.horizontal.3", group: "main", paletteSlot: 0, featureId: "lists.today"),
    RegistrySettingsTab(id: "ai_agents", title: "AI & Agents", iconId: "settings.ai_agents", sfSymbol: "sparkles", group: "main", paletteSlot: 4, featureId: "ai.reach-dial"),
    RegistrySettingsTab(id: "connections_data", title: "Connections & Data", iconId: "settings.connections", sfSymbol: "link", group: "main", paletteSlot: 5, featureId: "sync.backend"),
    RegistrySettingsTab(id: "privacy", title: "Privacy", iconId: "settings.privacy", sfSymbol: "hand.raised", group: "main", paletteSlot: 6, featureId: "settings.display"),
    RegistrySettingsTab(id: "about", title: "About", iconId: "settings.about", sfSymbol: "info.circle", group: "about", paletteSlot: nil, featureId: "settings.display"),
  ]

  static let rootGroups: [RegistrySettingsGroup] = [
    RegistrySettingsGroup(id: "account_root", header: nil, mobilePresentation: "card", desktopTab: "account", items: [
      RegistrySettingsItem(kind: "pageLink", key: nil, page: "account", surface: "account_profile_card", label: "Account", detail: nil, iconId: "settings.account", sfSymbol: "person.crop.circle", statusKey: "syncStatus", desktopInline: false, visibility: "always", platforms: nil),
    ]),
    RegistrySettingsGroup(id: "ai_agents_root", header: "AI & Agents", mobilePresentation: "inline", desktopTab: "ai_agents", items: [
      RegistrySettingsItem(kind: "pageLink", key: nil, page: "claude_pairing", surface: nil, label: "Connect Claude", detail: nil, iconId: "settings.claude", sfSymbol: "bubble.left.and.text.bubble.right", statusKey: "claudeStatus", desktopInline: true, visibility: "always", platforms: nil),
      RegistrySettingsItem(kind: "setting", key: "agentsPaused", page: nil, surface: nil, label: "Pause all agents", detail: "No agent can claim or work on a task while paused.", iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "signedIn", platforms: nil),
      RegistrySettingsItem(kind: "pageLink", key: nil, page: "ai_preferences", surface: nil, label: "AI Preferences", detail: nil, iconId: "settings.ai_agents", sfSymbol: "sparkles", statusKey: "aiMode", desktopInline: true, visibility: "always", platforms: nil),
    ]),
    RegistrySettingsGroup(id: "connections_data_root", header: "Connections & Data", mobilePresentation: "inline", desktopTab: "connections_data", items: [
      RegistrySettingsItem(kind: "pageLink", key: nil, page: "calendar", surface: nil, label: "Calendar", detail: nil, iconId: "settings.calendar", sfSymbol: "calendar", statusKey: "calendarStatus", desktopInline: false, visibility: "always", platforms: nil),
      RegistrySettingsItem(kind: "pageLink", key: nil, page: "reminders", surface: nil, label: "Reminders", detail: nil, iconId: "settings.reminders", sfSymbol: "checklist", statusKey: "remindersStatus", desktopInline: false, visibility: "always", platforms: ["ios", "ipados", "macos"]),
      RegistrySettingsItem(kind: "pageLink", key: nil, page: "import_export", surface: nil, label: "Import & Export", detail: nil, iconId: "settings.data", sfSymbol: "square.and.arrow.up", statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
    ]),
    RegistrySettingsGroup(id: "lists_root", header: "Lists", mobilePresentation: "inline", desktopTab: "general", items: [
      RegistrySettingsItem(kind: "pageLink", key: nil, page: "smart_lists", surface: nil, label: "Smart Lists", detail: nil, iconId: "list.today", sfSymbol: "sun.max.fill", statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
      RegistrySettingsItem(kind: "setting", key: "todayGroupByList", page: nil, surface: nil, label: "Group Today by list", detail: "When off, tasks appear in one list with their project or area underneath.", iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
      RegistrySettingsItem(kind: "setting", key: "todayShowCompleted", page: nil, surface: nil, label: "Show completed tasks", detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
      RegistrySettingsItem(kind: "setting", key: "tasksShowAging", page: nil, surface: nil, label: "Fade inactive tasks", detail: "Tasks without activity for 14 days fade out and move to Faded.", iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
      RegistrySettingsItem(kind: "setting", key: "tasksShowFaded", page: nil, surface: nil, label: "Show faded tasks", detail: "Show faded tasks in projects and areas.", iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
      RegistrySettingsItem(kind: "setting", key: "tasksFilingSuggestions", page: nil, surface: nil, label: "Suggest where to file", detail: "Learn where you usually file similar tasks.", iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
      RegistrySettingsItem(kind: "setting", key: "badgeShowOverdue", page: nil, surface: nil, label: "Overdue app icon badge", detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
    ]),
    RegistrySettingsGroup(id: "appearance_root", header: "Appearance", mobilePresentation: "inline", desktopTab: "general", items: [
      RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "accent_color", label: "Accent", detail: nil, iconId: "settings.appearance", sfSymbol: "paintpalette", statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
      RegistrySettingsItem(kind: "setting", key: "textSizeStep", page: nil, surface: nil, label: "Text Size", detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
      RegistrySettingsItem(kind: "setting", key: "tasksTitleLines", page: nil, surface: nil, label: "Title lines", detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: ["ios", "ipados", "android"]),
      RegistrySettingsItem(kind: "setting", key: "loggingAnimationsEnabled", page: nil, surface: nil, label: "Completion animations", detail: nil, iconId: "settings.animations", sfSymbol: "party.popper", statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
    ]),
    RegistrySettingsGroup(id: "meta_root", header: nil, mobilePresentation: "inline", desktopTab: nil, items: [
      RegistrySettingsItem(kind: "pageLink", key: nil, page: "privacy", surface: nil, label: "Privacy", detail: nil, iconId: "settings.privacy", sfSymbol: "hand.raised", statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
      RegistrySettingsItem(kind: "pageLink", key: nil, page: "about", surface: nil, label: "About", detail: nil, iconId: "settings.about", sfSymbol: "info.circle", statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
    ]),
  ]

  static let pages: [RegistrySettingsPage] = [
    RegistrySettingsPage(id: "account", title: "Account", iconId: "settings.account", sfSymbol: "person.crop.circle", depth: 1, platforms: nil, featureId: "sync.backend", sections: [
      RegistrySettingsSection(id: "profile", header: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "account_profile_editor", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
      ]),
      RegistrySettingsSection(id: "sync", header: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "sync_account_status", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
      ]),
      RegistrySettingsSection(id: "delete_account", header: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "delete_account", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "signedIn", platforms: nil),
      ]),
    ]),
    RegistrySettingsPage(id: "claude_pairing", title: "Connect Claude", iconId: "settings.claude", sfSymbol: "bubble.left.and.text.bubble.right", depth: 1, platforms: nil, featureId: "agents.connector", sections: [
      RegistrySettingsSection(id: "connector", header: "Connect Claude", platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "claude_connector", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
      ]),
    ]),
    RegistrySettingsPage(id: "ai_preferences", title: "AI Preferences", iconId: "settings.ai_agents", sfSymbol: "sparkles", depth: 1, platforms: nil, featureId: "ai.reach-dial", sections: [
      RegistrySettingsSection(id: "on_device", header: "On-device intelligence", platforms: ["ios", "ipados", "macos"], items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "apple_intelligence_status", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: ["ios", "ipados", "macos"]),
      ]),
      RegistrySettingsSection(id: "reach", header: "Where AI runs", platforms: nil, items: [
        RegistrySettingsItem(kind: "setting", key: "aiMode", page: nil, surface: nil, label: "AI Mode", detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
      ]),
      RegistrySettingsSection(id: "explainer", header: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "ai_explainer", label: "How AI helps with your tasks", detail: nil, iconId: "settings.about", sfSymbol: "info.circle", statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
      ]),
    ]),
    RegistrySettingsPage(id: "calendar", title: "Calendar", iconId: "settings.calendar", sfSymbol: "calendar", depth: 1, platforms: nil, featureId: "calendar.events", sections: [
      RegistrySettingsSection(id: "calendars", header: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "calendar_detail", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
      ]),
    ]),
    RegistrySettingsPage(id: "reminders", title: "Reminders", iconId: "settings.reminders", sfSymbol: "checklist", depth: 1, platforms: ["ios", "ipados", "macos"], featureId: "import.reminders", sections: [
      RegistrySettingsSection(id: "reminders", header: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "reminders_inbox", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: ["ios", "ipados", "macos"]),
      ]),
    ]),
    RegistrySettingsPage(id: "import_export", title: "Import & Export", iconId: "settings.data", sfSymbol: "square.and.arrow.up", depth: 1, platforms: nil, featureId: "sync.backend", sections: [
      RegistrySettingsSection(id: "move_in", header: "Move from another app", platforms: ["ios", "ipados", "macos"], items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "things_import", label: "Import from Things", detail: nil, iconId: "settings.import", sfSymbol: "square.and.arrow.down", statusKey: nil, desktopInline: false, visibility: "always", platforms: ["ios", "ipados", "macos"]),
      ]),
      RegistrySettingsSection(id: "transfer", header: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "import_export", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
      ]),
    ]),
    RegistrySettingsPage(id: "privacy", title: "Privacy", iconId: "settings.privacy", sfSymbol: "hand.raised", depth: 1, platforms: nil, featureId: "settings.display", sections: [
      RegistrySettingsSection(id: "data_locality", header: "Your data", platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "privacy_explainer", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
      ]),
      RegistrySettingsSection(id: "telemetry", header: "Anonymous usage data", platforms: nil, items: [
        RegistrySettingsItem(kind: "setting", key: "telemetryLevel", page: nil, surface: nil, label: "Usage data", detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
      ]),
    ]),
    RegistrySettingsPage(id: "about", title: "About", iconId: "settings.about", sfSymbol: "info.circle", depth: 1, platforms: nil, featureId: "settings.display", sections: [
      RegistrySettingsSection(id: "version", header: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "about_header", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
      ]),
      RegistrySettingsSection(id: "actions", header: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "check_updates", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: ["macos", "windows"]),
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "reset_get_started", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "reset_first_run", label: "Show Welcome Again", detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "send_feedback", label: nil, detail: nil, iconId: "settings.feedback", sfSymbol: "paperplane", statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
      ]),
      RegistrySettingsSection(id: "companion", header: "Septena Life", platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "septena_life_link", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
      ]),
      RegistrySettingsSection(id: "advanced_link", header: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "pageLink", key: nil, page: "advanced", surface: nil, label: "Advanced", detail: nil, iconId: "settings.advanced", sfSymbol: "wrench.and.screwdriver", statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
      ]),
    ]),
    RegistrySettingsPage(id: "advanced", title: "Advanced", iconId: "settings.advanced", sfSymbol: "wrench.and.screwdriver", depth: 2, platforms: nil, featureId: "settings.display", sections: [
      RegistrySettingsSection(id: "agent_tools", header: "Agent tools", platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "mcp_skills", label: "MCP Skills", detail: nil, iconId: "settings.skills", sfSymbol: "book.closed", statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
      ]),
      RegistrySettingsSection(id: "diagnostics", header: "Diagnostics", platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "sync_diagnostics", label: "Sync & storage diagnostics", detail: nil, iconId: "settings.diagnostics", sfSymbol: "stethoscope", statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "diagnostics_weekly", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
      ]),
      RegistrySettingsSection(id: "data_tools", header: "Data tools", platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "paste_json_import", label: "Paste JSON Backup…", detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
      ]),
      RegistrySettingsSection(id: "beta_ai", header: "AI diagnostics", platforms: ["ios", "ipados", "macos"], items: [
        RegistrySettingsItem(kind: "setting", key: "showModelLabels", page: nil, surface: nil, label: "Show model labels", detail: "Show which model answered next to each AI reply.", iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
        RegistrySettingsItem(kind: "setting", key: "pccRoutingEnabled", page: nil, surface: nil, label: "Use Private Cloud Compute", detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "minAppleOS27", platforms: nil),
        RegistrySettingsItem(kind: "setting", key: "pccReasoning", page: nil, surface: nil, label: "Private Cloud Compute reasoning", detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "minAppleOS27", platforms: nil),
      ]),
    ]),
    RegistrySettingsPage(id: "smart_lists", title: "Smart Lists", iconId: "list.today", sfSymbol: "sun.max.fill", depth: 1, platforms: nil, featureId: "settings.display", sections: [
      RegistrySettingsSection(id: "smart_lists", header: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "smart_lists_editor", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, desktopInline: false, visibility: "always", platforms: nil),
      ]),
    ]),
  ]

  static let pageById: [String: RegistrySettingsPage] = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })
  static let tabById: [String: RegistrySettingsTab] = Dictionary(uniqueKeysWithValues: desktopTabs.map { ($0.id, $0) })
}

/// Canonical smart-list metadata (`registry/destinations.json`).
struct RegistryDestination: Sendable, Hashable, Identifiable {
  let id: String
  let navigationKey: String
  let serverView: String
  let title: String
  let iconId: String
  let sfSymbol: String
  let sidebarOrder: Int
  let visibility: String
  let canHide: Bool
  let shortcutKeycaps: [String]?
  let emptyTitle: String
  let emptyDetail: String
}

enum RegistryDestinations {
  static let viewAliases: [String: String] = [
    "someday": "anytime",
    "unscheduled": "anytime",
    "triage": "inbox",
  ]

  static let all: [RegistryDestination] = [
    RegistryDestination(id: "today", navigationKey: "today", serverView: "today", title: "Today", iconId: "list.today", sfSymbol: "sun.max.fill", sidebarOrder: 0, visibility: "always", canHide: false, shortcutKeycaps: ["⌘", "1"], emptyTitle: "Nothing on Today", emptyDetail: "Add a task or move one here when you want to work on it today."),
    RegistryDestination(id: "review", navigationKey: "review", serverView: "all", title: "Review", iconId: "list.review", sfSymbol: "eye", sidebarOrder: 1, visibility: "always", canHide: true, shortcutKeycaps: nil, emptyTitle: "Nothing to review", emptyDetail: "Tasks an agent proposes as done appear here until you accept them."),
    RegistryDestination(id: "upcoming", navigationKey: "upcoming", serverView: "upcoming", title: "Upcoming", iconId: "list.upcoming", sfSymbol: "calendar", sidebarOrder: 2, visibility: "always", canHide: true, shortcutKeycaps: ["⌘", "2"], emptyTitle: "Nothing upcoming", emptyDetail: "Tasks with a future When or Deadline date appear here."),
    RegistryDestination(id: "repeating", navigationKey: "repeating", serverView: "all", title: "Repeating", iconId: "list.repeating", sfSymbol: "arrow.clockwise", sidebarOrder: 3, visibility: "always", canHide: true, shortcutKeycaps: nil, emptyTitle: "No repeating tasks", emptyDetail: "Give any task a Repeat rule and it will show up here."),
    RegistryDestination(id: "anytime", navigationKey: "unscheduled", serverView: "unscheduled", title: "Anytime", iconId: "list.anytime", sfSymbol: "rectangle.stack.fill", sidebarOrder: 4, visibility: "always", canHide: true, shortcutKeycaps: ["⌘", "3"], emptyTitle: "Nothing in Anytime", emptyDetail: "Open tasks without a date live here."),
    RegistryDestination(id: "logbook", navigationKey: "logbook", serverView: "logbook", title: "Logbook", iconId: "list.logbook", sfSymbol: "checkmark", sidebarOrder: 5, visibility: "always", canHide: true, shortcutKeycaps: ["⌘", "4"], emptyTitle: "Logbook is empty", emptyDetail: "Completed and let-go tasks are archived here."),
    RegistryDestination(id: "starred", navigationKey: "starred", serverView: "all", title: "Starred", iconId: "list.starred", sfSymbol: "star.fill", sidebarOrder: 6, visibility: "whenNonEmpty", canHide: true, shortcutKeycaps: nil, emptyTitle: "No Starred Tasks", emptyDetail: "Star important tasks to keep them one tap away."),
    RegistryDestination(id: "faded", navigationKey: "faded", serverView: "all", title: "Faded", iconId: "list.faded", sfSymbol: "circle.dashed", sidebarOrder: 7, visibility: "whenNonEmpty", canHide: true, shortcutKeycaps: nil, emptyTitle: "No Faded Tasks", emptyDetail: "Undated tasks without activity for 14 days appear here until you keep them or let them go."),
    RegistryDestination(id: "recentlyDeleted", navigationKey: "recentlyDeleted", serverView: "all", title: "Recently Deleted", iconId: "list.recently_deleted", sfSymbol: "trash", sidebarOrder: 8, visibility: "whenNonEmpty", canHide: true, shortcutKeycaps: nil, emptyTitle: "Recently Deleted is empty", emptyDetail: "Deleted tasks stay here for 30 days before they are removed."),
  ]

  static let byId: [String: RegistryDestination] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
  static let byNavigationKey: [String: RegistryDestination] = Dictionary(uniqueKeysWithValues: all.map { ($0.navigationKey, $0) })
}

/// Generated shortcut-sheet entry (`registry/actions.json`).
struct RegistryShortcutEntry: Sendable, Hashable, Identifiable {
  let id: String
  let label: String
  let keycaps: [String]
  let excludePlatforms: [String]
}

enum RegistryActions {
  static let titles: [String: String] = [
    "task.editDetails": "Edit Details…",
    "task.toggleInfo": "Show Info",
    "task.copy": "Copy",
    "task.duplicate": "Duplicate",
    "task.toggleComplete": "Mark as Complete",
    "task.cancel": "Cancel Task",
    "task.toggleToday": "Toggle Today",
    "task.when": "When…",
    "task.deadline": "Deadline…",
    "task.move": "Move…",
    "task.moveSuggested": "Move to Suggested List",
    "task.clearSchedule": "Clear Schedule",
    "task.repeat": "Repeat…",
    "task.pauseResumeRepeat": "Pause Repeat",
    "task.createNextCopy": "Create Next Copy",
    "task.delete": "Delete",
    "task.restore": "Restore",
    "task.deletePermanently": "Delete Permanently",
    "area.newProject": "New Project in Area",
    "area.rename": "Rename",
    "area.delete": "Delete Area",
    "project.rename": "Rename",
    "project.moveUp": "Move Up",
    "project.moveDown": "Move Down",
    "project.markDone": "Mark Done",
    "project.cancel": "Cancel Project",
    "project.delete": "Delete Project",
    "sidebar.newArea": "New Area",
    "sidebar.newProject": "New Project",
    "section.new": "New Section",
    "section.rename": "Rename",
    "section.delete": "Delete Section",
    "notice.openStep": "Open",
    "notice.toggleStep": "Mark as Done",
    "notice.hideGetStarted": "Hide Get Started",
    "app.newTask": "New To-Do",
    "app.quickAdd": "Quick Add…",
    "app.quickEntry": "Quick Entry",
    "app.quickFind": "Quick Find…",
    "app.toggleSidebar": "Show / Hide Sidebar",
    "app.settings": "Settings…",
    "app.keyboardShortcuts": "Keyboard Shortcuts",
  ]

  static let sfSymbols: [String: String] = [
    "task.editDetails": "info.circle",
    "task.toggleInfo": "info.circle",
    "task.copy": "doc.on.doc",
    "task.duplicate": "plus.square.on.square",
    "task.toggleComplete": "checkmark.circle",
    "task.cancel": "xmark.circle",
    "task.toggleToday": "sun.max.fill",
    "task.when": "calendar",
    "task.deadline": "flag",
    "task.move": "folder",
    "task.moveSuggested": "folder",
    "task.clearSchedule": "calendar.badge.minus",
    "task.repeat": "arrow.clockwise",
    "task.pauseResumeRepeat": "pause.circle",
    "task.createNextCopy": "plus.circle",
    "task.delete": "trash",
    "task.restore": "arrow.uturn.backward",
    "task.deletePermanently": "trash",
    "area.newProject": "plus",
    "area.rename": "pencil",
    "area.delete": "trash",
    "project.rename": "pencil",
    "project.moveUp": "chevron.up",
    "project.moveDown": "chevron.down",
    "project.markDone": "checkmark.circle",
    "project.cancel": "xmark.circle",
    "project.delete": "trash",
    "sidebar.newArea": "plus",
    "sidebar.newProject": "plus",
    "section.new": "plus",
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
  ]

  static let shortcutsGeneral: [RegistryShortcutEntry] = [
    RegistryShortcutEntry(id: "app.newTask", label: "New To-Do", keycaps: ["⌘", "N"], excludePlatforms: []),
    RegistryShortcutEntry(id: "app.quickAdd", label: "Quick Add…", keycaps: ["⌘", "I"], excludePlatforms: []),
    RegistryShortcutEntry(id: "app.quickFind", label: "Quick Find…", keycaps: ["⇧", "⌘", "F"], excludePlatforms: []),
    RegistryShortcutEntry(id: "app.toggleSidebar", label: "Show / Hide Sidebar", keycaps: ["⌃", "⌘", "S"], excludePlatforms: ["ios", "ipados"]),
    RegistryShortcutEntry(id: "app.settings", label: "Settings…", keycaps: ["⌘", ","], excludePlatforms: []),
    RegistryShortcutEntry(id: "app.keyboardShortcuts", label: "Keyboard Shortcuts", keycaps: ["⇧", "⌘", "/"], excludePlatforms: []),
  ]
  static let shortcutsTaskList: [RegistryShortcutEntry] = [
    RegistryShortcutEntry(id: "task.editDetails", label: "Edit Details…", keycaps: ["⌘", "R"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.toggleInfo", label: "Show Info", keycaps: ["⌥", "⌘", "I"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.copy", label: "Copy", keycaps: ["⌘", "C"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.duplicate", label: "Duplicate", keycaps: ["⌘", "D"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.toggleComplete", label: "Mark as Complete", keycaps: ["⌘", "K"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.cancel", label: "Cancel Task", keycaps: ["⌥", "⌘", "K"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.toggleToday", label: "Toggle Today", keycaps: ["⌘", "T"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.when", label: "When…", keycaps: ["⌘", "S"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.deadline", label: "Deadline…", keycaps: ["⇧", "⌘", "D"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.move", label: "Move…", keycaps: ["⇧", "⌘", "M"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.move.alt0", label: "Move…", keycaps: ["⌘", "M"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.moveSuggested", label: "Move to Suggested List", keycaps: ["⌥", "⌘", "M"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.clearSchedule", label: "Clear Schedule", keycaps: ["⇧", "⌘", "."], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.delete", label: "Delete", keycaps: ["⌘", "⌫"], excludePlatforms: []),
  ]
}

/// Destructive and fork confirmation copy (`registry/surfaces.json`).
struct RegistryPromptCopy: Sendable, Hashable {
  let id: String
  let title: String
  let message: String
  let confirmTitle: String?
}

enum RegistrySurfaces {
  static let maxConcurrentExplainers: Int = 1
  static let toastDurationSeconds: Double = 7
  static let taskAttributeOrder: [String] = ["today", "when", "deadline", "list", "repeat", "notes", "discuss", "attachments"]
  static let prompts: [String: RegistryPromptCopy] = [
    "deletePermanently": RegistryPromptCopy(id: "deletePermanently", title: "Delete Permanently?", message: "This cannot be undone.", confirmTitle: "Delete Permanently"),
    "deleteSection": RegistryPromptCopy(id: "deleteSection", title: "Delete this section?", message: "Its tasks stay in the project.", confirmTitle: "Delete Section"),
    "deleteArea": RegistryPromptCopy(id: "deleteArea", title: "Delete this area?", message: "Its projects stay, detached from the area.", confirmTitle: "Delete Area"),
    "deleteProject": RegistryPromptCopy(id: "deleteProject", title: "Delete this project?", message: "Its tasks move to Recently Deleted.", confirmTitle: "Delete Project"),
    "deleteAccount": RegistryPromptCopy(id: "deleteAccount", title: "Delete Account?", message: "Your tasks, areas, projects, and conversations are erased from the server and this device.", confirmTitle: "Delete Account"),
    "rescheduleFixedRepeat": RegistryPromptCopy(id: "rescheduleFixedRepeat", title: "Reschedule repeating task?", message: "Move only this task, or update the repeating schedule to the new date?", confirmTitle: nil),
  ]
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
  static let setupPrompt: String = "Set up Septena for me using https://septena.app/agents.md"
  static let firstPrompt: String = "Set up my Septena areas, projects, and tasks by following https://api.septena.app/onboard.md"
  static let steps: [RegistryFirstRunStep] = [
    RegistryFirstRunStep(id: "welcome", kind: "intro", icon: "onboarding.welcome", title: "Welcome to Septena", body: "A task list you share with your AI.", footnote: nil, returningTitle: nil, returningBody: nil, skipWhen: nil, requires: nil, completesGetStartedStep: nil, points: [RegistryFirstRunPoint(icon: "onboarding.devices", title: "On every device", detail: "Your tasks stay in step on iPhone, iPad and Mac."), RegistryFirstRunPoint(icon: "onboarding.agent", title: "Work with Claude", detail: "Claude can take a task, ask you a question, and hand back the result."), RegistryFirstRunPoint(icon: "onboarding.notes", title: "Notes keep the context", detail: "Each project has notes, so you and Claude know what it's for.")], choices: [], instructions: [], primary: RegistryFirstRunButton(title: "Continue", action: "next"), secondary: nil, tertiary: nil, afterDone: nil),
    RegistryFirstRunStep(id: "account", kind: "account", icon: "onboarding.account", title: "Sign in to sync", body: "Sign in with Apple to keep your tasks on all your devices and to let Claude connect. Septena never sees your Apple password.", footnote: "If you skip this, your tasks stay on this device until you sign in.", returningTitle: nil, returningBody: nil, skipWhen: "signedIn", requires: nil, completesGetStartedStep: nil, points: [], choices: [], instructions: [], primary: RegistryFirstRunButton(title: "Sign in with Apple", action: "signIn"), secondary: RegistryFirstRunButton(title: "Not now", action: "next"), tertiary: nil, afterDone: nil),
    RegistryFirstRunStep(id: "moveIn", kind: "choices", icon: "onboarding.move_in", title: "Bring your tasks", body: "Start from the list you already have, or start empty.", footnote: nil, returningTitle: nil, returningBody: nil, skipWhen: nil, requires: nil, completesGetStartedStep: "importTasks", points: [], choices: [RegistryFirstRunChoice(id: "things", icon: "onboarding.things", title: "From Things", detail: "Copies your areas, projects and tasks. Nothing in Things changes.", action: "importThings", platforms: ["ios", "ipados", "macos"]), RegistryFirstRunChoice(id: "reminders", icon: "settings.reminders", title: "From Reminders", detail: "Pick a Reminders list. Its items wait in your Inbox until you bring them in.", action: "importReminders", platforms: ["ios", "ipados", "macos"]), RegistryFirstRunChoice(id: "fresh", icon: "onboarding.fresh", title: "Start empty", detail: "Add tasks as they come up.", action: "next", platforms: ["ios", "ipados", "macos", "web", "android", "windows"])], instructions: [], primary: nil, secondary: nil, tertiary: nil, afterDone: nil),
    RegistryFirstRunStep(id: "connectClaude", kind: "connectAgent", icon: "settings.claude", title: "Connect Claude", body: "Claude reads and changes your tasks through your Septena account. You decide which tasks it works on.", footnote: nil, returningTitle: nil, returningBody: nil, skipWhen: nil, requires: "signedIn", completesGetStartedStep: "connectAI", points: [], choices: [], instructions: ["Copy the setup prompt and paste it into Claude.", "When Claude shows a code, enter it below.", "Paste the first prompt. Claude sets up your areas and projects with you."], primary: RegistryFirstRunButton(title: "Copy setup prompt", action: "copySetupPrompt"), secondary: RegistryFirstRunButton(title: "Later", action: "next"), tertiary: RegistryFirstRunButton(title: "Copy first prompt", action: "copyFirstPrompt"), afterDone: RegistryFirstRunButton(title: "Continue", action: "next")),
    RegistryFirstRunStep(id: "done", kind: "finish", icon: "onboarding.done", title: "You're all set", body: "Today shows what to do now. Anything you skipped stays on the Get started list.", footnote: nil, returningTitle: "Welcome back", returningBody: "This account is already set up. Your tasks are syncing to this device.", skipWhen: nil, requires: nil, completesGetStartedStep: nil, points: [], choices: [], instructions: [], primary: RegistryFirstRunButton(title: "Open Today", action: "finish"), secondary: nil, tertiary: nil, afterDone: nil),
  ]
}

/// Canonical capability parity ledger (`registry/capabilities.json`, ADR 0013 / ADR 0015).
enum RegistryCapabilities {
  static let byPlatform: [String: [String: String]] = [
    "ios": ["lists.inbox": "ships", "lists.today": "ships", "lists.review": "ships", "lists.upcoming": "ships", "lists.anytime": "ships", "lists.repeating": "ships", "lists.logbook": "ships", "lists.faded": "ships", "lists.starred": "ships", "lists.recently-deleted": "ships", "places.areas": "ships", "places.projects": "ships", "places.sections": "ships", "task.when-deadline": "ships", "task.repeat": "ships", "task.notes": "ships", "task.attachments": "ships", "task.history": "ships", "task.aging": "ships", "task.checklists": "planned", "task.tags": "planned", "task.alerts": "planned", "fade.sweep": "ships", "capture.quick-add": "ships", "capture.quick-entry": "not_applicable", "edit.filing-suggestion": "ships", "edit.undo": "ships", "edit.swipe-actions": "planned", "find.quick-find": "ships", "mac.keyboard": "not_applicable", "mac.updates": "not_applicable", "calendar.events": "ships", "import.reminders": "ships", "import.things": "ships", "ai.discuss": "ships", "ai.reach-dial": "ships", "agents.connector": "ships", "onboarding.first-run": "ships", "agents.stop-pause": "ships", "sync.backend": "ships", "account.delete": "ships", "settings.display": "ships"],
    "ipados": ["lists.inbox": "ships", "lists.today": "ships", "lists.review": "ships", "lists.upcoming": "ships", "lists.anytime": "ships", "lists.repeating": "ships", "lists.logbook": "ships", "lists.faded": "ships", "lists.starred": "ships", "lists.recently-deleted": "ships", "places.areas": "ships", "places.projects": "ships", "places.sections": "ships", "task.when-deadline": "ships", "task.repeat": "ships", "task.notes": "ships", "task.attachments": "ships", "task.history": "ships", "task.aging": "ships", "task.checklists": "planned", "task.tags": "planned", "task.alerts": "planned", "fade.sweep": "ships", "capture.quick-add": "ships", "capture.quick-entry": "not_applicable", "edit.filing-suggestion": "ships", "edit.undo": "ships", "edit.swipe-actions": "planned", "find.quick-find": "ships", "mac.keyboard": "ships", "mac.updates": "not_applicable", "calendar.events": "ships", "import.reminders": "ships", "import.things": "ships", "ai.discuss": "ships", "ai.reach-dial": "ships", "agents.connector": "ships", "onboarding.first-run": "ships", "agents.stop-pause": "ships", "sync.backend": "ships", "account.delete": "ships", "settings.display": "ships"],
    "macos": ["lists.inbox": "ships", "lists.today": "ships", "lists.review": "ships", "lists.upcoming": "ships", "lists.anytime": "ships", "lists.repeating": "ships", "lists.logbook": "ships", "lists.faded": "ships", "lists.starred": "ships", "lists.recently-deleted": "ships", "places.areas": "ships", "places.projects": "ships", "places.sections": "ships", "task.when-deadline": "ships", "task.repeat": "ships", "task.notes": "ships", "task.attachments": "partial", "task.history": "ships", "task.aging": "ships", "task.checklists": "planned", "task.tags": "planned", "task.alerts": "planned", "fade.sweep": "ships", "capture.quick-add": "not_applicable", "capture.quick-entry": "ships", "edit.filing-suggestion": "ships", "edit.undo": "ships", "edit.swipe-actions": "not_applicable", "find.quick-find": "ships", "mac.keyboard": "ships", "mac.updates": "ships", "calendar.events": "ships", "import.reminders": "ships", "import.things": "ships", "ai.discuss": "ships", "ai.reach-dial": "ships", "agents.connector": "ships", "onboarding.first-run": "ships", "agents.stop-pause": "ships", "sync.backend": "ships", "account.delete": "ships", "settings.display": "ships"],
    "web": ["lists.inbox": "planned", "lists.today": "planned", "lists.review": "planned", "lists.upcoming": "planned", "lists.anytime": "planned", "lists.repeating": "planned", "lists.logbook": "planned", "lists.faded": "planned", "lists.starred": "planned", "lists.recently-deleted": "planned", "places.areas": "planned", "places.projects": "planned", "places.sections": "planned", "task.when-deadline": "planned", "task.repeat": "planned", "task.notes": "planned", "task.attachments": "planned", "task.history": "planned", "task.aging": "planned", "task.checklists": "planned", "task.tags": "planned", "task.alerts": "planned", "fade.sweep": "planned", "capture.quick-add": "planned", "capture.quick-entry": "not_applicable", "edit.filing-suggestion": "not_applicable", "edit.undo": "planned", "edit.swipe-actions": "not_applicable", "find.quick-find": "planned", "mac.keyboard": "planned", "mac.updates": "not_applicable", "calendar.events": "planned", "import.reminders": "not_applicable", "import.things": "not_applicable", "ai.discuss": "planned", "ai.reach-dial": "planned", "agents.connector": "planned", "onboarding.first-run": "planned", "agents.stop-pause": "planned", "sync.backend": "planned", "account.delete": "planned", "settings.display": "planned"],
    "android": ["lists.inbox": "planned", "lists.today": "planned", "lists.review": "planned", "lists.upcoming": "planned", "lists.anytime": "planned", "lists.repeating": "planned", "lists.logbook": "planned", "lists.faded": "planned", "lists.starred": "planned", "lists.recently-deleted": "planned", "places.areas": "planned", "places.projects": "planned", "places.sections": "planned", "task.when-deadline": "planned", "task.repeat": "planned", "task.notes": "planned", "task.attachments": "planned", "task.history": "planned", "task.aging": "planned", "task.checklists": "planned", "task.tags": "planned", "task.alerts": "planned", "fade.sweep": "planned", "capture.quick-add": "planned", "capture.quick-entry": "not_applicable", "edit.filing-suggestion": "planned", "edit.undo": "planned", "edit.swipe-actions": "planned", "find.quick-find": "planned", "mac.keyboard": "planned", "mac.updates": "not_applicable", "calendar.events": "planned", "import.reminders": "not_applicable", "import.things": "not_applicable", "ai.discuss": "planned", "ai.reach-dial": "planned", "agents.connector": "planned", "onboarding.first-run": "planned", "agents.stop-pause": "planned", "sync.backend": "planned", "account.delete": "planned", "settings.display": "planned"],
    "windows": ["lists.inbox": "planned", "lists.today": "planned", "lists.review": "planned", "lists.upcoming": "planned", "lists.anytime": "planned", "lists.repeating": "planned", "lists.logbook": "planned", "lists.faded": "planned", "lists.starred": "planned", "lists.recently-deleted": "planned", "places.areas": "planned", "places.projects": "planned", "places.sections": "planned", "task.when-deadline": "planned", "task.repeat": "planned", "task.notes": "planned", "task.attachments": "planned", "task.history": "planned", "task.aging": "planned", "task.checklists": "planned", "task.tags": "planned", "task.alerts": "planned", "fade.sweep": "planned", "capture.quick-add": "not_applicable", "capture.quick-entry": "planned", "edit.filing-suggestion": "planned", "edit.undo": "planned", "edit.swipe-actions": "not_applicable", "find.quick-find": "planned", "mac.keyboard": "planned", "mac.updates": "planned", "calendar.events": "planned", "import.reminders": "not_applicable", "import.things": "not_applicable", "ai.discuss": "planned", "ai.reach-dial": "planned", "agents.connector": "planned", "onboarding.first-run": "planned", "agents.stop-pause": "planned", "sync.backend": "planned", "account.delete": "planned", "settings.display": "planned"],
    "watchos": ["lists.inbox": "partial", "lists.today": "partial", "lists.review": "not_applicable", "lists.upcoming": "not_applicable", "lists.anytime": "not_applicable", "lists.repeating": "not_applicable", "lists.logbook": "not_applicable", "lists.faded": "not_applicable", "lists.starred": "not_applicable", "lists.recently-deleted": "not_applicable", "places.areas": "not_applicable", "places.projects": "not_applicable", "places.sections": "not_applicable", "task.when-deadline": "not_applicable", "task.repeat": "not_applicable", "task.notes": "not_applicable", "task.attachments": "not_applicable", "task.history": "not_applicable", "task.aging": "not_applicable", "task.checklists": "not_applicable", "task.tags": "not_applicable", "task.alerts": "not_applicable", "fade.sweep": "not_applicable", "capture.quick-add": "not_applicable", "capture.quick-entry": "not_applicable", "edit.filing-suggestion": "not_applicable", "edit.undo": "not_applicable", "edit.swipe-actions": "not_applicable", "find.quick-find": "not_applicable", "mac.keyboard": "not_applicable", "mac.updates": "not_applicable", "calendar.events": "not_applicable", "import.reminders": "not_applicable", "import.things": "not_applicable", "ai.discuss": "not_applicable", "ai.reach-dial": "not_applicable", "agents.connector": "not_applicable", "onboarding.first-run": "not_applicable", "agents.stop-pause": "not_applicable", "sync.backend": "planned", "account.delete": "not_applicable", "settings.display": "not_applicable"],
  ]

  static func isShipped(_ featureId: String, on platform: String) -> Bool {
    byPlatform[platform]?[featureId] == "ships"
  }
}
