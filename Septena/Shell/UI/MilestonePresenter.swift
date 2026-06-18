import SwiftUI

// MilestonePresenter — the single consumer of the MilestoneInbox.
//
// Detectors run at the mutator boundary (MilestoneEngine) and only WRITE
// rows; this presenter, called from the app root on a debounced data-change
// signal and on scene activation, fires the visual for whatever is queued
// and marks it presented. One path for every source — habit toggles,
// training logs, background Withings ingests, App Intents — so a milestone
// earned anywhere surfaces the same way.
//
// Tiering (see docs/GOAL_MILESTONES_PLAN.md): PR / goal-target / held-30
// get the full ignition card, streaks get the classic streak ignition,
// intermediate rungs and XP get a louder burst flourish. Only the top
// milestone of a batch animates; the rest are marked presented quietly —
// never stack celebrations.
@MainActor
enum MilestonePresenter {

  /// Fires the celebration for whatever's queued. Returns `true` when a real
  /// milestone was presented this call — the app root uses that as the signal
  /// to (gently, once, much later) arm the "support Septena" earned moment.
  @discardableResult
  static func presentPending(milestones: MilestoneMutator,
                             theme: SectionTheme,
                             logCommit: LogCommitCenter,
                             now: Date) -> Bool {
    let pending = milestones.pendingPresentation(now: now)
    guard !pending.isEmpty else { return false }
    let top = pending.max { tier($0) < tier($1) } ?? pending[0]
    logCommit.fire(style(for: top, theme: theme))
    Haptics.success()
    A11y.announce(MilestoneUnits.label(top))
    milestones.markPresented(ids: pending.map(\.id), at: now)
    return true
  }

  /// The real tiering: which celebration a given milestone earns. Pure, so
  /// the Settings preview bench fires the SAME mapping a real crossing does.
  static func style(for m: GoalMilestoneEntity, theme: SectionTheme) -> LogCommitStyle {
    let accent = theme.color(for: sectionKey(scope: m.scope))
    switch m.kind {
    case "streak":
      return .ignition(accent: accent, streak: Int(m.value))
    case "pr":
      return .milestone(accent: accent, headline: MilestoneUnits.headline(m),
                        caption: caption(for: m))
    case "rung" where m.rungKey == "target" || m.rungKey == "held30":
      return .milestone(accent: accent, headline: MilestoneUnits.headline(m),
                        caption: caption(for: m))
    default:
      // Intermediate rungs / XP — acknowledged, not interrupted.
      return .flourish(motion: .burst, accent: accent, intensity: 1.2)
    }
  }

  // MARK: - Helpers

  /// Which section's accent a milestone wears, from its scope prefix.
  private static func sectionKey(scope: String) -> String {
    if scope.hasPrefix("habit:") { return "habits" }
    if scope.hasPrefix("exercise:") || scope == "training.volume" { return "training" }
    return "body"   // goal:<id> scopes are body-metric goals in v1
  }

  /// PR / target / held30 beat streaks beat everything else.
  private static func tier(_ m: GoalMilestoneEntity) -> Int {
    switch m.kind {
    case "pr": return 3
    case "rung": return (m.rungKey == "target" || m.rungKey == "held30") ? 3 : 1
    case "streak": return 2
    default: return 1
    }
  }

  /// Short all-caps caption under the headline number. The full sentence
  /// lives in `label` (and is what VoiceOver announces); the card wants the
  /// terse form.
  private static func caption(for m: GoalMilestoneEntity) -> String {
    switch m.kind {
    case "pr":
      // label is "<Exercise> PR: <w> kg" — the part before the colon is
      // already the terse form.
      return String(m.label.prefix(while: { $0 != ":" })).uppercased()
    case "rung" where m.rungKey == "held30":
      return "HELD 30 DAYS"
    case "rung" where m.rungKey == "target":
      return "TARGET REACHED"
    default:
      return m.label.uppercased()
    }
  }

  private static func trim(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
  }
}
