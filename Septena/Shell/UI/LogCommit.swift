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
  case flourish(motion: CommitMotion, accent: Color, intensity: Double,
                caption: String? = nil, voteEyebrow: Bool = true)
  /// Habit-streak milestone — radiating rings with the streak number
  /// popping in. Fired when a streak crosses a milestone rung.
  case ignition(accent: Color, streak: Int)
  /// Generalized milestone moment — same ignition choreography with a
  /// headline + caption instead of a streak count. Fired for training PRs
  /// and goal target/held rungs (see MilestonePresenter).
  case milestone(accent: Color, headline: String, caption: String)
  /// The Septena mark "opening" — the seven logo discs burst outward from
  /// center along their heptagonal vectors. `.spectrum` wears the canonical
  /// rainbow (the everyday in-app celebration); `.gold` wears the foil and is
  /// reserved for premium Septena+ moments (see `SeptenaPlusPaywall`).
  case septenaOpen(headline: String, caption: String, palette: SeptenaMarkPalette)
}

/// Which coloring the seven-disc "open" flourish wears. The split is a brand
/// rule, not a style knob: gold is reserved for premium (Septena+) moments;
/// the spectrum is the everyday mark used anywhere in the app.
enum SeptenaMarkPalette: Equatable {
  /// The canonical seven-color spectrum (red → purple). Everyday, in-app.
  case spectrum
  /// The Septena+ foil. Reserved for premium moments only.
  case gold
}

// MARK: - Center (the fire API)

/// The hero day dial's circle in *global* coordinates, published by
/// `DayDialHero` while it's on screen. The `.arc` flourish orbits this circle
/// when it can — clearing the last Today task then visibly completes the
/// ring the dial draws all day — and falls back to its screen-wide sweep
/// when the dial isn't visible (other tabs, hero hidden, scrolled away).
struct DayDialAnchor: Equatable {
  var center: CGPoint
  var radius: CGFloat
}

/// Injected into the environment at the app root. Any user-log action calls
/// `fire(_:)`; the single `LogCommitOverlay` watches `trigger` and replays.
@MainActor
@Observable
final class LogCommitCenter {
  /// The style to play on the next trigger bump.
  private(set) var style: LogCommitStyle?
  /// Replay counter — same contract as `CommitFlourish`'s `trigger`.
  private(set) var trigger: Int = 0
  /// Where the hero day dial currently sits (global coords), or nil when it
  /// isn't on screen. Written by `DayDialHero`; read by the overlay only
  /// while an `.arc` flourish renders, so routine scroll updates don't
  /// invalidate anything.
  var dayDialAnchor: DayDialAnchor?

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
  /// User opt-out for logging animations (Settings ▸ Customize). Absent → on.
  /// Gates the milestone `ignition` here too; the `flourish` case renders
  /// `CommitFlourish`, which honors the same key on its own.
  @AppStorage(SettingsKey.loggingAnimationsEnabled) private var animationsEnabled = true

  var body: some View {
    ZStack {
      if !reduceMotion, animationsEnabled, let style = center.style {
        LogCommitStyleView(style: style, trigger: center.trigger,
                           dialAnchor: center.dayDialAnchor)
      }
    }
    .allowsHitTesting(false)
  }
}

/// The style → renderer switch, factored out of `LogCommitOverlay` so any
/// host (the root overlay, the Settings milestone-preview bench) renders a
/// `LogCommitStyle` identically. Does NOT gate on Reduce Motion / the
/// animations pref — hosts decide that (the root overlay gates; the gallery
/// bypasses on purpose).
struct LogCommitStyleView: View {
  let style: LogCommitStyle
  let trigger: Int
  /// Only the root overlay knows the hero dial position; pass nil elsewhere.
  var dialAnchor: DayDialAnchor? = nil

  var body: some View {
    switch style {
    case .flourish(let motion, let accent, let intensity, let caption, let voteEyebrow):
      CommitFlourish(motion: motion, accent: accent,
                     intensity: intensity, trigger: trigger,
                     dialAnchor: motion == .arc ? dialAnchor : nil,
                     caption: caption, voteEyebrow: voteEyebrow)
    case .ignition(let accent, let streak):
      IgnitionView(accent: accent, streak: streak, trigger: trigger)
    case .milestone(let accent, let headline, let caption):
      IgnitionView(accent: accent, headline: headline, caption: caption,
                   trigger: trigger)
    case .septenaOpen(let headline, let caption, let palette):
      SeptenaOpenView(headline: headline, caption: caption,
                      palette: palette, trigger: trigger)
    }
  }
}

// MARK: - Streak milestones
//
// Streak detection + once-only bookkeeping moved to `MilestoneMutator`
// (SeptenaCore/MilestoneEngine.swift): the latched, CloudKit-synced
// GoalMilestone rows replaced the old UserDefaults map, and detection now
// runs at the mutator boundary so every write path (views, intents, MCP)
// detects. Presentation is `MilestonePresenter`, mounted at the app root.

