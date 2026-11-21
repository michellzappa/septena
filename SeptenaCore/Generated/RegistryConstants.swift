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
  static let recurrenceUnit: [String] = ["day", "week", "month"]
  static let convoAssignee: [String] = ["me", "local", "claude"]
  static let convoEndState: [String] = ["agent_done", "human_done", "agent_assisted_done", "needs_verify", "decomposed", "reminder_set", "promoted_to_today", "wont_do", "open"]
  static let convoHandoffActionType: [String] = ["open_url", "compose", "call", "none"]
  static let convoTurnRole: [String] = ["user", "provider"]
  static let convoTurnStep: [String] = ["confirm", "ground", "scope", "decide", "work"]
  static let telemetryLevel: [String] = ["none", "minimal", "balanced", "full"]
  static let entityNames: [String] = ["task", "area", "project", "attachment", "convo", "setting"]
  static let deletableEntities: [String] = ["task", "area", "project", "attachment"]
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
    "list.today": "sun.max.fill",
    "list.inbox": "tray.full",
    "list.review": "eye",
    "list.upcoming": "calendar",
    "list.repeating": "arrow.clockwise",
    "list.anytime": "rectangle.stack.fill",
    "list.logbook": "checkmark",
    "list.faded": "circle.dashed",
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
    "settings.tasks": "checklist",
    "settings.connections_ai": "brain.head.profile",
    "settings.data": "square.and.arrow.up",
    "settings.privacy": "hand.raised",
    "settings.about": "info.circle",
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
  static let textScaleFactors: [Int: Double] = [
    -2: 0.85,
    -1: 0.92,
    0: 1,
    1: 1.1,
    2: 1.2,
  ]
}

/// Unified task-app settings keys, defaults, and synced-key list (`registry/settings.json`).
enum RegistrySettings {
  static let syncedKeys: [String] = ["welcomeName", "telemetryLevel", "calendarHiddenTitles", "rolledInDismissedOn", "homeTimezone", "agentsPaused", "getStartedDismissed", "getStartedSteps"]

  enum StorageKey {
    static let welcomeName = "septena.homepage.welcomeName"
    static let telemetryLevel = "septena.privacy.telemetryLevel"
    static let rolledInDismissedOn = "septena.newTodos.dismissedDate"
    static let todayShowCompleted = "septena.today.showCompleted"
    static let todayGroupByList = "septena.today.groupByList"
    static let tasksShowAging = "septena.tasks.showAging"
    static let tasksTitleLines = "septena.tasks.titleLines"
    static let tasksFilingSuggestions = "septena.tasks.filingSuggestions"
    static let tasksShowCalendarEvents = "septena.tasks.showCalendarEvents"
    static let badgeShowOverdue = "septena.badge.showOverdue"
    static let loggingAnimationsEnabled = "septena.ui.loggingAnimations"
    static let textSizeStep = "septena.display.textSizeStep"
    static let sidebarCounts = "septena.septask.sidebarCounts"
    static let aiMode = "septena.ai.mode"
    static let diagnosticsEnabled = "septask.diagnostics.enabled"
  }

  enum Defaults {
    static let welcomeName: String = ""
    static let telemetryLevel: String = "balanced"
    static let agentsPaused: Bool = false
    static let getStartedDismissed: Bool = false
    static let todayShowCompleted: Bool = true
    static let todayGroupByList: Bool = true
    static let tasksShowAging: Bool = true
    static let tasksTitleLines: Int = 2
    static let tasksFilingSuggestions: Bool = true
    static let tasksShowCalendarEvents: Bool = true
    static let badgeShowOverdue: Bool = false
    static let loggingAnimationsEnabled: Bool = true
    static let textSizeStep: Int = 0
    static let sidebarCounts: Bool = true
    static let aiMode: String = "auto"
    static let diagnosticsEnabled: Bool = false
  }
}

