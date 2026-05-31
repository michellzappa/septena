import AppIntents
import SwiftUI

// Standard AppIntents discoverability UX, surfaced two ways:
//   • This central "Siri & Shortcuts" settings pane — a `ShortcutsLink`
//     (jumps to the Shortcuts app with every Septena action preloaded) plus
//     a reference list of `SiriTipView`s teaching the spoken phrases.
//   • Contextual `SiriTipView`s inside each section's detail pane (see
//     `sectionSiriTip(_:)`), so the tip appears where the user already
//     manages that data.
//
// PLATFORM. `SiriTipView` and `ShortcutsLink` are iOS / iPadOS only — both
// are unavailable on macOS. The *intents* still work on Mac (they appear in
// the Mac Shortcuts app through the shared `SeptenaShortcuts` provider); only
// these discoverability VIEWS are gated. macOS gets honest explanatory text
// instead, so the settings row stays meaningful on every platform without
// gating the destination across SettingsView's switch statements.
//
// Both iOS surfaces use Apple's tip chrome unstyled, so they match every
// other app's Siri tips. Adding a section means adding one `DismissableSiriTip`
// line here (and, if it deserves a contextual tip, a `sectionSiriTip` call in
// its plugin) — mirroring how `SeptenaShortcuts` lists one `AppShortcut` per
// action.

#if os(iOS)
/// A `SiriTipView` that owns its visibility, so the tip's dismiss control
/// actually works (vs. a throwaway `.constant(true)` binding). Generic over
/// the concrete intent type because `SiriTipView` resolves the spoken phrase
/// from the intent's `AppShortcut` at compile time.
struct DismissableSiriTip<I: AppIntent>: View {
  let intent: I
  @State private var visible = true

  init(_ intent: I) { self.intent = intent }

  var body: some View {
    SiriTipView(intent: intent, isVisible: $visible)
  }
}
#endif

/// Contextual Siri tip for a section's detail pane. Wrapped in a `Section`
/// so it drops straight into a plugin's `detailPaneContent()` alongside its
/// other `Section { }` blocks. iOS-only: on macOS it renders nothing (no
/// empty "Ask Siri" section), since Siri tips don't exist there.
@MainActor @ViewBuilder
func sectionSiriTip<I: AppIntent>(_ intent: I) -> some View {
  #if os(iOS)
  Section {
    DismissableSiriTip(intent)
  } header: {
    Text("Ask Siri")
  }
  #endif
}

/// Section-key → primary log intent, rendered as a contextual Siri tip. This
/// is the ONE place that maps a section to "the action you'd voice-trigger,"
/// called once from `SectionDetailPane` so every section's tip appears in its
/// Settings page without editing 13 plugins. The switch is unavoidable — Siri
/// tips need a concrete intent type, which Swift can't derive from the key
/// string (the same reason `SeptenaShortcuts` lists concrete intents). Keys
/// match `SectionManifest.key`. Sections with no loggable action (sleep, body,
/// activity) fall through to nothing. iOS-only via `sectionSiriTip`.
@MainActor @ViewBuilder
func sectionSiriTip(forKey key: String) -> some View {
  switch key {
  case "tasks":       sectionSiriTip(AddTaskIntent())
  case "supplements": sectionSiriTip(MarkSupplementTakenIntent())
  case "habits":      sectionSiriTip(MarkHabitDoneIntent())
  case "chores":      sectionSiriTip(CompleteChoreIntent())
  case "hydration":   sectionSiriTip(LogWaterIntent())
  case "caffeine":    sectionSiriTip(LogCaffeineIntent())
  case "cannabis":    sectionSiriTip(LogCannabisIntent())
  case "nutrition":   sectionSiriTip(LogMealIntent())
  case "training":    sectionSiriTip(LogTrainingIntent())
  case "mood":        sectionSiriTip(LogMoodIntent())
  case "gut":         sectionSiriTip(LogGutEntryIntent())
  case "groceries":   sectionSiriTip(MarkGroceryLowIntent())
  case "goals":       sectionSiriTip(AddGoalIntent())
  default:            EmptyView()
  }
}

struct SiriShortcutsSettingsPane: View {
  var body: some View {
    Form {
      #if os(iOS)
      Section {
        ShortcutsLink()
      } header: {
        Text("Shortcuts")
      } footer: {
        Text("Opens the Shortcuts app with every Septena action ready to drop into a shortcut, Home Screen tile, or automation.")
      }

      // One DismissableSiriTip per voice action — mirrors the 10 built-in
      // AppShortcuts in `SeptenaShortcuts` (Apple's hard cap of 10). Keep this
      // list and the provider in sync. Every OTHER action is still Siri-
      // callable too — assign it a phrase in the Shortcuts app.
      Section {
        DismissableSiriTip(AddTaskIntent())
        DismissableSiriTip(MarkSupplementTakenIntent())
        DismissableSiriTip(LogWaterIntent())
        DismissableSiriTip(LogCaffeineIntent())
        DismissableSiriTip(LogMealIntent())
        DismissableSiriTip(MarkHabitDoneIntent())
        DismissableSiriTip(MarkGroceryLowIntent())
        DismissableSiriTip(LogCannabisIntent())
        DismissableSiriTip(LogTrainingIntent())
        DismissableSiriTip(LogMoodIntent())
      } header: {
        Text("Ask Siri")
      } footer: {
        Text("Say one of these to log without opening the app. Asking for a section that's turned off turns it back on automatically — your data is never lost. Every other action is Siri-callable too — open the Shortcuts app to give it a phrase.")
      }
      #else
      Section {
        Text("Open the Shortcuts app to build shortcuts and automations from Septena's actions. Trigger them with Siri on iPhone and iPad.")
          .foregroundStyle(.secondary)
      } header: {
        Text("Shortcuts")
      }
      #endif
    }
    .formStyle(.grouped)
  }
}
