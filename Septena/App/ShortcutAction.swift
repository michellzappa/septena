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

enum ShortcutAction: Equatable {
  case openSection(String)

  private static let sectionPrefix = "com.septena.app.section."

  init?(rawValue: String) {
    guard rawValue.hasPrefix(Self.sectionPrefix) else { return nil }
    let key = String(rawValue.dropFirst(Self.sectionPrefix.count))
    guard !key.isEmpty else { return nil }
    self = .openSection(key)
  }

  var rawValue: String {
    switch self {
    case .openSection(let key): return Self.sectionPrefix + key
    }
  }
}
