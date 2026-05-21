import AppIntents

// Powers Siri ("Hey Siri, add buy milk to Septena"), Spotlight actions,
// and Shortcuts.app. Runs in the app's own process — when the system
// triggers an intent with the app cold-killed, iOS launches it in the
// background just to run `perform()`. That cold-launch path may execute
// before the SwiftUI scene's `.task` mounts, so we can't assume the
// CKEngine has been bound. `SeptenaServices.shared.start()` is the
// shared, idempotent entry point: both the scene and this intent call
// it, the first one wires the stack, the second awaits the same task.
// Once it returns, `taskMutator.create(...)` routes to CloudKit instead
// of falling back to FastAPI.

struct AddTaskIntent: AppIntent {
  static let title: LocalizedStringResource = "Add Task"
  static let description = IntentDescription("Add a new to-do to Septena.")

  @Parameter(title: "Title", requestValueDialog: "What's the task?")
  var taskTitle: String

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    await SeptenaServices.shared.start()
    _ = SeptenaServices.shared.taskMutator.create(title: taskTitle)
    return .result(dialog: "Added “\(taskTitle)” to Septena.")
  }
}

struct SeptenaShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: AddTaskIntent(),
      // AppShortcuts phrases must contain \(.applicationName); the leading
      // "Hey Siri, " is implicit. iOS 26 restricts inline String parameter
      // templating to AppEntity/AppEnum, so the title can't be captured
      // directly from the phrase — once any phrase matches, Siri prompts
      // "What's the task?" via the @Parameter's requestValueDialog. The
      // wide variety here is so the user doesn't have to memorize one
      // exact wording.
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
      systemImageName: "plus.circle"
    )
  }
}
