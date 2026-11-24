import SwiftUI
import SwiftData

enum Route: Hashable {
  case filter(TaskFilter)
  case next
  /// Navigation carries durable identity, never a stale model snapshot. Detail
  /// destinations resolve the live SwiftData record when they render.
  case project(id: String)
  case area(id: String)
}

extension Route {
  /// Stable, id-based selection token. Projects / areas compare by id (so a
  /// reloaded struct with the same id but changed fields keeps the highlight),
  /// filters and Next compare by value. This is the single source for the
  /// `List(selection:)` tag, the sidebar highlight, and the dropdown checkmark —
  /// the identity logic that used to be re-implemented in three places.
  var id: String {
    switch self {
    case .filter(let f):  return "filter.\(Self.filterKey(f))"
    case .next:           return "next"
    case .project(let id): return "project.\(id)"
    case .area(let id):    return "area.\(id)"
    }
  }

  /// True when both routes point at the same destination (id-based).
  func sameDestination(as other: Route) -> Bool { id == other.id }

  /// User-facing label for the destination.
  var title: String {
    switch self {
    case .filter(let f):  return f.title
    case .next:           return String(localized: "Next")
    case .project:        return String(localized: "Project")
    case .area:           return String(localized: "Area")
    }
  }

  /// SF Symbol for the destination. Areas with a user glyph return it via
  /// `emoji` instead; prefer `emoji` when it's non-nil.
  var icon: String {
    switch self {
    case .filter(let f):  return Self.filterIcon(f)
    case .next:           return "arrow.right"
    case .project:        return "number"
    case .area:           return "folder"
    }
  }

  private static func filterKey(_ f: TaskFilter) -> String {
    f.navigationKey
  }

  private static func filterIcon(_ f: TaskFilter) -> String {
    if let dest = RegistryDestinations.byNavigationKey[f.navigationKey] {
      return dest.sfSymbol
    }
    switch f {
    case .triage:  return RegistryIcons.sfSymbol(for: "list.inbox")
    case .project: return RegistryIcons.sfSymbol(for: "place.project")
    case .area:    return RegistryIcons.sfSymbol(for: "place.area")
    default:       return RegistryIcons.sfSymbol(for: "list.today")
    }
  }
}

/// The canonical, ordered set of Tasks destinations — smart-list identity
/// comes from `registry/destinations.json` via `SmartListPreferences.shared`
/// (per-account, synced across devices); area / project ordering is applied by
/// `StructureCache` via `TaskStructureOrder`. See `docs/DRAG_AND_DROP.md` §5.
@MainActor
enum TaskDestinations {
  /// Visible special smart lists across both sections, in user order.
  static func sidebarRoutes(nonEmptyIDs: Set<String>) -> [Route] {
    SmartListPreferences.shared
      .visibleDestinations(nonEmptyIDs: nonEmptyIDs)
      .compactMap { TaskFilter(destinationID: $0.id).map(Route.filter) }
  }

  /// Visible special smart lists in a specific sidebar zone (`.top` above
  /// Areas & Projects, or `.bottom` below Areas & Projects).
  static func sidebarRoutes(in section: SmartListSection,
                            nonEmptyIDs: Set<String>) -> [Route] {
    SmartListPreferences.shared
      .visibleDestinations(in: section, nonEmptyIDs: nonEmptyIDs)
      .compactMap { TaskFilter(destinationID: $0.id).map(Route.filter) }
  }

  /// Convenience for menus/dropdowns that don't already have precomputed counts.
  static func nonEmptySmartListIDs(in context: ModelContext) -> Set<String> {
    var nonEmpty = Set<String>()
    if !LocalCache.tasks(in: context, filter: .review).isEmpty { nonEmpty.insert("review") }
    if !LocalCache.tasks(in: context, filter: .agent).isEmpty { nonEmpty.insert("agent") }
    if !LocalCache.tasks(in: context, filter: .starred).isEmpty { nonEmpty.insert("starred") }
    if !LocalCache.tasks(in: context, filter: .faded).isEmpty { nonEmpty.insert("faded") }
    if !LocalCache.tasks(in: context, filter: .recentlyDeleted).isEmpty { nonEmpty.insert("recentlyDeleted") }
    return nonEmpty
  }

  static func sidebarRoutes(in section: SmartListSection,
                            context: ModelContext) -> [Route] {
    sidebarRoutes(in: section, nonEmptyIDs: nonEmptySmartListIDs(in: context))
  }

  static func sidebarRoutes(in context: ModelContext) -> [Route] {
    sidebarRoutes(nonEmptyIDs: nonEmptySmartListIDs(in: context))
  }

  /// Always-visible smart lists in the account's configured order.
  static var sidebarRoutes: [Route] { sidebarRoutes(nonEmptyIDs: []) }

