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

/// Prominent "+" for creating a task — shared between the local nav toolbar
/// (iPhone / macOS) and the iPad TabView trailing slot.
struct TaskListNewTaskButton: View {
  @Environment(NavigationState.self) private var nav
  @Environment(SectionTheme.self) private var theme

  var body: some View {
    Button {
      SeptenaLog.info("[Create] + button tapped")
      nav.shouldStartCreating = true
    } label: {
      Image(systemName: "plus")
    }
    .buttonStyle(.glassProminent)
    .tint(AdaptiveColor.fillForWhiteInk(theme.color(for: "tasks")))
    .accessibilityLabel("New Task")
  }
}

/// Presentation-only toolbar for a task list. Keeping this outside the deep
/// `TaskListView.taskList` modifier tree makes the host chrome independently
/// type-checkable; it never owns task draft or persistence behavior.
struct TaskListToolbarChrome: ViewModifier {
  let showsEmbeddedNewTask: Bool

  func body(content: Content) -> some View {
    content.toolbar {
      if showsEmbeddedNewTask {
        ToolbarItem(placement: .primaryAction) {
          TaskListNewTaskButton()
        }
      }
    }
  }
}

/// Septask's reconnect affordance intentionally composes after the standalone
/// page chrome so the trailing controls retain their established face/plus order.
struct TaskListClaudeReconnectToolbar: ViewModifier {
  let shows: Bool

  func body(content: Content) -> some View {
    #if SEPTASK && os(iOS)
    content.toolbar {
      if shows {
        ToolbarItem(placement: .topBarTrailing) {
          ClaudeReconnectCue(.pill)
        }
      }
    }
    #else
    content
    #endif
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

  func body(content: Content) -> some View {
    #if os(iOS)
    if usesPushNavigation {
      // iPad regular: the Tasks SIDEBAR publishes the window-level chrome
      // (gear/···/+); the detail must NOT also publish (it would clobber the
      // sidebar's entry). The bar inset lives on `SelectableScrollList`'s
      // `ScrollView` via `iPadTabBarInsetOwnPadding`.
      content
    } else if embedded {
      content
    } else {
      content.pageChrome(
        id: "tasks",
        title: "Tasks",
        add: recentlyDeleted ? nil : .action { nav.shouldStartCreating = true }
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
        add: recentlyDeleted ? nil : .action { nav.shouldStartCreating = true }
      )
    }
    #endif
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
