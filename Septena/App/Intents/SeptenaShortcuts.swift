import AppIntents

/// The app's single, global App Shortcuts surface — and the one place every
/// `AppShortcut` literal must live. Apple's `appintentsmetadataprocessor`
/// parses this property statically and accepts ONLY inline `AppShortcut(...)`
/// initializers (or `if #available` blocks) — no array literals, no
/// references to per-section factory properties. So per-section files own the
/// intents + entities; their voice phrases are declared together here.
///
/// HARD CAP: Apple allows a maximum of 10 AppShortcuts per app (build-
/// enforced — exceeding it fails the metadata export). We have 17 intents, so
/// this list is the 10 that get a built-in, zero-config "Hey Siri" phrase.
///
/// This is NOT a capability limit. EVERY intent is Siri-callable — the other
/// 7 just need the user to assign a phrase once in the Shortcuts app (and all
/// 17 already appear there and in Spotlight). The only thing curated here is
/// which 10 ship with a phrase out of the box, chosen purely by how often the
/// action gets logged — one primary log action per section. No action is held
/// back for being "sensitive": every log is treated the same; nothing is singled out as sensitive.
/// The 7 without a built-in phrase are the 5 catalog "Add" setup actions plus
/// the two lowest-frequency primaries (Chores, Goals, Gut rotate here).
/// Rebalance by swapping an `AppShortcut(...)` block in/out — keep total ≤10.
///
/// Phrases must contain \(.applicationName); the leading "Hey Siri," is
/// implicit. iOS 26 only allows a phrase to capture a parameter when it's an
/// AppEntity/AppEnum — otherwise Siri prompts via the @Parameter dialog.
struct SeptenaShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    // 1 — Tasks (highest-frequency capture)
    AppShortcut(
      intent: AddTaskIntent(),
      phrases: [
        "Add to \(.applicationName)",
        "Add task to \(.applicationName)",
        "Add a task to \(.applicationName)",
        "Add a to-do to \(.applicationName)",
        "New task in \(.applicationName)",
        "New reminder in \(.applicationName)",
        "Create a task in \(.applicationName)",
        "Capture in \(.applicationName)",
        "Remind me in \(.applicationName)",
        "In \(.applicationName) add a task",
      ],
      shortTitle: "Add Task",
      systemImageName: "checklist"
    )
    // 2 — Supplements
    AppShortcut(
      intent: MarkSupplementTakenIntent(),
      phrases: [
        "Log a supplement in \(.applicationName)",
        "Mark a supplement taken in \(.applicationName)",
        "Took a supplement in \(.applicationName)",
        "Log supplements in \(.applicationName)",
      ],
      shortTitle: "Mark Supplement Taken",
      systemImageName: "pills"
    )
    // 3 — Hydration
    AppShortcut(
      intent: LogWaterIntent(),
      phrases: [
        "Log water in \(.applicationName)",
        "Log a glass of water in \(.applicationName)",
        "Track water in \(.applicationName)",
        "Add water in \(.applicationName)",
      ],
      shortTitle: "Log Water",
      systemImageName: "drop.fill"
    )
    // 5 — Nutrition
    AppShortcut(
      intent: LogMealIntent(),
      phrases: [
        "Log a meal in \(.applicationName)",
        "Log food in \(.applicationName)",
        "Log what I ate in \(.applicationName)",
        "Track a meal in \(.applicationName)",
      ],
      shortTitle: "Log Meal",
      systemImageName: "fork.knife"
    )
    // 6 — Habits
    AppShortcut(
      intent: MarkHabitDoneIntent(),
      phrases: [
        "Mark a habit done in \(.applicationName)",
        "Log a habit in \(.applicationName)",
        "Check off a habit in \(.applicationName)",
      ],
      shortTitle: "Mark Habit Done",
      systemImageName: "repeat"
    )
    // 7 — Groceries (the "I'm out of X" flow)
    AppShortcut(
      intent: MarkGroceryLowIntent(),
      phrases: [
        "Add to my shopping list in \(.applicationName)",
        "I'm out of an item in \(.applicationName)",
        "Mark a grocery low in \(.applicationName)",
      ],
      shortTitle: "Mark Grocery Low",
      systemImageName: "cart"
    )
    // 9 — Training
    AppShortcut(
      intent: LogTrainingIntent(),
      phrases: [
        "Log a workout in \(.applicationName)",
        "Log an exercise in \(.applicationName)",
        "Log a set in \(.applicationName)",
      ],
      shortTitle: "Log Workout",
      systemImageName: "figure.strengthtraining.traditional"
    )
    // 10 — Mood
    AppShortcut(
      intent: LogMoodIntent(),
      phrases: [
        "Log my mood in \(.applicationName)",
        "Log a mood in \(.applicationName)",
      ],
      shortTitle: "Log Mood",
      systemImageName: "face.smiling"
    )
  }
}
