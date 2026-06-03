import SwiftUI
import SwiftData

// System-wide "log committed" confirmation language.
//
// One overlay, mounted once at the app root, that any surface can fire
// through `LogCommitCenter`. The choreography varies by domain so the
// celebration *matches what was logged* — the idea proven by
// `MoodCommitAnimation`, generalized into a reusable layer.
//
// Reduce Motion is honored centrally in `LogCommitOverlay`: when it's on,
// the visual is skipped entirely and only the call site's haptic +
// `A11y.announce(...)` carry the confirmation. Decorative motion is a hard
// opt-out, not a hint — same contract as `CommitFlourish` /
// `MoodCommitAnimation`.

// MARK: - Style catalog

/// The choreography to play. Add a case here (plus a branch in
/// `LogCommitOverlay`) when a domain wants its own "feel". Each carries the
/// section accent so the celebration reads as native to the surface.
enum LogCommitStyle: Equatable {
  /// A section's commit flourish — the motion matches what was logged.
  /// The `motion` is chosen at the call site from the section's data axis
  /// (see `CommitMotion`); `accent` makes it read as native to the surface;
  /// `intensity` scales loudness by the log's magnitude. This is the
  /// generalized form of the Mood-meter idea.
  case flourish(motion: CommitMotion, accent: Color, intensity: Double)
  /// Habit-streak milestone — radiating rings with the streak number
  /// popping in. Fired when a streak crosses 7 / 30 / 100 / 365.
  case ignition(accent: Color, streak: Int)
}

// MARK: - Center (the fire API)

/// Injected into the environment at the app root. Any user-log action calls
/// `fire(_:)`; the single `LogCommitOverlay` watches `trigger` and replays.
@MainActor
@Observable
final class LogCommitCenter {
  /// The style to play on the next trigger bump.
  private(set) var style: LogCommitStyle?
  /// Replay counter — same contract as `CommitFlourish`'s `trigger`.
  private(set) var trigger: Int = 0

  /// Fire a celebration. Safe to call from any foreground user-log site;
  /// the overlay itself no-ops under Reduce Motion. Pair it with a haptic
  /// and (ideally) an `A11y.announce(...)` at the call site so the
  /// confirmation survives when the visual is suppressed.
  func fire(_ style: LogCommitStyle) {
    self.style = style
    trigger &+= 1
  }
}

// MARK: - Overlay (mounted once at the app root)

/// Full-canvas, non-interactive overlay. Mount once above the app shell;
/// presented sheets render above it (call sites that log inside a sheet
/// fire after the sheet dismisses).
struct LogCommitOverlay: View {
  @Environment(LogCommitCenter.self) private var center
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      if !reduceMotion, let style = center.style {
        switch style {
        case .flourish(let motion, let accent, let intensity):
          CommitFlourish(motion: motion, accent: accent,
                         intensity: intensity, trigger: center.trigger)
        case .ignition(let accent, let streak):
          IgnitionView(accent: accent, streak: streak, trigger: center.trigger)
        }
      }
    }
    .allowsHitTesting(false)
  }
}

// MARK: - Streak milestones

/// The streak lengths worth celebrating. A milestone fires only when the
/// streak *lands exactly* on a threshold — crossing 7 celebrates once, not
/// again on day 8.
enum StreakMilestones {
  static let thresholds = [7, 30, 100, 365]

  /// The threshold `streak` exactly equals, or nil if it's between milestones.
  static func reached(_ streak: Int) -> Int? {
    thresholds.contains(streak) ? streak : nil
  }
}

/// Remembers the highest milestone we've already celebrated per habit, so a
/// milestone fires once and only once — until the streak breaks and the user
/// re-earns it. Backed by `UserDefaults` (a small `[habitId: milestone]` map).
enum HabitMilestoneStore {
  private static let key = "habit.celebratedMilestones"

