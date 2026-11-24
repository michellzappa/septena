import SwiftUI

// Chrome that wraps the task list rather than living inside it: the group
// header label, the "New Task" button, and the toolbar ViewModifiers the list
// applies in sequence. These were already extracted into modifiers to keep the
// type-checker alive on TaskListView's body — this moves them out of the file
// too. Split out of TaskListView.swift.


/// Compact tappable target for area / project section headers inside a list.
/// Wraps just the title (and optional chevron) so the click target matches the
/// visible text rather than the whole row width. Background wash on hover only.
struct GroupHeaderLabel: View {
  let title: String
  let hasChevron: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Text(title).sectionGroupHeaderTitleStyle()
        if hasChevron {
          Image(systemName: "chevron.right")
            .scaledFont(size: Theme.groupHeaderFontSize - 6, weight: .semibold)
            .foregroundStyle(Theme.iconMuted)
        }
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // Area/project headers are pointer-only affordances: clickable to drill
    // into the section, but kept OUT of the keyboard focus chain so ↑/↓ and
    // Tab traverse only task rows. Without this, the header Button steals a
    // focus stop between every group.
    .focusable(false)
    .inlineHover(cornerRadius: 6)
  }
}

/// Scoping for the app-global "start a new task" one-shot.
///
/// `NavigationState.shouldStartCreating` is a single flag that the on-screen
/// task list consumes. Two failure modes came from treating it as a plain
/// bool: a hidden list consumed it, and when NO list was on screen it lingered
/// and fired on whichever list appeared minutes later. TaskListView now only
/// consumes while on screen; this makes an unanswered request expire. The
/// window covers "navigate, then create" (the sidebar's New Task switches to
/// Today and then sets the flag): the new list appears well inside it.
@MainActor
enum TaskCreateRequest {
  fileprivate static var generation = 0
  static let lifetime: Duration = .seconds(1.5)
}

extension NavigationState {
  /// Ask the on-screen task list to start a new task. Use this instead of
  /// setting `shouldStartCreating` directly. A "+" that belongs to one list
  /// should call that list's own action instead (see `TaskListNewTaskButton`).
  func requestNewTask() {
    shouldStartCreating = true
    TaskCreateRequest.generation &+= 1
    let generation = TaskCreateRequest.generation
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: TaskCreateRequest.lifetime)
      guard let self, TaskCreateRequest.generation == generation else { return }
      self.shouldStartCreating = false
    }
  }
}

/// Prominent "+" for creating a task — shared between the local nav toolbar
/// (iPhone / macOS) and the iPad TabView trailing slot.
struct TaskListNewTaskButton: View {
  @Environment(NavigationState.self) private var nav
  @Environment(SectionTheme.self) private var theme
  /// The list this "+" belongs to. Nil falls back to the app-global request.
  var action: (() -> Void)? = nil

  var body: some View {
    Button {
      SeptenaLog.info("[Create] + button tapped")
      if let action { action() } else { nav.requestNewTask() }
    } label: {
      Image(systemName: "plus")
    }
    .glassProminentButtonStyleCompat()
    .tint(AdaptiveColor.fillForWhiteInk(theme.color(for: "tasks")))
    .accessibilityLabel(RegistryActions.title("app.newTask"))
  }
}

/// Presentation-only toolbar for a task list. Keeping this outside the deep
/// `TaskListView.taskList` modifier tree makes the host chrome independently
/// type-checkable; it never owns task draft or persistence behavior.
struct TaskListToolbarChrome: ViewModifier {
  let showsEmbeddedNewTask: Bool
  /// The owning list's own create action, so its "+" can't be answered by a
  /// different (hidden) list.
  var onNew: (() -> Void)? = nil
  /// A project page's New Section. When set, the "+" opens a menu with New
  /// Task and New Section, the same two rows as the iPhone Magic Plus menu.
  var onNewSection: (() -> Void)? = nil

  func body(content: Content) -> some View {
    content.toolbar {
      if showsEmbeddedNewTask {
        ToolbarItem(placement: .primaryAction) {
          if let onNewSection {
            TaskListNewMenuButton(onNewTask: onNew, onNewSection: onNewSection)
          } else {
            TaskListNewTaskButton(action: onNew)
          }
        }
      }
    }
  }
}

/// The project page's "+": a menu with New Task and New Section. Areas and
/// projects are made from the lists page, never from here.
struct TaskListNewMenuButton: View {
  @Environment(NavigationState.self) private var nav
  @Environment(SectionTheme.self) private var theme
  var onNewTask: (() -> Void)?
  let onNewSection: () -> Void

