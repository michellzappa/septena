import SwiftUI

/// The task list's view options, as menu rows.
///
/// One `@AppStorage` on `SettingsKey.todayGroupByList` is the whole story:
/// every surface that renders Today already reads that key
/// (`TaskListView`, `TasksDestinationView`, and Septena's AppKit
/// `SeptaskKitTaskList`), and Settings ▸ Tasks writes the same one. Exposing
/// it here is discoverability, not a second source of truth — which is why
/// this is a shared view rather than a copy per surface.
///
/// Mounted only in the macOS / iPadOS View menu (Septena Life's `App.swift` and
/// Septena's `SeptaskCommandMenus`). On iPhone and iPad it lives in Settings
/// only: it is a global setting, not a per-page option (2026-11-23).
///
/// The title says "Today" because the setting is Today-scoped — Anytime,
/// project pages, and Upcoming group unconditionally — so the item stays
/// truthful in the View menu without having to know which list is in front.
struct TaskViewOptions: View {
  @AppStorage(SettingsKey.todayGroupByList) private var todayGroupByList: Bool = true

  var body: some View {
    Toggle("Group Today by List", isOn: Self.announcing($todayGroupByList))
  }

  /// Wraps a view-option binding so a write also posts
  /// `.septenaTaskViewOptionsChanged`. SwiftUI surfaces bind the key through
  /// `@AppStorage` and repaint themselves; Septena's AppKit list reads
  /// `UserDefaults` directly and would otherwise keep its stale rows until the
  /// next task mutation. Every writer of a task view option goes through this
  /// — the menus here and the registry-driven Settings rows in `SeptaskSettingsView`.
  static func announcing(_ storage: Binding<Bool>) -> Binding<Bool> {
    Binding(
      get: { storage.wrappedValue },
      set: { newValue in
        storage.wrappedValue = newValue
        NotificationCenter.default.post(name: .septenaTaskViewOptionsChanged, object: nil)
      })
  }
}