  private static func load() -> [String: Int] {
    (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
  }

  private static func save(_ map: [String: Int]) {
    UserDefaults.standard.set(map, forKey: key)
  }

  static func lastCelebrated(_ habitId: String) -> Int {
    load()[habitId] ?? 0
  }

  static func setCelebrated(_ habitId: String, _ milestone: Int) {
    var map = load()
    map[habitId] = milestone
    save(map)
  }

  /// Re-base the stored milestone to the largest threshold the current streak
  /// still satisfies (0 if none). Called when a habit is un-done: if the
  /// streak drops below a celebrated milestone, crossing it again celebrates.
  static func reconcile(_ habitId: String, currentStreak: Int) {
    let earned = StreakMilestones.thresholds.filter { $0 <= currentStreak }.max() ?? 0
    var map = load()
    map[habitId] = earned
    save(map)
  }
}

// MARK: - Orchestration

/// Toggle a habit and, on completion, fire the milestone celebration when the
/// streak lands on a fresh threshold. Foreground habit-toggle sites call this
/// instead of poking `ChecklistMutator` directly so the haptic + celebration +
/// VoiceOver announcement stay consistent. `done` is the value being written.
/// `logCommit` is optional because some habit-toggle hosts (e.g. the
/// Home-Screen-Quick-Action sheet) don't inherit the root environment. When
/// it's nil the toggle, haptic, and milestone bookkeeping all still run — only
/// the visual celebration is skipped.
@MainActor
func completeHabit(id: String, date: String, done: Bool,
                   checklist: ChecklistMutator, context: ModelContext,
                   theme: SectionTheme, logCommit: LogCommitCenter?) {
  checklist.toggleHabit(id: id, date: date, done: done)
  Haptics.tick()
  // Milestone celebration is only for the *current* streak. Historical
  // backfills/corrections should update the day state, but must never rewrite
  // the "last celebrated" marker or fire a today-style streak celebration.
  guard date == SeptenaDate.today else { return }
  let streak = ChecklistMirror.habitStreak(context: context, habitId: id, asOf: date)
  guard done else { HabitMilestoneStore.reconcile(id, currentStreak: streak); return }
  if let m = StreakMilestones.reached(streak), HabitMilestoneStore.lastCelebrated(id) < m {
    HabitMilestoneStore.setCelebrated(id, m)
    Haptics.success()
    logCommit?.fire(.ignition(accent: theme.color(for: "habits"), streak: streak))
    A11y.announce("\(streak) day streak!")
  }
}

// MARK: - Ignition (streak milestone)

/// Radiating rings + the streak number springing in. The "your streak
/// crossed a milestone" moment the dashboard advertised but never paid off.
struct IgnitionView: View {
  let accent: Color
  let streak: Int
  let trigger: Int

  @State private var ringScale: CGFloat = 0.4
  @State private var ringOpacity: Double = 0
  @State private var numberScale: CGFloat = 0.5
  @State private var numberOpacity: Double = 0

  var body: some View {
    ZStack {
      // Three rings staggered outward — the "ignition" expansion.
      ForEach(0..<3, id: \.self) { i in
        Circle()
          .strokeBorder(accent.opacity(ringOpacity), lineWidth: 3)
          .frame(width: 150, height: 150)
          .scaleEffect(ringScale + CGFloat(i) * 0.35)
      }
      VStack(spacing: 2) {
        Text("\(streak)")
          .scaledFont(size: 64, weight: .bold, design: .rounded, relativeTo: .largeTitle)
          .monospacedDigit()
          .foregroundStyle(accent)
          .contentTransition(.numericText())
        Text("DAY STREAK")
          .font(.septenaBadge)
          .foregroundStyle(accent)
      }
      .scaleEffect(numberScale)
      .opacity(numberOpacity)
    }
    // Gating happens in LogCommitOverlay, so bare `withAnimation` here is
    // safe — this view never renders under Reduce Motion.
    .task(id: trigger) {
      guard trigger > 0 else { return }
      ringScale = 0.4; ringOpacity = 0.85
      numberScale = 0.5; numberOpacity = 0
      withAnimation(.easeOut(duration: 0.9)) {
        ringScale = 1.7
        ringOpacity = 0
      }
      withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) {
        numberScale = 1.0
        numberOpacity = 1.0
      }
      try? await Task.sleep(nanoseconds: 1_150_000_000)
      withAnimation(.easeOut(duration: 0.4)) {
        numberScale = 1.15
        numberOpacity = 0
      }
    }
  }
}