// MARK: - Ignition (milestone moment)

/// Radiating rings + the streak number springing in. The "your streak
/// crossed a milestone" moment the dashboard advertised but never paid off.
struct IgnitionView: View {
  let accent: Color
  let headline: String
  let caption: String
  let trigger: Int

  /// Streak convenience — the original habit-milestone form.
  init(accent: Color, streak: Int, trigger: Int) {
    self.init(accent: accent, headline: "\(streak)", caption: "DAY STREAK",
              trigger: trigger)
  }

  init(accent: Color, headline: String, caption: String, trigger: Int) {
    self.accent = accent
    self.headline = headline
    self.caption = caption
    self.trigger = trigger
  }

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
        Text(headline)
          .scaledFont(size: 64, weight: .bold, design: .rounded, relativeTo: .largeTitle)
          .monospacedDigit()
          .foregroundStyle(accent)
          .contentTransition(.numericText())
        Text(caption)
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

// MARK: - Septena open (the mark unfurling)

/// The Septena mark unfurling: the seven canonical discs start clustered tight
/// at the center, then radiate outward along their heptagonal vectors —
/// *growing* the whole way out before they fade at the edges. The headline +
/// caption spring in over the center. A seven-disc burst where `IgnitionView`
/// is a three-ring one. The `palette` decides the coloring — spectrum for
/// everyday in-app celebrations, gold for premium Septena+ moments. Honors
/// Reduce Motion the same way (never rendered under it).
struct SeptenaOpenView: View {
  let headline: String
  let caption: String
  let palette: SeptenaMarkPalette
  let trigger: Int

  /// Point distance a unit heptagon vector travels at `spread == 1`. The
  /// regular heptagon's vectors are ~0.277 long, so a disc reaches ~100pt out.
  private let travel: CGFloat = 360
  private let dotSize: CGFloat = 20

  /// Per-disc fill. Spectrum gives each its canonical color; gold paints all
  /// seven in the foil.
  private func discColor(_ index: Int) -> Color {
    switch palette {
    case .spectrum: return SeptenaPlus.discColors[index]
    case .gold:     return SeptenaPlus.foil
    }
  }

  /// Headline + caption color. Gold matches the foil; the spectrum's text
  /// stays neutral so it doesn't compete with the seven colored discs.
  private var textColor: Color {
    switch palette {
    case .spectrum: return .primary
    case .gold:     return SeptenaPlus.foil
    }
  }

  @State private var spread: CGFloat = 0.0
  @State private var dotScale: CGFloat = 0.12
  @State private var dotOpacity: Double = 0
  @State private var textScale: CGFloat = 0.5
  @State private var textOpacity: Double = 0

  var body: some View {
    ZStack {
      ForEach(Array(SeptenaPlus.discCenters.enumerated()), id: \.offset) { index, center in
        // Direction from the heptagon's center (0.5, 0.5) to this disc.
        let dx = center.x - 0.5
        let dy = center.y - 0.5
        Circle()
          .fill(discColor(index))
          .frame(width: dotSize, height: dotSize)
          .scaleEffect(dotScale)
          .opacity(dotOpacity)
          .offset(x: dx * travel * spread, y: dy * travel * spread)
      }
      VStack(spacing: 2) {
        Text(headline)
          .scaledFont(size: 64, weight: .bold, relativeTo: .largeTitle)
          .foregroundStyle(textColor)
        Text(caption)
          .font(.septenaBadge)
          .foregroundStyle(textColor)
      }
      .scaleEffect(textScale)
      .opacity(textOpacity)
    }
    // Gating happens at the call site (LogCommitOverlay / the paywall's own
    // Reduce-Motion branch), so bare `withAnimation` here is safe.
    .task(id: trigger) {
      guard trigger > 0 else { return }
      spread = 0.0; dotScale = 0.12; dotOpacity = 0
      textScale = 0.5; textOpacity = 0
      // Open: the discs radiate outward from a tight center cluster, growing
      // the whole way out in one continuous motion.
      withAnimation(.easeIn(duration: 0.12)) { dotOpacity = 0.95 }
      withAnimation(.easeOut(duration: 1.1)) {
        spread = 2.6
        dotScale = 2.8
      }
      // Fade them out near the edges, after they've grown and traveled.
      withAnimation(.easeOut(duration: 0.45).delay(0.7)) {
        dotOpacity = 0
      }
      withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) {
        textScale = 1.0
        textOpacity = 1.0
      }
      try? await Task.sleep(nanoseconds: 1_150_000_000)
      withAnimation(.easeOut(duration: 0.4)) {
        textScale = 1.15
        textOpacity = 0
      }
    }
  }
}
