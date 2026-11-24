// Home Screen Quick Actions: "New Task" (the composer) and "Today". Static
// items in Info.plist; the app delegate publishes the action on
// `NavigationState.pendingShortcut`.

enum ShortcutAction: String, Equatable {
  case newTask = "com.septena.app.newtask"
  case today = "com.septena.app.today"
}
