import AppIntents

// "Hey Siri, add buy milk to Septena." Runs in the app's own process — when
// the system triggers the intent with the app cold-killed, iOS launches it in
// the background just to run `perform()`. That path may execute before the
// SwiftUI scene's `.task` mounts, so we can't assume the CKEngine is bound —
// `prepareSection()` (→ `SeptenaServices.start()`) is the shared, idempotent
// boot both the scene and every intent call. The matching Siri phrases live
// in `SeptenaShortcuts` (SectionLogIntent.swift): Apple's metadata processor
// requires every AppShortcut literal to sit inline in that one provider.

struct AddTaskIntent: SectionLogIntent {
  static let sectionKey = "tasks"
  static let title: LocalizedStringResource = "Add Task"
  static let description = IntentDescription("Add a new to-do to Septena.")

  @Parameter(title: "Title", requestValueDialog: "What's the task?")
  var taskTitle: String

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    await prepareSection()
    _ = SeptenaServices.shared.taskMutator.create(title: taskTitle)
    return .result(dialog: "Added “\(taskTitle)” to Septena.")
  }
}