/// Canonical smart-list metadata (`registry/destinations.json`).
struct RegistryDestination: Sendable, Hashable, Identifiable {
  let id: String
  let navigationKey: String
  let serverView: String
  let title: String
  let iconId: String
  let sfSymbol: String
  let visibility: String
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
    RegistryDestination(id: "today", navigationKey: "today", serverView: "today", title: "Today", iconId: "list.today", sfSymbol: "sun.max.fill", visibility: "always", shortcutKeycaps: ["⌘", "1"], emptyTitle: "Nothing on Today", emptyDetail: "Add a task or move one here when you want to work on it today."),
    RegistryDestination(id: "review", navigationKey: "review", serverView: "all", title: "Review", iconId: "list.review", sfSymbol: "eye", visibility: "always", shortcutKeycaps: nil, emptyTitle: "Nothing to review", emptyDetail: "Tasks an agent proposes as done appear here until you accept them."),
    RegistryDestination(id: "upcoming", navigationKey: "upcoming", serverView: "upcoming", title: "Upcoming", iconId: "list.upcoming", sfSymbol: "calendar", visibility: "always", shortcutKeycaps: ["⌘", "2"], emptyTitle: "Nothing upcoming", emptyDetail: "Tasks with a future When or Deadline date appear here."),
    RegistryDestination(id: "repeating", navigationKey: "repeating", serverView: "all", title: "Repeating", iconId: "list.repeating", sfSymbol: "arrow.clockwise", visibility: "always", shortcutKeycaps: nil, emptyTitle: "No repeating tasks", emptyDetail: "Give any task a Repeat rule and it will show up here."),
    RegistryDestination(id: "anytime", navigationKey: "unscheduled", serverView: "unscheduled", title: "Anytime", iconId: "list.anytime", sfSymbol: "rectangle.stack.fill", visibility: "always", shortcutKeycaps: ["⌘", "3"], emptyTitle: "Nothing in Anytime", emptyDetail: "Open tasks without a date live here."),
    RegistryDestination(id: "logbook", navigationKey: "logbook", serverView: "logbook", title: "Logbook", iconId: "list.logbook", sfSymbol: "checkmark", visibility: "always", shortcutKeycaps: ["⌘", "4"], emptyTitle: "Logbook is empty", emptyDetail: "Completed and let-go tasks are archived here."),
    RegistryDestination(id: "faded", navigationKey: "faded", serverView: "all", title: "Faded", iconId: "list.faded", sfSymbol: "circle.dashed", visibility: "whenNonEmpty", shortcutKeycaps: nil, emptyTitle: "Nothing faded", emptyDetail: "Undated tasks untouched for 14 days quietly gather here."),
    RegistryDestination(id: "recentlyDeleted", navigationKey: "recentlyDeleted", serverView: "all", title: "Recently Deleted", iconId: "list.recently_deleted", sfSymbol: "trash", visibility: "whenNonEmpty", shortcutKeycaps: nil, emptyTitle: "Recently Deleted is empty", emptyDetail: "Deleted tasks stay here for 30 days before they are removed."),
  ]

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
    "rescheduleFixedRepeat": RegistryPromptCopy(id: "rescheduleFixedRepeat", title: "Reschedule repeating task?", message: "Move only this occurrence or shift the future schedule too?", confirmTitle: nil),
  ]
}

