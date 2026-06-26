import Foundation

/// One route for every "new to-do" entry point — Control Center, ⌘N, menu
/// bar, deep links. Lands on Tasks ▸ Today with the composer open.
@MainActor
enum OpenNewTaskRouting {
  static func apply(to navigation: NavigationState) {
    navigation.pendingTab = .tasks
    navigation.path = [.filter(.today)]
    navigation.shouldStartCreating = true
  }

  static func dispatch() {
    if let navigation = hostNavigation {
      apply(to: navigation)
      return
    }
    stashPending()
  }

  static func consumePending(into navigation: NavigationState) -> Bool {
    guard takePending() else { return false }
    apply(to: navigation)
    return true
  }

  private static var hostNavigation: NavigationState? {
    #if os(iOS)
    AppDelegate.navigation
    #elseif os(macOS)
    MacAppDelegate.navigation
    #else
    nil
    #endif
  }

  private static func stashPending() {
    #if os(iOS)
    AppDelegate.pendingOpenNewTask = true
    #elseif os(macOS)
    MacAppDelegate.pendingOpenNewTask = true
    #endif
  }

  private static func takePending() -> Bool {
    #if os(iOS)
    defer { AppDelegate.pendingOpenNewTask = false }
    return AppDelegate.pendingOpenNewTask
    #elseif os(macOS)
    defer { MacAppDelegate.pendingOpenNewTask = false }
    return MacAppDelegate.pendingOpenNewTask
    #else
    return false
    #endif
  }
}
