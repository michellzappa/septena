// Home Screen Quick Actions
//
// The user picks up to 4 sections in Settings → Customize → Quick Actions.
// Each selection becomes a dynamic UIApplicationShortcutItem applied at
// app launch and whenever the selection changes. The item `type` encodes
// the section key as `com.septena.app.section.<key>`; on trigger, the
// AppDelegate parses it back into a `ShortcutAction.openSection(key)`,
// publishes it on `NavigationState.pendingShortcut`, and RootTabView
// observes that to set `pendingSection`, which drives a section-sheet at
// the tab-root over whichever tab is currently selected.
//
// `newTask` is the always-present static item (declared in Info.plist, not
// applied dynamically): "Quick Add" straight from the icon long-press. It's
// the primary quick action in Septask (which has no sections) and routes to
// the same "open the composer" path every other new-task entry point uses.
// `today` is a Septask static item that lands on the Today smart list.

enum ShortcutAction: Equatable {
  case openSection(String)
  case newTask
  case today

  private static let sectionPrefix = "com.septena.app.section."
  private static let newTaskType = "com.septena.app.newtask"
  private static let todayType = "com.septena.app.today"

  init?(rawValue: String) {
    if rawValue == Self.newTaskType { self = .newTask; return }
    if rawValue == Self.todayType { self = .today; return }
    guard rawValue.hasPrefix(Self.sectionPrefix) else { return nil }
    let key = String(rawValue.dropFirst(Self.sectionPrefix.count))
    guard !key.isEmpty else { return nil }
    self = .openSection(key)
  }

  var rawValue: String {
    switch self {
    case .openSection(let key): return Self.sectionPrefix + key
    case .newTask: return Self.newTaskType
    case .today: return Self.todayType
    }
  }
}