  var body: some View {
    Menu {
      Button {
        if let onNewTask { onNewTask() } else { nav.requestNewTask() }
      } label: {
        Label(RegistryActions.title("app.newTask"), systemImage: "checkmark.circle")
      }
      Button(action: onNewSection) {
        Label(RegistryActions.title("section.new"), systemImage: "rectangle.split.1x2")
      }
    } label: {
      Image(systemName: "plus")
    }
    .glassProminentButtonStyleCompat()
    .tint(AdaptiveColor.fillForWhiteInk(theme.color(for: "tasks")))
    .accessibilityLabel(RegistryActions.title("app.newTask"))
  }
}

/// Standalone TaskListView (its own tab pane) gets the unified page chrome:
/// the constant gear (→ Settings) plus a contextual "+" (new task) that merges
/// with the sidebar's "···" on iPad regular. Embedded uses (Project/Area detail
/// wraps) inherit the parent's chrome and opt out — they keep a plain local "+".
struct TaskListStandaloneChrome: ViewModifier {
  @Environment(NavigationState.self) private var nav
  #if os(iOS)
  @Environment(\.usesPushNavigation) private var usesPushNavigation
  #endif
  let embedded: Bool
  let recentlyDeleted: Bool
  /// The Starred filter as a toolbar toggle beside Search. nil when the list
  /// has no starred open task (the button appears only when it can filter).
  var starFilter: Binding<Bool>? = nil
  /// The owning list's own create action (see `TaskListToolbarChrome.onNew`).
  var onNew: (() -> Void)? = nil

  private func newTask() {
    if let onNew { onNew() } else { nav.requestNewTask() }
  }

  #if os(iOS)
  /// An embedded area / project page has no page chrome of its own, but its
  /// Starred filter still sits in the nav bar, as on Today.
  @ToolbarContentBuilder
  private var embeddedStarItem: some ToolbarContent {
    if let starFilter {
      ToolbarItem(placement: .topBarTrailing) {
        StarFilterToolbarButton(isOn: starFilter)
      }
    }
  }
  #endif

  func body(content: Content) -> some View {
    #if os(iOS)
    if usesPushNavigation {
      #if SEPTASK
      // Septask has no floating window-level overlay bar (unlike Septena's
      // `RootTabView.iPadTabless`), so on iPad / unfolded iPhone Duo the
      // standalone detail column owns its own trailing action (New Task).
      // "Group Today by List" is a global setting: it lives in Settings, not
      // in a per-page "···" (decided 2026-11-23). The sidebar owns leading Quick Find / Settings,
      // and `NavigationSplitView` supplies the native sidebar toggle.
      if embedded {
        content.toolbar { embeddedStarItem }
      } else {
        content.toolbar {
          if let starFilter {
            ToolbarItem(placement: .topBarTrailing) {
              StarFilterToolbarButton(isOn: starFilter)
            }
          }
          if !recentlyDeleted {
            ToolbarItem(placement: .topBarTrailing) {
              PageAddButton { newTask() }
            }
          }
        }
      }
      #else
      // Septena iPad regular: the Tasks SIDEBAR publishes the window-level
      // chrome (gear/···/+); the detail must NOT also publish (it would clobber
      // the sidebar's entry). The bar inset lives on `SelectableScrollList`'s
      // `ScrollView` via `iPadTabBarInsetOwnPadding`.
      content
      #endif
    } else if embedded {
      content.toolbar { embeddedStarItem }
    } else {
      content.pageChrome(
        id: "tasks",
        title: "Tasks",
        accessory: { starFilter.map { AnyView(StarFilterToolbarButton(isOn: $0)) } },
        add: recentlyDeleted ? nil : .action { newTask() }
      )
    }
    #else
    if embedded {
      content
    } else {
      // macOS: the sidebar toolbar has no gear, so the detail provides it.
      content.pageChrome(
        id: "tasks",
        title: "Tasks",
        add: recentlyDeleted ? nil : .action { newTask() }
      )
    }
    #endif
  }
}

/// The Starred filter as a toolbar toggle: an outlined star at rest, a filled
/// Today-accent star while only starred tasks show.
struct StarFilterToolbarButton: View {
  @Binding var isOn: Bool

  var body: some View {
    Button {
      a11yAnimate(.snappy(duration: 0.18)) { isOn.toggle() }
    } label: {
      Image(systemName: RegistryIcons.sfSymbol(for: "action.star", on: isOn))
    }
    .tint(isOn ? Theme.todayAccent : .primary)
    .accessibilityLabel(Text(TaskFilter.starred.title))
    .accessibilityAddTraits(isOn ? .isSelected : [])
    // Local filter state: the haptic follows it (docs/HAPTICS_SPEC.md).
    .sensoryFeedback(trigger: isOn) { _, on in .selection(on ? .on : .off) }
  }
}

/// Encapsulates the standalone-tab nav chrome so we can opt out cleanly
/// when TaskListView is embedded inside a detail page.
struct TopLevelChromeModifier: ViewModifier {
  let showChrome: Bool

  func body(content: Content) -> some View {
    if showChrome {
      content
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    } else {
      content
    }
  }
}