  static func orderedAreas(_ loaded: [Area]) -> [Area] {
    TaskStructureOrder.orderedAreas(loaded)
  }

  static func orderedProjects(_ loaded: [Project]) -> [Project] {
    TaskStructureOrder.orderedProjects(loaded)
  }
}

@MainActor
@Observable
final class NavigationState {
  var path: [Route] = []

  /// One-shot request from task search. The receiving task list waits until it
  /// has loaded the matching route, then reveals the exact row and clears it.
  struct TaskReveal: Equatable {
    let taskID: String
    let routeID: String
  }
  var pendingTaskReveal: TaskReveal?

  /// The single navigation entry point. The app is conceptually flat, so a
  /// destination tap REPLACES the path (`push: false`, the default); only the
  /// iPhone area → project drill-in pushes onto the stack. Centralized here so
  /// the haptic + path mutation isn't re-implemented at every call site
  /// (sidebar rows, the title dropdown, Quick Find, project drill-in).
  func go(to route: Route, push: Bool = false) {
    Haptics.selection()
    if push { path.append(route) } else { path = [route] }
  }

  /// Navigate to a task's owning list and reveal that specific task once the
  /// destination has rendered. Search uses this rather than merely opening the
  /// containing project or smart list.
  func revealTask(id: String, in route: Route) {
    go(to: route)
    pendingTaskReveal = TaskReveal(taskID: id, routeID: route.id)
  }
  /// One-shot trigger: when set to true, the currently-visible
  /// TaskListView starts a new inline task (same flow as Command-N) on its
  /// next render. TaskListView resets it to false after consuming. Used
  /// by toolbar `+` actions and the sidebar Menu's New Task entry, so
  /// 'new task' never opens a modal sheet — always inline, like Things.
  var shouldStartCreating = false

  /// One-shot triggers for the sidebar's "New Project" / "New Area" sheets,
  /// set by the macOS menu bar's Task menu (there's no toolbar "···" on macOS —
  /// see `SeptenaPage`). `SidebarView` observes each, opens its sheet, and
  /// resets the flag. iOS reaches the same sheets through the sidebar overflow,
  /// so these stay false there.
  var shouldCreateProject = false
  var shouldCreateArea = false
  /// One-shot trigger for the active Project's "Add Section" heading prompt
  /// (used by the iPhone Magic Plus quick menu when viewing a project).
  var shouldCreateHeading = false

  /// True while the on-screen iOS `TaskListView` is in touch multi-select mode
  /// (`docs/MULTI_SELECT_SWIPE_AND_DRAG_SPEC.md` §5.2). Used by `SeptaskRootView`
  /// to hide the floating Magic Plus orb while the bottom selection bar is up.
  var isTaskMultiSelectActive = false

  /// One-shot trigger from a Home Screen Quick Action (long-press app
  /// icon). ContentView dispatches the route change + `shouldStartCreating`
  /// flip, then resets this to nil. nil means "no pending shortcut".
  var pendingShortcut: ShortcutAction?

  /// One-shot tab switch from a deep link (e.g. the Next widget's
  /// `septena://next`). RootTabView observes it, selects the tab, then
  /// resets to nil. nil means "no pending switch".
  var pendingTab: SeptenaTab?

  /// One-shot Section Tile widget deep link (`septena://section/<itemID>`).
  /// WeekDashboardView consumes this to mirror a dashboard tile tap.
  var pendingDashboardTile: String?

  /// macOS sidebar visibility — toggled by Command-/. `.all` shows both columns,
  /// `.detailOnly` collapses the sidebar so detail content runs edge-to-edge.
  /// Persisted device-locally via `SettingsKey.tasksSidebarVisibility`.
  var sidebarVisibility: NavigationSplitViewVisibility = .all {
    didSet { persistTasksSidebarVisibility(sidebarVisibility) }
  }

  init() {
    sidebarVisibility = loadTasksSidebarVisibility()
  }

  /// Drives Settings. Flipped from the sidebar's Settings button, the menu
  /// bar, and the home toolbars. On iOS it presents a sheet (closed with
  /// "Done"); on macOS RootTabView observes this flag and opens the
  /// dedicated `"settings"` Window instead, which carries its own traffic
  /// lights so it closes like any window.
  var showSettings = false

  /// Optional deep-link target for the Settings surface — set alongside
  /// `showSettings` by the contextual entry points ("Customize <Section>",
  /// the Insights gear) so Settings opens already pushed to that pane.
  /// `nil` opens the default root (Sections). Cleared on dismiss.
  /// Septask doesn't compile the full Settings surface (its own settings
  /// shell is P3 — docs/SEPTASK.md), so the property is gated with the type.
  #if !SEPTASK
  var settingsDestination: SettingsView.SettingsDestination?
  #endif

