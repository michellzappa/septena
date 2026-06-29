import Foundation

/// One route for every "start a training session" entry point that originates
/// outside the view tree — today that's `StartTrainingSessionIntent` (Siri /
/// Shortcuts / automations). Mirrors `OpenNewTaskRouting`: apply directly when
/// the app is warm (NavigationState already stashed on the platform delegate),
/// otherwise stash the chosen session-type id for the app's `.task` to drain on
/// first render.
///
/// The draft is NOT built here. Setting `pendingTrainingType` +
/// `showTrainingSession` reuses the exact in-app path the dashboard QuickAdd
/// menu's "Start: Upper" shortcuts use: `TrainingSessionView`'s `.onAppear`
/// matches the pending id against the live catalog and calls `store.start(...)`,
/// which builds the `DraftSession`, persists it, and (iOS) starts the Live
/// Activity. So a Shortcut and a tap on the dashboard converge on one code path.
///
/// If a session is already in progress, the pending type is ignored by that
/// `.onAppear` (it only auto-starts when `store.draft == nil`), so this
/// surfaces the live session rather than discarding it — matching the in-app
/// "resume" semantics.
@MainActor
enum TrainingStartRouting {
  static func apply(to navigation: NavigationState, typeId: String) {
    navigation.pendingTrainingType = typeId
    navigation.showTrainingSession = true
  }

  static func dispatch(typeId: String) {
    if let navigation = hostNavigation {
      apply(to: navigation, typeId: typeId)
      return
    }
    stashPending(typeId)
  }

  static func consumePending(into navigation: NavigationState) -> Bool {
    guard let typeId = takePending() else { return false }
    apply(to: navigation, typeId: typeId)
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

  private static func stashPending(_ typeId: String) {
    #if os(iOS)
    AppDelegate.pendingTrainingStart = typeId
    #elseif os(macOS)
    MacAppDelegate.pendingTrainingStart = typeId
    #endif
  }

  private static func takePending() -> String? {
    #if os(iOS)
    defer { AppDelegate.pendingTrainingStart = nil }
    return AppDelegate.pendingTrainingStart
    #elseif os(macOS)
    defer { MacAppDelegate.pendingTrainingStart = nil }
    return MacAppDelegate.pendingTrainingStart
    #else
    return nil
    #endif
  }
}
