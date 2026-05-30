import AppIntents

// Powers Siri ("Hey Siri, add buy milk to Septena"), Spotlight actions,
// and Shortcuts.app. Runs in the app's own process — when the system
// triggers an intent with the app cold-killed, iOS launches it in the
// background just to run `perform()`. That cold-launch path may execute
// before the SwiftUI scene's `.task` mounts, so we can't assume the
// CKEngine has been bound. `prepareSection()` (→ `SeptenaServices.start()`)
// is the shared, idempotent entry point: both the scene and this intent
// call it, the first wires the stack, the second awaits the same task.
// Once it returns, `taskMutator.create(...)` routes through the same
// CloudKit-backed mutation stack as the main app.

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

// Tasks' contribution to the global `SeptenaShortcuts` provider (declared
// in SectionLogIntent.swift). Kept here so the action lives with its intent.
enum TaskShortcuts {
  static var addTask: AppShortcut {
    AppShortcut(
      intent: AddTaskIntent(),
      // Phrases must contain \(.applicationName); the leading "Hey Siri, "
      // is implicit. iOS 26 restricts inline String parameter templating to
      // AppEntity/AppEnum, so the title can't be captured from the phrase —
      // once any phrase matches, Siri prompts via the @Parameter's
      // requestValueDialog. The wide variety saves memorizing one wording.
      phrases: [
        "Add to \(.applicationName)",
        "Add task to \(.applicationName)",
        "Add reminder to \(.applicationName)",
        "Add a task to \(.applicationName)",
        "Add a to-do to \(.applicationName)",
        "New task in \(.applicationName)",
        "New to-do in \(.applicationName)",
        "New reminder in \(.applicationName)",
        "Create task in \(.applicationName)",
        "Create a task in \(.applicationName)",
        "Save to \(.applicationName)",
        "Capture in \(.applicationName)",
        "Note in \(.applicationName)",
        "Remind me in \(.applicationName)",
        "Remind me with \(.applicationName)",
        "Remind me using \(.applicationName)",
        "In \(.applicationName) remind me",
        "In \(.applicationName) add a task",
        "In \(.applicationName) add a to-do",
        "In \(.applicationName) create a task",
        "Using \(.applicationName) remind me",
      ],
      shortTitle: "Add Task",
      systemImageName: "checklist"
    )
  }
}