  /// The one app-global modal sheet currently presented (or nil). All the
  /// app-level palettes/sheets — Quick Find, Add Info, the Quick-Action section
  /// sheet, the Training logger, the Mood check-in, the keyboard cheat-sheet —
  /// route through this single optional + one `.sheet(item:)` at the tab root,
  /// instead of a boolean-per-sheet plus its own `onChange`/`onDismiss`
  /// cleanup. Settings is the deliberate exception (macOS opens it as a Window,
  /// so it keeps `showSettings`).
  var presentedModal: AppModal? = nil

  /// Set by the first-run welcome as it finishes, consumed by the welcome
  /// gate's `onDismiss`: once the welcome cover is gone, open the Add Info
  /// quick-add for this section so the user logs their first thing. Routed
  /// through the gate (not fired inline) so the sheet presents cleanly after
  /// the cover dismisses rather than racing it. Nil → no first-log nudge.
  var pendingFirstLog: AddInfoSection? = nil

  /// Optional pre-selected session type. When non-nil, the Training
  /// session sheet auto-starts a draft of this type on appear and skips
  /// the picker step — used by the dashboard QuickAdd menu's smart
  /// shortcuts ("Start: Upper", etc.). Cleared after consumption.
  var pendingTrainingType: String? = nil

  // MARK: - Modal convenience

  // Thin bridges so the many call sites that present these sheets stay terse
  // and read intent-first (`nav.showQuickFind = true`) while the storage is the
  // single `presentedModal`. Setting `false` only dismisses if *that* modal is
  // the one showing, so one sheet can't clear another.
  var showQuickFind: Bool {
    get { presentedModal == .quickFind }
    set { setModal(.quickFind, newValue) }
  }
  var showTrainingSession: Bool {
    get { presentedModal == .trainingSession }
    set { setModal(.trainingSession, newValue) }
  }
  var showMoodCheckin: Bool {
    get { presentedModal == .moodCheckin }
    set { setModal(.moodCheckin, newValue) }
  }
  var showKeyboardShortcuts: Bool {
    get { presentedModal == .keyboardShortcuts }
    set { setModal(.keyboardShortcuts, newValue) }
  }

  /// Present the Add Info palette, optionally jumping straight to a section.
  func presentAddInfo(section: AddInfoSection? = nil) {
    presentedModal = .addInfo(section: section)
  }

  /// Present one intake tracker's page from the global Add Info palette.
  func presentIntakeKind(_ id: String) {
    presentedModal = .intakeKind(id: id)
  }

  /// Present the Quick-Action / deep-link section sheet for a manifest key.
  func presentSection(key: String) {
    presentedModal = .section(key: key)
  }

  private func setModal(_ modal: AppModal, _ on: Bool) {
    if on { presentedModal = modal }
    else if presentedModal == modal { presentedModal = nil }
  }
}

private func loadTasksSidebarVisibility() -> NavigationSplitViewVisibility {
  switch UserDefaults.standard.string(forKey: SettingsKey.tasksSidebarVisibility) {
  case "detailOnly": return .detailOnly
  default: return .all
  }
}

private func persistTasksSidebarVisibility(_ visibility: NavigationSplitViewVisibility) {
  let raw = visibility == .detailOnly ? "detailOnly" : "all"
  UserDefaults.standard.set(raw, forKey: SettingsKey.tasksSidebarVisibility)
}

extension NavigationState {
  /// Whether the Tasks tab should show the index "···" menu (New Area / Project /
  /// Task Settings). Hidden on pushed lists (iPhone) and area/project detail.
  func tasksShowsIndexOverflow(usesPushNavigation: Bool) -> Bool {
    if !usesPushNavigation { return path.isEmpty }
    guard let route = path.last else { return true }
    switch route {
    case .project, .area: return false
    case .filter, .next: return true
    }
  }
}

/// Every app-global modal sheet, as one value. Replaces the former bag of
/// `show*` booleans + `pendingSection`/`addInfoRequestedSection` payloads, so
/// the tab root mounts one `.sheet(item:)` rather than seven near-identical
/// blocks. `id` keys the sheet identity (payloads don't re-trigger it).
enum AppModal: Identifiable, Hashable {
  case quickFind
  case addInfo(section: AddInfoSection?)
  case section(key: String)
  case intakeKind(id: String)
  case trainingSession
  case moodCheckin
  case keyboardShortcuts

  var id: String {
    switch self {
    case .quickFind:          return "quickFind"
    case .addInfo:            return "addInfo"
    case .section(let key):   return "section.\(key)"
    case .intakeKind(let id): return "intakeKind.\(id)"
    case .trainingSession:    return "trainingSession"
    case .moodCheckin:        return "moodCheckin"
    case .keyboardShortcuts:  return "keyboardShortcuts"
    }
  }
}
