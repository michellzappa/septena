import SwiftUI

// Store-health surfacing — the two places a lost write becomes visible.
//
// `StoreHealth` rolls a failed save back, so the write is discarded and the
// row keeps its previous value. Before this, that was reported only to
// Console: the user saw work they had typed not be there and had no way to
// tell a lost write from their own mistake. Two surfaces, deliberately
// different in weight:
//
//   `.storeHealthAlert()`       — at the moment of loss, once per failure.
//   `StoreHealthSettingsSection` — the running count, for after the fact.
//
// Neither can affect whether a write lands. They only report what
// `StoreHealth` already decided and already rolled back.

// MARK: - At the moment of loss

/// Presents a lost write as a standard alert, then acknowledges it so the same
/// failure is never reported twice.
///
/// An alert, not a quieter banner, on purpose: the user has just lost typed
/// work, and the whole defect was that nothing said so. A notice they can miss
/// would reproduce the complaint. It is also plain SwiftUI — no new overlay
/// infrastructure to maintain, per the standard-SwiftUI rule in CLAUDE.md.
///
/// Hung on the task surfaces rather than fired globally from the mutator: the
/// surfaces are where a lost task is noticed, and a view-level alert cannot
/// fire while the app is in the background with nothing on screen. A failure
/// raised while no task surface is mounted stays in `unreportedFailure` and is
/// reported when one appears.
struct StoreHealthAlertModifier: ViewModifier {
  @State private var state = StoreHealthState.shared

  func body(content: Content) -> some View {
    content.alert(
      StoreHealthState.alertTitle,
      isPresented: Binding(
        get: { state.unreportedFailure != nil },
        // A dismissal from anywhere (the button, Esc, a tap outside) clears
        // the pending report — the user has seen it either way.
        set: { if !$0 { state.acknowledge() } }
      )
    ) {
      Button(String(localized: "OK", comment: "Store health alert — dismiss")) {
        state.acknowledge()
      }
    } message: {
      Text(StoreHealthState.alertMessage)
    }
  }
}

extension View {
  /// Report a rolled-back save to the user, once per failure. Apply to a task
  /// surface — see `StoreHealthAlertModifier` for why it is not global.
  func storeHealthAlert() -> some View {
    modifier(StoreHealthAlertModifier())
  }
}

// MARK: - After the fact

/// The running count and the last failure's engineering summary, for a
/// diagnostics pane. Renders nothing at all when no save has failed this
/// process — the healthy case should not carry a row that invites worry.
struct StoreHealthSettingsSection: View {
  @State private var state = StoreHealthState.shared

  var body: some View {
    if let last = state.lastFailure {
      Section {
        LabeledContent(
          String(localized: "Writes rolled back",
                 comment: "Store health diagnostics — count of failed saves this launch"),
          value: "\(state.saveFailures)")
        LabeledContent(
          String(localized: "Most recent",
                 comment: "Store health diagnostics — when the last save failed"),
          value: last.at.formatted(date: .abbreviated, time: .standard))
        // The raw summary names the entity and attribute that failed, which is
        // what makes a report actionable. Selectable so it can be pasted into
        // an issue; `.footnote` because it is for diagnosis, not reading.
        Text(last.summary)
          .font(.footnote)
          .textSelection(.enabled)
          .foregroundStyle(.secondary)
      } header: {
        Text(String(localized: "Store health",
                    comment: "Store health diagnostics — section header"))
      } footer: {
        Text(String(
          localized: """
            A save that fails is rolled back, so that one change is not stored \
            while later changes keep working. The count resets when the app \
            relaunches. If this is above zero, the edit it names needs redoing.
            """,
          comment: "Store health diagnostics — section footer"))
      }
    }
  }
}