/// Canonical capability parity ledger (`registry/capabilities.json`, ADR 0013 / ADR 0015).
enum RegistryCapabilities {
  static let byPlatform: [String: [String: String]] = [
    "ios": ["lists.inbox": "ships", "lists.today": "ships", "lists.review": "ships", "lists.upcoming": "ships", "lists.anytime": "ships", "lists.repeating": "ships", "lists.logbook": "ships", "lists.faded": "ships", "lists.recently-deleted": "ships", "places.areas": "ships", "places.projects": "ships", "places.sections": "ships", "task.when-deadline": "ships", "task.repeat": "ships", "task.notes": "ships", "task.attachments": "ships", "task.history": "ships", "task.aging": "ships", "task.checklists": "planned", "task.tags": "planned", "task.alerts": "planned", "fade.sweep": "ships", "capture.quick-add": "ships", "capture.quick-entry": "not_applicable", "edit.filing-suggestion": "ships", "edit.undo": "ships", "edit.swipe-actions": "planned", "find.quick-find": "ships", "mac.keyboard": "not_applicable", "mac.updates": "not_applicable", "calendar.events": "ships", "import.reminders": "ships", "import.things": "ships", "ai.discuss": "ships", "ai.reach-dial": "ships", "agents.connector": "ships", "agents.stop-pause": "ships", "sync.backend": "ships", "account.delete": "ships", "settings.display": "ships"],
    "ipados": ["lists.inbox": "ships", "lists.today": "ships", "lists.review": "ships", "lists.upcoming": "ships", "lists.anytime": "ships", "lists.repeating": "ships", "lists.logbook": "ships", "lists.faded": "ships", "lists.recently-deleted": "ships", "places.areas": "ships", "places.projects": "ships", "places.sections": "ships", "task.when-deadline": "ships", "task.repeat": "ships", "task.notes": "ships", "task.attachments": "ships", "task.history": "ships", "task.aging": "ships", "task.checklists": "planned", "task.tags": "planned", "task.alerts": "planned", "fade.sweep": "ships", "capture.quick-add": "ships", "capture.quick-entry": "not_applicable", "edit.filing-suggestion": "ships", "edit.undo": "ships", "edit.swipe-actions": "planned", "find.quick-find": "ships", "mac.keyboard": "ships", "mac.updates": "not_applicable", "calendar.events": "ships", "import.reminders": "ships", "import.things": "ships", "ai.discuss": "ships", "ai.reach-dial": "ships", "agents.connector": "ships", "agents.stop-pause": "ships", "sync.backend": "ships", "account.delete": "ships", "settings.display": "ships"],
    "macos": ["lists.inbox": "ships", "lists.today": "ships", "lists.review": "ships", "lists.upcoming": "ships", "lists.anytime": "ships", "lists.repeating": "ships", "lists.logbook": "ships", "lists.faded": "ships", "lists.recently-deleted": "ships", "places.areas": "ships", "places.projects": "ships", "places.sections": "ships", "task.when-deadline": "ships", "task.repeat": "ships", "task.notes": "ships", "task.attachments": "partial", "task.history": "ships", "task.aging": "ships", "task.checklists": "planned", "task.tags": "planned", "task.alerts": "planned", "fade.sweep": "ships", "capture.quick-add": "not_applicable", "capture.quick-entry": "ships", "edit.filing-suggestion": "ships", "edit.undo": "ships", "edit.swipe-actions": "not_applicable", "find.quick-find": "ships", "mac.keyboard": "ships", "mac.updates": "ships", "calendar.events": "ships", "import.reminders": "ships", "import.things": "ships", "ai.discuss": "ships", "ai.reach-dial": "ships", "agents.connector": "ships", "agents.stop-pause": "ships", "sync.backend": "ships", "account.delete": "ships", "settings.display": "ships"],
    "web": ["lists.inbox": "planned", "lists.today": "planned", "lists.review": "planned", "lists.upcoming": "planned", "lists.anytime": "planned", "lists.repeating": "planned", "lists.logbook": "planned", "lists.faded": "planned", "lists.recently-deleted": "planned", "places.areas": "planned", "places.projects": "planned", "places.sections": "planned", "task.when-deadline": "planned", "task.repeat": "planned", "task.notes": "planned", "task.attachments": "planned", "task.history": "planned", "task.aging": "planned", "task.checklists": "planned", "task.tags": "planned", "task.alerts": "planned", "fade.sweep": "planned", "capture.quick-add": "planned", "capture.quick-entry": "not_applicable", "edit.filing-suggestion": "not_applicable", "edit.undo": "planned", "edit.swipe-actions": "not_applicable", "find.quick-find": "planned", "mac.keyboard": "planned", "mac.updates": "not_applicable", "calendar.events": "planned", "import.reminders": "not_applicable", "import.things": "not_applicable", "ai.discuss": "planned", "ai.reach-dial": "planned", "agents.connector": "planned", "agents.stop-pause": "planned", "sync.backend": "planned", "account.delete": "planned", "settings.display": "planned"],
    "android": ["lists.inbox": "planned", "lists.today": "planned", "lists.review": "planned", "lists.upcoming": "planned", "lists.anytime": "planned", "lists.repeating": "planned", "lists.logbook": "planned", "lists.faded": "planned", "lists.recently-deleted": "planned", "places.areas": "planned", "places.projects": "planned", "places.sections": "planned", "task.when-deadline": "planned", "task.repeat": "planned", "task.notes": "planned", "task.attachments": "planned", "task.history": "planned", "task.aging": "planned", "task.checklists": "planned", "task.tags": "planned", "task.alerts": "planned", "fade.sweep": "planned", "capture.quick-add": "planned", "capture.quick-entry": "not_applicable", "edit.filing-suggestion": "planned", "edit.undo": "planned", "edit.swipe-actions": "planned", "find.quick-find": "planned", "mac.keyboard": "planned", "mac.updates": "not_applicable", "calendar.events": "planned", "import.reminders": "not_applicable", "import.things": "not_applicable", "ai.discuss": "planned", "ai.reach-dial": "planned", "agents.connector": "planned", "agents.stop-pause": "planned", "sync.backend": "planned", "account.delete": "planned", "settings.display": "planned"],
    "windows": ["lists.inbox": "planned", "lists.today": "planned", "lists.review": "planned", "lists.upcoming": "planned", "lists.anytime": "planned", "lists.repeating": "planned", "lists.logbook": "planned", "lists.faded": "planned", "lists.recently-deleted": "planned", "places.areas": "planned", "places.projects": "planned", "places.sections": "planned", "task.when-deadline": "planned", "task.repeat": "planned", "task.notes": "planned", "task.attachments": "planned", "task.history": "planned", "task.aging": "planned", "task.checklists": "planned", "task.tags": "planned", "task.alerts": "planned", "fade.sweep": "planned", "capture.quick-add": "not_applicable", "capture.quick-entry": "planned", "edit.filing-suggestion": "planned", "edit.undo": "planned", "edit.swipe-actions": "not_applicable", "find.quick-find": "planned", "mac.keyboard": "planned", "mac.updates": "planned", "calendar.events": "planned", "import.reminders": "not_applicable", "import.things": "not_applicable", "ai.discuss": "planned", "ai.reach-dial": "planned", "agents.connector": "planned", "agents.stop-pause": "planned", "sync.backend": "planned", "account.delete": "planned", "settings.display": "planned"],
    "watchos": ["lists.inbox": "partial", "lists.today": "partial", "lists.review": "not_applicable", "lists.upcoming": "not_applicable", "lists.anytime": "not_applicable", "lists.repeating": "not_applicable", "lists.logbook": "not_applicable", "lists.faded": "not_applicable", "lists.recently-deleted": "not_applicable", "places.areas": "not_applicable", "places.projects": "not_applicable", "places.sections": "not_applicable", "task.when-deadline": "not_applicable", "task.repeat": "not_applicable", "task.notes": "not_applicable", "task.attachments": "not_applicable", "task.history": "not_applicable", "task.aging": "not_applicable", "task.checklists": "not_applicable", "task.tags": "not_applicable", "task.alerts": "not_applicable", "fade.sweep": "not_applicable", "capture.quick-add": "not_applicable", "capture.quick-entry": "not_applicable", "edit.filing-suggestion": "not_applicable", "edit.undo": "not_applicable", "edit.swipe-actions": "not_applicable", "find.quick-find": "not_applicable", "mac.keyboard": "not_applicable", "mac.updates": "not_applicable", "calendar.events": "not_applicable", "import.reminders": "not_applicable", "import.things": "not_applicable", "ai.discuss": "not_applicable", "ai.reach-dial": "not_applicable", "agents.connector": "not_applicable", "agents.stop-pause": "not_applicable", "sync.backend": "planned", "account.delete": "not_applicable", "settings.display": "not_applicable"],
  ]

  static func isShipped(_ featureId: String, on platform: String) -> Bool {
    byPlatform[platform]?[featureId] == "ships"
  }
}
