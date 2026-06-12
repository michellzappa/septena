import AppIntents
import Foundation

// App Intents spine — every loggable section action becomes a Shortcut, a
// Siri phrase, and a Spotlight result through this one pattern.
//
// A `SectionLogIntent` is tied to its section by the manifest `key`. That
// single string is the join to everything section-shaped: it boots the
// shared stack, auto-enables the section, and (via `manifest`) hands the
// intent the section's catalog identity. Adding a section's intents means
// one new file that conforms to this — no central switch, the same shape as
// `SectionPlugin` / `SectionManifest`.
//
// The protocol is deliberately NOT @MainActor. An AppIntent's type must stay
// nonisolated so its `init()` is callable from the nonisolated
// `AppShortcutsProvider.appShortcuts` context (and the OS metadata
// extractor). Only the work that touches the SwiftData / CloudKit stack hops
// onto the main actor: each conformer's `perform()` and `prepareSection()`.

protocol SectionLogIntent: AppIntent {
  /// Matches `SectionManifest.key` (and `SectionEntity.id`). The one tie
  /// between an intent and its section.
  static var sectionKey: String { get }
}

extension SectionLogIntent {
  /// The catalog row this intent belongs to. Force-unwrap is safe: a
  /// `sectionKey` always names a real manifest entry (a compile-time
  /// constant matched to `SectionManifest.all`).
  var manifest: SectionManifest { SectionManifest.byKey[Self.sectionKey]! }

  /// Run before every mutation. Boots the CloudKit-backed stack
  /// (idempotent; safe on a cold background launch), then REFUSES if the
  /// section is turned off.
  ///
  /// ENABLEMENT. App Shortcuts are extracted statically by the OS at
  /// install/update time, so the *set* of shortcuts can't be filtered by the
  /// runtime `SectionEntity.isEnabled` flag — the system wouldn't see the
  /// change. We honor enablement at run time instead, and we mirror MCP: a
  /// disabled section's tools simply aren't available. Rather than silently
  /// re-enabling on use, we throw `SectionDisabledError`, which Siri /
  /// Shortcuts surface as a spoken reason. The other surface that reflects
  /// this is the parameter picker — each `EntityQuery.suggestedEntities()`
  /// returns nothing for a disabled section. `.always` sections (tasks, goals)
  /// are locked on and always pass.
  @MainActor
  func requireSection() async throws {
    await SeptenaServices.shared.start()
    guard SeptenaServices.shared.isSectionEnabled(Self.sectionKey) else {
      throw SectionDisabledError(label: manifest.defaultLabel)
    }
  }
}

/// Thrown by `requireSection()` when an intent targets a section the user has
/// turned off. Conforms to `CustomLocalizedStringResourceConvertible` so Siri
/// and the Shortcuts app present the reason to the person instead of a generic
/// failure.
struct SectionDisabledError: Error, CustomLocalizedStringResourceConvertible {
  let label: String
  var localizedStringResource: LocalizedStringResource {
    "\(label) is turned off in Septena. Turn it on to use this action."
  }
}

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
/// back for being "sensitive": cannabis is treated exactly like any other log.
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
