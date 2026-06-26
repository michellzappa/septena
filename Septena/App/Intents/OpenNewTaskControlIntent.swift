import AppIntents
import Foundation

/// Control Center / Lock Screen — opens Septena on the new-task composer.
/// Control Widgets cannot prompt for a title inline; this jumps straight into
/// the create flow (same as toolbar + / ⌘N).
struct OpenNewTaskControlIntent: AppIntent {
  static var title: LocalizedStringResource = "Add Task"
  static var description = IntentDescription("Open Septena to a new to-do.")
  static var openAppWhenRun: Bool = true

  @MainActor
  func perform() async throws -> some IntentResult {
    #if WIDGET_EXTENSION
    // Widget metadata only — hand off to the host app via deep link.
    guard let url = URL(string: "septena://tasks/new") else { return .result() }
    return .result(opensIntent: OpenURLIntent(url))
    #else
    OpenNewTaskRouting.dispatch()
    return .result()
    #endif
  }
}
