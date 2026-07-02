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

  // Septask has no App/Mac delegate; the stash-and-consume path is
  // full-app-only, so entry points fall back to the focused-scene actions.
  private static var hostNavigation: NavigationState? {
    #if SEPTASK
    nil
    #elseif os(iOS)
    AppDelegate.navigation
    #elseif os(macOS)
    MacAppDelegate.navigation
    #else
    nil
    #endif
  }

  private static func stashPending() {
    #if SEPTASK
    #elseif os(iOS)
    AppDelegate.pendingOpenNewTask = true
    #elseif os(macOS)
    MacAppDelegate.pendingOpenNewTask = true
    #endif
  }

  private static func takePending() -> Bool {
    #if SEPTASK
    return false
    #elseif os(iOS)
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
