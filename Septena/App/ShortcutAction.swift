// Home Screen Quick Actions
//
// Two static shortcuts declared in Info.plist (UIApplicationShortcutItems):
//   - com.septena.app.new-todo   -> open Inbox + start an inline draft row
//   - com.septena.app.show-today -> jump to Today smart list
// SwiftUI has no native shortcut handler, so AppDelegate bridges the event
// into NavigationState. ContentView observes `pendingShortcut` and routes.

enum ShortcutAction: String, Equatable {
  case newTodo   = "com.septena.app.new-todo"
  case showToday = "com.septena.app.show-today"
}
