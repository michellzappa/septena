// GENERATED FILE — DO NOT EDIT BY HAND.
// Sources: registry/{entities,rules,icons,tokens,capabilities,settings,destinations,actions,surfaces,plans,import-sources}.json
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
  static let maxRefsPerTask: Int = 20
  static let refKeyMax: Int = 1000
  static let refSnapshotMax: Int = 2048
  static let doPlannedMinutesMax: Int = 240
  static let doNoteMax: Int = 500
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
  static let taskStatus: [String] = ["open", "done", "cancelled", "checklistChecked"]
  static let checklistMode: [String] = ["plain", "groceries"]
  static let taskSource: [String] = ["app", "mcp"]
  static let projectStatus: [String] = ["active", "done", "cancelled"]
  static let taskKind: [String] = ["heading"]
  static let listSort: [String] = ["manual", "when", "deadline", "title", "created"]
  static let recurrenceUnit: [String] = ["day", "week", "month", "year"]
  static let reminderMode: [String] = ["floating", "fixed"]
  static let convoAssignee: [String] = ["me", "local", "claude"]
  static let convoEndState: [String] = ["agent_done", "human_done", "agent_assisted_done", "needs_verify", "decomposed", "reminder_set", "promoted_to_today", "wont_do", "open"]
  static let convoHandoffActionType: [String] = ["open_url", "compose", "call", "none"]
  static let convoTurnRole: [String] = ["user", "provider"]
  static let convoTurnStep: [String] = ["confirm", "ground", "scope", "decide", "work"]
  static let doExit: [String] = ["done", "stopped", "later", "replaced", "closed"]
  static let taskRefRole: [String] = ["about", "from", "blocked_by", "follow_up"]
  static let telemetryLevel: [String] = ["none", "minimal", "balanced", "full"]
  static let appearanceMode: [String] = ["system", "light", "dark"]
  static let accentColor: [String] = ["colorful", "tamarillo", "persimmon", "yuzu", "carambola", "haskap", "acai", "pitaya", "jabuticaba"]
  static let appIconFinish: [String] = ["obsidian", "ceramic", "framed"]
  static let canvasTexture: [String] = ["none", "topography", "fieldMatrix", "stippleDrift", "ridges", "washiPaper"]
  static let textureMotion: [String] = ["still", "slowDrift"]
  static let entityNames: [String] = ["task", "area", "project", "attachment", "checklistItem", "taskRef", "tag", "doSession", "convo", "setting"]
  static let deletableEntities: [String] = ["task", "area", "project", "attachment", "checklistItem", "taskRef", "tag", "doSession"]
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
  static let doStaleHours: Int = 4
  static let doLapseHours: Int = 24
  static let navigationHistoryLimit: Int = 50
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
    "list.agent": "person.2.badge.gearshape",
    "agent.queued": "clock",
    "agent.working": "ellipsis.circle",
    "agent.your_turn": "questionmark.bubble",
    "agent.stopped": "stop.circle",
    "agent.done": "checkmark.circle",
    "list.upcoming": "calendar",
    "list.repeating": "arrow.clockwise",
    "list.anytime": "rectangle.stack.fill",
    "list.logbook": "checkmark",
    "list.faded": "circle.dashed",
    "list.waiting": "hourglass",
    "action.waiting": "hourglass",
    "action.got_it_back": "arrow.uturn.backward.circle",
    "list.starred": "star.fill",
    "list.recently_deleted": "trash",
    "place.area": "folder",
    "place.project": "number",
    "place.section": "text.alignleft",
    "action.edit_details": "info.circle",
    "action.open": "arrow.up.left.and.arrow.down.right",
    "action.share_project": "person.crop.circle.badge.plus",
    "project.shared": "person.2.fill",
    "action.assign": "person",
    "action.share": "square.and.arrow.up",
    "action.accept": "checkmark.seal",
    "action.send_back": "arrowshape.turn.up.backward",
    "action.rename": "pencil",
    "action.copy": "doc.on.doc",
    "action.paste": "doc.on.clipboard",
    "action.duplicate": "plus.square.on.square",
    "action.complete": "checkmark.circle",
    "action.do": "play.circle",
    "action.do_stop": "pause.circle",
    "action.do_here": "arrow.up.left.and.arrow.down.right",
    "action.do_show_list": "list.bullet",
    "action.cancel": "xmark.circle",
    "action.delete": "trash",
    "action.let_go": "wind",
    "action.restore": "arrow.uturn.backward",
    "action.today_add": "sun.max.fill",
    "action.today_remove": "sun.min",
    "action.schedule": "calendar",
    "action.when": "calendar",
    "action.deadline": "flag",
    "date.tomorrow": "sunrise",
    "date.clear": "xmark.circle",
    "date.time": "clock",
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
    "action.go_back": "chevron.backward",
    "action.go_forward": "chevron.forward",
    "action.search": "magnifyingglass",
    "action.settings": "gearshape",
    "action.sidebar": "sidebar.leading",
    "action.notes": "text.alignleft",
    "action.discuss": "bubble.left.and.bubble.right",
    "action.attachment": "paperclip",
    "action.history": "clock.arrow.circlepath",
    "action.checklist": "checklist",
    "action.tag": "tag",
    "action.reminder": "bell",
    "action.star": "star",
    "action.emoji": "face.smiling",
    "settings.account": "person.crop.circle",
    "settings.devices": "laptopcomputer.and.iphone",
    "settings.sign_in_approval": "person.badge.key",
    "auth.device": "laptopcomputer.and.iphone",
    "auth.apple": "apple.logo",
    "auth.google": "g.circle",
    "auth.microsoft": "m.circle",
    "auth.email": "envelope",
    "auth.scan_code": "qrcode.viewfinder",
    "settings.general": "slider.horizontal.3",
    "settings.tasks": "checklist",
    "action.reference": "link.badge.plus",
    "reference.email": "envelope",
    "reference.thread": "envelope",
    "reference.event": "calendar",
    "reference.issue": "smallcircle.filled.circle",
    "reference.task": "checkmark.square",
    "reference.door": "arrow.up.right.square",
    "reference.url": "globe",
    "reference.file": "doc",
    "reference.other": "link",
    "task.added_by_agent": "text.bubble.badge.sparkles",
    "settings.ai_agents": "cpu",
    "settings.agents": "person.2",
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
    "settings.help": "questionmark.circle",
    "settings.feedback": "paperplane",
    "settings.open_source": "chevron.left.forwardslash.chevron.right",
    "settings.paste": "doc.on.clipboard",
    "settings.plus": "plus.circle.fill",
    "settings.notifications": "bell",
    "settings.language": "globe",
    "settings.shortcuts": "keyboard",
    "settings.siri_shortcuts": "square.2.layers.3d",
    "plans.free": "iphone",
    "plans.pro": "infinity",
    "plans.history": "clock.arrow.circlepath",
    "plans.plus": "plus",
    "plans.devices": "laptopcomputer.and.iphone",
    "plans.agents": "bubble.left.and.text.bubble.right.fill",
    "plans.files": "paperclip",
    "notice.sign_in": "person.crop.circle.badge.exclamationmark",
    "notice.rolled_in": "arrow.down.circle",
    "notice.get_started": "sparkles",
    "notice.fade_intro": "circle.lefthalf.filled",
    "convo.needs_you": "circle.fill",
    "convo.working": "circle.fill",
    "convo.done": "checkmark.circle.fill",
    "convo.wont_do": "minus.circle",
    "notice.second_device": "laptopcomputer.and.iphone",
    "notice.trial_end": "hourglass",
    "notice.weekly_sweep": "circle.dashed",
    "action.text_size": "textformat.size",
    "action.window": "macwindow",
    "action.sidebar_counts": "number",
    "action.sort": "arrow.up.arrow.down",
  ]

  static func sfSymbol(for id: String) -> String {
    sfSymbols[id] ?? "circle"
  }

  /// Filled variants (`icons.json` `sfSymbolOn`) a control shows while it is on.
  static let sfSymbolsOn: [String: String] = [
    "action.do": "play.circle.fill",
    "action.star": "star.fill",
  ]

  /// The symbol for `id` in a control's state: its filled variant while on,
  /// when the icon declares one. Every on/off control reads its icon here.
  static func sfSymbol(for id: String, on: Bool) -> String {
    on ? (sfSymbolsOn[id] ?? sfSymbol(for: id)) : sfSymbol(for: id)
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
    static let pointerHoverOpacity: Double = 0.05
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
  enum CompletionMotion {
    static let settleDelayMs: Int = 3000
    static let fadeOutMs: Int = 350
    static let checkPopMs: Int = 280
    static let pulseRingMs: Int = 400
  }
  static let accentPalette: [String] = ["#ef4444", "#f97316", "#f59e0b", "#eab308", "#84cc16", "#22c55e", "#10b981", "#14b8a6", "#06b6d4", "#0ea5e9", "#3b82f6", "#6366f1", "#8b5cf6", "#a855f7", "#ec4899", "#f43f5e"]
  static let fruitAccents: [RegistryFruitAccent] = [
    RegistryFruitAccent(id: "colorful", name: RegistryL10n.t("Colorful"), origin: "Default · Blue + semantic", lightHex: "#007AFF", darkHex: "#0A84FF", checkLightHex: "#FFFFFF", checkDarkHex: "#FFFFFF", multicolor: true),
    RegistryFruitAccent(id: "tamarillo", name: RegistryL10n.t("Tamarillo"), origin: "Andes · Crimson", lightHex: "#D6333F", darkHex: "#FF5C67", checkLightHex: "#FFFFFF", checkDarkHex: "#FFFFFF", multicolor: false),
    RegistryFruitAccent(id: "persimmon", name: RegistryL10n.t("Persimmon"), origin: "East Asia · Vermilion", lightHex: "#E05212", darkHex: "#FF7738", checkLightHex: "#FFFFFF", checkDarkHex: "#FFFFFF", multicolor: false),
    RegistryFruitAccent(id: "yuzu", name: RegistryL10n.t("Yuzu"), origin: "Japan · Citrus gold", lightHex: "#C28500", darkHex: "#F2BF2C", checkLightHex: "#FFFFFF", checkDarkHex: "#141518", multicolor: false),
    RegistryFruitAccent(id: "carambola", name: RegistryL10n.t("Carambola"), origin: "SE Asia · Starfruit", lightHex: "#5B8C00", darkHex: "#9EE034", checkLightHex: "#FFFFFF", checkDarkHex: "#141518", multicolor: false),
    RegistryFruitAccent(id: "haskap", name: RegistryL10n.t("Haskap"), origin: "Hokkaido · Honeyberry blue", lightHex: "#1D63DC", darkHex: "#4E94FF", checkLightHex: "#FFFFFF", checkDarkHex: "#FFFFFF", multicolor: false),
    RegistryFruitAccent(id: "acai", name: RegistryL10n.t("Açaí"), origin: "Amazon · Indigo", lightHex: "#6544D6", darkHex: "#9B82FF", checkLightHex: "#FFFFFF", checkDarkHex: "#FFFFFF", multicolor: false),
    RegistryFruitAccent(id: "pitaya", name: RegistryL10n.t("Pitaya"), origin: "Mesoamerica · Dragonfruit", lightHex: "#D4266C", darkHex: "#FF5C9B", checkLightHex: "#FFFFFF", checkDarkHex: "#FFFFFF", multicolor: false),
    RegistryFruitAccent(id: "jabuticaba", name: RegistryL10n.t("Jabuticaba"), origin: "Brazil · Obsidian ink", lightHex: "#27272E", darkHex: "#E4E4EA", checkLightHex: "#FFFFFF", checkDarkHex: "#141518", multicolor: false),
  ]
  /// Icon id → hex for icons that keep their semantic color under the
  /// multicolor fruit (`multicolorGlyphs`); other fruits tint them with the accent.
  static let multicolorGlyphHex: [String: String] = ["list.today": "#F5C721", "plans.devices": "#007AFF", "plans.agents": "#E05212", "plans.files": "#30B0C7", "plans.history": "#5856D6"]
  static let textures: [RegistryTextureOption] = [
    RegistryTextureOption(id: "none", name: RegistryL10n.t("Pure Canvas"), tag: RegistryL10n.t("Baseline")),
    RegistryTextureOption(id: "topography", name: RegistryL10n.t("Topography"), tag: RegistryL10n.t("Height Map")),
    RegistryTextureOption(id: "fieldMatrix", name: RegistryL10n.t("Field Matrix"), tag: RegistryL10n.t("Industrial")),
    RegistryTextureOption(id: "stippleDrift", name: RegistryL10n.t("Stipple Drift"), tag: RegistryL10n.t("Print / Ink")),
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
  /// The help center. Help rows and menu items open it or a page below it.
  static let helpURL = URL(string: "https://septena.app/help")!
  static let syncedKeys: [String] = ["welcomeName", "telemetryLevel", "calendarHiddenTitles", "rolledInDismissedOn", "homeTimezone", "agentsPaused", "agentCommentNotifications", "agentCommentNotificationsByAgent", "getStartedDismissed", "getStartedSteps", "upsellsSeen", "onboardedAt", "accentColor", "canvasTexture", "textureIntensity", "textureMotion", "smartListOrder", "smartListHidden", "smartListPlacement", "listSort", "tasksShowAging", "fadeSweptAt", "fadeSweepDismissedOn"]

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
    static let listSort = "septena.lists.sort"
    static let appearanceMode = "septena.appearance.mode"
    static let syncTheme = "septena.appearance.syncTheme"
    static let appIconFinish = "septena.appearance.appIconFinish"
    static let todayShowCompleted = "septena.today.showCompleted"
    static let todayGroupByList = "septena.today.groupByList"
    static let tasksShowAging = "septena.tasks.showAging"
    static let tasksShowFaded = "septena.tasks.showFaded"
    static let tasksTitleLines = "septena.tasks.titleLines"
    static let tasksFilingSuggestions = "septena.tasks.filingSuggestions"
    static let tasksShowCalendarEvents = "septena.tasks.showCalendarEvents"
    static let badgeShowOverdue = "septena.badge.showOverdue"
    static let loggingAnimationsEnabled = "septena.ui.loggingAnimations"
    static let inboxZeroMotionEnabled = "septena.ui.inboxZeroMotion"
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
    static let agentCommentNotifications: String = "needs_input"
    static let getStartedDismissed: Bool = false
    static let accentColor: String = "colorful"
    static let canvasTexture: String = "none"
    static let textureIntensity: Int = 55
    static let textureMotion: String = "still"
    static let appearanceMode: String = "system"
    static let syncTheme: Bool = true
    static let appIconFinish: String = "obsidian"
    static let todayShowCompleted: Bool = true
    static let todayGroupByList: Bool = true
    static let tasksShowAging: Bool = true
    static let tasksShowFaded: Bool = true
    static let tasksTitleLines: Int = 2
    static let tasksFilingSuggestions: Bool = true
    static let tasksShowCalendarEvents: Bool = true
    static let badgeShowOverdue: Bool = false
    static let loggingAnimationsEnabled: Bool = true
    static let inboxZeroMotionEnabled: Bool = true
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
    static let appearance = "appearance"
    static let agents = "agents"
    static let connections = "connections"
    static let privacy = "privacy"
    static let about = "about"
  }

  enum PageID {
    static let account = "account"
    static let plus = "plus"
    static let devicesAccess = "devices_access"
    static let general = "general"
    static let smartLists = "smart_lists"
    static let aiPreferences = "ai_preferences"
    static let appearance = "appearance"
    static let agents = "agents"
    static let connections = "connections"
    static let calendar = "calendar"
    static let reminders = "reminders"
    static let shortcuts = "shortcuts"
    static let privacy = "privacy"
    static let importExport = "import_export"
    static let about = "about"
    static let advanced = "advanced"
  }

  static let optionsByKey: [String: [RegistrySettingsOption]] = [
    "agentCommentNotifications": [RegistrySettingsOption(value: "every_comment", title: RegistryL10n.t("Every comment")), RegistrySettingsOption(value: "needs_input", title: RegistryL10n.t("Needs my answer or approval")), RegistrySettingsOption(value: "daily_digest", title: RegistryL10n.t("Daily digest")), RegistrySettingsOption(value: "off", title: RegistryL10n.t("No notifications"))],
    "listSort": [RegistrySettingsOption(value: "manual", title: RegistryL10n.t("Manual")), RegistrySettingsOption(value: "when", title: RegistryL10n.t("When")), RegistrySettingsOption(value: "deadline", title: RegistryL10n.t("Deadline")), RegistrySettingsOption(value: "title", title: RegistryL10n.t("Title")), RegistrySettingsOption(value: "created", title: RegistryL10n.t("Created"))],
    "appearanceMode": [RegistrySettingsOption(value: "system", title: RegistryL10n.t("System")), RegistrySettingsOption(value: "light", title: RegistryL10n.t("Light")), RegistrySettingsOption(value: "dark", title: RegistryL10n.t("Dark"))],
    "tasksTitleLines": [RegistrySettingsOption(value: "1", title: RegistryL10n.t("One")), RegistrySettingsOption(value: "2", title: RegistryL10n.t("Two")), RegistrySettingsOption(value: "3", title: RegistryL10n.t("Three"))],
    "aiMode": [RegistrySettingsOption(value: "onDeviceOnly", title: RegistryL10n.t("On-device only")), RegistrySettingsOption(value: "auto", title: RegistryL10n.t("Automatic")), RegistrySettingsOption(value: "useMyClaude", title: RegistryL10n.t("Use my Claude"))],
    "pccReasoning": [RegistrySettingsOption(value: "light", title: RegistryL10n.t("Light")), RegistrySettingsOption(value: "balanced", title: RegistryL10n.t("Balanced")), RegistrySettingsOption(value: "thorough", title: RegistryL10n.t("Thorough"))],
  ]

  static let desktopTabs: [RegistrySettingsTab] = [
    RegistrySettingsTab(id: "account", title: RegistryL10n.t("Account"), iconId: "settings.account", sfSymbol: "person.crop.circle", group: "identity", paletteSlot: nil, featureId: "sync.backend"),
    RegistrySettingsTab(id: "general", title: RegistryL10n.t("General"), iconId: "settings.general", sfSymbol: "slider.horizontal.3", group: "main", paletteSlot: 0, featureId: "lists.today"),
    RegistrySettingsTab(id: "appearance", title: RegistryL10n.t("Appearance"), iconId: "settings.appearance", sfSymbol: "paintpalette", group: "main", paletteSlot: 2, featureId: "settings.display"),
    RegistrySettingsTab(id: "agents", title: RegistryL10n.t("Agents"), iconId: "settings.agents", sfSymbol: "person.2", group: "main", paletteSlot: 4, featureId: "agents.connector"),
    RegistrySettingsTab(id: "connections", title: RegistryL10n.t("Connections"), iconId: "settings.connections", sfSymbol: "link", group: "main", paletteSlot: 5, featureId: "calendar.feed"),
    RegistrySettingsTab(id: "privacy", title: RegistryL10n.t("Privacy & Data"), iconId: "settings.privacy", sfSymbol: "hand.raised", group: "main", paletteSlot: 6, featureId: "settings.display"),
    RegistrySettingsTab(id: "about", title: RegistryL10n.t("About"), iconId: "settings.about", sfSymbol: "info.circle", group: "about", paletteSlot: nil, featureId: "settings.display"),
  ]

  static let rootGroups: [RegistrySettingsGroup] = [
    RegistrySettingsGroup(id: "account_root", header: nil, mobilePresentation: "card", items: [
      RegistrySettingsItem(kind: "pageLink", key: nil, page: "account", surface: "account_profile_card", label: RegistryL10n.t("Account"), detail: nil, iconId: "settings.account", sfSymbol: "person.crop.circle", statusKey: "syncStatus", visibility: "always", platforms: nil, featureId: "sync.backend"),
    ]),
    RegistrySettingsGroup(id: "places_root", header: nil, mobilePresentation: "inline", items: [
      RegistrySettingsItem(kind: "pageLink", key: nil, page: "general", surface: nil, label: RegistryL10n.t("General"), detail: nil, iconId: "settings.general", sfSymbol: "slider.horizontal.3", statusKey: nil, visibility: "always", platforms: nil, featureId: "lists.today"),
      RegistrySettingsItem(kind: "pageLink", key: nil, page: "appearance", surface: nil, label: RegistryL10n.t("Appearance"), detail: nil, iconId: "settings.appearance", sfSymbol: "paintpalette", statusKey: nil, visibility: "always", platforms: nil, featureId: "settings.display"),
      RegistrySettingsItem(kind: "pageLink", key: nil, page: "agents", surface: nil, label: RegistryL10n.t("Agents"), detail: nil, iconId: "settings.agents", sfSymbol: "person.2", statusKey: "agentsStatus", visibility: "always", platforms: nil, featureId: "agents.connector"),
      RegistrySettingsItem(kind: "pageLink", key: nil, page: "connections", surface: nil, label: RegistryL10n.t("Connections"), detail: nil, iconId: "settings.connections", sfSymbol: "link", statusKey: nil, visibility: "always", platforms: nil, featureId: "calendar.feed"),
      RegistrySettingsItem(kind: "pageLink", key: nil, page: "privacy", surface: nil, label: RegistryL10n.t("Privacy & Data"), detail: nil, iconId: "settings.privacy", sfSymbol: "hand.raised", statusKey: nil, visibility: "always", platforms: nil, featureId: "settings.display"),
    ]),
    RegistrySettingsGroup(id: "about_root", header: nil, mobilePresentation: "inline", items: [
      RegistrySettingsItem(kind: "pageLink", key: nil, page: "about", surface: nil, label: RegistryL10n.t("About"), detail: nil, iconId: "settings.about", sfSymbol: "info.circle", statusKey: nil, visibility: "always", platforms: nil, featureId: "settings.display"),
    ]),
  ]

  static let pages: [RegistrySettingsPage] = [
    RegistrySettingsPage(id: "account", title: RegistryL10n.t("Account"), iconId: "settings.account", sfSymbol: "person.crop.circle", depth: 1, platforms: nil, featureId: "sync.backend", sections: [
      RegistrySettingsSection(id: "profile", header: nil, footer: RegistryL10n.t("Your name stays on this device, and syncs when you sign in."), platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "account_profile_editor", label: RegistryL10n.t("Your name"), detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: nil, featureId: "sync.backend"),
      ]),
      RegistrySettingsSection(id: "plan", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "pageLink", key: nil, page: "plus", surface: nil, label: RegistryL10n.t("Septena Plus"), detail: nil, iconId: "settings.plus", sfSymbol: "plus.circle.fill", statusKey: "planStatus", visibility: "always", platforms: nil, featureId: "sync.backend"),
      ]),
      RegistrySettingsSection(id: "devices_access", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "pageLink", key: nil, page: "devices_access", surface: nil, label: RegistryL10n.t("Devices"), detail: nil, iconId: "settings.devices", sfSymbol: "laptopcomputer.and.iphone", statusKey: nil, visibility: "always", platforms: nil, featureId: "sync.backend"),
      ]),
      RegistrySettingsSection(id: "sign_in_methods", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "sign_in_methods", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "signedIn", platforms: nil, featureId: "sync.backend"),
      ]),
      RegistrySettingsSection(id: "sync", header: RegistryL10n.t("Sync"), footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "sync_account_status", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: nil, featureId: "sync.backend"),
      ]),
      RegistrySettingsSection(id: "delete_account", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "delete_account", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "signedIn", platforms: nil, featureId: "account.delete"),
      ]),
    ]),
    RegistrySettingsPage(id: "plus", title: RegistryL10n.t("Septena Plus"), iconId: "settings.plus", sfSymbol: "plus.circle.fill", depth: 2, platforms: nil, featureId: "sync.backend", sections: [
      RegistrySettingsSection(id: "offer", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "plus_offer", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: nil, featureId: "sync.backend"),
      ]),
    ]),
    RegistrySettingsPage(id: "devices_access", title: RegistryL10n.t("Devices"), iconId: "settings.devices", sfSymbol: "laptopcomputer.and.iphone", depth: 2, platforms: nil, featureId: "sync.backend", sections: [
      RegistrySettingsSection(id: "devices", header: RegistryL10n.t("Devices"), footer: RegistryL10n.t("Each app you signed in to. A device you sign out stops syncing within the hour."), platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "access_devices", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: nil, featureId: "sync.backend"),
      ]),
      RegistrySettingsSection(id: "sign_in_approval", header: RegistryL10n.t("Add a device"), footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "sign_in_approval", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "signedIn", platforms: nil, featureId: "sync.backend"),
      ]),
      RegistrySettingsSection(id: "watch", header: nil, footer: nil, platforms: ["ios"], items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "apple_watch", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: ["ios"], featureId: "sync.backend"),
      ]),
    ]),
    RegistrySettingsPage(id: "general", title: RegistryL10n.t("General"), iconId: "settings.general", sfSymbol: "slider.horizontal.3", depth: 1, platforms: nil, featureId: "lists.today", sections: [
      RegistrySettingsSection(id: "lists", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "pageLink", key: nil, page: "smart_lists", surface: nil, label: RegistryL10n.t("Lists"), detail: RegistryL10n.t("Choose which lists you see and their order."), iconId: "list.today", sfSymbol: "sun.max.fill", statusKey: nil, visibility: "always", platforms: nil, featureId: "settings.display"),
        RegistrySettingsItem(kind: "setting", key: "todayGroupByList", page: nil, surface: nil, label: RegistryL10n.t("Group Today by list"), detail: RegistryL10n.t("When off, tasks appear in one list with their project or area underneath."), iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: nil, featureId: "lists.today"),
        RegistrySettingsItem(kind: "setting", key: "todayShowCompleted", page: nil, surface: nil, label: RegistryL10n.t("Show completed tasks"), detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: nil, featureId: "lists.today"),
        RegistrySettingsItem(kind: "setting", key: "tasksShowAging", page: nil, surface: nil, label: RegistryL10n.t("Fade inactive tasks"), detail: RegistryL10n.t("Tasks without activity for 14 days fade out and move to Review. This applies on all your devices."), iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: nil, featureId: "task.aging"),
        RegistrySettingsItem(kind: "setting", key: "tasksShowFaded", page: nil, surface: nil, label: RegistryL10n.t("Show faded tasks"), detail: RegistryL10n.t("Show faded tasks in projects and areas."), iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: nil, featureId: "task.aging"),
        RegistrySettingsItem(kind: "setting", key: "tasksFilingSuggestions", page: nil, surface: nil, label: RegistryL10n.t("Suggest where to file"), detail: RegistryL10n.t("Learn where you usually file similar tasks."), iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: nil, featureId: "edit.filing-suggestion"),
        RegistrySettingsItem(kind: "setting", key: "badgeShowOverdue", page: nil, surface: nil, label: RegistryL10n.t("Overdue app icon badge"), detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: ["macos"], featureId: "settings.display"),
        RegistrySettingsItem(kind: "setting", key: "sidebarCounts", page: nil, surface: nil, label: RegistryL10n.t("Show sidebar counts"), detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: ["web"], featureId: "settings.display"),
      ]),
      RegistrySettingsSection(id: "notifications", header: RegistryL10n.t("Notifications"), footer: nil, platforms: ["web"], items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "browser_notifications", label: RegistryL10n.t("Timed reminders"), detail: nil, iconId: "settings.notifications", sfSymbol: "bell", statusKey: nil, visibility: "always", platforms: ["web"], featureId: "task.alerts"),
      ]),
      RegistrySettingsSection(id: "language", header: RegistryL10n.t("Language"), footer: nil, platforms: ["web"], items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "web_language", label: RegistryL10n.t("Language"), detail: nil, iconId: "settings.language", sfSymbol: "globe", statusKey: nil, visibility: "always", platforms: ["web"], featureId: "settings.display"),
      ]),
      RegistrySettingsSection(id: "ai", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "pageLink", key: nil, page: "ai_preferences", surface: nil, label: RegistryL10n.t("AI on this device"), detail: nil, iconId: "settings.ai_agents", sfSymbol: "cpu", statusKey: "aiMode", visibility: "always", platforms: nil, featureId: "ai.reach-dial"),
      ]),
    ]),
    RegistrySettingsPage(id: "smart_lists", title: RegistryL10n.t("Lists"), iconId: "list.today", sfSymbol: "sun.max.fill", depth: 2, platforms: nil, featureId: "settings.display", sections: [
      RegistrySettingsSection(id: "smart_lists", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "smart_lists_editor", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: nil, featureId: "settings.display"),
      ]),
    ]),
    RegistrySettingsPage(id: "ai_preferences", title: RegistryL10n.t("AI on this device"), iconId: "settings.ai_agents", sfSymbol: "cpu", depth: 2, platforms: nil, featureId: "ai.reach-dial", sections: [
      RegistrySettingsSection(id: "on_device", header: nil, footer: nil, platforms: ["ios", "ipados", "macos"], items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "apple_intelligence_status", label: RegistryL10n.t("Apple Intelligence"), detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: ["ios", "ipados", "macos"], featureId: "ai.reach-dial"),
      ]),
      RegistrySettingsSection(id: "reach", header: RegistryL10n.t("Where AI runs"), footer: RegistryL10n.t("Septena never runs AI on your data and never reads it. The intelligence is your own (Apple on-device, Private Cloud Compute, or your Claude). This only sets where requests may run."), platforms: nil, items: [
        RegistrySettingsItem(kind: "setting", key: "aiMode", page: nil, surface: nil, label: RegistryL10n.t("AI Mode"), detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: nil, featureId: "ai.reach-dial"),
      ]),
      RegistrySettingsSection(id: "explainer", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "ai_explainer", label: RegistryL10n.t("How AI helps with your tasks"), detail: nil, iconId: "settings.about", sfSymbol: "info.circle", statusKey: nil, visibility: "always", platforms: nil, featureId: "ai.reach-dial"),
      ]),
    ]),
    RegistrySettingsPage(id: "appearance", title: RegistryL10n.t("Appearance"), iconId: "settings.appearance", sfSymbol: "paintpalette", depth: 1, platforms: nil, featureId: "settings.display", sections: [
      RegistrySettingsSection(id: "appearance", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "accent_color", label: RegistryL10n.t("Accent"), detail: nil, iconId: "settings.appearance", sfSymbol: "paintpalette", statusKey: nil, visibility: "always", platforms: nil, featureId: "appearance.accents"),
        RegistrySettingsItem(kind: "setting", key: "textSizeStep", page: nil, surface: nil, label: RegistryL10n.t("Text Size"), detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: nil, featureId: "appearance.text-size"),
        RegistrySettingsItem(kind: "setting", key: "tasksTitleLines", page: nil, surface: nil, label: RegistryL10n.t("Title lines"), detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: ["ios", "ipados", "android"], featureId: "settings.display"),
        RegistrySettingsItem(kind: "setting", key: "loggingAnimationsEnabled", page: nil, surface: nil, label: RegistryL10n.t("Completion animations"), detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: nil, featureId: "settings.display"),
        RegistrySettingsItem(kind: "setting", key: "inboxZeroMotionEnabled", page: nil, surface: nil, label: RegistryL10n.t("Inbox zero animation"), detail: RegistryL10n.t("Play a short animation when you empty the Inbox."), iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: ["ios", "ipados", "macos"], featureId: "settings.display"),
      ]),
    ]),
    RegistrySettingsPage(id: "agents", title: RegistryL10n.t("Agents"), iconId: "settings.agents", sfSymbol: "person.2", depth: 1, platforms: nil, featureId: "agents.connector", sections: [
      RegistrySettingsSection(id: "pause", header: nil, footer: RegistryL10n.t("While paused, no agent can pick up or work on a task. Stop one task from its conversation instead. Agents never close assigned tasks on their own; finished work lands in Review for you to accept or send back."), platforms: nil, items: [
        RegistrySettingsItem(kind: "setting", key: "agentsPaused", page: nil, surface: nil, label: RegistryL10n.t("Pause all agents"), detail: RegistryL10n.t("While paused, no agent can start or work on a task."), iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "signedIn", platforms: nil, featureId: "agents.stop-pause"),
      ]),
      RegistrySettingsSection(id: "notifications", header: RegistryL10n.t("Notifications"), footer: RegistryL10n.t("Choose when agent comments notify you. You can override this for any connected agent below."), platforms: nil, items: [
        RegistrySettingsItem(kind: "setting", key: "agentCommentNotifications", page: nil, surface: nil, label: RegistryL10n.t("Agent comments"), detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "signedIn", platforms: nil, featureId: "agents.connector"),
      ]),
      RegistrySettingsSection(id: "agents", header: RegistryL10n.t("Connected agents"), footer: RegistryL10n.t("Each agent you connected to your tasks, with the name you gave it. An agent counts while it was used in the last 30 days. Your phones, tablets and computers are under Account, Devices."), platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "access_agents", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: nil, featureId: "agents.connector"),
      ]),
      RegistrySettingsSection(id: "connect", header: RegistryL10n.t("Connect an agent"), footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "claude_connector", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: nil, featureId: "agents.connector"),
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "mcp_skills", label: RegistryL10n.t("MCP Skills"), detail: RegistryL10n.t("The brief that teaches a model how to use your tasks through the connection (tools, conventions, and examples)."), iconId: "settings.skills", sfSymbol: "book.closed", statusKey: nil, visibility: "always", platforms: nil, featureId: "agents.connector"),
      ]),
    ]),
    RegistrySettingsPage(id: "connections", title: RegistryL10n.t("Connections"), iconId: "settings.connections", sfSymbol: "link", depth: 1, platforms: nil, featureId: "calendar.feed", sections: [
      RegistrySettingsSection(id: "connections", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "pageLink", key: nil, page: "calendar", surface: nil, label: RegistryL10n.t("Calendar"), detail: nil, iconId: "settings.calendar", sfSymbol: "calendar", statusKey: "calendarStatus", visibility: "always", platforms: nil, featureId: "calendar.events"),
        RegistrySettingsItem(kind: "pageLink", key: nil, page: "reminders", surface: nil, label: RegistryL10n.t("Reminders"), detail: nil, iconId: "settings.reminders", sfSymbol: "checklist", statusKey: "remindersStatus", visibility: "always", platforms: ["ios", "ipados", "macos"], featureId: "import.reminders"),
        RegistrySettingsItem(kind: "pageLink", key: nil, page: "shortcuts", surface: nil, label: RegistryL10n.t("Siri & Shortcuts"), detail: nil, iconId: "settings.siri_shortcuts", sfSymbol: "square.2.layers.3d", statusKey: nil, visibility: "always", platforms: ["ios", "ipados", "macos"], featureId: "system.shortcuts"),
      ]),
    ]),
    RegistrySettingsPage(id: "calendar", title: RegistryL10n.t("Calendar"), iconId: "settings.calendar", sfSymbol: "calendar", depth: 2, platforms: nil, featureId: "calendar.events", sections: [
      RegistrySettingsSection(id: "calendars", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "calendar_detail", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: nil, featureId: "calendar.events"),
      ]),
    ]),
    RegistrySettingsPage(id: "reminders", title: RegistryL10n.t("Reminders"), iconId: "settings.reminders", sfSymbol: "checklist", depth: 2, platforms: ["ios", "ipados", "macos"], featureId: "import.reminders", sections: [
      RegistrySettingsSection(id: "reminders", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "reminders_inbox", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: ["ios", "ipados", "macos"], featureId: "import.reminders"),
      ]),
    ]),
    RegistrySettingsPage(id: "shortcuts", title: RegistryL10n.t("Siri & Shortcuts"), iconId: "settings.siri_shortcuts", sfSymbol: "square.2.layers.3d", depth: 2, platforms: ["ios", "ipados", "macos"], featureId: "system.shortcuts", sections: [
      RegistrySettingsSection(id: "actions", header: nil, footer: RegistryL10n.t("The Shortcuts app lists every Septena action. Add them to your own shortcuts."), platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "siri_shortcuts", label: RegistryL10n.t("Open Shortcuts"), detail: RegistryL10n.t("Septena works with Siri and the Shortcuts app. Ask Siri to add a task, or build a shortcut that adds, completes or shows your tasks."), iconId: "settings.siri_shortcuts", sfSymbol: "square.2.layers.3d", statusKey: nil, visibility: "always", platforms: ["ios", "ipados", "macos"], featureId: "system.shortcuts"),
      ]),
    ]),
    RegistrySettingsPage(id: "privacy", title: RegistryL10n.t("Privacy & Data"), iconId: "settings.privacy", sfSymbol: "hand.raised", depth: 1, platforms: nil, featureId: "settings.display", sections: [
      RegistrySettingsSection(id: "data_locality", header: RegistryL10n.t("Your data"), footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "privacy_explainer", label: nil, detail: RegistryL10n.t("Your tasks, areas, projects, and conversations stay on this device until you sign in. When signed in, they sync through Septena’s private server at api.septena.app, encrypted at rest (not end-to-end, so connected agents can read them when you choose). AI on your device stays on your device. Connect an agent under Agents."), iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: nil, featureId: "settings.display"),
      ]),
      RegistrySettingsSection(id: "transfer", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "pageLink", key: nil, page: "import_export", surface: nil, label: RegistryL10n.t("Import & Export"), detail: nil, iconId: "settings.data", sfSymbol: "square.and.arrow.up", statusKey: nil, visibility: "always", platforms: nil, featureId: "sync.backend"),
      ]),
    ]),
    RegistrySettingsPage(id: "import_export", title: RegistryL10n.t("Import & Export"), iconId: "settings.data", sfSymbol: "square.and.arrow.up", depth: 2, platforms: nil, featureId: "sync.backend", sections: [
      RegistrySettingsSection(id: "move_in", header: RegistryL10n.t("Move from another app"), footer: RegistryL10n.t("You can undo an import."), platforms: ["ios", "ipados", "macos"], items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "import_sources", label: RegistryL10n.t("Move from another app"), detail: nil, iconId: "settings.import", sfSymbol: "square.and.arrow.down", statusKey: nil, visibility: "always", platforms: ["ios", "ipados", "macos"], featureId: "import.things"),
      ]),
      RegistrySettingsSection(id: "transfer", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "import_export", label: nil, detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: nil, featureId: "sync.backend"),
      ]),
    ]),
    RegistrySettingsPage(id: "about", title: RegistryL10n.t("About"), iconId: "settings.about", sfSymbol: "info.circle", depth: 1, platforms: nil, featureId: "settings.display", sections: [
      RegistrySettingsSection(id: "version", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "about_header", label: RegistryL10n.t("Tasks that think with you"), detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: nil, featureId: "settings.display"),
      ]),
      RegistrySettingsSection(id: "actions", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "open_help", label: RegistryL10n.t("Help"), detail: nil, iconId: "settings.help", sfSymbol: "questionmark.circle", statusKey: nil, visibility: "always", platforms: nil, featureId: "settings.display"),
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "contact_support", label: RegistryL10n.t("Contact Support"), detail: nil, iconId: "settings.feedback", sfSymbol: "paperplane", statusKey: nil, visibility: "always", platforms: nil, featureId: "support.contact"),
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "keyboard_shortcuts", label: RegistryL10n.t("Keyboard Shortcuts"), detail: nil, iconId: "settings.shortcuts", sfSymbol: "keyboard", statusKey: nil, visibility: "always", platforms: ["web"], featureId: "mac.keyboard"),
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "check_updates", label: RegistryL10n.t("Check for Updates…"), detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: ["macos", "windows", "linux"], featureId: "mac.updates"),
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "reset_get_started", label: RegistryL10n.t("Show Get Started Again"), detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: nil, featureId: "settings.display"),
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "reset_first_run", label: RegistryL10n.t("Show Welcome Again"), detail: nil, iconId: nil, sfSymbol: nil, statusKey: nil, visibility: "always", platforms: nil, featureId: "onboarding.first-run"),
      ]),
      RegistrySettingsSection(id: "open_source", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "open_source", label: RegistryL10n.t("Open source"), detail: RegistryL10n.t("MIT License"), iconId: "settings.open_source", sfSymbol: "chevron.left.forwardslash.chevron.right", statusKey: nil, visibility: "always", platforms: nil, featureId: "settings.display"),
      ]),
      RegistrySettingsSection(id: "advanced_link", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "pageLink", key: nil, page: "advanced", surface: nil, label: RegistryL10n.t("Advanced"), detail: nil, iconId: "settings.advanced", sfSymbol: "wrench.and.screwdriver", statusKey: nil, visibility: "always", platforms: nil, featureId: "settings.display"),
      ]),
    ]),
    RegistrySettingsPage(id: "advanced", title: RegistryL10n.t("Advanced"), iconId: "settings.advanced", sfSymbol: "wrench.and.screwdriver", depth: 2, platforms: nil, featureId: "settings.display", sections: [
      RegistrySettingsSection(id: "diagnostics", header: nil, footer: nil, platforms: nil, items: [
        RegistrySettingsItem(kind: "customSurface", key: nil, page: nil, surface: "sync_diagnostics", label: RegistryL10n.t("Sync & storage diagnostics"), detail: RegistryL10n.t("Changes the server refused appear here, newest first. The server kept its own version of each."), iconId: "settings.diagnostics", sfSymbol: "stethoscope", statusKey: nil, visibility: "always", platforms: nil, featureId: "sync.backend"),
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
  /// Plain copy of a settings surface (`copy` in settings.json); the copy id when the registry has none.
  static func copy(_ surface: String, _ id: String) -> String { copyTable[surface + "." + id] ?? id }
  private static let copyTable: [String: String] = [
    "delete_account.button": RegistryL10n.t("Delete account"),
    "delete_account.footer": RegistryL10n.t("Deletes your account and all your tasks on the Septena server."),
    "delete_account.title": RegistryL10n.t("Delete your account?"),
    "delete_account.intro": RegistryL10n.t("This deletes the following from the Septena server:"),
    "delete_account.tasks": RegistryL10n.t("Your tasks, areas and projects"),
    "delete_account.attachments": RegistryL10n.t("Your attachments"),
    "delete_account.conversations": RegistryL10n.t("Your task conversations"),
    "delete_account.settings": RegistryL10n.t("Your synced settings"),
    "delete_account.consequence": RegistryL10n.t("It also removes your tasks from this device and signs you out. You can’t undo this."),
    "delete_account.failed": RegistryL10n.t("Couldn’t delete your account. Nothing was deleted."),
    "account_profile_card.yourProfile": RegistryL10n.t("Your Profile"),
    "account_profile_card.signInToSync": RegistryL10n.t("On this device · Sign in to sync"),
    "sync_account_status.accountIdLabel": RegistryL10n.t("Account ID"),
    "sync_account_status.accountIdFooter": RegistryL10n.t("Share this ID with support if you need help with your account."),
    "sync_account_status.copy": RegistryL10n.t("Copy"),
    "sync_account_status.copied": RegistryL10n.t("Copied"),
    "syncStatus.syncing": RegistryL10n.t("Syncing"),
    "syncStatus.synced": RegistryL10n.t("Synced"),
    "syncStatus.offline": RegistryL10n.t("Offline"),
    "syncStatus.needsSignIn": RegistryL10n.t("Sign in"),
    "access_devices.currentDevice": RegistryL10n.t("Current device"),
    "access_devices.signOutMessage": RegistryL10n.t("That device stops syncing within the hour. Its tasks stay on it until you sign in there again."),
    "access_devices.deviceApplePhone": RegistryL10n.t("iPhone or iPad"),
    "access_devices.deviceMac": RegistryL10n.t("Mac"),
    "access_devices.deviceWatch": RegistryL10n.t("Apple Watch"),
    "access_devices.deviceAndroid": RegistryL10n.t("Android"),
    "access_devices.deviceBrowser": RegistryL10n.t("Browser"),
    "access_devices.deviceUnknown": RegistryL10n.t("Unknown device"),
    "access_agents.paused": RegistryL10n.t("Paused"),
    "access_agents.notificationsLabel": RegistryL10n.t("Notifications"),
    "access_agents.notificationsDefault": RegistryL10n.t("Use default"),
    "ai_explainer.title": RegistryL10n.t("How AI helps"),
    "ai_explainer.intro": RegistryL10n.t("Some tasks need thinking before you can act. Tap Discuss and talk them through, right on the task."),
    "ai_explainer.flowHeader": RegistryL10n.t("How a task conversation moves"),
    "ai_explainer.captureTitle": RegistryL10n.t("Capture"),
    "ai_explainer.captureDetail": RegistryL10n.t("Jot down the task. A few words are enough."),
    "ai_explainer.confirmTitle": RegistryL10n.t("Confirm"),
    "ai_explainer.confirmDetail": RegistryL10n.t("AI asks what you mean. Nothing happens until you answer."),
    "ai_explainer.lookUpTitle": RegistryL10n.t("Look up"),
    "ai_explainer.lookUpDetail": RegistryL10n.t("Pulls relevant context from your own data."),
    "ai_explainer.decideTitle": RegistryL10n.t("Decide"),
    "ai_explainer.decideDetail": RegistryL10n.t("Offers a few options for you to pick. A harder call may use the cloud."),
    "ai_explainer.workTitle": RegistryL10n.t("Work"),
    "ai_explainer.workDetail": RegistryL10n.t("Does what it can: a draft, a comparison. Uses the web or your Claude only when needed."),
    "ai_explainer.handOffTitle": RegistryL10n.t("Hand off"),
    "ai_explainer.handOffDetail": RegistryL10n.t("Anything only you can do (pay, send) becomes one clear button."),
    "ai_explainer.runsOnDevice": RegistryL10n.t("On-device"),
    "ai_explainer.runsReaches": RegistryL10n.t("On-device ↗"),
    "ai_explainer.flowFooter": RegistryL10n.t("On Automatic, every step runs on your device first. It reaches further only for steps your device can’t do (↗)."),
    "ai_explainer.turnHeader": RegistryL10n.t("Whose turn?"),
    "ai_explainer.turnYours": RegistryL10n.t("Your turn: a question is waiting"),
    "ai_explainer.turnAI": RegistryL10n.t("AI’s turn: it’s working"),
    "ai_explainer.turnDone": RegistryL10n.t("Done"),
    "ai_explainer.localHeader": RegistryL10n.t("Some help is always on your device"),
    "ai_explainer.privateHeader": RegistryL10n.t("Your AI, never our servers"),
    "ai_explainer.closing": RegistryL10n.t("Nothing important happens on its own. AI can fill in small, reversible details; any real decision or action that can’t be undone waits for your confirmation."),
    "mcp_skills.copySkill": RegistryL10n.t("Copy Skill"),
    "mcp_skills.copyFooter": RegistryL10n.t("Paste into a model's context to teach it the task tools without connecting MCP."),
    "mcp_skills.loadFailed": RegistryL10n.t("The brief did not load. Check your connection and open this page again."),
    "sign_in_approval.title": RegistryL10n.t("Approve a device sign-in"),
    "sign_in_approval.footer": RegistryL10n.t("To sign in on a new phone, tablet or computer, tap Get a sign-in code on it. Then scan or enter that code here."),
    "sign_in_approval.codePlaceholder": RegistryL10n.t("ABCD-EFGH"),
    "sign_in_approval.enterFooter": RegistryL10n.t("Enter the 8-character code shown on the new device."),
    "sign_in_approval.continue": RegistryL10n.t("Continue"),
    "sign_in_approval.checking": RegistryL10n.t("Checking the code…"),
    "sign_in_approval.safetyFooter": RegistryL10n.t("Only approve a code you started yourself. Septena never asks for a code by email, text or phone call."),
    "sign_in_approval.approve": RegistryL10n.t("Approve"),
    "sign_in_approval.dontApprove": RegistryL10n.t("Don't approve"),
    "sign_in_approval.approving": RegistryL10n.t("Approving…"),
    "sign_in_approval.tryAnother": RegistryL10n.t("Try another code"),
    "sign_in_approval.done": RegistryL10n.t("Done"),
    "sign_in_approval.invalidCode": RegistryL10n.t("That code is wrong or has expired."),
    "sign_in_approval.codeUsed": RegistryL10n.t("That code was already used."),
    "sign_in_approval.tooManyAttempts": RegistryL10n.t("Too many wrong codes. Try again in 10 minutes."),
    "sign_in_approval.doneConnector": RegistryL10n.t("Agent connected. Go back to your browser to finish."),
    "claude_connector.signInHeader": RegistryL10n.t("Sign in to connect an agent"),
    "claude_connector.signInBody": RegistryL10n.t("Sign in so your agent can connect to your tasks through your private Septena account."),
    "claude_connector.setupPrompt": RegistryL10n.t("Setup prompt"),
    "claude_connector.setupPromptDetail": RegistryL10n.t("Paste into your agent to connect your account"),
    "claude_connector.firstPrompt": RegistryL10n.t("Starter prompt"),
    "claude_connector.firstPromptDetail": RegistryL10n.t("Set up your areas, projects, and tasks"),
    "claude_connector.connectorUrl": RegistryL10n.t("MCP server URL"),
    "claude_connector.connectorUrlDetail": RegistryL10n.t("Add as a custom MCP server in any MCP client"),
    "claude_connector.approveHeader": RegistryL10n.t("Approve connection code"),
    "claude_connector.haveCode": RegistryL10n.t("Have a connection code?"),
    "claude_connector.codeHint": RegistryL10n.t("If your browser showed an 8-character code, enter it here. Only enter a code from a window you opened yourself."),
    "claude_connector.copy": RegistryL10n.t("Copy"),
    "claude_connector.copied": RegistryL10n.t("Copied"),
    "claude_connector.codePlaceholder": RegistryL10n.t("ABCD-EFGH"),
    "claude_connector.footer": RegistryL10n.t("Add the MCP server URL to any MCP client, or paste the setup prompt into your agent. When your browser shows an 8-character code, enter it above. Only enter a code from a window you opened yourself."),
    "aiMode.onDeviceOnlyNoModel": RegistryL10n.t("Discuss never leaves this device. Septena has no on-device model here, so Discuss is off."),
    "aiMode.autoNoModel": RegistryL10n.t("Septena has no on-device model here, so Discuss hands the task to your own Claude. Recommended."),
    "smart_lists_editor.topHeader": RegistryL10n.t("Above Areas & Projects"),
    "smart_lists_editor.topFooter": RegistryL10n.t("Working lists shown at the top of the sidebar."),
    "smart_lists_editor.bottomHeader": RegistryL10n.t("Below Areas & Projects"),
    "smart_lists_editor.bottomFooter": RegistryL10n.t("Archive and utility lists shown below your areas and projects. Drag to reorder within a section, or use the arrow button to move a list above or below. Changes sync across all your devices."),
    "smart_lists_editor.bottomFooterButtons": RegistryL10n.t("Archive and utility lists shown below your areas and projects. Use the arrows to reorder a list or to move it above or below. Changes sync across all your devices."),
    "smart_lists_editor.reset": RegistryL10n.t("Reset to Defaults"),
    "smart_lists_editor.empty": RegistryL10n.t("No smart lists in this section"),
    "smart_lists_editor.alwaysShown": RegistryL10n.t("Always shown"),
    "smart_lists_editor.whenNonEmpty": RegistryL10n.t("Shown when non-empty"),
    "smart_lists_editor.moveBelow": RegistryL10n.t("Move below Areas & Projects"),
    "smart_lists_editor.moveAbove": RegistryL10n.t("Move above Areas & Projects"),
    "smart_lists_editor.moveUp": RegistryL10n.t("Move up"),
    "smart_lists_editor.moveDown": RegistryL10n.t("Move down"),
    "sync_diagnostics.issues": RegistryL10n.t("Sync issues"),
    "sync_diagnostics.clear": RegistryL10n.t("Clear sync issues"),
    "calendar_detail.deviceHeader": RegistryL10n.t("Device calendars"),
    "calendar_detail.deviceToggle": RegistryL10n.t("Show calendar events"),
    "calendar_detail.deviceToggleDetail": RegistryL10n.t("Read-only agenda in Today and Upcoming"),
    "calendar_detail.devicePermissionAction": RegistryL10n.t("Allow calendar access"),
    "calendar_detail.feedHeader": RegistryL10n.t("Calendar Feed (iCal)"),
    "calendar_detail.feedSignIn": RegistryL10n.t("Sign in to Septena sync to create a private calendar feed URL for Apple Calendar, Google Calendar, or Outlook."),
    "calendar_detail.feedToggle": RegistryL10n.t("Private iCal feed"),
    "calendar_detail.include": RegistryL10n.t("Include"),
    "calendar_detail.scopeAll": RegistryL10n.t("All dated tasks"),
    "calendar_detail.scopeTimed": RegistryL10n.t("Timed tasks only"),
    "calendar_detail.copyUrl": RegistryL10n.t("Copy URL"),
    "calendar_detail.openInCalendar": RegistryL10n.t("Open in Calendar"),
    "calendar_detail.rotate": RegistryL10n.t("Rotate Link"),
    "calendar_detail.rotateTitle": RegistryL10n.t("Rotate Calendar Feed Link?"),
    "calendar_detail.rotateMessage": RegistryL10n.t("Rotating replaces your private feed link immediately. Existing calendar subscriptions will stop updating until you re-subscribe with the new URL."),
    "calendar_detail.feedFooter": RegistryL10n.t("Read-only subscription feed for your scheduled tasks and deadlines. Anyone with the private URL can read titles and notes in the feed; rotate or disable it anytime."),
    "import_export.exportJsonTitle": RegistryL10n.t("Export JSON backup"),
    "import_export.exportJsonDetail": RegistryL10n.t("Full Septena tasks, areas, projects, and checklists (importable)"),
    "import_export.exportMarkdownTitle": RegistryL10n.t("Export Markdown"),
    "import_export.exportMarkdownDetail": RegistryL10n.t("Readable checklist grouped by area and project"),
    "import_export.exportCsvTitle": RegistryL10n.t("Export CSV"),
    "import_export.exportCsvDetail": RegistryL10n.t("Spreadsheet-friendly table of tasks"),
    "import_export.importJsonTitle": RegistryL10n.t("Import JSON backup…"),
    "import_export.importJsonDetail": RegistryL10n.t("Preview and import a Septena JSON export"),
    "import_export.importDialogTitle": RegistryL10n.t("Import Septena backup"),
    "import_export.importNote": RegistryL10n.t("Existing items with matching IDs are kept; new items are added and synced."),
    "import_export.importConfirm": RegistryL10n.t("Import"),
    "import_export.exportedJson": RegistryL10n.t("Exported JSON backup."),
    "import_export.exportedMarkdown": RegistryL10n.t("Exported Markdown."),
    "import_export.exportedCsv": RegistryL10n.t("Exported CSV."),
    "import_export.exportFailed": RegistryL10n.t("Export failed."),
    "import_export.importFailed": RegistryL10n.t("Import failed."),
  ]
}

/// Canonical smart-list IDs (`registry/destinations.json`).
enum RegistryDestinationID: String, CaseIterable, Hashable, Sendable {
  case inbox = "inbox"
  case today = "today"
  case review = "review"
  case agent = "agent"
  case upcoming = "upcoming"
  case repeating = "repeating"
  case anytime = "anytime"
  case logbook = "logbook"
  case starred = "starred"
  case faded = "faded"
  case recentlyDeleted = "recentlyDeleted"
}

/// Canonical smart-list metadata (`registry/destinations.json`).
struct RegistryDestination: Sendable, Hashable, Identifiable {
  let id: RegistryDestinationID
  let navigationKey: String
  let serverView: String
  let title: String
  let iconId: String
  let sfSymbol: String
  let sidebarSection: String
  let visibility: String
  let canHide: Bool
  let canMoveSection: Bool
  /// The list keeps a manual order and takes a Sort By (docs/LIST_SORT_SPEC.md).
  let supportsManualOrder: Bool
  /// Where a Magic Plus tap creates the draft on this list: `here`, `tomorrow`
  /// (here, on tomorrow) or `today` (opens Today first).
  let newTaskTarget: String
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
    RegistryDestination(id: .inbox, navigationKey: "triage", serverView: "triage", title: RegistryL10n.t("Inbox"), iconId: "list.inbox", sfSymbol: "tray.full", sidebarSection: "top", visibility: "todayBand", canHide: false, canMoveSection: false, supportsManualOrder: false, newTaskTarget: "here", emptyTitle: RegistryL10n.t("Inbox is empty"), emptyDetail: RegistryL10n.t("New tasks wait at the top of Today until you schedule or file them."), featureId: "lists.inbox"),
    RegistryDestination(id: .today, navigationKey: "today", serverView: "today", title: RegistryL10n.t("Today"), iconId: "list.today", sfSymbol: "sun.max.fill", sidebarSection: "top", visibility: "always", canHide: false, canMoveSection: false, supportsManualOrder: true, newTaskTarget: "here", emptyTitle: RegistryL10n.t("Nothing on Today"), emptyDetail: RegistryL10n.t("Today can stay empty. Add a task when you want one."), featureId: "lists.today"),
    RegistryDestination(id: .review, navigationKey: "review", serverView: "all", title: RegistryL10n.t("Review"), iconId: "list.review", sfSymbol: "eye", sidebarSection: "top", visibility: "whenNonEmpty", canHide: true, canMoveSection: false, supportsManualOrder: false, newTaskTarget: "today", emptyTitle: RegistryL10n.t("Nothing to review"), emptyDetail: RegistryL10n.t("Your agent's questions, finished work and tasks in progress show up here, and so do tasks you are waiting on. Faded tasks do too."), featureId: "lists.review"),
    RegistryDestination(id: .agent, navigationKey: "agent", serverView: "all", title: RegistryL10n.t("Agent"), iconId: "list.agent", sfSymbol: "person.2.badge.gearshape", sidebarSection: "top", visibility: "reviewGroup", canHide: false, canMoveSection: false, supportsManualOrder: false, newTaskTarget: "today", emptyTitle: RegistryL10n.t("No agent work"), emptyDetail: RegistryL10n.t("Tasks you assign to Claude show up in Review, grouped by where the work stands."), featureId: "lists.agent"),
    RegistryDestination(id: .upcoming, navigationKey: "upcoming", serverView: "upcoming", title: RegistryL10n.t("Upcoming"), iconId: "list.upcoming", sfSymbol: "calendar", sidebarSection: "top", visibility: "always", canHide: true, canMoveSection: false, supportsManualOrder: false, newTaskTarget: "tomorrow", emptyTitle: RegistryL10n.t("Nothing upcoming"), emptyDetail: RegistryL10n.t("Tasks with a future When or Deadline date appear here."), featureId: "lists.upcoming"),
    RegistryDestination(id: .repeating, navigationKey: "repeating", serverView: "all", title: RegistryL10n.t("Repeating"), iconId: "list.repeating", sfSymbol: "arrow.clockwise", sidebarSection: "top", visibility: "always", canHide: true, canMoveSection: false, supportsManualOrder: false, newTaskTarget: "today", emptyTitle: RegistryL10n.t("No repeating tasks"), emptyDetail: RegistryL10n.t("Give any task a Repeat rule and it will show up here."), featureId: "lists.repeating"),
    RegistryDestination(id: .anytime, navigationKey: "unscheduled", serverView: "unscheduled", title: RegistryL10n.t("Anytime"), iconId: "list.anytime", sfSymbol: "rectangle.stack.fill", sidebarSection: "top", visibility: "always", canHide: true, canMoveSection: false, supportsManualOrder: true, newTaskTarget: "here", emptyTitle: RegistryL10n.t("Nothing in Anytime"), emptyDetail: RegistryL10n.t("Open tasks without a date live here."), featureId: "lists.anytime"),
    RegistryDestination(id: .logbook, navigationKey: "logbook", serverView: "logbook", title: RegistryL10n.t("Logbook"), iconId: "list.logbook", sfSymbol: "checkmark", sidebarSection: "bottom", visibility: "always", canHide: true, canMoveSection: false, supportsManualOrder: false, newTaskTarget: "today", emptyTitle: RegistryL10n.t("Logbook is empty"), emptyDetail: RegistryL10n.t("Tasks you complete or let go end up here."), featureId: "lists.logbook"),
    RegistryDestination(id: .starred, navigationKey: "starred", serverView: "all", title: RegistryL10n.t("Starred"), iconId: "list.starred", sfSymbol: "star.fill", sidebarSection: "top", visibility: "whenNonEmpty", canHide: true, canMoveSection: false, supportsManualOrder: false, newTaskTarget: "today", emptyTitle: RegistryL10n.t("No starred tasks"), emptyDetail: RegistryL10n.t("Star tasks to keep them one tap away."), featureId: "lists.starred"),
    RegistryDestination(id: .faded, navigationKey: "faded", serverView: "all", title: RegistryL10n.t("Faded"), iconId: "list.faded", sfSymbol: "circle.dashed", sidebarSection: "top", visibility: "reviewGroup", canHide: false, canMoveSection: false, supportsManualOrder: false, newTaskTarget: "today", emptyTitle: RegistryL10n.t("No Faded Tasks"), emptyDetail: RegistryL10n.t("Tasks without activity for 14 days appear here until you keep them or let them go."), featureId: "lists.faded"),
    RegistryDestination(id: .recentlyDeleted, navigationKey: "recentlyDeleted", serverView: "all", title: RegistryL10n.t("Deleted"), iconId: "list.recently_deleted", sfSymbol: "trash", sidebarSection: "top", visibility: "logbookTab", canHide: false, canMoveSection: false, supportsManualOrder: false, newTaskTarget: "today", emptyTitle: RegistryL10n.t("No Deleted Tasks"), emptyDetail: RegistryL10n.t("Septena keeps deleted tasks here for 30 days, then deletes them for good."), featureId: "lists.recently-deleted"),
  ]

  static let byId: [RegistryDestinationID: RegistryDestination] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
  static let byNavigationKey: [String: RegistryDestination] = Dictionary(uniqueKeysWithValues: all.map { ($0.navigationKey, $0) })

  /// Digit shortcuts in order (`digitShortcuts` in destinations.json): the first
  /// enabled list in the sidebar takes the first one.
  static let digitShortcuts: [RegistryShortcut] = [
    RegistryShortcut(key: "1", modifiers: ["primary"], keycaps: ["⌘", "1"], excludePlatforms: []),
    RegistryShortcut(key: "2", modifiers: ["primary"], keycaps: ["⌘", "2"], excludePlatforms: []),
    RegistryShortcut(key: "3", modifiers: ["primary"], keycaps: ["⌘", "3"], excludePlatforms: []),
    RegistryShortcut(key: "4", modifiers: ["primary"], keycaps: ["⌘", "4"], excludePlatforms: []),
    RegistryShortcut(key: "5", modifiers: ["primary"], keycaps: ["⌘", "5"], excludePlatforms: []),
    RegistryShortcut(key: "6", modifiers: ["primary"], keycaps: ["⌘", "6"], excludePlatforms: []),
    RegistryShortcut(key: "7", modifiers: ["primary"], keycaps: ["⌘", "7"], excludePlatforms: []),
    RegistryShortcut(key: "8", modifiers: ["primary"], keycaps: ["⌘", "8"], excludePlatforms: []),
    RegistryShortcut(key: "9", modifiers: ["primary"], keycaps: ["⌘", "9"], excludePlatforms: []),
  ]
  /// Only lists with this `visibility` take a digit.
  static let digitShortcutVisibility: String = "always"

  /// Ordered row groups per destination id (`groups` in destinations.json).
  static let groups: [RegistryDestinationID: [RegistryDestinationGroup]] = [
    .review: [
      RegistryDestinationGroup(id: "questions", title: RegistryL10n.t("Questions"), iconId: "agent.your_turn", sfSymbol: "questionmark.bubble"),
      RegistryDestinationGroup(id: "finished", title: RegistryL10n.t("Finished work"), iconId: "list.review", sfSymbol: "eye"),
      RegistryDestinationGroup(id: "waiting", title: RegistryL10n.t("Waiting"), iconId: "list.waiting", sfSymbol: "hourglass"),
      RegistryDestinationGroup(id: "working", title: RegistryL10n.t("Working"), iconId: "agent.working", sfSymbol: "ellipsis.circle"),
      RegistryDestinationGroup(id: "queued", title: RegistryL10n.t("Queued"), iconId: "agent.queued", sfSymbol: "clock"),
      RegistryDestinationGroup(id: "stopped", title: RegistryL10n.t("Stopped"), iconId: "agent.stopped", sfSymbol: "stop.circle"),
      RegistryDestinationGroup(id: "faded", title: RegistryL10n.t("Faded"), iconId: "list.faded", sfSymbol: "circle.dashed"),
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

/// Canonical action IDs (`registry/actions.json` `actions`).
enum RegistryActionID: String, CaseIterable, Hashable, Sendable {
  case taskEditDetails = "task.editDetails"
  case taskOpen = "task.open"
  case taskShare = "task.share"
  case taskAcceptReview = "task.acceptReview"
  case taskSendBackReview = "task.sendBackReview"
  case taskToggleInfo = "task.toggleInfo"
  case taskCopy = "task.copy"
  case taskSelect = "task.select"
  case taskSelectAll = "task.selectAll"
  case taskDuplicate = "task.duplicate"
  case taskDo = "task.do"
  case doDone = "do.done"
  case doStop = "do.stop"
  case doLater = "do.later"
  case doHere = "do.here"
  case doShowList = "do.showList"
  case doConfirm = "do.confirm"
  case doAddAndDo = "do.addAndDo"
  case taskToggleComplete = "task.toggleComplete"
  case taskCancel = "task.cancel"
  case taskToggleToday = "task.toggleToday"
  case taskToggleStar = "task.toggleStar"
  case taskTags = "task.tags"
  case taskAddChecklistItem = "task.addChecklistItem"
  case taskAddReference = "task.addReference"
  case taskReferenceOpen = "task.reference.open"
  case taskReferenceCopyLink = "task.reference.copyLink"
  case taskReferenceRemove = "task.reference.remove"
  case taskDetailSave = "task.detail.save"
  case taskToggleChecklistItem = "task.toggleChecklistItem"
  case taskDeleteChecklistItem = "task.deleteChecklistItem"
  case taskWhen = "task.when"
  case taskWaitingOn = "task.waitingOn"
  case taskGotItBack = "task.gotItBack"
  case taskDeadline = "task.deadline"
  case taskReminder = "task.reminder"
  case taskMove = "task.move"
  case taskMoveSuggested = "task.moveSuggested"
  case taskClearSchedule = "task.clearSchedule"
  case taskRepeat = "task.repeat"
  case taskPauseResumeRepeat = "task.pauseResumeRepeat"
  case taskCreateNextCopy = "task.createNextCopy"
  case taskDelete = "task.delete"
  case taskRestore = "task.restore"
  case taskDeletePermanently = "task.deletePermanently"
  case taskEmptyTrash = "task.emptyTrash"
  case taskKeepFaded = "task.keepFaded"
  case taskLetGoFaded = "task.letGoFaded"
  case placeSaveNotes = "place.saveNotes"
  case areaNewProject = "area.newProject"
  case areaRename = "area.rename"
  case areaChangeEmoji = "area.changeEmoji"
  case areaMoveUp = "area.moveUp"
  case areaMoveDown = "area.moveDown"
  case areaDelete = "area.delete"
  case projectRename = "project.rename"
  case projectMoveUp = "project.moveUp"
  case projectMoveDown = "project.moveDown"
  case projectMove = "project.move"
  case projectUseAsChecklist = "project.useAsChecklist"
  case projectMarkDone = "project.markDone"
  case projectCancel = "project.cancel"
  case projectDelete = "project.delete"
  case projectShare = "project.share"
  case loggedClear = "logged.clear"
  case sidebarNewArea = "sidebar.newArea"
  case sidebarJoinShared = "sidebar.joinShared"
  case sidebarNewProject = "sidebar.newProject"
  case sectionNew = "section.new"
  case sectionNewTask = "section.newTask"
  case sectionRename = "section.rename"
  case sectionDelete = "section.delete"
  case noticeOpenStep = "notice.openStep"
  case noticeToggleStep = "notice.toggleStep"
  case noticeHideGetStarted = "notice.hideGetStarted"
  case appNewTask = "app.newTask"
  case appQuickAdd = "app.quickAdd"
  case appShareCaptureAdd = "app.shareCapture.add"
  case appQuickEntry = "app.quickEntry"
  case appQuickFind = "app.quickFind"
  case appGoBack = "app.goBack"
  case appGoForward = "app.goForward"
  case appPauseAgents = "app.pauseAgents"
  case taskConversationStop = "task.conversation.stop"
  case taskConversationOther = "task.conversation.other"
  case taskConversationSend = "task.conversation.send"
  case taskConversationReply = "task.conversation.reply"
  case appToggleSidebar = "app.toggleSidebar"
  case appSettings = "app.settings"
  case appUndo = "app.undo"
  case accountSignOut = "account.signOut"
  case settingsSave = "settings.save"
  case appHelp = "app.help"
  case appContactSupport = "app.contactSupport"
  case appKeyboardShortcuts = "app.keyboardShortcuts"
  case appToggleSidebarCounts = "app.toggleSidebarCounts"
  case appTextSizeIncrease = "app.textSizeIncrease"
  case appTextSizeDecrease = "app.textSizeDecrease"
  case appTextSizeReset = "app.textSizeReset"
  case appSeptenaWindow = "app.septenaWindow"
  case appClassicWindow = "app.classicWindow"
}

/// Canonical context-menu IDs (`registry/actions.json` `contextMenus`).
enum RegistryContextMenuID: String, CaseIterable, Hashable, Sendable {
  case taskRow = "task.row"
  case taskReference = "task.reference"
  case taskRecentlyDeleted = "task.recentlyDeleted"
  case taskFaded = "task.faded"
  case sidebarArea = "sidebar.area"
  case sidebarProject = "sidebar.project"
  case sidebarEmpty = "sidebar.empty"
  case projectHeading = "project.heading"
  case projectBlankSpace = "project.blankSpace"
  case scopeLoggedFooter = "scope.loggedFooter"
  case noticeGetStartedStep = "notice.getStartedStep"
}

/// Canonical menu-bar menu IDs (`registry/actions.json` `menuBar`).
enum RegistryMenuBarID: String, CaseIterable, Hashable, Sendable {
  case app = "app"
  case file = "file"
  case view = "view"
  case go = "go"
  case task = "task"
  case help = "help"
}

/// Generated shortcut-sheet entry (`registry/actions.json`).
struct RegistryShortcutEntry: Sendable, Hashable, Identifiable {
  let id: String
  let actionId: RegistryActionID
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
  let excludeDestinations: [RegistryDestinationID]
  let onlyDestinations: [RegistryDestinationID]
  let requiresRecurrence: Bool
  /// The action's capability (`featureId`); a menu hides it where it does not ship.
  let featureId: String
}

/// One item in a context menu or menu-bar menu (`registry/actions.json`).
/// `kind` is `action`, `destination`, `submenu`, `divider` or `slot` (the shell fills a slot).
struct RegistryMenuItem: Sendable, Hashable, Identifiable {
  let kind: String
  let id: String
  let actionId: RegistryActionID?
  let title: String?
  let sfSymbol: String?
  let items: [RegistryMenuItem]
}

/// One menu-bar menu. `system` names the platform menu it merges into (app, file, view, help).
struct RegistryMenu: Sendable, Hashable, Identifiable {
  let id: RegistryMenuBarID
  let title: String
  let system: String?
  let items: [RegistryMenuItem]
}

enum RegistryActions {
  static let titles: [RegistryActionID: String] = [
    .taskEditDetails: RegistryL10n.t("Edit Details…"),
    .taskOpen: RegistryL10n.t("Open"),
    .taskShare: RegistryL10n.t("Share…"),
    .taskAcceptReview: RegistryL10n.t("Accept"),
    .taskSendBackReview: RegistryL10n.t("Send Back…"),
    .taskToggleInfo: RegistryL10n.t("Show Info"),
    .taskCopy: RegistryL10n.t("Copy"),
    .taskSelect: RegistryL10n.t("Select"),
    .taskSelectAll: RegistryL10n.t("Select All"),
    .taskDuplicate: RegistryL10n.t("Duplicate"),
    .taskDo: RegistryL10n.t("Do"),
    .doDone: RegistryL10n.t("Done"),
    .doStop: RegistryL10n.t("Stop for Now"),
    .doLater: RegistryL10n.t("Later…"),
    .doHere: RegistryL10n.t("Do Here"),
    .doShowList: RegistryL10n.t("Show List"),
    .doConfirm: RegistryL10n.t("Still on It"),
    .doAddAndDo: RegistryL10n.t("Add and Do"),
    .taskToggleComplete: RegistryL10n.t("Mark as Complete"),
    .taskCancel: RegistryL10n.t("Cancel Task"),
    .taskToggleToday: RegistryL10n.t("Toggle Today"),
    .taskToggleStar: RegistryL10n.t("Toggle Star"),
    .taskTags: RegistryL10n.t("Tags…"),
    .taskAddChecklistItem: RegistryL10n.t("Add Checklist Item"),
    .taskAddReference: RegistryL10n.t("Add Reference…"),
    .taskReferenceOpen: RegistryL10n.t("Open"),
    .taskReferenceCopyLink: RegistryL10n.t("Copy Link"),
    .taskReferenceRemove: RegistryL10n.t("Remove"),
    .taskDetailSave: RegistryL10n.t("Save"),
    .taskToggleChecklistItem: RegistryL10n.t("Toggle Checklist Item"),
    .taskDeleteChecklistItem: RegistryL10n.t("Delete Checklist Item"),
    .taskWhen: RegistryL10n.t("When…"),
    .taskWaitingOn: RegistryL10n.t("Waiting On…"),
    .taskGotItBack: RegistryL10n.t("Got It Back"),
    .taskDeadline: RegistryL10n.t("Deadline…"),
    .taskReminder: RegistryL10n.t("Reminder…"),
    .taskMove: RegistryL10n.t("Move…"),
    .taskMoveSuggested: RegistryL10n.t("Move to Suggested List"),
    .taskClearSchedule: RegistryL10n.t("Clear When"),
    .taskRepeat: RegistryL10n.t("Repeat…"),
    .taskPauseResumeRepeat: RegistryL10n.t("Pause Repeat"),
    .taskCreateNextCopy: RegistryL10n.t("Create Next Copy"),
    .taskDelete: RegistryL10n.t("Delete"),
    .taskRestore: RegistryL10n.t("Restore"),
    .taskDeletePermanently: RegistryL10n.t("Delete Permanently"),
    .taskEmptyTrash: RegistryL10n.t("Empty Trash"),
    .taskKeepFaded: RegistryL10n.t("Keep"),
    .taskLetGoFaded: RegistryL10n.t("Let Go"),
    .placeSaveNotes: RegistryL10n.t("Save Notes"),
    .areaNewProject: RegistryL10n.t("New Project in Area"),
    .areaRename: RegistryL10n.t("Rename"),
    .areaChangeEmoji: RegistryL10n.t("Change Emoji…"),
    .areaMoveUp: RegistryL10n.t("Move Up"),
    .areaMoveDown: RegistryL10n.t("Move Down"),
    .areaDelete: RegistryL10n.t("Delete Area"),
    .projectRename: RegistryL10n.t("Rename"),
    .projectMoveUp: RegistryL10n.t("Move Up"),
    .projectMoveDown: RegistryL10n.t("Move Down"),
    .projectMove: RegistryL10n.t("Move…"),
    .projectUseAsChecklist: RegistryL10n.t("Use as Checklist"),
    .projectMarkDone: RegistryL10n.t("Mark Done"),
    .projectCancel: RegistryL10n.t("Cancel Project"),
    .projectDelete: RegistryL10n.t("Delete Project"),
    .projectShare: RegistryL10n.t("Share Project…"),
    .loggedClear: RegistryL10n.t("Clear Logged…"),
    .sidebarNewArea: RegistryL10n.t("New Area"),
    .sidebarJoinShared: RegistryL10n.t("Join a Shared Project…"),
    .sidebarNewProject: RegistryL10n.t("New Project"),
    .sectionNew: RegistryL10n.t("New Section"),
    .sectionNewTask: RegistryL10n.t("New Task in Section"),
    .sectionRename: RegistryL10n.t("Rename"),
    .sectionDelete: RegistryL10n.t("Delete Section"),
    .noticeOpenStep: RegistryL10n.t("Open"),
    .noticeToggleStep: RegistryL10n.t("Mark as Done"),
    .noticeHideGetStarted: RegistryL10n.t("Hide Get Started"),
    .appNewTask: RegistryL10n.t("New Task"),
    .appQuickAdd: RegistryL10n.t("Quick Add…"),
    .appShareCaptureAdd: RegistryL10n.t("Add"),
    .appQuickEntry: RegistryL10n.t("Quick Entry"),
    .appQuickFind: RegistryL10n.t("Quick Find…"),
    .appGoBack: RegistryL10n.t("Back"),
    .appGoForward: RegistryL10n.t("Forward"),
    .appPauseAgents: RegistryL10n.t("Pause all agents"),
    .taskConversationStop: RegistryL10n.t("Stop"),
    .taskConversationOther: RegistryL10n.t("Other…"),
    .taskConversationSend: RegistryL10n.t("Send"),
    .taskConversationReply: RegistryL10n.t("Reply…"),
    .appToggleSidebar: RegistryL10n.t("Show / Hide Sidebar"),
    .appSettings: RegistryL10n.t("Settings…"),
    .appUndo: RegistryL10n.t("Undo"),
    .accountSignOut: RegistryL10n.t("Sign out"),
    .settingsSave: RegistryL10n.t("Save"),
    .appHelp: RegistryL10n.t("Septena Help"),
    .appContactSupport: RegistryL10n.t("Contact Support…"),
    .appKeyboardShortcuts: RegistryL10n.t("Keyboard Shortcuts"),
    .appToggleSidebarCounts: RegistryL10n.t("Show Sidebar Counts"),
    .appTextSizeIncrease: RegistryL10n.t("Increase Text Size"),
    .appTextSizeDecrease: RegistryL10n.t("Decrease Text Size"),
    .appTextSizeReset: RegistryL10n.t("Reset Text Size"),
    .appSeptenaWindow: RegistryL10n.t("Septena Window"),
    .appClassicWindow: RegistryL10n.t("Classic Window"),
  ]

  static let sfSymbols: [RegistryActionID: String] = [
    .taskEditDetails: "info.circle",
    .taskOpen: "arrow.up.left.and.arrow.down.right",
    .taskShare: "square.and.arrow.up",
    .taskAcceptReview: "checkmark.seal",
    .taskSendBackReview: "arrowshape.turn.up.backward",
    .taskToggleInfo: "info.circle",
    .taskCopy: "doc.on.doc",
    .taskSelect: "checklist",
    .taskSelectAll: "checklist",
    .taskDuplicate: "plus.square.on.square",
    .taskDo: "play.circle",
    .doDone: "checkmark.circle",
    .doStop: "pause.circle",
    .doLater: "calendar",
    .doHere: "arrow.up.left.and.arrow.down.right",
    .doShowList: "list.bullet",
    .doConfirm: "play.circle",
    .doAddAndDo: "play.circle",
    .taskToggleComplete: "checkmark.circle",
    .taskCancel: "xmark.circle",
    .taskToggleToday: "sun.max.fill",
    .taskToggleStar: "star",
    .taskTags: "tag",
    .taskAddChecklistItem: "checklist",
    .taskAddReference: "link.badge.plus",
    .taskReferenceOpen: "arrow.up.left.and.arrow.down.right",
    .taskReferenceCopyLink: "doc.on.doc",
    .taskReferenceRemove: "trash",
    .taskDetailSave: "info.circle",
    .taskToggleChecklistItem: "checkmark.circle",
    .taskDeleteChecklistItem: "trash",
    .taskWhen: "calendar",
    .taskWaitingOn: "hourglass",
    .taskGotItBack: "arrow.uturn.backward.circle",
    .taskDeadline: "flag",
    .taskReminder: "bell",
    .taskMove: "folder",
    .taskMoveSuggested: "folder",
    .taskClearSchedule: "calendar.badge.minus",
    .taskRepeat: "arrow.clockwise",
    .taskPauseResumeRepeat: "pause.circle",
    .taskCreateNextCopy: "plus.circle",
    .taskDelete: "trash",
    .taskRestore: "arrow.uturn.backward",
    .taskDeletePermanently: "trash",
    .taskEmptyTrash: "trash",
    .taskKeepFaded: "arrow.uturn.backward",
    .taskLetGoFaded: "wind",
    .placeSaveNotes: "text.alignleft",
    .areaNewProject: "plus",
    .areaRename: "pencil",
    .areaChangeEmoji: "face.smiling",
    .areaMoveUp: "chevron.up",
    .areaMoveDown: "chevron.down",
    .areaDelete: "trash",
    .projectRename: "pencil",
    .projectMoveUp: "chevron.up",
    .projectMoveDown: "chevron.down",
    .projectMove: "folder",
    .projectUseAsChecklist: "checklist",
    .projectMarkDone: "checkmark.circle",
    .projectCancel: "xmark.circle",
    .projectDelete: "trash",
    .projectShare: "person.crop.circle.badge.plus",
    .loggedClear: "trash",
    .sidebarNewArea: "plus",
    .sidebarJoinShared: "person.crop.circle.badge.plus",
    .sidebarNewProject: "plus",
    .sectionNew: "plus",
    .sectionNewTask: "plus",
    .sectionRename: "pencil",
    .sectionDelete: "trash",
    .noticeOpenStep: "info.circle",
    .noticeToggleStep: "checkmark.circle",
    .noticeHideGetStarted: "xmark.circle",
    .appNewTask: "plus",
    .appQuickAdd: "plus",
    .appShareCaptureAdd: "plus",
    .appQuickEntry: "plus",
    .appQuickFind: "magnifyingglass",
    .appGoBack: "chevron.backward",
    .appGoForward: "chevron.forward",
    .appPauseAgents: "cpu",
    .taskConversationStop: "xmark.circle",
    .taskConversationOther: "info.circle",
    .taskConversationSend: "checkmark.circle",
    .taskConversationReply: "info.circle",
    .appToggleSidebar: "sidebar.leading",
    .appSettings: "checklist",
    .appUndo: "arrow.uturn.backward",
    .accountSignOut: "xmark.circle",
    .settingsSave: "checkmark.circle",
    .appHelp: "questionmark.circle",
    .appContactSupport: "paperplane",
    .appKeyboardShortcuts: "info.circle",
    .appToggleSidebarCounts: "number",
    .appTextSizeIncrease: "textformat.size",
    .appTextSizeDecrease: "textformat.size",
    .appTextSizeReset: "textformat.size",
    .appSeptenaWindow: "macwindow",
    .appClassicWindow: "macwindow",
  ]

  /// Other titles of an action: `desktopTitle`, `activeTitle` (state on), `pluralTitle`, `addTitle`, `removeTitle`, `shortTitle` (compact buttons).
  static let alternateTitles: [RegistryActionID: [String: String]] = [
    .taskEditDetails: ["desktopTitle": RegistryL10n.t("Rename")],
    .taskToggleInfo: ["activeTitle": RegistryL10n.t("Hide Info")],
    .taskSelect: ["activeTitle": RegistryL10n.t("Done")],
    .taskSelectAll: ["activeTitle": RegistryL10n.t("Deselect All")],
    .taskDuplicate: ["pluralTitle": RegistryL10n.t("Duplicate Tasks")],
    .taskToggleComplete: ["shortTitle": RegistryL10n.t("Complete")],
    .taskCancel: ["pluralTitle": RegistryL10n.t("Cancel Tasks")],
    .taskToggleToday: ["addTitle": RegistryL10n.t("Move to Today"), "removeTitle": RegistryL10n.t("Remove from Today"), "shortTitle": RegistryL10n.t("Today")],
    .taskToggleStar: ["addTitle": RegistryL10n.t("Star"), "removeTitle": RegistryL10n.t("Unstar")],
    .taskAddReference: ["shortTitle": RegistryL10n.t("Add Reference")],
    .taskWhen: ["shortTitle": RegistryL10n.t("Schedule")],
    .taskReminder: ["addTitle": RegistryL10n.t("Add Reminder…")],
    .taskMove: ["pluralTitle": RegistryL10n.t("Move Tasks"), "shortTitle": RegistryL10n.t("Move")],
    .taskPauseResumeRepeat: ["activeTitle": RegistryL10n.t("Resume Repeat")],
    .taskDelete: ["pluralTitle": RegistryL10n.t("Delete Tasks")],
    .projectMove: ["shortTitle": RegistryL10n.t("Move")],
    .noticeToggleStep: ["activeTitle": RegistryL10n.t("Mark as Not Done")],
    .appQuickAdd: ["addTitle": RegistryL10n.t("Add")],
    .appQuickFind: ["desktopTitle": RegistryL10n.t("Command Bar…")],
    .appPauseAgents: ["activeTitle": RegistryL10n.t("Resume all agents")],
    .taskConversationStop: ["activeTitle": RegistryL10n.t("Resume")],
    .appToggleSidebar: ["addTitle": RegistryL10n.t("Show Sidebar"), "removeTitle": RegistryL10n.t("Hide Sidebar")],
    .appToggleSidebarCounts: ["activeTitle": RegistryL10n.t("Hide Sidebar Counts")],
  ]

  static let shortcuts: [RegistryActionID: RegistryShortcut] = [
    .taskEditDetails: RegistryShortcut(key: "r", modifiers: ["primary"], keycaps: ["⌘", "R"], excludePlatforms: []),
    .taskToggleInfo: RegistryShortcut(key: "i", modifiers: ["primary", "alt"], keycaps: ["⌥", "⌘", "I"], excludePlatforms: []),
    .taskCopy: RegistryShortcut(key: "c", modifiers: ["primary"], keycaps: ["⌘", "C"], excludePlatforms: []),
    .taskDuplicate: RegistryShortcut(key: "d", modifiers: ["primary"], keycaps: ["⌘", "D"], excludePlatforms: []),
    .taskDo: RegistryShortcut(key: "j", modifiers: ["primary"], keycaps: ["⌘", "J"], excludePlatforms: []),
    .taskToggleComplete: RegistryShortcut(key: "return", modifiers: ["primary"], keycaps: ["⌘", "↩"], excludePlatforms: []),
    .taskCancel: RegistryShortcut(key: "return", modifiers: ["primary", "alt"], keycaps: ["⌥", "⌘", "↩"], excludePlatforms: []),
    .taskToggleToday: RegistryShortcut(key: "t", modifiers: ["primary"], keycaps: ["⌘", "T"], excludePlatforms: []),
    .taskToggleStar: RegistryShortcut(key: "s", modifiers: ["primary", "alt"], keycaps: ["⌥", "⌘", "S"], excludePlatforms: []),
    .taskTags: RegistryShortcut(key: "t", modifiers: ["primary", "shift"], keycaps: ["⇧", "⌘", "T"], excludePlatforms: []),
    .taskAddChecklistItem: RegistryShortcut(key: "c", modifiers: ["primary", "shift"], keycaps: ["⇧", "⌘", "C"], excludePlatforms: ["ios", "ipados"]),
    .taskWhen: RegistryShortcut(key: "s", modifiers: ["primary"], keycaps: ["⌘", "S"], excludePlatforms: []),
    .taskDeadline: RegistryShortcut(key: "d", modifiers: ["primary", "shift"], keycaps: ["⇧", "⌘", "D"], excludePlatforms: []),
    .taskReminder: RegistryShortcut(key: "r", modifiers: ["primary", "alt"], keycaps: ["⌥", "⌘", "R"], excludePlatforms: []),
    .taskMove: RegistryShortcut(key: "m", modifiers: ["primary", "shift"], keycaps: ["⇧", "⌘", "M"], excludePlatforms: [], alternates: [RegistryShortcut(key: "m", modifiers: ["primary"], keycaps: ["⌘", "M"], excludePlatforms: [])]),
    .taskMoveSuggested: RegistryShortcut(key: "m", modifiers: ["primary", "alt"], keycaps: ["⌥", "⌘", "M"], excludePlatforms: []),
    .taskClearSchedule: RegistryShortcut(key: ".", modifiers: ["primary", "shift"], keycaps: ["⇧", "⌘", "."], excludePlatforms: []),
    .taskDelete: RegistryShortcut(key: "delete", modifiers: ["primary"], keycaps: ["⌘", "⌫"], excludePlatforms: []),
    .taskDeletePermanently: RegistryShortcut(key: "delete", modifiers: ["primary"], keycaps: ["⌘", "⌫"], excludePlatforms: []),
    .sectionRename: RegistryShortcut(key: "r", modifiers: ["primary"], keycaps: ["⌘", "R"], excludePlatforms: []),
    .noticeToggleStep: RegistryShortcut(key: "return", modifiers: ["primary"], keycaps: ["⌘", "↩"], excludePlatforms: []),
    .appNewTask: RegistryShortcut(key: "n", modifiers: ["primary"], keycaps: ["⌘", "N"], excludePlatforms: []),
    .appQuickAdd: RegistryShortcut(key: "i", modifiers: ["primary"], keycaps: ["⌘", "I"], excludePlatforms: []),
    .appQuickEntry: RegistryShortcut(key: "space", modifiers: ["ctrl", "alt"], keycaps: ["⌃", "⌥", "space"], excludePlatforms: []),
    .appQuickFind: RegistryShortcut(key: "k", modifiers: ["primary"], keycaps: ["⌘", "K"], excludePlatforms: [], alternates: [RegistryShortcut(key: "f", modifiers: ["primary", "shift"], keycaps: ["⇧", "⌘", "F"], excludePlatforms: [])]),
    .appGoBack: RegistryShortcut(key: "[", modifiers: ["primary"], keycaps: ["⌘", "["], excludePlatforms: []),
    .appGoForward: RegistryShortcut(key: "]", modifiers: ["primary"], keycaps: ["⌘", "]"], excludePlatforms: []),
    .appToggleSidebar: RegistryShortcut(key: "s", modifiers: ["ctrl", "primary"], keycaps: ["⌃", "⌘", "S"], excludePlatforms: ["ios", "ipados"]),
    .appSettings: RegistryShortcut(key: ",", modifiers: ["primary"], keycaps: ["⌘", ","], excludePlatforms: []),
    .appKeyboardShortcuts: RegistryShortcut(key: "/", modifiers: ["primary", "shift"], keycaps: ["⇧", "⌘", "/"], excludePlatforms: []),
    .appTextSizeIncrease: RegistryShortcut(key: "+", modifiers: ["primary"], keycaps: ["⌘", "+"], excludePlatforms: []),
    .appTextSizeDecrease: RegistryShortcut(key: "-", modifiers: ["primary"], keycaps: ["⌘", "-"], excludePlatforms: []),
    .appTextSizeReset: RegistryShortcut(key: "0", modifiers: ["primary"], keycaps: ["⌘", "0"], excludePlatforms: []),
  ]

  /// The task attribute whose picker an action opens (`opensAttribute`, ADR 0029).
  /// Every entry point for an attribute (pill, page row, context menu, menu bar,
  /// shortcut) runs this action, so all of them open the same picker.
  static let opensAttribute: [RegistryActionID: RegistryTaskAttributeID] = [
    .taskTags: .tags,
    .taskWhen: .when,
    .taskDeadline: .deadline,
    .taskReminder: .reminder,
    .taskMove: .list,
    .taskRepeat: .repeat,
  ]
  /// The action that opens the picker for `attributeId`, or nil for an attribute with no picker.
  static func action(opening attributeId: RegistryTaskAttributeID) -> RegistryActionID? {
    opensAttribute.first(where: { $0.value == attributeId })?.key
  }

  /// Actions whose `role` is `destructive` (red in menus).
  static let destructive: Set<RegistryActionID> = [
    .taskReferenceRemove,
    .taskDeleteChecklistItem,
    .taskDelete,
    .taskDeletePermanently,
    .taskEmptyTrash,
    .areaDelete,
    .projectDelete,
    .loggedClear,
    .sectionDelete,
    .taskConversationStop,
    .accountSignOut,
  ]

  static let availability: [RegistryActionID: RegistryActionAvailability] = [
    .taskEditDetails: RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [.recentlyDeleted], onlyDestinations: [], requiresRecurrence: false, featureId: "lists.today"),
    .taskOpen: RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [.recentlyDeleted], onlyDestinations: [], requiresRecurrence: false, featureId: "task.page"),
    .taskShare: RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: [.recentlyDeleted], onlyDestinations: [], requiresRecurrence: false, featureId: "task.share"),
    .taskAcceptReview: RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [.recentlyDeleted], onlyDestinations: [], requiresRecurrence: false, featureId: "lists.review"),
    .taskSendBackReview: RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [.recentlyDeleted], onlyDestinations: [], requiresRecurrence: false, featureId: "lists.review"),
    .taskToggleInfo: RegistryActionAvailability(selection: "any", platforms: ["macos", "web", "windows", "linux"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "task.page"),
    .taskCopy: RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "lists.today"),
    .taskSelect: RegistryActionAvailability(selection: "single", platforms: ["ios", "ipados", "android"], excludeDestinations: [.recentlyDeleted], onlyDestinations: [], requiresRecurrence: false, featureId: "edit.multi-select"),
    .taskSelectAll: RegistryActionAvailability(selection: "any", platforms: ["ios", "ipados", "android"], excludeDestinations: [.recentlyDeleted], onlyDestinations: [], requiresRecurrence: false, featureId: "edit.multi-select"),
    .taskDuplicate: RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: [.recentlyDeleted], onlyDestinations: [], requiresRecurrence: false, featureId: "lists.today"),
    .taskDo: RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [.recentlyDeleted, .logbook], onlyDestinations: [], requiresRecurrence: false, featureId: "task.do"),
    .doDone: RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "task.do"),
    .doStop: RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "task.do"),
    .doLater: RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "task.do"),
    .doHere: RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "task.do"),
    .doShowList: RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "task.do"),
    .doConfirm: RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "task.do"),
    .doAddAndDo: RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "task.do"),
    .taskToggleComplete: RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: [.recentlyDeleted], onlyDestinations: [], requiresRecurrence: false, featureId: "lists.today"),
    .taskCancel: RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: [.recentlyDeleted], onlyDestinations: [], requiresRecurrence: false, featureId: "lists.today"),
    .taskToggleToday: RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: [.recentlyDeleted], onlyDestinations: [], requiresRecurrence: false, featureId: "lists.today"),
    .taskToggleStar: RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: [.recentlyDeleted], onlyDestinations: [], requiresRecurrence: false, featureId: "lists.starred"),
    .taskTags: RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: [.recentlyDeleted], onlyDestinations: [], requiresRecurrence: false, featureId: "task.tags"),
    .taskAddChecklistItem: RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [.recentlyDeleted], onlyDestinations: [], requiresRecurrence: false, featureId: "task.checklists"),
    .taskAddReference: RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [.recentlyDeleted], onlyDestinations: [], requiresRecurrence: false, featureId: "task.references"),
    .taskReferenceOpen: RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "task.references"),
    .taskReferenceCopyLink: RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "task.references"),
    .taskReferenceRemove: RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "task.references"),
    .taskDetailSave: RegistryActionAvailability(selection: "none", platforms: ["android"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "task.notes"),
    .taskToggleChecklistItem: RegistryActionAvailability(selection: "single", platforms: ["android"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "task.checklists"),
    .taskDeleteChecklistItem: RegistryActionAvailability(selection: "single", platforms: ["android"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "task.checklists"),
    .taskWhen: RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: [.recentlyDeleted], onlyDestinations: [], requiresRecurrence: false, featureId: "task.when-deadline"),
    .taskWaitingOn: RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [.recentlyDeleted], onlyDestinations: [], requiresRecurrence: false, featureId: "review.waiting"),
    .taskGotItBack: RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: [.recentlyDeleted], onlyDestinations: [], requiresRecurrence: false, featureId: "review.waiting"),
    .taskDeadline: RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: [.recentlyDeleted], onlyDestinations: [], requiresRecurrence: false, featureId: "task.when-deadline"),
    .taskReminder: RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [.recentlyDeleted], onlyDestinations: [], requiresRecurrence: false, featureId: "task.alerts"),
    .taskMove: RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: [.recentlyDeleted], onlyDestinations: [], requiresRecurrence: false, featureId: "places.projects"),
    .taskMoveSuggested: RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [.logbook, .recentlyDeleted], onlyDestinations: [], requiresRecurrence: false, featureId: "edit.filing-suggestion"),
    .taskClearSchedule: RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: [.recentlyDeleted], onlyDestinations: [], requiresRecurrence: false, featureId: "task.when-deadline"),
    .taskRepeat: RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: [.recentlyDeleted], onlyDestinations: [], requiresRecurrence: false, featureId: "task.repeat"),
    .taskPauseResumeRepeat: RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: [.recentlyDeleted], onlyDestinations: [], requiresRecurrence: true, featureId: "task.repeat"),
    .taskCreateNextCopy: RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [.recentlyDeleted], onlyDestinations: [], requiresRecurrence: true, featureId: "task.repeat"),
    .taskDelete: RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: [.recentlyDeleted], onlyDestinations: [], requiresRecurrence: false, featureId: "lists.recently-deleted"),
    .taskRestore: RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: [], onlyDestinations: [.recentlyDeleted], requiresRecurrence: false, featureId: "lists.recently-deleted"),
    .taskDeletePermanently: RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: [], onlyDestinations: [.recentlyDeleted], requiresRecurrence: false, featureId: "lists.recently-deleted"),
    .taskEmptyTrash: RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [.recentlyDeleted], requiresRecurrence: false, featureId: "lists.recently-deleted"),
    .taskKeepFaded: RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: [], onlyDestinations: [.faded, .review], requiresRecurrence: false, featureId: "fade.sweep"),
    .taskLetGoFaded: RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: [], onlyDestinations: [.faded, .review], requiresRecurrence: false, featureId: "fade.sweep"),
    .placeSaveNotes: RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.projects"),
    .areaNewProject: RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.projects"),
    .areaRename: RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.areas"),
    .areaChangeEmoji: RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.areas"),
    .areaMoveUp: RegistryActionAvailability(selection: "single", platforms: ["ios", "ipados", "android"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.areas"),
    .areaMoveDown: RegistryActionAvailability(selection: "single", platforms: ["ios", "ipados", "android"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.areas"),
    .areaDelete: RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.areas"),
    .projectRename: RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.projects"),
    .projectMoveUp: RegistryActionAvailability(selection: "single", platforms: ["ios", "ipados", "android"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.projects"),
    .projectMoveDown: RegistryActionAvailability(selection: "single", platforms: ["ios", "ipados", "android"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.projects"),
    .projectMove: RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.projects"),
    .projectUseAsChecklist: RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.projects"),
    .projectMarkDone: RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.projects"),
    .projectCancel: RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.projects"),
    .projectDelete: RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.projects"),
    .projectShare: RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "sharing.projects"),
    .loggedClear: RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "lists.logbook"),
    .sidebarNewArea: RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.areas"),
    .sidebarJoinShared: RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "sharing.projects"),
    .sidebarNewProject: RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.projects"),
    .sectionNew: RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.sections"),
    .sectionNewTask: RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.sections"),
    .sectionRename: RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.sections"),
    .sectionDelete: RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "places.sections"),
    .noticeOpenStep: RegistryActionAvailability(selection: "single", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "lists.today"),
    .noticeToggleStep: RegistryActionAvailability(selection: "any", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "lists.today"),
    .noticeHideGetStarted: RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "lists.today"),
    .appNewTask: RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "lists.today"),
    .appQuickAdd: RegistryActionAvailability(selection: "none", platforms: ["ios", "ipados", "web", "android"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "capture.quick-add"),
    .appShareCaptureAdd: RegistryActionAvailability(selection: "none", platforms: ["android"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "capture.share-target"),
    .appQuickEntry: RegistryActionAvailability(selection: "none", platforms: ["macos", "windows", "linux"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "capture.quick-entry"),
    .appQuickFind: RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "find.quick-find"),
    .appGoBack: RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "mac.keyboard"),
    .appGoForward: RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "mac.keyboard"),
    .appPauseAgents: RegistryActionAvailability(selection: "none", platforms: ["android"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "agents.stop-pause"),
    .taskConversationStop: RegistryActionAvailability(selection: "single", platforms: ["android"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "agents.stop-pause"),
    .taskConversationOther: RegistryActionAvailability(selection: "single", platforms: ["android"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "ai.discuss"),
    .taskConversationSend: RegistryActionAvailability(selection: "single", platforms: ["android"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "ai.discuss"),
    .taskConversationReply: RegistryActionAvailability(selection: "single", platforms: ["android"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "ai.discuss"),
    .appToggleSidebar: RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "mac.keyboard"),
    .appSettings: RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "settings.display"),
    .appUndo: RegistryActionAvailability(selection: "none", platforms: ["android"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "edit.undo"),
    .accountSignOut: RegistryActionAvailability(selection: "none", platforms: ["android"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "sync.backend"),
    .settingsSave: RegistryActionAvailability(selection: "none", platforms: ["android"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "settings.display"),
    .appHelp: RegistryActionAvailability(selection: "none", platforms: ["macos", "ipados", "web", "windows", "linux"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "settings.display"),
    .appContactSupport: RegistryActionAvailability(selection: "none", platforms: ["macos", "ipados", "web", "windows", "linux"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "support.contact"),
    .appKeyboardShortcuts: RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "mac.keyboard"),
    .appToggleSidebarCounts: RegistryActionAvailability(selection: "none", platforms: ["macos", "ipados", "web", "windows", "linux"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "settings.display"),
    .appTextSizeIncrease: RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "settings.display"),
    .appTextSizeDecrease: RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "settings.display"),
    .appTextSizeReset: RegistryActionAvailability(selection: "none", platforms: [], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "settings.display"),
    .appSeptenaWindow: RegistryActionAvailability(selection: "none", platforms: ["macos"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "mac.keyboard"),
    .appClassicWindow: RegistryActionAvailability(selection: "none", platforms: ["macos"], excludeDestinations: [], onlyDestinations: [], requiresRecurrence: false, featureId: "mac.keyboard"),
  ]

  static let contextMenus: [RegistryContextMenuID: [RegistryMenuItem]] = [
    .taskRow: [
      RegistryMenuItem(kind: "action", id: "task.acceptReview", actionId: .taskAcceptReview, title: RegistryL10n.t("Accept"), sfSymbol: "checkmark.seal", items: []),
      RegistryMenuItem(kind: "action", id: "task.sendBackReview", actionId: .taskSendBackReview, title: RegistryL10n.t("Send Back…"), sfSymbol: "arrowshape.turn.up.backward", items: []),
      RegistryMenuItem(kind: "action", id: "task.gotItBack", actionId: .taskGotItBack, title: RegistryL10n.t("Got It Back"), sfSymbol: "arrow.uturn.backward.circle", items: []),
      RegistryMenuItem(kind: "slot", id: "filingSuggestion", actionId: nil, title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "divider", id: "divider.4", actionId: nil, title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "task.do", actionId: .taskDo, title: RegistryL10n.t("Do"), sfSymbol: "play.circle", items: []),
      RegistryMenuItem(kind: "action", id: "task.when", actionId: .taskWhen, title: RegistryL10n.t("When…"), sfSymbol: "calendar", items: []),
      RegistryMenuItem(kind: "submenu", id: "move", actionId: nil, title: RegistryL10n.t("Move"), sfSymbol: "folder", items: [RegistryMenuItem(kind: "slot", id: "sectionDestinations", actionId: nil, title: nil, sfSymbol: nil, items: []), RegistryMenuItem(kind: "divider", id: "divider.1", actionId: nil, title: nil, sfSymbol: nil, items: []), RegistryMenuItem(kind: "slot", id: "moveDestinations", actionId: nil, title: nil, sfSymbol: nil, items: []), RegistryMenuItem(kind: "divider", id: "divider.3", actionId: nil, title: nil, sfSymbol: nil, items: []), RegistryMenuItem(kind: "action", id: "task.move", actionId: .taskMove, title: RegistryL10n.t("Move…"), sfSymbol: "folder", items: [])]),
      RegistryMenuItem(kind: "submenu", id: "assign", actionId: nil, title: RegistryL10n.t("Assign To"), sfSymbol: "person", items: [RegistryMenuItem(kind: "slot", id: "assignees", actionId: nil, title: nil, sfSymbol: nil, items: [])]),
      RegistryMenuItem(kind: "action", id: "task.tags", actionId: .taskTags, title: RegistryL10n.t("Tags…"), sfSymbol: "tag", items: []),
      RegistryMenuItem(kind: "action", id: "task.deadline", actionId: .taskDeadline, title: RegistryL10n.t("Deadline…"), sfSymbol: "flag", items: []),
      RegistryMenuItem(kind: "action", id: "task.waitingOn", actionId: .taskWaitingOn, title: RegistryL10n.t("Waiting On…"), sfSymbol: "hourglass", items: []),
      RegistryMenuItem(kind: "action", id: "task.toggleStar", actionId: .taskToggleStar, title: RegistryL10n.t("Toggle Star"), sfSymbol: "star", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.13", actionId: nil, title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "task.open", actionId: .taskOpen, title: RegistryL10n.t("Open"), sfSymbol: "arrow.up.left.and.arrow.down.right", items: []),
      RegistryMenuItem(kind: "action", id: "task.addReference", actionId: .taskAddReference, title: RegistryL10n.t("Add Reference…"), sfSymbol: "link.badge.plus", items: []),
      RegistryMenuItem(kind: "action", id: "task.duplicate", actionId: .taskDuplicate, title: RegistryL10n.t("Duplicate"), sfSymbol: "plus.square.on.square", items: []),
      RegistryMenuItem(kind: "action", id: "task.share", actionId: .taskShare, title: RegistryL10n.t("Share…"), sfSymbol: "square.and.arrow.up", items: []),
      RegistryMenuItem(kind: "action", id: "task.select", actionId: .taskSelect, title: RegistryL10n.t("Select"), sfSymbol: "checklist", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.19", actionId: nil, title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "task.toggleComplete", actionId: .taskToggleComplete, title: RegistryL10n.t("Mark as Complete"), sfSymbol: "checkmark.circle", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.21", actionId: nil, title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "task.delete", actionId: .taskDelete, title: RegistryL10n.t("Delete"), sfSymbol: "trash", items: []),
    ],
    .taskReference: [
      RegistryMenuItem(kind: "action", id: "task.reference.open", actionId: .taskReferenceOpen, title: RegistryL10n.t("Open"), sfSymbol: "arrow.up.left.and.arrow.down.right", items: []),
      RegistryMenuItem(kind: "action", id: "task.reference.copyLink", actionId: .taskReferenceCopyLink, title: RegistryL10n.t("Copy Link"), sfSymbol: "doc.on.doc", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.2", actionId: nil, title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "task.reference.remove", actionId: .taskReferenceRemove, title: RegistryL10n.t("Remove"), sfSymbol: "trash", items: []),
    ],
    .taskRecentlyDeleted: [
      RegistryMenuItem(kind: "action", id: "task.restore", actionId: .taskRestore, title: RegistryL10n.t("Restore"), sfSymbol: "arrow.uturn.backward", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.1", actionId: nil, title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "task.deletePermanently", actionId: .taskDeletePermanently, title: RegistryL10n.t("Delete Permanently"), sfSymbol: "trash", items: []),
    ],
    .taskFaded: [
      RegistryMenuItem(kind: "action", id: "task.keepFaded", actionId: .taskKeepFaded, title: RegistryL10n.t("Keep"), sfSymbol: "arrow.uturn.backward", items: []),
      RegistryMenuItem(kind: "action", id: "task.letGoFaded", actionId: .taskLetGoFaded, title: RegistryL10n.t("Let Go"), sfSymbol: "wind", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.2", actionId: nil, title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "task.delete", actionId: .taskDelete, title: RegistryL10n.t("Delete"), sfSymbol: "trash", items: []),
    ],
    .sidebarArea: [
      RegistryMenuItem(kind: "action", id: "area.newProject", actionId: .areaNewProject, title: RegistryL10n.t("New Project in Area"), sfSymbol: "plus", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.1", actionId: nil, title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "area.rename", actionId: .areaRename, title: RegistryL10n.t("Rename"), sfSymbol: "pencil", items: []),
      RegistryMenuItem(kind: "action", id: "area.changeEmoji", actionId: .areaChangeEmoji, title: RegistryL10n.t("Change Emoji…"), sfSymbol: "face.smiling", items: []),
      RegistryMenuItem(kind: "action", id: "area.moveUp", actionId: .areaMoveUp, title: RegistryL10n.t("Move Up"), sfSymbol: "chevron.up", items: []),
      RegistryMenuItem(kind: "action", id: "area.moveDown", actionId: .areaMoveDown, title: RegistryL10n.t("Move Down"), sfSymbol: "chevron.down", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.6", actionId: nil, title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "area.delete", actionId: .areaDelete, title: RegistryL10n.t("Delete Area"), sfSymbol: "trash", items: []),
    ],
    .sidebarProject: [
      RegistryMenuItem(kind: "action", id: "project.rename", actionId: .projectRename, title: RegistryL10n.t("Rename"), sfSymbol: "pencil", items: []),
      RegistryMenuItem(kind: "action", id: "project.moveUp", actionId: .projectMoveUp, title: RegistryL10n.t("Move Up"), sfSymbol: "chevron.up", items: []),
      RegistryMenuItem(kind: "action", id: "project.moveDown", actionId: .projectMoveDown, title: RegistryL10n.t("Move Down"), sfSymbol: "chevron.down", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.3", actionId: nil, title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "project.move", actionId: .projectMove, title: RegistryL10n.t("Move…"), sfSymbol: "folder", items: []),
      RegistryMenuItem(kind: "action", id: "project.useAsChecklist", actionId: .projectUseAsChecklist, title: RegistryL10n.t("Use as Checklist"), sfSymbol: "checklist", items: []),
      RegistryMenuItem(kind: "action", id: "project.share", actionId: .projectShare, title: RegistryL10n.t("Share Project…"), sfSymbol: "person.crop.circle.badge.plus", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.7", actionId: nil, title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "project.markDone", actionId: .projectMarkDone, title: RegistryL10n.t("Mark Done"), sfSymbol: "checkmark.circle", items: []),
      RegistryMenuItem(kind: "action", id: "project.cancel", actionId: .projectCancel, title: RegistryL10n.t("Cancel Project"), sfSymbol: "xmark.circle", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.10", actionId: nil, title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "project.delete", actionId: .projectDelete, title: RegistryL10n.t("Delete Project"), sfSymbol: "trash", items: []),
    ],
    .sidebarEmpty: [
      RegistryMenuItem(kind: "action", id: "sidebar.newArea", actionId: .sidebarNewArea, title: RegistryL10n.t("New Area"), sfSymbol: "plus", items: []),
      RegistryMenuItem(kind: "action", id: "sidebar.newProject", actionId: .sidebarNewProject, title: RegistryL10n.t("New Project"), sfSymbol: "plus", items: []),
      RegistryMenuItem(kind: "action", id: "sidebar.joinShared", actionId: .sidebarJoinShared, title: RegistryL10n.t("Join a Shared Project…"), sfSymbol: "person.crop.circle.badge.plus", items: []),
    ],
    .projectHeading: [
      RegistryMenuItem(kind: "action", id: "section.rename", actionId: .sectionRename, title: RegistryL10n.t("Rename"), sfSymbol: "pencil", items: []),
      RegistryMenuItem(kind: "action", id: "section.newTask", actionId: .sectionNewTask, title: RegistryL10n.t("New Task in Section"), sfSymbol: "plus", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.2", actionId: nil, title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "section.delete", actionId: .sectionDelete, title: RegistryL10n.t("Delete Section"), sfSymbol: "trash", items: []),
    ],
    .projectBlankSpace: [
      RegistryMenuItem(kind: "action", id: "section.new", actionId: .sectionNew, title: RegistryL10n.t("New Section"), sfSymbol: "plus", items: []),
    ],
    .scopeLoggedFooter: [
      RegistryMenuItem(kind: "action", id: "logged.clear", actionId: .loggedClear, title: RegistryL10n.t("Clear Logged…"), sfSymbol: "trash", items: []),
    ],
    .noticeGetStartedStep: [
      RegistryMenuItem(kind: "action", id: "notice.openStep", actionId: .noticeOpenStep, title: RegistryL10n.t("Open"), sfSymbol: "info.circle", items: []),
      RegistryMenuItem(kind: "action", id: "notice.toggleStep", actionId: .noticeToggleStep, title: RegistryL10n.t("Mark as Done"), sfSymbol: "checkmark.circle", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.2", actionId: nil, title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "notice.hideGetStarted", actionId: .noticeHideGetStarted, title: RegistryL10n.t("Hide Get Started"), sfSymbol: "xmark.circle", items: []),
    ],
  ]

  static let menuBar: [RegistryMenu] = [
    RegistryMenu(id: .app, title: RegistryL10n.t("Septena"), system: "app", items: [
      RegistryMenuItem(kind: "action", id: "app.settings", actionId: .appSettings, title: RegistryL10n.t("Settings…"), sfSymbol: "checklist", items: []),
    ]),
    RegistryMenu(id: .file, title: RegistryL10n.t("File"), system: "file", items: [
      RegistryMenuItem(kind: "action", id: "app.newTask", actionId: .appNewTask, title: RegistryL10n.t("New Task"), sfSymbol: "plus", items: []),
      RegistryMenuItem(kind: "action", id: "app.quickAdd", actionId: .appQuickAdd, title: RegistryL10n.t("Quick Add…"), sfSymbol: "plus", items: []),
    ]),
    RegistryMenu(id: .view, title: RegistryL10n.t("View"), system: "view", items: [
      RegistryMenuItem(kind: "action", id: "app.toggleSidebar", actionId: .appToggleSidebar, title: RegistryL10n.t("Show / Hide Sidebar"), sfSymbol: "sidebar.leading", items: []),
      RegistryMenuItem(kind: "action", id: "task.toggleInfo", actionId: .taskToggleInfo, title: RegistryL10n.t("Show Info"), sfSymbol: "info.circle", items: []),
      RegistryMenuItem(kind: "action", id: "app.toggleSidebarCounts", actionId: .appToggleSidebarCounts, title: RegistryL10n.t("Show Sidebar Counts"), sfSymbol: "number", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.3", actionId: nil, title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "submenu", id: "sortBy", actionId: nil, title: RegistryL10n.t("Sort By"), sfSymbol: "arrow.up.arrow.down", items: [RegistryMenuItem(kind: "slot", id: "listSortOptions", actionId: nil, title: nil, sfSymbol: nil, items: [])]),
      RegistryMenuItem(kind: "divider", id: "divider.5", actionId: nil, title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "submenu", id: "textSize", actionId: nil, title: RegistryL10n.t("Text Size"), sfSymbol: "textformat.size", items: [RegistryMenuItem(kind: "slot", id: "textSizeSteps", actionId: nil, title: nil, sfSymbol: nil, items: []), RegistryMenuItem(kind: "divider", id: "divider.1", actionId: nil, title: nil, sfSymbol: nil, items: []), RegistryMenuItem(kind: "action", id: "app.textSizeIncrease", actionId: .appTextSizeIncrease, title: RegistryL10n.t("Increase Text Size"), sfSymbol: "textformat.size", items: []), RegistryMenuItem(kind: "action", id: "app.textSizeDecrease", actionId: .appTextSizeDecrease, title: RegistryL10n.t("Decrease Text Size"), sfSymbol: "textformat.size", items: []), RegistryMenuItem(kind: "action", id: "app.textSizeReset", actionId: .appTextSizeReset, title: RegistryL10n.t("Reset Text Size"), sfSymbol: "textformat.size", items: [])]),
    ]),
    RegistryMenu(id: .go, title: RegistryL10n.t("Go"), system: nil, items: [
      RegistryMenuItem(kind: "action", id: "app.goBack", actionId: .appGoBack, title: RegistryL10n.t("Back"), sfSymbol: "chevron.backward", items: []),
      RegistryMenuItem(kind: "action", id: "app.goForward", actionId: .appGoForward, title: RegistryL10n.t("Forward"), sfSymbol: "chevron.forward", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.2", actionId: nil, title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "slot", id: "smartLists", actionId: nil, title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "divider", id: "divider.4", actionId: nil, title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "app.quickFind", actionId: .appQuickFind, title: RegistryL10n.t("Quick Find…"), sfSymbol: "magnifyingglass", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.6", actionId: nil, title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "app.septenaWindow", actionId: .appSeptenaWindow, title: RegistryL10n.t("Septena Window"), sfSymbol: "macwindow", items: []),
      RegistryMenuItem(kind: "action", id: "app.classicWindow", actionId: .appClassicWindow, title: RegistryL10n.t("Classic Window"), sfSymbol: "macwindow", items: []),
      RegistryMenuItem(kind: "action", id: "app.quickEntry", actionId: .appQuickEntry, title: RegistryL10n.t("Quick Entry"), sfSymbol: "plus", items: []),
    ]),
    RegistryMenu(id: .task, title: RegistryL10n.t("Task"), system: nil, items: [
      RegistryMenuItem(kind: "action", id: "sidebar.newProject", actionId: .sidebarNewProject, title: RegistryL10n.t("New Project"), sfSymbol: "plus", items: []),
      RegistryMenuItem(kind: "action", id: "sidebar.joinShared", actionId: .sidebarJoinShared, title: RegistryL10n.t("Join a Shared Project…"), sfSymbol: "person.crop.circle.badge.plus", items: []),
      RegistryMenuItem(kind: "action", id: "sidebar.newArea", actionId: .sidebarNewArea, title: RegistryL10n.t("New Area"), sfSymbol: "plus", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.3", actionId: nil, title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "task.do", actionId: .taskDo, title: RegistryL10n.t("Do"), sfSymbol: "play.circle", items: []),
      RegistryMenuItem(kind: "action", id: "task.toggleToday", actionId: .taskToggleToday, title: RegistryL10n.t("Toggle Today"), sfSymbol: "sun.max.fill", items: []),
      RegistryMenuItem(kind: "action", id: "task.when", actionId: .taskWhen, title: RegistryL10n.t("When…"), sfSymbol: "calendar", items: []),
      RegistryMenuItem(kind: "action", id: "task.clearSchedule", actionId: .taskClearSchedule, title: RegistryL10n.t("Clear When"), sfSymbol: "calendar.badge.minus", items: []),
      RegistryMenuItem(kind: "action", id: "task.repeat", actionId: .taskRepeat, title: RegistryL10n.t("Repeat…"), sfSymbol: "arrow.clockwise", items: []),
      RegistryMenuItem(kind: "action", id: "task.createNextCopy", actionId: .taskCreateNextCopy, title: RegistryL10n.t("Create Next Copy"), sfSymbol: "plus.circle", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.10", actionId: nil, title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "task.move", actionId: .taskMove, title: RegistryL10n.t("Move…"), sfSymbol: "folder", items: []),
      RegistryMenuItem(kind: "action", id: "task.tags", actionId: .taskTags, title: RegistryL10n.t("Tags…"), sfSymbol: "tag", items: []),
      RegistryMenuItem(kind: "action", id: "task.deadline", actionId: .taskDeadline, title: RegistryL10n.t("Deadline…"), sfSymbol: "flag", items: []),
      RegistryMenuItem(kind: "action", id: "task.reminder", actionId: .taskReminder, title: RegistryL10n.t("Reminder…"), sfSymbol: "bell", items: []),
      RegistryMenuItem(kind: "action", id: "task.waitingOn", actionId: .taskWaitingOn, title: RegistryL10n.t("Waiting On…"), sfSymbol: "hourglass", items: []),
      RegistryMenuItem(kind: "action", id: "task.gotItBack", actionId: .taskGotItBack, title: RegistryL10n.t("Got It Back"), sfSymbol: "arrow.uturn.backward.circle", items: []),
      RegistryMenuItem(kind: "action", id: "task.toggleStar", actionId: .taskToggleStar, title: RegistryL10n.t("Toggle Star"), sfSymbol: "star", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.18", actionId: nil, title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "task.editDetails", actionId: .taskEditDetails, title: RegistryL10n.t("Rename"), sfSymbol: "info.circle", items: []),
      RegistryMenuItem(kind: "action", id: "task.duplicate", actionId: .taskDuplicate, title: RegistryL10n.t("Duplicate"), sfSymbol: "plus.square.on.square", items: []),
      RegistryMenuItem(kind: "action", id: "task.addChecklistItem", actionId: .taskAddChecklistItem, title: RegistryL10n.t("Add Checklist Item"), sfSymbol: "checklist", items: []),
      RegistryMenuItem(kind: "action", id: "task.addReference", actionId: .taskAddReference, title: RegistryL10n.t("Add Reference…"), sfSymbol: "link.badge.plus", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.23", actionId: nil, title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "task.toggleComplete", actionId: .taskToggleComplete, title: RegistryL10n.t("Mark as Complete"), sfSymbol: "checkmark.circle", items: []),
      RegistryMenuItem(kind: "action", id: "task.cancel", actionId: .taskCancel, title: RegistryL10n.t("Cancel Task"), sfSymbol: "xmark.circle", items: []),
      RegistryMenuItem(kind: "divider", id: "divider.26", actionId: nil, title: nil, sfSymbol: nil, items: []),
      RegistryMenuItem(kind: "action", id: "task.delete", actionId: .taskDelete, title: RegistryL10n.t("Delete"), sfSymbol: "trash", items: []),
    ]),
    RegistryMenu(id: .help, title: RegistryL10n.t("Help"), system: "help", items: [
      RegistryMenuItem(kind: "action", id: "app.help", actionId: .appHelp, title: RegistryL10n.t("Septena Help"), sfSymbol: "questionmark.circle", items: []),
      RegistryMenuItem(kind: "action", id: "app.contactSupport", actionId: .appContactSupport, title: RegistryL10n.t("Contact Support…"), sfSymbol: "paperplane", items: []),
      RegistryMenuItem(kind: "action", id: "app.keyboardShortcuts", actionId: .appKeyboardShortcuts, title: RegistryL10n.t("Keyboard Shortcuts"), sfSymbol: "info.circle", items: []),
    ]),
  ]

  static let shortcutsGeneral: [RegistryShortcutEntry] = [
    RegistryShortcutEntry(id: "app.newTask", actionId: .appNewTask, label: RegistryL10n.t("New Task"), keycaps: ["⌘", "N"], excludePlatforms: []),
    RegistryShortcutEntry(id: "app.quickAdd", actionId: .appQuickAdd, label: RegistryL10n.t("Quick Add…"), keycaps: ["⌘", "I"], excludePlatforms: []),
    RegistryShortcutEntry(id: "app.quickFind", actionId: .appQuickFind, label: RegistryL10n.t("Quick Find…"), keycaps: ["⌘", "K"], excludePlatforms: []),
    RegistryShortcutEntry(id: "app.quickFind.alt0", actionId: .appQuickFind, label: RegistryL10n.t("Quick Find…"), keycaps: ["⇧", "⌘", "F"], excludePlatforms: []),
    RegistryShortcutEntry(id: "app.goBack", actionId: .appGoBack, label: RegistryL10n.t("Back"), keycaps: ["⌘", "["], excludePlatforms: []),
    RegistryShortcutEntry(id: "app.goForward", actionId: .appGoForward, label: RegistryL10n.t("Forward"), keycaps: ["⌘", "]"], excludePlatforms: []),
    RegistryShortcutEntry(id: "app.toggleSidebar", actionId: .appToggleSidebar, label: RegistryL10n.t("Show / Hide Sidebar"), keycaps: ["⌃", "⌘", "S"], excludePlatforms: ["ios", "ipados"]),
    RegistryShortcutEntry(id: "app.settings", actionId: .appSettings, label: RegistryL10n.t("Settings…"), keycaps: ["⌘", ","], excludePlatforms: []),
    RegistryShortcutEntry(id: "app.keyboardShortcuts", actionId: .appKeyboardShortcuts, label: RegistryL10n.t("Keyboard Shortcuts"), keycaps: ["⇧", "⌘", "/"], excludePlatforms: []),
  ]
  static let shortcutsTaskList: [RegistryShortcutEntry] = [
    RegistryShortcutEntry(id: "task.editDetails", actionId: .taskEditDetails, label: RegistryL10n.t("Edit Details…"), keycaps: ["⌘", "R"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.do", actionId: .taskDo, label: RegistryL10n.t("Do"), keycaps: ["⌘", "J"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.toggleInfo", actionId: .taskToggleInfo, label: RegistryL10n.t("Show Info"), keycaps: ["⌥", "⌘", "I"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.copy", actionId: .taskCopy, label: RegistryL10n.t("Copy"), keycaps: ["⌘", "C"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.duplicate", actionId: .taskDuplicate, label: RegistryL10n.t("Duplicate"), keycaps: ["⌘", "D"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.toggleComplete", actionId: .taskToggleComplete, label: RegistryL10n.t("Mark as Complete"), keycaps: ["⌘", "↩"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.cancel", actionId: .taskCancel, label: RegistryL10n.t("Cancel Task"), keycaps: ["⌥", "⌘", "↩"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.toggleToday", actionId: .taskToggleToday, label: RegistryL10n.t("Toggle Today"), keycaps: ["⌘", "T"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.toggleStar", actionId: .taskToggleStar, label: RegistryL10n.t("Toggle Star"), keycaps: ["⌥", "⌘", "S"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.tags", actionId: .taskTags, label: RegistryL10n.t("Tags…"), keycaps: ["⇧", "⌘", "T"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.addChecklistItem", actionId: .taskAddChecklistItem, label: RegistryL10n.t("Add Checklist Item"), keycaps: ["⇧", "⌘", "C"], excludePlatforms: ["ios", "ipados"]),
    RegistryShortcutEntry(id: "task.when", actionId: .taskWhen, label: RegistryL10n.t("When…"), keycaps: ["⌘", "S"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.deadline", actionId: .taskDeadline, label: RegistryL10n.t("Deadline…"), keycaps: ["⇧", "⌘", "D"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.reminder", actionId: .taskReminder, label: RegistryL10n.t("Reminder…"), keycaps: ["⌥", "⌘", "R"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.move", actionId: .taskMove, label: RegistryL10n.t("Move…"), keycaps: ["⇧", "⌘", "M"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.move.alt0", actionId: .taskMove, label: RegistryL10n.t("Move…"), keycaps: ["⌘", "M"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.moveSuggested", actionId: .taskMoveSuggested, label: RegistryL10n.t("Move to Suggested List"), keycaps: ["⌥", "⌘", "M"], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.clearSchedule", actionId: .taskClearSchedule, label: RegistryL10n.t("Clear When"), keycaps: ["⇧", "⌘", "."], excludePlatforms: []),
    RegistryShortcutEntry(id: "task.delete", actionId: .taskDelete, label: RegistryL10n.t("Delete"), keycaps: ["⌘", "⌫"], excludePlatforms: []),
  ]
}

/// Canonical notice IDs (`registry/surfaces.json` `notices`).
enum RegistryNoticeID: String, CaseIterable, Hashable, Sendable {
  case signIn = "signIn"
  case rolledIn = "rolledIn"
  case getStarted = "getStarted"
  case trialEnd = "trialEnd"
  case secondDevice = "secondDevice"
  case weeklySweep = "weeklySweep"
  case fadedPile = "fadedPile"
  case fadeIntro = "fadeIntro"
}

/// One notice in a task list (`registry/surfaces.json` `notices`). A notice whose
/// title has a count gets a title function in `RegistryNotices` instead of `title`.
struct RegistryNotice: Sendable, Hashable, Identifiable {
  let id: RegistryNoticeID
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
  /// The `registry/plans.json` upsell this notice shows. Its title and detail
  /// come from `RegistryPlans.upsell(_:)`, never from this row.
  let upsellId: String?
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
    RegistryNotice(id: .signIn, kind: "actionNeeded", priority: 0, iconId: "notice.sign_in", sfSymbol: "person.crop.circle.badge.exclamationmark", dismissScope: "device", dismissible: true, explainerSlot: false, featureId: "sync.backend", title: RegistryL10n.t("Not signed in"), detail: RegistryL10n.t("Your changes stay on this device until you sign in."), platformDetails: ["macos": RegistryL10n.t("Your changes stay on this Mac until you sign in."), "ipados": RegistryL10n.t("Your changes stay on this iPad until you sign in."), "ios": RegistryL10n.t("Your changes stay on this iPhone until you sign in.")], primaryTitle: RegistryL10n.t("Sign in…"), upsellId: nil, steps: []),
    RegistryNotice(id: .rolledIn, kind: "info", priority: 1, iconId: "notice.rolled_in", sfSymbol: "arrow.down.circle", dismissScope: "accountDay", dismissible: true, explainerSlot: false, featureId: "lists.today", title: nil, detail: nil, platformDetails: [:], primaryTitle: nil, upsellId: nil, steps: []),
    RegistryNotice(id: .getStarted, kind: "info", priority: 2, iconId: "notice.get_started", sfSymbol: "sparkles", dismissScope: "account", dismissible: true, explainerSlot: true, featureId: "lists.today", title: RegistryL10n.t("Get started with Septena"), detail: nil, platformDetails: [:], primaryTitle: nil, upsellId: nil, steps: [RegistryNoticeStep(id: "connectAI", title: RegistryL10n.t("Connect your agent"), detail: RegistryL10n.t("Let your agent work from your list"), platformDetails: [:]), RegistryNoticeStep(id: "importTasks", title: RegistryL10n.t("Bring in your tasks"), detail: RegistryL10n.t("Import from another app"), platformDetails: [:]), RegistryNoticeStep(id: "addTask", title: RegistryL10n.t("Add your first task"), detail: RegistryL10n.t("It lands in your Inbox until you schedule or file it"), platformDetails: ["macos": RegistryL10n.t("Or press ⌃⌥Space anywhere on your Mac")])]),
    RegistryNotice(id: .trialEnd, kind: "info", priority: 1, iconId: "notice.trial_end", sfSymbol: "hourglass", dismissScope: "account", dismissible: true, explainerSlot: false, featureId: "sync.backend", title: nil, detail: nil, platformDetails: [:], primaryTitle: RegistryL10n.t("See Plus"), upsellId: "trial_end", steps: []),
    RegistryNotice(id: .secondDevice, kind: "info", priority: 1, iconId: "notice.second_device", sfSymbol: "laptopcomputer.and.iphone", dismissScope: "account", dismissible: true, explainerSlot: false, featureId: "sync.backend", title: nil, detail: nil, platformDetails: [:], primaryTitle: RegistryL10n.t("See Plus"), upsellId: "second_device", steps: []),
    RegistryNotice(id: .weeklySweep, kind: "info", priority: 3, iconId: "notice.weekly_sweep", sfSymbol: "circle.dashed", dismissScope: "accountWeek", dismissible: true, explainerSlot: false, featureId: "fade.sweep", title: nil, detail: RegistryL10n.t("Still want any of them?"), platformDetails: [:], primaryTitle: RegistryL10n.t("Review"), upsellId: nil, steps: []),
    RegistryNotice(id: .fadedPile, kind: "info", priority: 5, iconId: "notice.weekly_sweep", sfSymbol: "circle.dashed", dismissScope: "none", dismissible: false, explainerSlot: false, featureId: "lists.faded", title: RegistryL10n.t("Tasks without activity for 14 days"), detail: RegistryL10n.t("Open a task or choose Keep to bring it back, or review the list and let the rest go."), platformDetails: [:], primaryTitle: RegistryL10n.t("Review…"), upsellId: nil, steps: []),
    RegistryNotice(id: .fadeIntro, kind: "info", priority: 4, iconId: "notice.fade_intro", sfSymbol: "circle.lefthalf.filled", dismissScope: "device", dismissible: true, explainerSlot: true, featureId: "task.aging", title: RegistryL10n.t("Inactive tasks start to fade"), detail: RegistryL10n.t("Tasks fade after 14 days without activity and move to Review. A deadline or a date ahead keeps a task out. Open or edit a task to bring it back. You can turn this off in Settings."), platformDetails: [:], primaryTitle: nil, upsellId: nil, steps: []),
  ]
  static let byId: [RegistryNoticeID: RegistryNotice] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
  static func rolledInTitle(count: Int) -> String { RegistryL10n.plural("%lld tasks rolled into Today", count: count, one: "1 task rolled into Today", other: "%lld tasks rolled into Today", args: [count]) }
  static func weeklySweepTitle(count: Int) -> String { RegistryL10n.plural("%lld tasks faded this week", count: count, one: "1 task faded this week", other: "%lld tasks faded this week", args: [count]) }
}

/// Canonical prompt IDs (`registry/surfaces.json` `prompts`).
enum RegistryPromptID: String, CaseIterable, Hashable, Sendable {
  case deletePermanently = "deletePermanently"
  case emptyTrash = "emptyTrash"
  case deleteSection = "deleteSection"
  case deleteArea = "deleteArea"
  case deleteProject = "deleteProject"
  case clearLogged = "clearLogged"
  case rescheduleFixedRepeat = "rescheduleFixedRepeat"
  case disconnectAgent = "disconnectAgent"
  case changeNotSaved = "changeNotSaved"
  case agentKeyCreated = "agentKeyCreated"
  case agentReplaces = "agentReplaces"
  case scanSignInCode = "scanSignInCode"
  case cameraUnavailable = "cameraUnavailable"
  case newSection = "newSection"
  case renameSection = "renameSection"
  case newArea = "newArea"
  case renameArea = "renameArea"
  case newProject = "newProject"
  case renameProject = "renameProject"
  case renameAgent = "renameAgent"
  case nameAgent = "nameAgent"
  case newAgentKey = "newAgentKey"
  case conversationOther = "conversationOther"
  case conversationReply = "conversationReply"
  case sendBackReview = "sendBackReview"
}

/// Canonical fork-prompt option IDs (`registry/surfaces.json` `prompts.items[].options`).
enum RegistryPromptOptionID: String, CaseIterable, Hashable, Sendable {
  case exception = "exception"
  case updateRule = "updateRule"
  case none = "none"
  case agent = "agent"
}

/// Destructive and fork confirmation copy (`registry/surfaces.json` `prompts`).
struct RegistryPromptCopy: Sendable, Hashable {
  let id: RegistryPromptID
  let title: String
  let message: String
  let confirmTitle: String?
  /// Fork prompts only: the choices, in order.
  let options: [RegistryPromptOption]
}

struct RegistryPromptOption: Sendable, Hashable, Identifiable {
  let id: RegistryPromptOptionID
  let title: String
}

/// A prompt that asks for a name (`registry/surfaces.json` `prompts.text`).
struct RegistryTextPrompt: Sendable, Hashable, Identifiable {
  let id: RegistryPromptID
  let title: String
  let placeholder: String
  let confirmTitle: String
}

enum RegistryPrompts {
  static let cancelTitle: String = RegistryL10n.t("Cancel")
  static let errorTitle: String = RegistryL10n.t("Error")
  static let errorConfirmTitle: String = RegistryL10n.t("OK")
  /// Prompts with fixed copy. Prompts with counts or names are functions below.
  static let fixed: [RegistryPromptID: RegistryPromptCopy] = [
    .deleteSection: RegistryPromptCopy(id: .deleteSection, title: RegistryL10n.t("Delete this section?"), message: RegistryL10n.t("Its tasks stay in the project."), confirmTitle: RegistryL10n.t("Delete Section"), options: []),
    .rescheduleFixedRepeat: RegistryPromptCopy(id: .rescheduleFixedRepeat, title: RegistryL10n.t("Reschedule repeating task?"), message: RegistryL10n.t("Move only this task, or update the repeating schedule to the new date?"), confirmTitle: nil, options: [RegistryPromptOption(id: .exception, title: RegistryL10n.t("Only This Task")), RegistryPromptOption(id: .updateRule, title: RegistryL10n.t("Update Schedule"))]),
    .changeNotSaved: RegistryPromptCopy(id: .changeNotSaved, title: RegistryL10n.t("A change couldn’t be saved"), message: RegistryL10n.t("One edit was rolled back and is not stored. Anything you typed just now may need retyping. Later changes still save normally."), confirmTitle: RegistryL10n.t("OK"), options: []),
    .agentKeyCreated: RegistryPromptCopy(id: .agentKeyCreated, title: RegistryL10n.t("Your agent key"), message: RegistryL10n.t("Septena shows this key only once. Paste it into your script or agent. To stop the agent, disconnect it in this list."), confirmTitle: RegistryL10n.t("Copy Key"), options: []),
    .agentReplaces: RegistryPromptCopy(id: .agentReplaces, title: RegistryL10n.t("Replaces"), message: RegistryL10n.t("If this agent takes the place of one you connected before, pick it. That agent stops working."), confirmTitle: nil, options: [RegistryPromptOption(id: .none, title: RegistryL10n.t("Nothing, a new agent")), RegistryPromptOption(id: .agent, title: RegistryL10n.t("An agent below"))]),
    .scanSignInCode: RegistryPromptCopy(id: .scanSignInCode, title: RegistryL10n.t("Scan a sign-in code"), message: RegistryL10n.t("Point the camera at the QR code on the other screen."), confirmTitle: RegistryL10n.t("Scan Code"), options: []),
    .cameraUnavailable: RegistryPromptCopy(id: .cameraUnavailable, title: RegistryL10n.t("Septena can’t use the camera"), message: RegistryL10n.t("Allow camera access for Septena in Settings, or enter the code instead."), confirmTitle: nil, options: []),
  ]
  static let text: [RegistryPromptID: RegistryTextPrompt] = [
    .newSection: RegistryTextPrompt(id: .newSection, title: RegistryL10n.t("New Section"), placeholder: RegistryL10n.t("Section name"), confirmTitle: RegistryL10n.t("Add")),
    .renameSection: RegistryTextPrompt(id: .renameSection, title: RegistryL10n.t("Rename Section"), placeholder: RegistryL10n.t("Section name"), confirmTitle: RegistryL10n.t("Rename")),
    .newArea: RegistryTextPrompt(id: .newArea, title: RegistryL10n.t("New Area"), placeholder: RegistryL10n.t("Area name"), confirmTitle: RegistryL10n.t("Create")),
    .renameArea: RegistryTextPrompt(id: .renameArea, title: RegistryL10n.t("Rename Area"), placeholder: RegistryL10n.t("Area name"), confirmTitle: RegistryL10n.t("Rename")),
    .newProject: RegistryTextPrompt(id: .newProject, title: RegistryL10n.t("New Project"), placeholder: RegistryL10n.t("Project name"), confirmTitle: RegistryL10n.t("Create")),
    .renameProject: RegistryTextPrompt(id: .renameProject, title: RegistryL10n.t("Rename Project"), placeholder: RegistryL10n.t("Project name"), confirmTitle: RegistryL10n.t("Rename")),
    .renameAgent: RegistryTextPrompt(id: .renameAgent, title: RegistryL10n.t("Rename Agent"), placeholder: RegistryL10n.t("Agent name"), confirmTitle: RegistryL10n.t("Rename")),
    .nameAgent: RegistryTextPrompt(id: .nameAgent, title: RegistryL10n.t("Name this agent"), placeholder: RegistryL10n.t("Agent name"), confirmTitle: RegistryL10n.t("Save")),
    .newAgentKey: RegistryTextPrompt(id: .newAgentKey, title: RegistryL10n.t("New Agent Key"), placeholder: RegistryL10n.t("Agent name"), confirmTitle: RegistryL10n.t("Create")),
    .conversationOther: RegistryTextPrompt(id: .conversationOther, title: RegistryL10n.t("Other…"), placeholder: RegistryL10n.t("Type your answer"), confirmTitle: RegistryL10n.t("Send")),
    .conversationReply: RegistryTextPrompt(id: .conversationReply, title: RegistryL10n.t("Reply…"), placeholder: RegistryL10n.t("Reply to thread"), confirmTitle: RegistryL10n.t("Send")),
    .sendBackReview: RegistryTextPrompt(id: .sendBackReview, title: RegistryL10n.t("Send back for another pass"), placeholder: RegistryL10n.t("What needs another pass?"), confirmTitle: RegistryL10n.t("Send back")),
  ]
  static func tasksPhrase(count: Int) -> String { RegistryL10n.plural("%lld tasks", count: count, one: "1 task", other: "%lld tasks", args: [count]) }
  static func projectsPhrase(count: Int) -> String { RegistryL10n.plural("%lld projects", count: count, one: "1 project", other: "%lld projects", args: [count]) }
  static func agentsPhrase(count: Int) -> String { RegistryL10n.plural("%lld agents", count: count, one: "1 agent", other: "%lld agents", args: [count]) }
  static func waitingDaysPhrase(count: Int) -> String { RegistryL10n.plural("%lld days", count: count, one: "1 day", other: "%lld days", args: [count]) }
  static func deletePermanently(count: Int) -> RegistryPromptCopy {
    RegistryPromptCopy(id: .deletePermanently, title: RegistryL10n.plural("Delete %lld tasks permanently?", count: count, one: "Delete this task permanently?", other: "Delete %lld tasks permanently?", args: [count]), message: RegistryL10n.t("You can’t undo this."), confirmTitle: RegistryL10n.t("Delete Permanently"), options: [])
  }
  static func emptyTrash(count: Int) -> RegistryPromptCopy {
    RegistryPromptCopy(id: .emptyTrash, title: RegistryL10n.plural("Delete all %lld deleted tasks permanently?", count: count, one: "Delete 1 deleted task permanently?", other: "Delete all %lld deleted tasks permanently?", args: [count]), message: RegistryL10n.t("You can’t undo this."), confirmTitle: RegistryL10n.t("Empty Trash"), options: [])
  }
  static func deleteArea(name: String, projects: Int, tasks: Int) -> RegistryPromptCopy {
    let name = name.isEmpty ? RegistryL10n.t("Area") : name
    let projectPhrase = projectsPhrase(count: projects)
    let taskPhrase = tasksPhrase(count: tasks)
    if projects == 0 && tasks == 0 { return RegistryPromptCopy(id: .deleteArea, title: RegistryL10n.format("Delete “%@”?", english: "Delete “%@”?", args: [name]), message: RegistryL10n.t("You can undo this."), confirmTitle: RegistryL10n.t("Delete"), options: []) }
    if projects == 0 { return RegistryPromptCopy(id: .deleteArea, title: RegistryL10n.format("Delete “%@” and its %@?", english: "Delete “%@” and its %@?", args: [name, taskPhrase]), message: RegistryL10n.t("The tasks move to Recently Deleted. You can undo this."), confirmTitle: RegistryL10n.t("Delete"), options: []) }
    if tasks == 0 { return RegistryPromptCopy(id: .deleteArea, title: RegistryL10n.format("Delete “%@” and its %@? (projects only)", english: "Delete “%@” and its %@?", args: [name, projectPhrase]), message: RegistryL10n.t("You can undo this."), confirmTitle: RegistryL10n.t("Delete"), options: []) }
    return RegistryPromptCopy(id: .deleteArea, title: RegistryL10n.format("Delete “%@”, its %@ and %@?", english: "Delete “%@”, its %@ and %@?", args: [name, projectPhrase, taskPhrase]), message: RegistryL10n.t("The tasks move to Recently Deleted. You can undo this."), confirmTitle: RegistryL10n.t("Delete"), options: [])
  }
  static func deleteProject(name: String, tasks: Int) -> RegistryPromptCopy {
    let name = name.isEmpty ? RegistryL10n.t("Project") : name
    let taskPhrase = tasksPhrase(count: tasks)
    if tasks == 0 { return RegistryPromptCopy(id: .deleteProject, title: RegistryL10n.format("Delete “%@”?", english: "Delete “%@”?", args: [name]), message: RegistryL10n.t("You can undo this."), confirmTitle: RegistryL10n.t("Delete"), options: []) }
    return RegistryPromptCopy(id: .deleteProject, title: RegistryL10n.format("Delete “%@” and its %@?", english: "Delete “%@” and its %@?", args: [name, taskPhrase]), message: RegistryL10n.t("The tasks move to Recently Deleted. You can undo this."), confirmTitle: RegistryL10n.t("Delete"), options: [])
  }
  static func clearLogged(count: Int, name: String) -> RegistryPromptCopy {
    RegistryPromptCopy(id: .clearLogged, title: RegistryL10n.plural("Clear %lld logged items from “%@”?", count: count, one: "Clear 1 logged item from “%2$@”?", other: "Clear %lld logged items from “%@”?", args: [count, name]), message: RegistryL10n.t("Cleared items move to Recently Deleted. You can undo this."), confirmTitle: RegistryL10n.t("Clear"), options: [])
  }
  static func disconnectAgent(name: String) -> RegistryPromptCopy {
    RegistryPromptCopy(id: .disconnectAgent, title: RegistryL10n.format("Disconnect %@?", english: "Disconnect %@?", args: [name]), message: RegistryL10n.format("%@ can no longer read or change your tasks. To use it again, connect it again.", english: "%@ can no longer read or change your tasks. To use it again, connect it again.", args: [name]), confirmTitle: RegistryL10n.t("Disconnect"), options: [])
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
  static func importedReminders(count: Int) -> String { RegistryL10n.plural("%lld reminders moved to the Inbox", count: count, one: "Reminder moved to the Inbox", other: "%lld reminders moved to the Inbox", args: [count]) }
}

/// Canonical task attribute IDs (`registry/surfaces.json` `taskAttributes`).
enum RegistryTaskAttributeID: String, CaseIterable, Hashable, Sendable {
  case paste = "paste"
  case notes = "notes"
  case when = "when"
  case deadline = "deadline"
  case reminder = "reminder"
  case `repeat` = "repeat"
  case star = "star"
  case list = "list"
  case tags = "tags"
  case checklist = "checklist"
  case attachments = "attachments"
  case discuss = "discuss"
  case history = "history"
}

/// One task attribute (`registry/surfaces.json` `taskAttributes`): a composer
/// pill, an inspector row and a picker title. `surfaceTier` `field` is an
/// always-visible field (notes), not a pill. `chip` is a transient composer
/// chip shown only on a blank new task (Paste), not a pill. `editOnly` needs a saved task.
struct RegistryTaskAttribute: Sendable, Hashable, Identifiable {
  let id: RegistryTaskAttributeID
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
  /// The attribute's symbol in its state: the filled variant while set or on.
  func sfSymbol(on: Bool) -> String { RegistryIcons.sfSymbol(for: iconId, on: on) }
  /// The attribute shows on `platform` when its capability ships (ADR 0015).
  func applies(to platform: String) -> Bool { RegistryCapabilities.isAvailable(featureId, on: platform) }
}

enum RegistrySurfaces {
  static let taskAttributes: [RegistryTaskAttribute] = [
    RegistryTaskAttribute(id: .paste, label: RegistryL10n.t("Paste"), iconId: "action.paste", sfSymbol: "doc.on.clipboard", commitContract: "pickCommits", surfaceTier: "chip", featureId: "capture.quick-entry", editOnly: false, workingLabel: nil),
    RegistryTaskAttribute(id: .notes, label: RegistryL10n.t("Notes"), iconId: "action.notes", sfSymbol: "text.alignleft", commitContract: "closeCommits", surfaceTier: "field", featureId: "task.notes", editOnly: false, workingLabel: nil),
    RegistryTaskAttribute(id: .when, label: RegistryL10n.t("When"), iconId: "action.when", sfSymbol: "calendar", commitContract: "pickCommits", surfaceTier: "popover", featureId: "task.when-deadline", editOnly: false, workingLabel: nil),
    RegistryTaskAttribute(id: .deadline, label: RegistryL10n.t("Deadline"), iconId: "action.deadline", sfSymbol: "flag", commitContract: "pickCommits", surfaceTier: "popover", featureId: "task.when-deadline", editOnly: false, workingLabel: nil),
    RegistryTaskAttribute(id: .reminder, label: RegistryL10n.t("Remind"), iconId: "action.reminder", sfSymbol: "bell", commitContract: "pickCommits", surfaceTier: "popover", featureId: "task.alerts", editOnly: false, workingLabel: nil),
    RegistryTaskAttribute(id: .repeat, label: RegistryL10n.t("Repeat"), iconId: "action.repeat", sfSymbol: "arrow.clockwise", commitContract: "closeCommits", surfaceTier: "popover", featureId: "task.repeat", editOnly: false, workingLabel: nil),
    RegistryTaskAttribute(id: .star, label: RegistryL10n.t("Star"), iconId: "action.star", sfSymbol: "star", commitContract: "pickCommits", surfaceTier: "inline", featureId: "lists.starred", editOnly: false, workingLabel: nil),
    RegistryTaskAttribute(id: .list, label: RegistryL10n.t("List"), iconId: "action.move", sfSymbol: "folder", commitContract: "pickCommits", surfaceTier: "popover", featureId: "places.projects", editOnly: false, workingLabel: nil),
    RegistryTaskAttribute(id: .tags, label: RegistryL10n.t("Tags"), iconId: "action.tag", sfSymbol: "tag", commitContract: "pickCommits", surfaceTier: "popover", featureId: "task.tags", editOnly: true, workingLabel: nil),
    RegistryTaskAttribute(id: .checklist, label: RegistryL10n.t("Checklist"), iconId: "action.checklist", sfSymbol: "checklist", commitContract: "pickCommits", surfaceTier: "inline", featureId: "task.checklists", editOnly: true, workingLabel: nil),
    RegistryTaskAttribute(id: .attachments, label: RegistryL10n.t("Attachments"), iconId: "action.attachment", sfSymbol: "paperclip", commitContract: "pickCommits", surfaceTier: "inline", featureId: "task.attachments", editOnly: true, workingLabel: nil),
    RegistryTaskAttribute(id: .discuss, label: RegistryL10n.t("Discuss"), iconId: "action.discuss", sfSymbol: "bubble.left.and.bubble.right", commitContract: "closeCommits", surfaceTier: "inline", featureId: "ai.discuss", editOnly: true, workingLabel: RegistryL10n.t("Thinking…")),
    RegistryTaskAttribute(id: .history, label: RegistryL10n.t("History"), iconId: "action.history", sfSymbol: "clock.arrow.circlepath", commitContract: "pickCommits", surfaceTier: "inline", featureId: "task.history", editOnly: true, workingLabel: nil),
  ]
  /// The pills that show on `platform`, in rail order (every attribute except
  /// fields and chips, whose capability ships there).
  static func taskAttributePills(on platform: String) -> [RegistryTaskAttribute] {
    taskAttributes.filter { $0.isPill && $0.applies(to: platform) }
  }
  /// The attribute with `id`.
  static func taskAttribute(_ id: RegistryTaskAttributeID) -> RegistryTaskAttribute {
    guard let a = taskAttributes.first(where: { $0.id == id }) else { preconditionFailure("unknown task attribute \(id)") }
    return a
  }
  /// Count text for a pill value (`countLabel`), or nil when the attribute has none.
  static func taskAttributeCount(_ id: RegistryTaskAttributeID, count: Int) -> String? {
    switch id {
    case .tags: return RegistryL10n.plural("%lld tags", count: count, one: "%lld tag", other: "%lld tags", args: [count])
    case .attachments: return RegistryL10n.plural("%lld files", count: count, one: "%lld file", other: "%lld files", args: [count])
    default: return nil
    }
  }
  /// The task page (`surfaces.json` `taskPage`, ADR 0029) in block order.
  static let taskPageBlocks: [RegistryTaskPageBlock] = [
    RegistryTaskPageBlock(id: "taskPage.header", kind: .header, depths: [.inline, .page, .review], label: nil, attributeId: nil, featureId: "lists.today", editOnly: false),
    RegistryTaskPageBlock(id: "taskPage.notes", kind: .notes, depths: [.inline, .page, .review], label: RegistryL10n.t("Notes"), attributeId: .notes, featureId: "task.notes", editOnly: false),
    RegistryTaskPageBlock(id: "taskPage.attributes", kind: .attributes, depths: [.inline, .page], label: nil, attributeId: nil, featureId: "lists.today", editOnly: false),
    RegistryTaskPageBlock(id: "taskPage.checklist", kind: .checklist, depths: [.inline, .page], label: RegistryL10n.t("Checklist"), attributeId: .checklist, featureId: "task.checklists", editOnly: true),
    RegistryTaskPageBlock(id: "taskPage.attachments", kind: .attachments, depths: [.inline, .page], label: RegistryL10n.t("Attachments"), attributeId: .attachments, featureId: "task.attachments", editOnly: true),
    RegistryTaskPageBlock(id: "taskPage.references", kind: .references, depths: [.inline, .page], label: RegistryL10n.t("References"), attributeId: nil, featureId: "task.references", editOnly: true),
    RegistryTaskPageBlock(id: "taskPage.conversation", kind: .conversation, depths: [.page, .review], label: RegistryL10n.t("Conversation"), attributeId: nil, featureId: "ai.discuss", editOnly: true),
    RegistryTaskPageBlock(id: "taskPage.provenance", kind: .provenance, depths: [.page, .review], label: RegistryL10n.t("Added by"), attributeId: nil, featureId: "task.provenance", editOnly: true),
    RegistryTaskPageBlock(id: "taskPage.history", kind: .history, depths: [.page], label: RegistryL10n.t("History"), attributeId: .history, featureId: "task.history", editOnly: true),
  ]
  /// The blocks a host renders at `depth` on `platform`, in order. A create
  /// (no saved task yet) passes `isEditing: false` to drop `editOnly` blocks.
  static func taskPageBlocks(_ depth: RegistryTaskPageDepth, on platform: String, isEditing: Bool = true) -> [RegistryTaskPageBlock] {
    taskPageBlocks.filter { $0.depths.contains(depth) && $0.applies(to: platform) && (isEditing || !$0.editOnly) }
  }
  /// The rows under the date board's day strip, in order (`surfaces.json` `taskDateBoard`).
  static let dateBoardRows: [RegistryDateBoardRow] = [
    RegistryDateBoardRow(id: "dateBoard.calendar", kind: .calendar, group: .pick, label: RegistryL10n.t("Pick another date"), attributeLabels: [:], sfSymbol: "calendar", attributes: [.when, .deadline], featureId: "task.when-deadline"),
    RegistryDateBoardRow(id: "dateBoard.time", kind: .time, group: .refine, label: RegistryL10n.t("Add time"), attributeLabels: [:], sfSymbol: "clock", attributes: [.when], featureId: "task.when-deadline"),
    RegistryDateBoardRow(id: "dateBoard.repeatRule", kind: .repeatRule, group: .refine, label: RegistryL10n.t("Repeat…"), attributeLabels: [:], sfSymbol: "arrow.clockwise", attributes: [.when], featureId: "task.repeat"),
    RegistryDateBoardRow(id: "dateBoard.clear", kind: .clear, group: .remove, label: RegistryL10n.t("Clear (Anytime)"), attributeLabels: [.deadline: RegistryL10n.t("No Deadline")], sfSymbol: "xmark.circle", attributes: [.when, .deadline], featureId: "task.when-deadline"),
  ]
  static func dateBoardRows(for attribute: RegistryDateBoardAttribute, on platform: String) -> [RegistryDateBoardRow] {
    dateBoardRows.filter { $0.applies(to: attribute, on: platform) }
  }
  /// The date board opens with the start cell focused (`taskDateBoard.openFocus`).
  /// False: no cell is focused until the first arrow key or the pointer.
  static let dateBoardFocusesOnOpen: Bool = false
  static let taskDateBoardOverdueLabel: String = RegistryL10n.t("Overdue")
  /// The calendar row when the task has a date past the day strip.
  static func dateBoardCalendarLabel(date: String) -> String { RegistryL10n.format("Pick another date (%@)", english: "Pick another date (%@)", args: [date]) }
  /// The word for the day after today, in date labels.
  static let tomorrowLabel: String = RegistryL10n.t("Tomorrow")
  /// Provenance block (`taskPage.provenance`): the name a task you added shows as,
  /// the name for an agent row with no `sourceClient`, and the agent glyph.
  static let provenanceSelfLabel: String = RegistryL10n.t("You")
  static let provenanceAgentFallbackName: String = "Claude"
  static let provenanceAgentSymbol: String = "text.bubble.badge.sparkles"
  /// Agent prompt copy (`taskPage.conversation`, docs/AGENT_PROMPT_SPEC.md).
  static let agentPromptAskKicker: String = RegistryL10n.t("Your agent asks")
  static let agentPromptReviewKicker: String = RegistryL10n.t("Review requested")
  static let agentPromptReviewFallback: String = RegistryL10n.t("Ready for review")
  static let agentPromptAcceptedLabel: String = RegistryL10n.t("Accepted")
  /// The weekly fade sweep's title (`surfaces.json` `fadeSweep`).
  static let fadeSweepTitle: String = RegistryL10n.t("Faded Tasks")
  /// The sweep's closing line after Let the rest go (#711, a permission line).
  static let fadeSweepLetGoTitle: String = RegistryL10n.t("It can wait. The rest is in your Logbook.")
  /// Quick Find copy (`surfaces.json` `quickFind`).
  static let quickFindPlaceholder: String = RegistryL10n.t("Search tasks, projects, areas…")
  static let quickFindCommandPlaceholder: String = RegistryL10n.t("Search or run a command…")
  static let quickFindEmptyTitle: String = RegistryL10n.t("Search Tasks")
  static let quickFindEmptyDetail: String = RegistryL10n.t("Find any task, project, or area.")
  static let quickFindCompletedLabel: String = RegistryL10n.t("Completed")
  static let checklistAddItem: String = RegistryL10n.t("Add item")
  static let checklistOnList: String = RegistryL10n.t("On list")
  static let checklistChecked: String = RegistryL10n.t("Checked")
  static let checklistMoveToGroup: String = RegistryL10n.t("Move to group")
  static let checklistUngrouped: String = RegistryL10n.t("Ungrouped")
  static func checklistAddItemToGroup(group: String) -> String { RegistryL10n.format("Add item to %@", english: "Add item to %@", args: [group]) }
  /// The last add-field suggestion: Add "<typed text>" (docs/PROJECT_CHECKLIST_SPEC.md).
  static func checklistAddTyped(title: String) -> String { RegistryL10n.format("Add “%@”", english: "Add “%@”", args: [title]) }
  static let checklistProjectType: String = RegistryL10n.t("Project type")
  static let standardProjectTitle: String = RegistryL10n.t("Project")
  static let checklistProjectTitle: String = RegistryL10n.t("Checklist")
  /// The heading title for a core grocery group key (`checklistProjects.groups`), nil for an unknown key.
  static func checklistGroupTitle(_ key: String) -> String? {
    switch key {
    case "produce": return RegistryL10n.t("Produce")
    case "dairy": return RegistryL10n.t("Dairy")
    case "bakery": return RegistryL10n.t("Bakery")
    case "meatSeafood": return RegistryL10n.t("Meat & Seafood")
    case "pantry": return RegistryL10n.t("Pantry")
    case "frozen": return RegistryL10n.t("Frozen")
    default: return nil
    }
  }
  /// Sort By copy (`surfaces.json` `listSort`, docs/LIST_SORT_SPEC.md).
  static let listSortMenuTitle: String = RegistryL10n.t("Sort By")
  static let listSortSymbol: String = "arrow.up.arrow.down"
  /// "Sorted by {sort}": the list header line when the sort is not Manual.
  static func listSortSortedBy(sort: String) -> String { RegistryL10n.format("Sorted by %@", english: "Sorted by %@", args: [sort]) }
  /// The block of `kind`. Each kind appears exactly once (the generator checks it).
  static func taskPageBlock(_ kind: RegistryTaskPageBlockKind) -> RegistryTaskPageBlock {
    guard let b = taskPageBlocks.first(where: { $0.kind == kind }) else { preconditionFailure("no task page block \(kind)") }
    return b
  }
}

/// The attributes that the date board edits.
enum RegistryDateBoardAttribute: String, Sendable, Hashable {
  case when
  case deadline
}

/// The closed set of date board rows. Each platform writes one handler per kind.
enum RegistryDateBoardRowKind: String, Sendable, Hashable {
  case calendar
  case time
  case repeatRule
  case clear
}

/// The date board's row groups, in order. The day strip opens `pick`; a divider separates groups.
enum RegistryDateBoardGroup: String, Sendable, Hashable {
  case pick
  case refine
  case remove
}

/// One row under the date board's day strip (`surfaces.json` `taskDateBoard.rows`).
struct RegistryDateBoardRow: Sendable, Hashable, Identifiable {
  let id: String
  let kind: RegistryDateBoardRowKind
  let group: RegistryDateBoardGroup
  let label: String
  /// Attribute → label that replaces `label` in that attribute's picker.
  let attributeLabels: [RegistryDateBoardAttribute: String]
  let sfSymbol: String
  let attributes: [RegistryDateBoardAttribute]
  let featureId: String
  func label(for attribute: RegistryDateBoardAttribute) -> String { attributeLabels[attribute] ?? label }
  /// The row shows in `attribute`'s picker on `platform` when its capability ships there (ADR 0015).
  func applies(to attribute: RegistryDateBoardAttribute, on platform: String) -> Bool {
    attributes.contains(attribute) && RegistryCapabilities.isAvailable(featureId, on: platform)
  }
}

/// The closed set of task page block kinds (ADR 0029). Each platform writes one renderer per kind.
enum RegistryTaskPageBlockKind: String, Sendable, Hashable, CaseIterable {
  case header
  case notes
  case attributes
  case checklist
  case attachments
  case references
  case conversation
  case provenance
  case history
}

/// Where a task page block shows: `inline` (the quick edit in the row), `page` (the full task page), or `review` (the page of a task waiting for the user to accept it).
enum RegistryTaskPageDepth: String, Sendable, Hashable {
  case inline
  case page
  case review
}

/// One block of the task page (`surfaces.json` `taskPage.blocks`). `label` is the
/// section heading (its own, or its attribute's); nil for header, notes and attributes.
struct RegistryTaskPageBlock: Sendable, Hashable, Identifiable {
  let id: String
  let kind: RegistryTaskPageBlockKind
  let depths: [RegistryTaskPageDepth]
  let label: String?
  let attributeId: RegistryTaskAttributeID?
  let featureId: String
  let editOnly: Bool
  /// The block shows on `platform` when its capability ships there (ADR 0015).
  func applies(to platform: String) -> Bool { RegistryCapabilities.isAvailable(featureId, on: platform) }
}

/// The label and the symbol of one reference kind (`surfaces.json` `taskReferences.kinds`).
struct RegistryTaskReferenceKind: Sendable, Hashable {
  let id: String
  let label: String
  let sfSymbol: String
}

/// Task references (`surfaces.json` `taskReferences`, docs/TASK_REFERENCES_SPEC.md §8).
enum RegistryTaskReferences {
  static let kinds: [RegistryTaskReferenceKind] = [
    RegistryTaskReferenceKind(id: "email", label: RegistryL10n.t("Email"), sfSymbol: "envelope"),
    RegistryTaskReferenceKind(id: "thread", label: RegistryL10n.t("Email thread"), sfSymbol: "envelope"),
    RegistryTaskReferenceKind(id: "event", label: RegistryL10n.t("Calendar event"), sfSymbol: "calendar"),
    RegistryTaskReferenceKind(id: "issue", label: RegistryL10n.t("GitHub issue"), sfSymbol: "smallcircle.filled.circle"),
    RegistryTaskReferenceKind(id: "task", label: RegistryL10n.t("Task"), sfSymbol: "checkmark.square"),
    RegistryTaskReferenceKind(id: "door", label: RegistryL10n.t("Starlings record"), sfSymbol: "arrow.up.right.square"),
    RegistryTaskReferenceKind(id: "url", label: RegistryL10n.t("Web page"), sfSymbol: "globe"),
    RegistryTaskReferenceKind(id: "file", label: RegistryL10n.t("File"), sfSymbol: "doc"),
  ]
  /// A kind this build does not know.
  static let otherKind: RegistryTaskReferenceKind = RegistryTaskReferenceKind(id: "", label: RegistryL10n.t("Reference"), sfSymbol: "link")
  static func kind(_ id: String) -> RegistryTaskReferenceKind { kinds.first { $0.id == id } ?? otherKind }
  /// The label of a role that shows one, by role.
  static let roleLabels: [String: String] = ["blocked_by": RegistryL10n.t("Blocked by"), "follow_up": RegistryL10n.t("Follow-up to")]
  static func open(name: String) -> String { RegistryL10n.format("Open %@", english: "Open %@", args: [name]) }
  static func createdFrom(name: String) -> String { RegistryL10n.format("Created from %@", english: "Created from %@", args: [name]) }
  static func limitReached(count: Int) -> String { RegistryL10n.format("This task already has %lld references.", english: "This task already has %lld references.", args: [count]) }
  static func suggestion(name: String) -> String { RegistryL10n.format("Add %@ as a reference", english: "Add %@ as a reference", args: [name]) }
  static func alsoIn(name: String) -> String { RegistryL10n.format("Also in %@", english: "Also in %@", args: [name]) }
  static let addPlaceholder: String = RegistryL10n.t("Paste a link")
  static let addConfirmTitle: String = RegistryL10n.t("Add")
  static let offersTitle: String = RegistryL10n.t("Links in this task")
  static let invalidMessage: String = RegistryL10n.t("Septena can’t add this. Paste a web link or a mail link.")
  static let failedMessage: String = RegistryL10n.t("Couldn’t add the reference.")
  static let alreadyTaskTitle: String = RegistryL10n.t("Already a task")
  /// The most links of one task's title and notes that show as suggestions.
  static let maxSuggestions = 3
}

/// Do: one task now (`registry/surfaces.json` `doing`, docs/DO_SPEC.md §3 to §5).
enum RegistryDoing {
  /// The lengths offered, in minutes.
  static let lengths: [Int] = [10, 25, 50]
  static let lastTimeTitle: String = RegistryL10n.t("Where you stopped")
  static let firstStepTitle: String = RegistryL10n.t("What’s the first step?")
  static let lengthTitle: String = RegistryL10n.t("Length")
  static let noLengthTitle: String = RegistryL10n.t("No length")
  static let stopNoteTitle: String = RegistryL10n.t("Where did you stop?")
  static let stopNoteSaveTitle: String = RegistryL10n.t("Save")
  static let stopNoteSkipTitle: String = RegistryL10n.t("Skip")
  static let openExitLabel: String = RegistryL10n.t("Doing now")
  static func lengthOption(count: Int) -> String { RegistryL10n.format("%lld min", english: "%lld min", args: [count]) }
  static func notice(title: String) -> String { RegistryL10n.format("Doing %@", english: "Doing %@", args: [title]) }
  static func stale(title: String) -> String { RegistryL10n.format("Still on %@?", english: "Still on %@?", args: [title]) }
  static func plannedEnd(count: Int) -> String { RegistryL10n.plural("%lld minutes are up.", count: count, one: "1 minute is up.", other: "%lld minutes are up.", args: [count]) }
  static func needsYou(count: Int) -> String { RegistryL10n.plural("%lld things need you", count: count, one: "1 thing needs you", other: "%lld things need you", args: [count]) }
  /// The label of an exit (`doExit`) in the history.
  static let exitLabels: [String: String] = ["done": RegistryL10n.t("Done"), "stopped": RegistryL10n.t("Stopped for now"), "later": RegistryL10n.t("Moved to later"), "replaced": RegistryL10n.t("Switched to another task"), "closed": RegistryL10n.t("Ended")]
}

/// Waiting on a person (`registry/surfaces.json` `waiting`, docs/REVIEW_SPEC.md §6).
enum RegistryWaiting {
  static func label(name: String) -> String { RegistryL10n.format("Waiting on %@", english: "Waiting on %@", args: [name]) }
  static let sheetTitle: String = RegistryL10n.t("Waiting On")
  static let namePlaceholder: String = RegistryL10n.t("Name")
  static let confirmTitle: String = RegistryL10n.t("Save")
  static let checkBackTitle: String = RegistryL10n.t("Check back")
  static let noCheckBackTitle: String = RegistryL10n.t("No date")
  /// The check-back date Waiting On… offers, in days from today.
  static let defaultCheckBackDays = 7
}

/// The notes on a project's or an area's page (`registry/surfaces.json` `placeNotes`).
enum RegistryPlaceNotes {
  /// Lines of the folded notes.
  static let previewLines = 3
  static let showMoreTitle: String = RegistryL10n.t("Show more")
  static let showLessTitle: String = RegistryL10n.t("Show less")
}

/// A button of the phone top bar (`registry/surfaces.json` `topBar`).
enum RegistryTopBarItem: String {
  case settings, back, more, star, search
}

/// The phone top bar: the buttons each screen shows, in order, as groups (`registry/surfaces.json` `topBar`).
enum RegistryTopBar {
  enum Screen { case listsHome, list }
  static func leading(_ screen: Screen) -> [[RegistryTopBarItem]] {
    switch screen {
    case .listsHome: return [[.settings]]
    case .list: return [[.back]]
    }
  }
  static func trailing(_ screen: Screen) -> [[RegistryTopBarItem]] {
    switch screen {
    case .listsHome: return [[.more], [.search]]
    case .list: return [[.more, .star], [.search]]
    }
  }
}

/// Shared projects (`registry/surfaces.json` `sharing`).
enum RegistrySharing {
  static let title: String = RegistryL10n.t("Share Project")
  static let intro: String = RegistryL10n.t("Members see and edit this project's tasks, sections, deadlines and notes. Files, reminders and agent conversations stay private, and everyone keeps their own Today and When.")
  static let name: String = RegistryL10n.t("Your name")
  static let start: String = RegistryL10n.t("Share Project")
  static let members: String = RegistryL10n.t("Members")
  static let owner: String = RegistryL10n.t("Owner")
  static let you: String = RegistryL10n.t("You")
  static let invite: String = RegistryL10n.t("Invite Someone")
  static let inviteNote: String = RegistryL10n.t("Each link works for one person and lasts 7 days.")
  static let invites: String = RegistryL10n.t("Unused invites")
  static let expires: String = RegistryL10n.t("Expires")
  static let revoke: String = RegistryL10n.t("Revoke")
  static let remove: String = RegistryL10n.t("Remove")
  static let stop: String = RegistryL10n.t("Stop Sharing")
  static let stopDetail: String = RegistryL10n.t("The other members lose this project. You keep it and its tasks.")
  static let leave: String = RegistryL10n.t("Leave Project")
  static let leaveDetail: String = RegistryL10n.t("The project leaves your account. Everyone else keeps it.")
  static let joinTitle: String = RegistryL10n.t("Join a Shared Project")
  static let joinLink: String = RegistryL10n.t("Invite link")
  static let joinDetail: String = RegistryL10n.t("Joining is free.")
  static let sharedBy: String = RegistryL10n.t("Shared by")
  static let join: String = RegistryL10n.t("Join")
  static let invalid: String = RegistryL10n.t("This invite no longer works. Ask for a new link.")
  static let full: String = RegistryL10n.t("This project has no room for another member or invite.")
  static let signInFirst: String = RegistryL10n.t("Sign in to Septena first.")
  static let failed: String = RegistryL10n.t("Could not reach Septena.")
  static let nobody: String = RegistryL10n.t("Nobody")
}

/// Sign-in by device approval (`registry/surfaces.json` `deviceSignIn`).
enum RegistryDeviceSignIn {
  static let title: String = RegistryL10n.t("Sign in to Septena")
  static let intro: String = RegistryL10n.t("Use a device where Septena is already signed in.")
  static let start: String = RegistryL10n.t("Get a sign-in code")
  static let approve: String = RegistryL10n.t("On another device where you are signed in, open Septena and go to Settings ▸ Account ▸ Approve a sign-in. Tap Scan Code and point the camera at this screen, or enter this code:")
  static let lifetime: String = RegistryL10n.t("The code works for 10 minutes. After you approve it, this screen continues by itself.")
  static let expired: String = RegistryL10n.t("The code expired.")
  static let unreachable: String = RegistryL10n.t("Could not reach Septena.")
  static let retry: String = RegistryL10n.t("Get a new code")
}

/// The question before a sign-in replaces another account's tasks (`registry/surfaces.json` `accountSwitch`).
enum RegistryAccountSwitch {
  static let title: String = RegistryL10n.t("Replace the tasks on this device?")
  static let body: String = RegistryL10n.t("You signed in with a different account. The tasks on this device belong to the account you used before. They are removed from this device, and this account’s tasks take their place.")
  static let tasksOne: String = RegistryL10n.t("1 task is on this device.")
  static let tasksOther: String = RegistryL10n.t("{count} tasks are on this device.")
  static let unsentOne: String = RegistryL10n.t("1 change was not sent yet and will be lost.")
  static let unsentOther: String = RegistryL10n.t("{count} changes were not sent yet and will be lost.")
  static let export: String = RegistryL10n.t("Export a Backup First")
  static let replace: String = RegistryL10n.t("Replace")
  static let cancel: String = RegistryL10n.t("Cancel")
}

/// Contact Support's screen (`registry/surfaces.json` `support`, ADR 0054).
enum RegistrySupport {
  static let title: String = RegistryL10n.t("Contact Support")
  static let helpHint: String = RegistryL10n.t("Most answers are in Help.")
  static let helpLink: String = RegistryL10n.t("Open Help")
  static let messageLabel: String = RegistryL10n.t("Message")
  static let messagePlaceholder: String = RegistryL10n.t("What happened, and what did you expect?")
  static let emailFieldLabel: String = RegistryL10n.t("Email")
  static let emailDetail: String = RegistryL10n.t("We need your email to reply.")
  static let diagnosticsLabel: String = RegistryL10n.t("Include diagnostics")
  static let diagnosticsDetail: String = RegistryL10n.t("Adds your device, Septena version and sync status. It never includes your tasks.")
  static let send: String = RegistryL10n.t("Send")
  static let sending: String = RegistryL10n.t("Sending…")
  static let sent: String = RegistryL10n.t("Sent. The reply shows here.")
  static let sendFailed: String = RegistryL10n.t("Couldn't send your message.")
  static let sendAgain: String = RegistryL10n.t("Send Again")
  static let noMessages: String = RegistryL10n.t("No messages yet.")
  static let fromYou: String = RegistryL10n.t("You")
  static let fromSeptena: String = RegistryL10n.t("Septena")
  static let emailRequired: String = RegistryL10n.t("Enter your email so we can reply.")
  static let tooManyMessages: String = RegistryL10n.t("Too many messages. Try again later.")
  static let unreadReply: String = RegistryL10n.t("New reply")
  static let closeTitle: String = RegistryL10n.t("Done")
}

/// Canonical first-run step IDs (`registry/surfaces.json` `firstRun.steps`).
enum RegistryFirstRunStepID: String, CaseIterable, Hashable, Sendable {
  case welcome = "welcome"
  case account = "account"
  case accountDevice = "accountDevice"
  case agentSetup = "agentSetup"
  case done = "done"
}

/// Canonical first-run button action IDs (`registry/surfaces.json` `firstRun.steps`).
enum RegistryFirstRunActionID: String, CaseIterable, Hashable, Sendable {
  case next = "next"
  case finish = "finish"
  case signIn = "signIn"
  case importThings = "importThings"
  case importReminders = "importReminders"
  case copySetupPrompt = "copySetupPrompt"
}

/// One button in the first run. `action` is one of a closed set the client implements.
struct RegistryFirstRunButton: Sendable, Hashable {
  let title: String
  let action: RegistryFirstRunActionID
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
  let action: RegistryFirstRunActionID
  let platforms: [String]
}

/// One first-run step (`registry/surfaces.json` `firstRun.steps`). `kind` picks the view.
struct RegistryFirstRunStep: Sendable, Hashable, Identifiable {
  let id: RegistryFirstRunStepID
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
  /// The platforms this step shows on; empty means every platform.
  let platforms: [String]
  /// The step shows only where this capability ships (`RegistryCapabilities.isAvailable`).
  let featureId: String?
  let points: [RegistryFirstRunPoint]
  let choices: [RegistryFirstRunChoice]
  let primary: RegistryFirstRunButton?
  let secondary: RegistryFirstRunButton?
  /// Replaces `secondary` once the step's work is done (paired, imported).
  let afterDone: RegistryFirstRunButton?
}

enum RegistryFirstRun {
  static let featureId: String = "onboarding.first-run"
  /// The synced setting that records a finished first run, so a second device skips it.
  static let completionSetting: String = "onboardedAt"
  static let connectorUrl: String = "https://api.septena.app/mcp"
  static let backTitle: String = RegistryL10n.t("Back")
  static let setupPrompt: String = RegistryL10n.t("Set up Septena for me using https://septena.app/agents.md")
  static let firstPrompt: String = RegistryL10n.t("Set up my Septena areas, projects, and tasks by following https://api.septena.app/onboard.md")
  static let steps: [RegistryFirstRunStep] = [
    RegistryFirstRunStep(id: .welcome, kind: "intro", icon: "onboarding.welcome", title: RegistryL10n.t("Welcome to Septena"), body: RegistryL10n.t("Tasks that think with you."), footnote: nil, returningTitle: nil, returningBody: nil, skipWhen: nil, requires: nil, completesGetStartedStep: nil, platforms: [], featureId: nil, points: [RegistryFirstRunPoint(icon: "onboarding.devices", title: RegistryL10n.t("On every device"), detail: RegistryL10n.t("Your tasks stay in step on every device you sign in to.")), RegistryFirstRunPoint(icon: "onboarding.agent", title: RegistryL10n.t("Your agents do the work"), detail: RegistryL10n.t("You decide when it’s done.")), RegistryFirstRunPoint(icon: "onboarding.notes", title: RegistryL10n.t("Notes keep the context"), detail: RegistryL10n.t("Each project has notes, so you and your agents know what it’s for."))], choices: [], primary: RegistryFirstRunButton(title: RegistryL10n.t("Continue"), action: .next), secondary: nil, afterDone: nil),
    RegistryFirstRunStep(id: .account, kind: "account", icon: "onboarding.account", title: RegistryL10n.t("Sign in to sync"), body: RegistryL10n.t("Sign in to keep your tasks in sync on all your devices and let your agents connect. Your first sign-in creates your account."), footnote: RegistryL10n.t("If you skip this, your tasks stay on this device until you sign in."), returningTitle: nil, returningBody: nil, skipWhen: "signedIn", requires: nil, completesGetStartedStep: nil, platforms: ["ios", "ipados", "macos"], featureId: nil, points: [], choices: [], primary: RegistryFirstRunButton(title: RegistryL10n.t("Sign in"), action: .signIn), secondary: RegistryFirstRunButton(title: RegistryL10n.t("Not now"), action: .next), afterDone: nil),
    RegistryFirstRunStep(id: .accountDevice, kind: "account", icon: "onboarding.account", title: RegistryL10n.t("Sign in to sync"), body: RegistryL10n.t("Sign in to keep your tasks in sync on all your devices and let your agents connect. Your first sign-in creates your account."), footnote: nil, returningTitle: nil, returningBody: nil, skipWhen: "signedIn", requires: nil, completesGetStartedStep: nil, platforms: ["android"], featureId: nil, points: [], choices: [], primary: RegistryFirstRunButton(title: RegistryL10n.t("Sign in"), action: .signIn), secondary: nil, afterDone: nil),
    RegistryFirstRunStep(id: .agentSetup, kind: "connectAgent", icon: "list.agent", title: RegistryL10n.t("Connect an agent"), body: RegistryL10n.t("Connect the agent you already use. You choose what it works on, and only you mark work done."), footnote: nil, returningTitle: nil, returningBody: nil, skipWhen: nil, requires: "signedIn", completesGetStartedStep: "connectAI", platforms: [], featureId: "agents.connector", points: [], choices: [], primary: RegistryFirstRunButton(title: RegistryL10n.t("Copy setup prompt"), action: .copySetupPrompt), secondary: RegistryFirstRunButton(title: RegistryL10n.t("Skip"), action: .next), afterDone: RegistryFirstRunButton(title: RegistryL10n.t("Continue"), action: .next)),
    RegistryFirstRunStep(id: .done, kind: "finish", icon: "onboarding.done", title: RegistryL10n.t("You’re all set"), body: RegistryL10n.t("Today shows what to do now. Anything you skipped stays on the Get started list."), footnote: nil, returningTitle: RegistryL10n.t("Welcome back"), returningBody: RegistryL10n.t("This account is already set up. Your tasks are syncing to this device."), skipWhen: nil, requires: nil, completesGetStartedStep: nil, platforms: [], featureId: nil, points: [], choices: [], primary: RegistryFirstRunButton(title: RegistryL10n.t("Open Today"), action: .finish), secondary: nil, afterDone: nil),
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

/// One-time non-renewing pass for Plus (ADR 0061).
struct RegistryPlanPass: Sendable, Hashable, Identifiable {
  let id: String
  let plan: String
  let productId: String
  let years: Int
  let amountMinor: Int
  let currency: String
  let title: String
  let detail: String
  let label: String
  let rateDetail: String
  let action: String
}

struct RegistryPlanCard: Sendable, Hashable, Identifiable {
  let id: String
  let title: String
  /// Registry icon id (icons.json).
  let icon: String
  let detail: String
  let footnote: String?
  let highlighted: Bool
}

struct RegistryPlanRow: Sendable, Hashable, Identifiable {
  let id: String
  let label: String
  let planned: Bool
  let free: RegistryPlanCell
  let plus: RegistryPlanCell
  let pro: RegistryPlanCell
}

struct RegistryPlanOutcome: Sendable, Hashable, Identifiable {
  let id: String
  let icon: String
  let title: String
  let detail: String
  let rows: [RegistryPlanRow]
}

/// One benefit of a paid plan (`benefits` in plans.json, docs/PREMIUM_LANGUAGE.md).
struct RegistryPlanBenefit: Sendable, Hashable, Identifiable {
  let id: String
  /// Registry icon id (icons.json); its tile color is `AppearancePreferences.glyphSwiftUIColor`.
  let icon: String
  let title: String
  let detail: String
}

struct RegistryPlanNote: Sendable, Hashable, Identifiable {
  let id: String
  let title: String
  let detail: String
  /// For an upsell moment: the plan that answers it (`plus` or `pro`). The paywall opens on it.
  var plan: String? = nil
}

/// Plans and pricing (`registry/plans.json`). The site's /pricing page reads the same file.
enum RegistryPlans {
  static var name: String { RegistryL10n.t("Septena Plus") }
  static var shortName: String { RegistryL10n.t("Plus") }
  static var proName: String { RegistryL10n.t("Pro") }
  static var headline: String { RegistryL10n.t("Free on one device. Plus on all of them.") }
  static var subhead: String { RegistryL10n.t("Every task feature is free on the device you use. A free account adds a backup and lets you connect one agent. Plus covers all your devices, three agents, synced files and a longer history.") }
  static let checkoutOpen = false
  static var checkoutNotice: String { RegistryL10n.t("Subscriptions open at App Store launch.") }
  static let trialDays = 14
  static var trialTitle: String { RegistryL10n.t("Every new account starts with 14 days of Plus") }
  static var trialDetail: String { RegistryL10n.t("You do not need a card. After 14 days the account becomes a free account, and your tasks stay where they are.") }
  static var priceFootnote: String { RegistryL10n.t("Prices include VAT where it applies. In the US, prices are the same numbers in USD plus applicable local sales tax. Elsewhere, the App Store and Google Play charge their matching local price.") }
  static var prices: [RegistryPlanPrice] { [
    RegistryPlanPrice(id: "annual", productId: "com.septena.tasks.sync.annual", amountMinor: 7000, currency: "EUR", interval: "year", highlighted: true, label: RegistryL10n.t("€70 a year"), detail: RegistryL10n.t("Two months free. You save €14 against paying monthly.")),
    RegistryPlanPrice(id: "monthly", productId: "com.septena.tasks.sync.monthly", amountMinor: 700, currency: "EUR", interval: "month", highlighted: false, label: RegistryL10n.t("€7 a month"), detail: RegistryL10n.t("Cancel at any time.")),
  ] }
  /// What Pro costs (ADR 0059): the higher level of the same subscription group.
  static var proPrices: [RegistryPlanPrice] { [
    RegistryPlanPrice(id: "pro_annual", productId: "com.septena.tasks.sync.pro.annual", amountMinor: 14000, currency: "EUR", interval: "year", highlighted: true, label: RegistryL10n.t("€140 a year"), detail: RegistryL10n.t("Two months free. You save €28 against paying monthly.")),
    RegistryPlanPrice(id: "pro_monthly", productId: "com.septena.tasks.sync.pro.monthly", amountMinor: 1400, currency: "EUR", interval: "month", highlighted: false, label: RegistryL10n.t("€14 a month"), detail: RegistryL10n.t("Cancel at any time.")),
  ] }
  /// The 7-Year Plus Pass (ADR 0061): one-time Non-Renewing Subscription, Plus only.
  static var pass: RegistryPlanPass { RegistryPlanPass(id: "plus_7year", plan: "plus", productId: "com.septena.tasks.sync.plus.7year", years: 7, amountMinor: 21000, currency: "EUR", title: RegistryL10n.t("Pay once for seven years of Plus"), detail: RegistryL10n.t("If you prefer not to keep a subscription, one payment covers seven years of Septena Plus across your devices, for the price of three annual years. When the seven years end, your tasks stay on your devices, and you can extend, move to a free account, or export everything. Support for running the open-source sync server on your own Cloudflare account is on the roadmap."), label: RegistryL10n.t("€210 once"), rateDetail: RegistryL10n.t("€30 a year for 7 years. Pay for 3 years, get 7."), action: RegistryL10n.t("Get 7-Year Pass")) }
  static var plusBenefits: [RegistryPlanBenefit] { [
    RegistryPlanBenefit(id: "devices", icon: "plans.devices", title: RegistryL10n.t("Every device, always current"), detail: RegistryL10n.t("Your list on all your devices, updated as you type.")),
    RegistryPlanBenefit(id: "agents", icon: "plans.agents", title: RegistryL10n.t("Three agents at work"), detail: RegistryL10n.t("Connect Claude and two more. Each one asks before it acts.")),
    RegistryPlanBenefit(id: "files", icon: "plans.files", title: RegistryL10n.t("10 GB of synced files"), detail: RegistryL10n.t("Attach a file once and it opens on every device.")),
    RegistryPlanBenefit(id: "history", icon: "plans.history", title: RegistryL10n.t("A year of history"), detail: RegistryL10n.t("See who changed what, and bring back what you deleted.")),
  ] }
  static var proBenefits: [RegistryPlanBenefit] { [
    RegistryPlanBenefit(id: "agents", icon: "plans.agents", title: RegistryL10n.t("No limit on agents"), detail: RegistryL10n.t("Run as many agents on your list as your work needs.")),
    RegistryPlanBenefit(id: "files", icon: "plans.files", title: RegistryL10n.t("50 GB of synced files"), detail: RegistryL10n.t("Room for scans, screenshots and long documents.")),
    RegistryPlanBenefit(id: "everything", icon: "plans.plus", title: RegistryL10n.t("Everything in Plus"), detail: RegistryL10n.t("Every device, a year of history and shared projects.")),
  ] }
  /// The full comparison of every plan, on the website.
  static let compareURL = URL(string: "https://septena.app/pricing")!
  /// The rows every plan card lists (`cardRows`), in order.
  static let cardRowIDs: [String] = ["devices", "connected", "files", "history"]
  static var cards: [RegistryPlanCard] { [
    RegistryPlanCard(id: "free", title: RegistryL10n.t("Free"), icon: "plans.free", detail: RegistryL10n.t("The full task app on one device. You do not need an account."), footnote: nil, highlighted: false),
    RegistryPlanCard(id: "plus", title: RegistryL10n.t("Septena Plus"), icon: "settings.plus", detail: RegistryL10n.t("Your list on every device, updated live."), footnote: RegistryL10n.t("Everything in Free is included."), highlighted: true),
    RegistryPlanCard(id: "pro", title: RegistryL10n.t("Septena Pro"), icon: "plans.pro", detail: RegistryL10n.t("For people who hand a lot of work to agents."), footnote: RegistryL10n.t("Everything in Plus is included."), highlighted: false),
  ] }
  /// The Pro card, for an account that has Pro. The paywalls offer it in #719 (ADR 0059).
  static var proCard: RegistryPlanCard { RegistryPlanCard(id: "pro", title: RegistryL10n.t("Septena Pro"), icon: "plans.pro", detail: RegistryL10n.t("For people who hand a lot of work to agents."), footnote: RegistryL10n.t("Everything in Plus is included."), highlighted: false) }
  static var outcomes: [RegistryPlanOutcome] { [
    RegistryPlanOutcome(id: "everywhere", icon: "onboarding.devices", title: RegistryL10n.t("Your list everywhere"), detail: RegistryL10n.t("The same tasks on every device, updated as you type."), rows: [
      RegistryPlanRow(id: "devices", label: RegistryL10n.t("Devices"), planned: false, free: .text(RegistryL10n.t("1")), plus: .text(RegistryL10n.t("All your devices")), pro: .text(RegistryL10n.t("All your devices"))),
      RegistryPlanRow(id: "backup", label: RegistryL10n.t("Backup on our server"), planned: false, free: .included, plus: .included, pro: .included),
      RegistryPlanRow(id: "new_device", label: RegistryL10n.t("Move to a new device"), planned: false, free: .included, plus: .included, pro: .included),
      RegistryPlanRow(id: "beta", label: RegistryL10n.t("Early builds on TestFlight"), planned: false, free: .notIncluded, plus: .included, pro: .included),
    ]),
    RegistryPlanOutcome(id: "nothing_lost", icon: "plans.history", title: RegistryL10n.t("Nothing lost"), detail: RegistryL10n.t("See who changed what and bring back what you deleted. Your files open on every device."), rows: [
      RegistryPlanRow(id: "history", label: RegistryL10n.t("Change history"), planned: false, free: .text(RegistryL10n.t("30 days")), plus: .text(RegistryL10n.t("365 days")), pro: .text(RegistryL10n.t("365 days"))),
      RegistryPlanRow(id: "deleted", label: RegistryL10n.t("Recently Deleted"), planned: false, free: .text(RegistryL10n.t("30 days")), plus: .text(RegistryL10n.t("30 days")), pro: .text(RegistryL10n.t("30 days"))),
      RegistryPlanRow(id: "files", label: RegistryL10n.t("Files"), planned: false, free: .text(RegistryL10n.t("On your device")), plus: .text(RegistryL10n.t("10 GB synced")), pro: .text(RegistryL10n.t("50 GB synced"))),
      RegistryPlanRow(id: "export", label: RegistryL10n.t("Export as JSON"), planned: false, free: .included, plus: .included, pro: .included),
    ]),
    RegistryPlanOutcome(id: "agents", icon: "onboarding.agent", title: RegistryL10n.t("Help that keeps working"), detail: RegistryL10n.t("Connect Claude or another agent to your list. It asks before it acts, and you can stop it at any time."), rows: [
      RegistryPlanRow(id: "connected", label: RegistryL10n.t("Agents"), planned: false, free: .text(RegistryL10n.t("1")), plus: .text(RegistryL10n.t("3")), pro: .text(RegistryL10n.t("No limit"))),
      RegistryPlanRow(id: "share", label: RegistryL10n.t("Shared projects"), planned: false, free: .text(RegistryL10n.t("Join")), plus: .text(RegistryL10n.t("Create and invite")), pro: .text(RegistryL10n.t("Create and invite"))),
    ]),
  ] }
  static var promises: [RegistryPlanNote] { [
    RegistryPlanNote(id: "core_free", title: RegistryL10n.t("The task app stays free"), detail: RegistryL10n.t("Tasks, lists, projects and areas have no caps on any plan.")),
    RegistryPlanNote(id: "no_hostage", title: RegistryL10n.t("We never hold your data back"), detail: RegistryL10n.t("Export works on every plan. A limit hides older items. It never deletes them, and Plus shows them again.")),
    RegistryPlanNote(id: "cancel", title: RegistryL10n.t("Cancel at any time"), detail: RegistryL10n.t("Your account becomes a free account. Every device keeps its tasks, and the server keeps your synced copy for 12 months.")),
    RegistryPlanNote(id: "own_ai", title: RegistryL10n.t("You pay your AI provider, not us"), detail: RegistryL10n.t("Septena runs the sync server and the connector. When you connect Claude or another agent, its bill stays with that provider.")),
  ] }
  static var upsells: [RegistryPlanNote] { [
    RegistryPlanNote(id: "second_device", title: RegistryL10n.t("This device is not syncing"), detail: RegistryL10n.t("A free account syncs one device. Plus syncs all of them. You can also move your free account to this device."), plan: "plus"),
    RegistryPlanNote(id: "history_edge", title: RegistryL10n.t("Older changes are hidden"), detail: RegistryL10n.t("A free account shows 30 days of history. Plus shows a full year."), plan: "plus"),
    RegistryPlanNote(id: "file_elsewhere", title: RegistryL10n.t("This file is on another device"), detail: RegistryL10n.t("Plus syncs files and images to all your devices."), plan: "plus"),
    RegistryPlanNote(id: "connector_cap", title: RegistryL10n.t("Daily change limit reached"), detail: RegistryL10n.t("Agents on this account made 500 changes today. They can make changes again tomorrow."), plan: "plus"),
    RegistryPlanNote(id: "share_create", title: RegistryL10n.t("Sharing a project needs Plus"), detail: RegistryL10n.t("Anyone can join a shared project for free. Plus lets you create one and invite people."), plan: "plus"),
    RegistryPlanNote(id: "trial_end", title: RegistryL10n.t("Your 14 days of Plus have ended"), detail: RegistryL10n.t("Your account is now a free account. One device keeps syncing. Your tasks on every device stay where they are."), plan: "plus"),
    RegistryPlanNote(id: "agents_full", title: RegistryL10n.t("Your agent slot is in use"), detail: RegistryL10n.t("A free account connects one agent. Plus connects three. Pro has no limit."), plan: "plus"),
    RegistryPlanNote(id: "agents_full_plus", title: RegistryL10n.t("All three agent slots are in use"), detail: RegistryL10n.t("Plus connects three agents. Pro connects as many as you run, and holds 50 GB of files."), plan: "pro"),
  ] }
  static func card(_ id: String) -> RegistryPlanCard? { cards.first { $0.id == id } }
  static func upsell(_ id: String) -> RegistryPlanNote? { upsells.first { $0.id == id } }
  /// The paywall's Terms of Use and Privacy Policy links (App Review 3.1.2).
  static let termsURL = URL(string: "https://septena.app/terms")!
  static let privacyURL = URL(string: "https://septena.app/privacy")!

  enum Action {
    static var subscribe: String { RegistryL10n.t("Subscribe") }
    static var restore: String { RegistryL10n.t("Restore Purchases") }
    static var manage: String { RegistryL10n.t("Manage Subscription") }
    static var notNow: String { RegistryL10n.t("Not Now") }
    static var learnMore: String { RegistryL10n.t("See what Plus adds") }
    static var syncThisDevice: String { RegistryL10n.t("Sync This Device") }
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
    static func proThrough(date: String) -> String { RegistryL10n.format("Pro through %@", english: "Pro through %@", args: [date]) }
    static var filesSyncing: String { RegistryL10n.t("Files are still syncing between your devices.") }
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
    static var ownedGrantPro: String { RegistryL10n.t("Pro is on for this account.") }
    static var ownedOtherAccount: String { RegistryL10n.t("This Apple ID's Plus belongs to another Septena account. Sign in to that account to use it.") }
    static var syncThisDeviceFailed: String { RegistryL10n.t("Septena could not reach the server. Try again in a moment.") }
    static var done: String { RegistryL10n.t("Done") }
    static var seePro: String { RegistryL10n.t("See Pro") }
    static var choosePlan: String { RegistryL10n.t("Choose a plan") }
    static func youGet(plan: String) -> String { RegistryL10n.format("With %@", english: "With %@", args: [plan]) }
    static var upgradeNote: String { RegistryL10n.t("Pro starts right away. The App Store refunds the unused part of your Plus.") }
    static var upgradeFromPassNote: String { RegistryL10n.t("Pro starts right away. Upgrading to Pro does not refund a 7-Year Pass. If you cancel Pro later, you return to the time remaining on your pass.") }
    static var upgradeElsewhere: String { RegistryL10n.t("To move to Pro, change your plan in the store where you bought Plus.") }
    static var yourPlanIncludes: String { RegistryL10n.t("Your plan includes") }
    static var compareAll: String { RegistryL10n.t("Compare every plan") }
    static var buyElsewhere: String { RegistryL10n.t("This copy of Septena does not sell plans. Buy Plus or Pro in the App Store version on any device. It turns on here when you sign in to the same account.") }
  }
}

/// How a platform offers a sign-in method (`registry/sign-in.json`).
enum RegistrySignInFlow: String, Sendable {
  /// The platform's own flow. For email and device, the client draws the form.
  case native
  /// A redirect through api.septena.app in the system browser sheet.
  case web
  /// The platform cannot offer the method.
  case unavailable = "none"
}

enum RegistrySignInMethodId: String, Sendable, CaseIterable {
  case apple = "apple"
  case google = "google"
  case microsoft = "microsoft"
  case email = "email"
  case device = "device"
}

struct RegistrySignInMethod: Sendable, Hashable, Identifiable {
  let id: RegistrySignInMethodId
  /// `provider`, `email` or `device`.
  let kind: String
  /// The provider's name for copy (`{provider}`); nil for email and device.
  let name: String?
  let title: String
  /// Registry icon id (icons.json).
  let icon: String
  /// False only for device approval: it needs an account that exists.
  let createsAccount: Bool
  let featureId: String
  /// Flow by platform id (`ios`, `ipados`, `macos`, ...).
  let flows: [String: RegistrySignInFlow]
}

/// The sign-in screen (`registry/sign-in.json`, ADR 0047). It is also the
/// create-account screen. The backend's GET /v1/auth/methods says which
/// methods are on; hide the others.
enum RegistrySignIn {
  static var methods: [RegistrySignInMethod] { [
    RegistrySignInMethod(id: .apple, kind: "provider", name: "Apple", title: RegistryL10n.t("Continue with Apple"), icon: "auth.apple", createsAccount: true, featureId: "account.sign-in-apple", flows: ["ios": .native, "ipados": .native, "macos": .native, "web": .web, "android": .web, "windows": .web, "linux": .web]),
    RegistrySignInMethod(id: .google, kind: "provider", name: "Google", title: RegistryL10n.t("Continue with Google"), icon: "auth.google", createsAccount: true, featureId: "account.sign-in-google", flows: ["ios": .web, "ipados": .web, "macos": .web, "web": .web, "android": .native, "windows": .web, "linux": .web]),
    RegistrySignInMethod(id: .microsoft, kind: "provider", name: "Microsoft", title: RegistryL10n.t("Continue with Microsoft"), icon: "auth.microsoft", createsAccount: true, featureId: "account.sign-in-microsoft", flows: ["ios": .web, "ipados": .web, "macos": .web, "web": .web, "android": .web, "windows": .web, "linux": .web]),
    RegistrySignInMethod(id: .email, kind: "email", name: nil, title: RegistryL10n.t("Continue with email"), icon: "auth.email", createsAccount: true, featureId: "account.sign-in-email", flows: ["ios": .native, "ipados": .native, "macos": .native, "web": .native, "android": .native, "windows": .native, "linux": .native]),
    RegistrySignInMethod(id: .device, kind: "device", name: nil, title: RegistryL10n.t("I use Septena on another device"), icon: "auth.device", createsAccount: false, featureId: "account.sign-in-device", flows: ["ios": .native, "ipados": .native, "macos": .native, "web": .native, "android": .native, "windows": .native, "linux": .native]),
  ] }
  /// Method order by platform id: the platform's provider, the other providers, email, device.
  static let order: [String: [RegistrySignInMethodId]] = [
    "ios": [.apple, .google, .microsoft, .email, .device],
    "ipados": [.apple, .google, .microsoft, .email, .device],
    "macos": [.apple, .google, .microsoft, .email, .device],
    "web": [.apple, .google, .microsoft, .email, .device],
    "android": [.google, .apple, .microsoft, .email, .device],
    "windows": [.apple, .google, .microsoft, .email, .device],
    "linux": [.apple, .google, .microsoft, .email, .device],
  ]
  static func method(_ id: RegistrySignInMethodId) -> RegistrySignInMethod? { methods.first { $0.id == id } }
  /// The methods `platform` offers, in screen order.
  static func methods(on platform: String) -> [RegistrySignInMethod] {
    let all = methods
    return (order[platform] ?? []).compactMap { id in all.first { $0.id == id } }
  }
  /// The Terms line's links (plans.json `legal`).
  static var termsURL: URL { RegistryPlans.termsURL }
  static var privacyURL: URL { RegistryPlans.privacyURL }

  enum Copy {
    static var heading: String { RegistryL10n.t("Sign in to Septena") }
    static var subheading: String { RegistryL10n.t("New here? Your first sign-in creates your account.") }
    static func terms(terms: String, privacy: String) -> String { RegistryL10n.format("By continuing, you agree to the %@ and the %@.", english: "By continuing, you agree to the %@ and the %@.", args: [terms, privacy]) }
    static var termsLabel: String { RegistryL10n.t("Terms of Use") }
    static var privacyLabel: String { RegistryL10n.t("Privacy Policy") }
    static var loading: String { RegistryL10n.t("Loading Septena") }
  }
  enum Email {
    static var emailLabel: String { RegistryL10n.t("Email") }
    static var emailPlaceholder: String { RegistryL10n.t("you@example.com") }
    static var sendCode: String { RegistryL10n.t("Send code") }
    static func codeSent(email: String) -> String { RegistryL10n.format("We sent a code to %@.", english: "We sent a code to %@.", args: [email]) }
    static var codeLabel: String { RegistryL10n.t("Code") }
    static var signIn: String { RegistryL10n.t("Sign in") }
    static var resend: String { RegistryL10n.t("Send a new code") }
    static var differentEmail: String { RegistryL10n.t("Use a different email") }
  }
  enum Errors {
    static var invalidEmail: String { RegistryL10n.t("Enter a valid email address.") }
    static func wrongCode(count: Int) -> String { RegistryL10n.plural("That code is wrong. You have %lld tries left.", count: count, one: "That code is wrong. You have 1 try left.", other: "That code is wrong. You have %lld tries left.", args: [count]) }
    static var tooManyTries: String { RegistryL10n.t("Too many wrong codes. Get a new code and try again.") }
    static var codeExpired: String { RegistryL10n.t("This code has expired. Get a new code and try again.") }
    static var rateLimited: String { RegistryL10n.t("Too many requests. Try again later.") }
    static var network: String { RegistryL10n.t("Can't reach Septena. Check your connection and try again.") }
  }
  enum ExistingAccount {
    static var title: String { RegistryL10n.t("This email already has a Septena account") }
    static func detail(email: String, provider: String) -> String { RegistryL10n.format("We'll send a code to %@. Enter it to sign in, and we'll add %@ to that account.", english: "We'll send a code to %@. Enter it to sign in, and we'll add %@ to that account.", args: [email, provider]) }
    static var button: String { RegistryL10n.t("Email me a code") }
    static func manualDetail(email: String, provider: String) -> String { RegistryL10n.format("Sign in with %@, then add %@ in Settings.", english: "Sign in with %@, then add %@ in Settings.", args: [email, provider]) }
  }
  enum Manage {
    static var heading: String { RegistryL10n.t("Sign-in methods") }
    static var footer: String { RegistryL10n.t("Add another sign-in method to open this same account on any device. You cannot remove your last method.") }
    static var remove: String { RegistryL10n.t("Remove") }
    static var cancel: String { RegistryL10n.t("Cancel") }
    static func addProvider(provider: String) -> String { RegistryL10n.format("Add %@", english: "Add %@", args: [provider]) }
    static var addEmail: String { RegistryL10n.t("Add email") }
    static var addAppleDetail: String { RegistryL10n.t("Link your Apple ID to sign in to this same Septena account.") }
    static var alreadyLinked: String { RegistryL10n.t("That sign-in method already belongs to another Septena account.") }
    static var lastMethod: String { RegistryL10n.t("Add another sign-in method before removing your last one.") }
    static var added: String { RegistryL10n.t("Sign-in method added.") }
    static var removed: String { RegistryL10n.t("Sign-in method removed.") }
    static var loadFailed: String { RegistryL10n.t("Could not load sign-in methods.") }
    static var addFailed: String { RegistryL10n.t("Could not add sign-in method.") }
    static var removeFailed: String { RegistryL10n.t("Could not remove sign-in method.") }
  }
}

/// One app Septena imports from, or plans to (`registry/import-sources.json`).
struct RegistryImportSource: Sendable, Hashable {
  let id: String
  let name: String
  let status: String
  let input: String
  let issue: Int
  let detail: String?
}

enum RegistryImportSources {
  static var all: [RegistryImportSource] { [
    RegistryImportSource(id: "things", name: "Things", status: "ships", input: "file", issue: 99, detail: RegistryL10n.t("Copies your areas, projects and tasks. Things stays as it is.")),
    RegistryImportSource(id: "reminders", name: "Apple Reminders", status: "ships", input: "localLibrary", issue: 99, detail: RegistryL10n.t("Moves reminders into your Inbox. Each one you import leaves Reminders.")),
    RegistryImportSource(id: "microsoft-todo", name: "Microsoft To Do", status: "planned", input: "account", issue: 52, detail: nil),
    RegistryImportSource(id: "todoist", name: "Todoist", status: "planned", input: "account", issue: 100, detail: nil),
    RegistryImportSource(id: "ticktick", name: "TickTick", status: "planned", input: "account", issue: 100, detail: nil),
    RegistryImportSource(id: "omnifocus", name: "OmniFocus", status: "planned", input: "file", issue: 102, detail: nil),
    RegistryImportSource(id: "superlist", name: "Superlist", status: "planned", input: "file", issue: 101, detail: nil),
    RegistryImportSource(id: "anydo", name: "Any.do", status: "assisted", input: "file", issue: 102, detail: nil),
  ] }
}

/// Canonical capability parity ledger (`registry/capabilities.json`, ADR 0013 / ADR 0015).
enum RegistryCapabilities {
  static let byPlatform: [String: [String: String]] = [
    "ios": ["lists.inbox": "ships", "lists.today": "ships", "lists.review": "ships", "review.waiting": "ships", "lists.agent": "ships", "lists.upcoming": "ships", "lists.anytime": "ships", "lists.sort": "ships", "lists.repeating": "ships", "lists.logbook": "ships", "lists.faded": "ships", "lists.starred": "ships", "lists.recently-deleted": "ships", "places.areas": "ships", "places.projects": "ships", "places.sections": "ships", "task.when-deadline": "ships", "task.repeat": "ships", "task.notes": "ships", "task.attachments": "ships", "task.do": "ships", "task.references": "ships", "task.history": "ships", "task.provenance": "ships", "task.aging": "ships", "task.checklists": "ships", "task.tags": "ships", "task.share": "ships", "task.alerts": "ships", "fade.sweep": "ships", "capture.quick-add": "ships", "sharing.projects": "ships", "capture.share-target": "ships", "capture.quick-entry": "not_applicable", "edit.filing-suggestion": "ships", "edit.undo": "ships", "edit.multi-select": "ships", "find.quick-find": "ships", "task.page": "partial", "mac.keyboard": "not_applicable", "mac.updates": "not_applicable", "calendar.events": "ships", "import.reminders": "ships", "import.things": "ships", "ai.discuss": "ships", "ai.reach-dial": "ships", "agents.connector": "ships", "onboarding.first-run": "ships", "agents.stop-pause": "ships", "sync.backend": "ships", "account.delete": "ships", "account.sign-in-apple": "ships", "account.sign-in-google": "planned", "account.sign-in-microsoft": "planned", "account.sign-in-email": "ships", "account.sign-in-device": "ships", "task.times": "ships", "calendar.feed": "ships", "widgets.tasks": "ships", "system.shortcuts": "ships", "watch.app": "not_applicable", "data.import-export": "ships", "agents.list": "ships", "settings.display": "ships", "support.contact": "ships", "appearance.accents": "ships", "appearance.textures": "ships", "appearance.mode": "ships", "appearance.text-size": "ships"],
    "ipados": ["lists.inbox": "ships", "lists.today": "ships", "lists.review": "ships", "review.waiting": "ships", "lists.agent": "ships", "lists.upcoming": "ships", "lists.anytime": "ships", "lists.sort": "ships", "lists.repeating": "ships", "lists.logbook": "ships", "lists.faded": "ships", "lists.starred": "ships", "lists.recently-deleted": "ships", "places.areas": "ships", "places.projects": "ships", "places.sections": "ships", "task.when-deadline": "ships", "task.repeat": "ships", "task.notes": "ships", "task.attachments": "ships", "task.do": "ships", "task.references": "ships", "task.history": "ships", "task.provenance": "ships", "task.aging": "ships", "task.checklists": "ships", "task.tags": "ships", "task.share": "ships", "task.alerts": "ships", "fade.sweep": "ships", "capture.quick-add": "ships", "sharing.projects": "ships", "capture.share-target": "ships", "capture.quick-entry": "not_applicable", "edit.filing-suggestion": "ships", "edit.undo": "ships", "edit.multi-select": "ships", "find.quick-find": "ships", "task.page": "partial", "mac.keyboard": "ships", "mac.updates": "not_applicable", "calendar.events": "ships", "import.reminders": "ships", "import.things": "ships", "ai.discuss": "ships", "ai.reach-dial": "ships", "agents.connector": "ships", "onboarding.first-run": "ships", "agents.stop-pause": "ships", "sync.backend": "ships", "account.delete": "ships", "account.sign-in-apple": "ships", "account.sign-in-google": "planned", "account.sign-in-microsoft": "planned", "account.sign-in-email": "ships", "account.sign-in-device": "ships", "task.times": "ships", "calendar.feed": "ships", "widgets.tasks": "ships", "system.shortcuts": "ships", "watch.app": "not_applicable", "data.import-export": "ships", "agents.list": "ships", "settings.display": "ships", "support.contact": "ships", "appearance.accents": "ships", "appearance.textures": "ships", "appearance.mode": "ships", "appearance.text-size": "ships"],
    "macos": ["lists.inbox": "ships", "lists.today": "ships", "lists.review": "ships", "review.waiting": "ships", "lists.agent": "ships", "lists.upcoming": "ships", "lists.anytime": "ships", "lists.sort": "ships", "lists.repeating": "ships", "lists.logbook": "ships", "lists.faded": "ships", "lists.starred": "ships", "lists.recently-deleted": "ships", "places.areas": "ships", "places.projects": "ships", "places.sections": "ships", "task.when-deadline": "ships", "task.repeat": "ships", "task.notes": "ships", "task.attachments": "ships", "task.do": "ships", "task.references": "ships", "task.history": "ships", "task.provenance": "ships", "task.aging": "ships", "task.checklists": "ships", "task.tags": "ships", "task.share": "ships", "task.alerts": "ships", "fade.sweep": "ships", "capture.quick-add": "not_applicable", "sharing.projects": "ships", "capture.share-target": "not_applicable", "capture.quick-entry": "ships", "edit.filing-suggestion": "ships", "edit.undo": "ships", "edit.multi-select": "ships", "find.quick-find": "ships", "task.page": "partial", "mac.keyboard": "ships", "mac.updates": "ships", "calendar.events": "ships", "import.reminders": "ships", "import.things": "ships", "ai.discuss": "ships", "ai.reach-dial": "ships", "agents.connector": "ships", "onboarding.first-run": "ships", "agents.stop-pause": "ships", "sync.backend": "ships", "account.delete": "ships", "account.sign-in-apple": "ships", "account.sign-in-google": "planned", "account.sign-in-microsoft": "planned", "account.sign-in-email": "ships", "account.sign-in-device": "ships", "task.times": "ships", "calendar.feed": "ships", "widgets.tasks": "ships", "system.shortcuts": "ships", "watch.app": "not_applicable", "data.import-export": "ships", "agents.list": "ships", "settings.display": "ships", "support.contact": "ships", "appearance.accents": "ships", "appearance.textures": "ships", "appearance.mode": "ships", "appearance.text-size": "ships"],
    "web": ["lists.inbox": "ships", "lists.today": "ships", "lists.review": "ships", "review.waiting": "ships", "lists.agent": "ships", "lists.upcoming": "ships", "lists.anytime": "ships", "lists.sort": "ships", "lists.repeating": "ships", "lists.logbook": "ships", "lists.faded": "ships", "lists.starred": "ships", "lists.recently-deleted": "ships", "places.areas": "ships", "places.projects": "ships", "places.sections": "ships", "task.when-deadline": "ships", "task.repeat": "ships", "task.notes": "ships", "task.attachments": "ships", "task.do": "planned", "task.references": "ships", "task.history": "ships", "task.provenance": "ships", "task.aging": "ships", "task.checklists": "ships", "task.tags": "ships", "task.share": "ships", "task.alerts": "ships", "fade.sweep": "ships", "capture.quick-add": "ships", "sharing.projects": "planned", "capture.share-target": "ships", "capture.quick-entry": "not_applicable", "edit.filing-suggestion": "not_applicable", "edit.undo": "ships", "edit.multi-select": "ships", "find.quick-find": "ships", "task.page": "partial", "mac.keyboard": "ships", "mac.updates": "not_applicable", "calendar.events": "planned", "import.reminders": "not_applicable", "import.things": "not_applicable", "ai.discuss": "ships", "ai.reach-dial": "ships", "agents.connector": "ships", "onboarding.first-run": "ships", "agents.stop-pause": "ships", "sync.backend": "ships", "account.delete": "ships", "account.sign-in-apple": "planned", "account.sign-in-google": "planned", "account.sign-in-microsoft": "planned", "account.sign-in-email": "ships", "account.sign-in-device": "ships", "task.times": "ships", "calendar.feed": "ships", "widgets.tasks": "not_applicable", "system.shortcuts": "not_applicable", "watch.app": "not_applicable", "data.import-export": "ships", "agents.list": "ships", "settings.display": "ships", "support.contact": "ships", "appearance.accents": "ships", "appearance.textures": "ships", "appearance.mode": "ships", "appearance.text-size": "ships"],
    "android": ["lists.inbox": "ships", "lists.today": "ships", "lists.review": "ships", "review.waiting": "ships", "lists.agent": "ships", "lists.upcoming": "ships", "lists.anytime": "ships", "lists.sort": "ships", "lists.repeating": "ships", "lists.logbook": "ships", "lists.faded": "ships", "lists.starred": "ships", "lists.recently-deleted": "ships", "places.areas": "ships", "places.projects": "ships", "places.sections": "ships", "task.when-deadline": "ships", "task.repeat": "ships", "task.notes": "ships", "task.attachments": "ships", "task.do": "ships", "task.references": "ships", "task.history": "ships", "task.provenance": "ships", "task.aging": "ships", "task.checklists": "ships", "task.tags": "ships", "task.share": "ships", "task.alerts": "ships", "fade.sweep": "ships", "capture.quick-add": "ships", "sharing.projects": "ships", "capture.share-target": "ships", "capture.quick-entry": "not_applicable", "edit.filing-suggestion": "ships", "edit.undo": "ships", "edit.multi-select": "ships", "find.quick-find": "ships", "task.page": "partial", "mac.keyboard": "ships", "mac.updates": "not_applicable", "calendar.events": "ships", "import.reminders": "not_applicable", "import.things": "not_applicable", "ai.discuss": "partial", "ai.reach-dial": "ships", "agents.connector": "ships", "onboarding.first-run": "ships", "agents.stop-pause": "ships", "sync.backend": "ships", "account.delete": "ships", "account.sign-in-apple": "planned", "account.sign-in-google": "planned", "account.sign-in-microsoft": "planned", "account.sign-in-email": "ships", "account.sign-in-device": "ships", "task.times": "ships", "calendar.feed": "ships", "widgets.tasks": "ships", "system.shortcuts": "not_applicable", "watch.app": "not_applicable", "data.import-export": "ships", "agents.list": "ships", "settings.display": "ships", "support.contact": "ships", "appearance.accents": "ships", "appearance.textures": "ships", "appearance.mode": "ships", "appearance.text-size": "ships"],
    "windows": ["lists.inbox": "planned", "lists.today": "planned", "lists.review": "planned", "review.waiting": "planned", "lists.agent": "planned", "lists.upcoming": "planned", "lists.anytime": "planned", "lists.sort": "planned", "lists.repeating": "planned", "lists.logbook": "planned", "lists.faded": "planned", "lists.starred": "planned", "lists.recently-deleted": "planned", "places.areas": "planned", "places.projects": "planned", "places.sections": "planned", "task.when-deadline": "planned", "task.repeat": "planned", "task.notes": "planned", "task.attachments": "planned", "task.do": "planned", "task.references": "planned", "task.history": "planned", "task.provenance": "planned", "task.aging": "planned", "task.checklists": "planned", "task.tags": "planned", "task.share": "planned", "task.alerts": "planned", "fade.sweep": "planned", "capture.quick-add": "not_applicable", "sharing.projects": "planned", "capture.share-target": "planned", "capture.quick-entry": "planned", "edit.filing-suggestion": "planned", "edit.undo": "planned", "edit.multi-select": "planned", "find.quick-find": "planned", "task.page": "planned", "mac.keyboard": "planned", "mac.updates": "planned", "calendar.events": "planned", "import.reminders": "not_applicable", "import.things": "not_applicable", "ai.discuss": "planned", "ai.reach-dial": "planned", "agents.connector": "planned", "onboarding.first-run": "planned", "agents.stop-pause": "planned", "sync.backend": "planned", "account.delete": "planned", "account.sign-in-apple": "planned", "account.sign-in-google": "planned", "account.sign-in-microsoft": "planned", "account.sign-in-email": "planned", "account.sign-in-device": "planned", "task.times": "planned", "calendar.feed": "planned", "widgets.tasks": "planned", "system.shortcuts": "not_applicable", "watch.app": "not_applicable", "data.import-export": "planned", "agents.list": "planned", "settings.display": "planned", "support.contact": "planned", "appearance.accents": "planned", "appearance.textures": "planned", "appearance.mode": "planned", "appearance.text-size": "planned"],
    "linux": ["lists.inbox": "planned", "lists.today": "planned", "lists.review": "planned", "review.waiting": "planned", "lists.agent": "planned", "lists.upcoming": "planned", "lists.anytime": "planned", "lists.sort": "planned", "lists.repeating": "planned", "lists.logbook": "planned", "lists.faded": "planned", "lists.starred": "planned", "lists.recently-deleted": "planned", "places.areas": "planned", "places.projects": "planned", "places.sections": "planned", "task.when-deadline": "planned", "task.repeat": "planned", "task.notes": "planned", "task.attachments": "planned", "task.do": "planned", "task.references": "planned", "task.history": "planned", "task.provenance": "planned", "task.aging": "planned", "task.checklists": "planned", "task.tags": "planned", "task.share": "planned", "task.alerts": "planned", "fade.sweep": "planned", "capture.quick-add": "not_applicable", "sharing.projects": "planned", "capture.share-target": "planned", "capture.quick-entry": "planned", "edit.filing-suggestion": "planned", "edit.undo": "planned", "edit.multi-select": "planned", "find.quick-find": "planned", "task.page": "planned", "mac.keyboard": "planned", "mac.updates": "planned", "calendar.events": "planned", "import.reminders": "not_applicable", "import.things": "not_applicable", "ai.discuss": "planned", "ai.reach-dial": "planned", "agents.connector": "planned", "onboarding.first-run": "planned", "agents.stop-pause": "planned", "sync.backend": "planned", "account.delete": "planned", "account.sign-in-apple": "planned", "account.sign-in-google": "planned", "account.sign-in-microsoft": "planned", "account.sign-in-email": "planned", "account.sign-in-device": "planned", "task.times": "planned", "calendar.feed": "planned", "widgets.tasks": "planned", "system.shortcuts": "not_applicable", "watch.app": "not_applicable", "data.import-export": "planned", "agents.list": "planned", "settings.display": "planned", "support.contact": "planned", "appearance.accents": "planned", "appearance.textures": "planned", "appearance.mode": "planned", "appearance.text-size": "planned"],
    "watchos": ["lists.inbox": "partial", "lists.today": "partial", "lists.review": "not_applicable", "review.waiting": "not_applicable", "lists.agent": "not_applicable", "lists.upcoming": "not_applicable", "lists.anytime": "not_applicable", "lists.sort": "not_applicable", "lists.repeating": "not_applicable", "lists.logbook": "not_applicable", "lists.faded": "not_applicable", "lists.starred": "not_applicable", "lists.recently-deleted": "not_applicable", "places.areas": "not_applicable", "places.projects": "not_applicable", "places.sections": "not_applicable", "task.when-deadline": "not_applicable", "task.repeat": "not_applicable", "task.notes": "not_applicable", "task.attachments": "not_applicable", "task.do": "planned", "task.references": "not_applicable", "task.history": "not_applicable", "task.provenance": "not_applicable", "task.aging": "not_applicable", "task.checklists": "not_applicable", "task.tags": "not_applicable", "task.share": "not_applicable", "task.alerts": "not_applicable", "fade.sweep": "not_applicable", "capture.quick-add": "not_applicable", "sharing.projects": "not_applicable", "capture.share-target": "not_applicable", "capture.quick-entry": "not_applicable", "edit.filing-suggestion": "not_applicable", "edit.undo": "not_applicable", "edit.multi-select": "not_applicable", "find.quick-find": "not_applicable", "task.page": "partial", "mac.keyboard": "not_applicable", "mac.updates": "not_applicable", "calendar.events": "not_applicable", "import.reminders": "not_applicable", "import.things": "not_applicable", "ai.discuss": "not_applicable", "ai.reach-dial": "not_applicable", "agents.connector": "not_applicable", "onboarding.first-run": "not_applicable", "agents.stop-pause": "not_applicable", "sync.backend": "planned", "account.delete": "not_applicable", "account.sign-in-apple": "not_applicable", "account.sign-in-google": "not_applicable", "account.sign-in-microsoft": "not_applicable", "account.sign-in-email": "not_applicable", "account.sign-in-device": "not_applicable", "task.times": "not_applicable", "calendar.feed": "not_applicable", "widgets.tasks": "not_applicable", "system.shortcuts": "not_applicable", "watch.app": "ships", "data.import-export": "not_applicable", "agents.list": "not_applicable", "settings.display": "not_applicable", "support.contact": "not_applicable", "appearance.accents": "not_applicable", "appearance.textures": "not_applicable", "appearance.mode": "not_applicable", "appearance.text-size": "not_applicable"],
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
