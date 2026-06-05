import SwiftUI

/// Identifiable wrapper so a section key can drive `.sheet(item:)` at
/// the tab-root. The key is the only payload; resolution to a view
/// happens in the sheet builder.
struct PendingSection: Identifiable, Hashable {
  let key: String
  var id: String { key }
}

enum Route: Hashable {
  case filter(TaskFilter)
  case next
  case project(Project)
  case area(Area)
}

@MainActor
@Observable
final class NavigationState {
  var path: [Route] = []
  /// One-shot trigger: when set to true, the currently-visible
  /// TaskListView starts a new inline task (same flow as Command-N) on its
  /// next render. TaskListView resets it to false after consuming. Used
  /// by toolbar `+` actions and the sidebar Menu's New To-Do entry, so
  /// 'new task' never opens a modal sheet — always inline, like Things.
  var shouldStartCreating = false

  /// One-shot trigger from a Home Screen Quick Action (long-press app
  /// icon). ContentView dispatches the route change + `shouldStartCreating`
  /// flip, then resets this to nil. nil means "no pending shortcut".
  var pendingShortcut: ShortcutAction?

  /// One-shot tab switch from a deep link (e.g. the Next widget's
  /// `septena://next`). RootTabView observes it, selects the tab, then
  /// resets to nil. nil means "no pending switch".
  var pendingTab: SeptenaTab?

  /// One-shot driver for the section sheet presented at RootTabView when
  /// a Home Screen Quick Action resolves. Hosted at the tab-root (not
  /// inside WeekDashboardView) so the sheet presents reliably regardless
  /// of which tab the user was last on — switching tabs first and then
  /// setting a sheet item raced with SwiftUI's tab swap.
  var pendingSection: PendingSection?

  /// macOS sidebar visibility — toggled by Command-/. `.all` shows both columns,
  /// `.detailOnly` collapses the sidebar so detail content runs edge-to-edge.
  var sidebarVisibility: NavigationSplitViewVisibility = .all

  /// Drives the Settings sheet. Flipped from the sidebar's Settings button
  /// and the macOS toolbar gear; the sheet closes via its own Done button.
  var showSettings = false

/// Drives the Quick Find palette (Command-Shift-F). A floating sheet over the
  /// main window; selecting a result routes via `path` and dismisses itself.
  var showQuickFind = false

  /// Drives the unified Add Info palette (Command-K, or long-press the FAB on
  /// touch). Sheet routes capture into any of the ten Septena sections
  /// using the same rules-based smart behaviour as the web Command-K palette.
  var showAddInfo = false

  /// Optional jump-target — when non-nil, AddInfoSheet opens directly to
  /// that page instead of the root list. Cleared on dismiss.
  var addInfoRequestedSection: AddInfoSection? = nil

  /// Drives the Training session sheet (logger). Flipped from Command-K's
  /// "Start training" rows, the Training destination's Start button, and
  /// from any future quick-action; the sheet itself reads the live draft
  /// out of `TrainingDraftStore` so resume-after-dismiss just works.
  var showTrainingSession = false

  /// Optional pre-selected session type. When non-nil, the Training
  /// session sheet auto-starts a draft of this type on appear and skips
  /// the picker step — used by the dashboard QuickAdd menu's smart
  /// shortcuts ("Start: Upper", etc.). Cleared after consumption.
  var pendingTrainingType: String? = nil

  /// Drives the Keyboard Shortcuts cheat-sheet (⌘? — i.e. ⌘⇧/). A reference
  /// overlay listing every shortcut, grouped by area. Read-only; closes via
  /// its own Done button or Escape.
  var showKeyboardShortcuts = false

}
