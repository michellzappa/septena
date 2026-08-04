import SwiftUI

// The task checkbox and its celebration vocabulary — the highest-frequency
// control in the app, and the one place the row's motion feel is defined.
// Split out of TaskComponents.swift.

// MARK: - Checkbox feel
//
// The checkbox's celebration vocabulary — the checkbox-local counterpart of
// `CommitMotion`. Checkable rows celebrate *at the box*, never on the canvas
// (checking things off is the app's highest-frequency action; full-screen
// flourishes there would wear out fast).
//
// STANDARDIZED: every checkable row (tasks, habits, supplements, chores) now
// shares `.stamp` — one consistent tap across the app. The other three feels
// remain as an available vocabulary, demoed in Settings ▸ Customize's Motion
// Gallery, and can be reassigned per row type if we ever want to differentiate
// again:
//
//   • .stamp                — a crisp stamp + one pulse ring. Done. (in use)
//   • .echo                 — the pulse answers itself: one more mark on the
//                             streak, today echoed by the days behind it.
//   • .drop                 — the fill falls in and lands with a soft
//                             splash. One more capsule down.
//   • .tuck                 — stamps, dips, and files the ring downward.
//                             Put away, onto the pile.
//
// Every feel lives in the box's own geometry and resolves within ~0.45s,
// with a matched CoreHaptics pattern timed to its visual beats — quiet
// transients and faint swells, never a flat buzz.
enum CheckFeel {
  case stamp
  case echo
  case drop
  case tuck

  /// The compact haptic that pairs with this feel — same beats the visual
  /// plays, built from quiet transients + faint swells. `intensity` nudges
  /// loudness inside a narrow band (rows pass day-progress); the band is
  /// clamped tight on purpose — these stay subtle at any count.
  ///
  /// What separates the feels is *rhythm*, not loudness: stamp is one beat,
  /// echo is two spaced beats, drop is a fall-then-thud, tuck is a thud
  /// then a later, softer close. Each timing matches its visual exactly.
  func hapticSpec(intensity: Double = 1) -> HapticPatternSpec {
    let i = Float(min(1.2, max(0.7, intensity)))
    switch self {
    case .stamp:
      // ONE beat. Crisp at the check's landing, then the faintest settle
      // riding right behind it — reads as a single crack.
      return HapticPatternSpec(beats: [
        HapticBeat(kind: .transient, time: 0.04, intensity: 0.42 * i, sharpness: 0.78),
        HapticBeat(kind: .transient, time: 0.12, intensity: 0.14 * i, sharpness: 0.45),
      ], fallback: .tick)
    case .echo:
      // TWO beats, clearly spaced: today's mark, answered by a quieter,
      // rounder echo (visual ring at +0.18s). The gap is the signature.
      return HapticPatternSpec(beats: [
        HapticBeat(kind: .transient, time: 0,    intensity: 0.45 * i, sharpness: 0.62),
        HapticBeat(kind: .transient, time: 0.18, intensity: 0.24 * i, sharpness: 0.38),
      ], fallback: .tick)
    case .drop:
      // FALL → THUD: a faint swell of air while the fill falls, then a
      // soft round landing synced to the impact squash (~0.15s).
      return HapticPatternSpec(beats: [
        HapticBeat(kind: .continuous, time: 0, duration: 0.13, intensity: 0.18 * i, sharpness: 0.15),
        HapticBeat(kind: .transient, time: 0.15, intensity: 0.45 * i, sharpness: 0.3),
      ], fallback: .tick)
    case .tuck:
      // THUD → soft CLOSE: a low muted thud, then the drawer easing shut
      // synced to the visual's dip (~0.22s). Slowest rhythm of the four.
      return HapticPatternSpec(beats: [
        HapticBeat(kind: .transient, time: 0,    intensity: 0.4 * i,  sharpness: 0.25),
        HapticBeat(kind: .transient, time: 0.22, intensity: 0.24 * i, sharpness: 0.45),
      ], fallback: .tick)
    }
  }
}

// MARK: - Task row language flag

/// Feature flag for the revised task-row visual language
/// (docs/TASK_ROW_LANGUAGE_SPEC.md): form-driven readiness on the left box
/// (dashed = unratified proposal, a haloed corner accent dot = unread context),
/// the agent cue lifted off the right edge, and Today relocated to a right-side
/// chip so the box stays neutral. On by default; set the `taskRowLanguageV2`
/// UserDefaults key to false to restore the legacy row.
enum TaskRowFlags {
  static var languageV2: Bool {
    UserDefaults.standard.object(forKey: "taskRowLanguageV2") as? Bool ?? true
  }
  /// Settings ▸ Tasks ▸ Today ▸ "Show aging on Today". Absent → on.
  static var agingEnabled: Bool {
    UserDefaults.standard.object(forKey: SettingsKey.tasksShowAging) as? Bool ?? true
  }
  /// Settings ▸ Tasks ▸ "Suggest filing destinations". Absent → on.
  static var filingSuggestionsEnabled: Bool {
    UserDefaults.standard.object(forKey: SettingsKey.tasksFilingSuggestions) as? Bool ?? true
  }
}

// MARK: - Checkbox

struct TaskCheckbox: View {
  @Environment(SectionTheme.self) private var theme
  /// Optional override — used by non-task items (habits/supplements/chores)
  /// to wear their section accent. `nil` means inherit list tint.
  var tint: Color? = nil
  let isDone: Bool
  /// Readiness form (language v2): when true the open box is drawn dashed to
  /// mark an unratified *proposal* — not completable until ratified.
  var dashed: Bool = false
  /// Readiness form (language v2): a small haloed corner dot in this color marks
  /// a committed task carrying *unread context*. `nil` → no dot.
  var cornerDot: Color? = nil
  /// When true (and not done), the checkbox stroke/fill switch to
  /// `Theme.todayAccent` to signal a task 'promoted to Today' — folding the
  /// today indicator into the checkbox itself, so it no longer sits as a
  /// separate glyph inline with the title.
  var isToday: Bool = false
  /// Language v2: fill (0…1) for the **Today tenure dial** that wraps the box —
  /// the single temporal device that replaces the old amber `arrivedToday` box
  /// fill *and* the trailing carry-age ring. `nil` → no dial. Driven by
  /// `SeptenaTask.todayTenureFill`. Gold, concentric, fills one seventh per day
  /// to full at a week; keeps the box itself pure form (no hue on the control).
  var tenureFill: Double? = nil
  /// Rising-edge counter from `PromoteFlashStore` — plays a brief amber ring
  /// when the row is pinned to Today.
  var promotePulseTrigger: Int = 0
  /// Which celebration plays on check. Standardized to `.stamp` across every
  /// checkable row; the other feels stay available (see `CheckFeel`).
  var feel: CheckFeel = .stamp
  /// When true, ignore the user's "Logging animations" opt-out and always
  /// play the feel on check (Reduce Motion is still honored). Set only by
  /// the Motion Gallery, where the whole point is to feel it on demand.
  var ignoresUserPreference: Bool = false
  let onToggle: () -> Void

  // Smaller rounded square than the old circle glyph — reads as a checkbox,
  // not a progress dot. Sizes are the visible box, not the tap area.
  #if os(macOS)
  private static let boxSize: CGFloat = 14
  private static let boxCorner: CGFloat = 3.5
  private static let boxStroke: CGFloat = 1.2
  private static let checkSize: CGFloat = 9
  #else
  private static let boxSize: CGFloat = 18
  private static let boxCorner: CGFloat = 4.5
  private static let boxStroke: CGFloat = 1.4
  private static let checkSize: CGFloat = 12
  #endif
  /// Tenure fill never reaches full opacity — a hair of translucency keeps an
  /// aged Today task from reading as a solid/"done" box.
  private static let tenureMaxOpacity: Double = 0.7

  /// Checkbox chrome is neutral gray by default; Today rows swap stroke
  /// and fill to `Theme.todayAccent`.
  private var boxStrokeColor: Color {
    // Legacy: amber box meant "is on Today" on off-Today surfaces.
    if !TaskRowFlags.languageV2, isToday { return Theme.todayAccent }
    // Language v2: outline is "presence" amber when the surface wants it
    // (i.e. `isToday` is true). For aging, we fade an amber overlay in sync
    // with `tenureFill` below (no step-change on day 1+).
    if TaskRowFlags.languageV2, isToday { return Theme.todayAccent }
    return Theme.checkboxStroke
  }
  private var boxFillColor: Color {
    if !TaskRowFlags.languageV2, isToday { return Theme.todayAccent }
    return Theme.checkboxFill
  }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Decorative feel honors the same opt-out as the commit flourishes
  /// (Settings ▸ Customize). The check/uncheck state change itself still
  /// animates via `.a11yAnimation` — that's feedback, not decoration.
  @AppStorage(SettingsKey.loggingAnimationsEnabled) private var animationsEnabled = true

  // One-shot feel state, driven imperatively from onChange (same pattern as
  // the flourish renderers). All values rest at "invisible"; `resetFeel()`
  // snaps them back on uncheck so a mid-animation undo can't strand them.
  @State private var ringScale: CGFloat = 1
  @State private var ringOpacity: Double = 0
  @State private var ringStroke: Color? = nil
  @State private var ringDrift: CGFloat = 0    // tuck: ring files downward
  @State private var echoScale: CGFloat = 1    // echo: the second, quieter ring
  @State private var echoOpacity: Double = 0
  @State private var bodyDrop: CGFloat = 0     // drop: fill falls in from above
  @State private var bodySquash: CGFloat = 1   // drop: impact squash
  @State private var bodyDip: CGFloat = 0      // tuck: box dips, then recovers

  private var checkboxButton: some View {
    Button(action: onToggle) {
      ZStack {
        // Today tenure fill — the box's interior tints gold, deepening with
        // days-on-Today (see `tenureFill`): transparent on the arrival day, a
        // seventh more each carried day, capped just shy of opaque so an aged
        // task never reads as a solid/done box. Shape never changes — only the
        // fill's opacity (and, in language v2, the open outline warms in sync).
        // Sits behind the open stroke; hidden once done.
        if TaskRowFlags.languageV2, !isDone, let tenureFill {
          let strength = tenureFill.isFinite ? max(0, min(1, tenureFill)) : 0
          RoundedRectangle(cornerRadius: Self.boxCorner, style: .continuous)
            .fill(Theme.todayAccent.opacity(strength * Self.tenureMaxOpacity))
            .frame(width: Self.boxSize, height: Self.boxSize)
            .a11yAnimation(Theme.Motion.quick, value: strength)
        }
        // Echo ring (habits) — the second, quieter pulse behind the main one.
        RoundedRectangle(cornerRadius: Self.boxCorner, style: .continuous)
          .strokeBorder((tint ?? boxFillColor).opacity(echoOpacity), lineWidth: 1.2)
          .frame(width: Self.boxSize, height: Self.boxSize)
          .scaleEffect(echoScale)
        // Main pulse ring — every feel throws exactly one (tuck's drifts
        // down as it fades). Local and brief on purpose: checkable rows
        // celebrate at the box, never on the canvas.
        RoundedRectangle(cornerRadius: Self.boxCorner, style: .continuous)
          .strokeBorder((ringStroke ?? tint ?? boxFillColor).opacity(ringOpacity), lineWidth: 1.5)
          .frame(width: Self.boxSize, height: Self.boxSize)
          .scaleEffect(ringScale)
          .offset(y: ringDrift)
        // Open chrome — fades out under the arriving fill. Language v2 draws it
        // dashed for an unratified proposal (a provisional, not-yet task).
        RoundedRectangle(cornerRadius: Self.boxCorner, style: .continuous)
          .strokeBorder(boxStrokeColor,
                        style: StrokeStyle(lineWidth: Self.boxStroke,
                                           dash: (dashed && TaskRowFlags.languageV2) ? [2.5, 2] : []))
          .frame(width: Self.boxSize, height: Self.boxSize)
          .opacity(isDone ? 0 : 1)
          .a11yAnimation(Theme.Motion.quick, value: isDone)
          .a11yAnimation(Theme.Motion.quick, value: isToday)

        // Language v2 aging: fade the outline from gray → yellow in lockstep
        // with the Today tenure fill, so we don't have a step change when
        // `tenureFill` becomes non-nil.
        if TaskRowFlags.languageV2, !isDone, !isToday, let tenureFill {
          let strength = tenureFill.isFinite ? max(0, min(1, tenureFill)) : 0
          RoundedRectangle(cornerRadius: Self.boxCorner, style: .continuous)
            .strokeBorder(Theme.todayAccent.opacity(strength * Self.tenureMaxOpacity),
                          lineWidth: Self.boxStroke)
            .frame(width: Self.boxSize, height: Self.boxSize)
            .opacity(isDone ? 0 : 1)
            .a11yAnimation(Theme.Motion.quick, value: strength)
        }
        // Fill + check, grouped so the feel choreography (drop, squash, dip)
        // moves them as one body. The fill pops with a touch of overshoot;
        // the check stamps in from smaller, reading as follow-through.
        // Uncheck shrinks away quietly (undo is a correction, not a moment).
        ZStack {
          RoundedRectangle(cornerRadius: Self.boxCorner, style: .continuous)
            .fill(boxFillColor)
            .frame(width: Self.boxSize, height: Self.boxSize)
            .scaleEffect(isDone ? 1 : 0.55)
            .opacity(isDone ? 1 : 0)
            .a11yAnimation(isDone ? Theme.Motion.check : Theme.Motion.quick, value: isDone)
          Image(systemName: "checkmark")
            .scaledFont(size: Self.checkSize, weight: .bold)
            .foregroundStyle(.white)
            .scaleEffect(isDone ? 1 : 0.25)
            .opacity(isDone ? 1 : 0)
            .a11yAnimation(isDone ? Theme.Motion.check : Theme.Motion.quick, value: isDone)
        }
        .scaleEffect(x: 1, y: bodySquash, anchor: .bottom)
        .offset(y: bodyDrop + bodyDip)

        // Unread-context corner dot (language v2): a haloed accent dot pinned to
        // the box's top-right, reading as an "unread" marker on a committed task.
        if let cornerDot, TaskRowFlags.languageV2 {
          Circle()
            .fill(cornerDot)
            .frame(width: 7, height: 7)
            .overlay(Circle().stroke(Theme.paperBackground, lineWidth: 1.5))
            .offset(x: Self.boxSize / 2, y: -Self.boxSize / 2)
        }
      }
      .frame(width: Theme.checkboxTap, height: Theme.checkboxTap)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  var body: some View {
    checkboxButton
      .offset(x: -Theme.checkboxLeadingNudge)
    // Keep the checkbox OUT of the keyboard focus ring. On macOS a focusable
    // button inside a selected List row gets activated by Space — which silently
    // completed tasks. Completion is the checkbox-click or ⌘K; never a stray
    // Space. (Mouse clicks are unaffected — this only governs keyboard focus.)
    .focusable(false)
    .onChange(of: isDone) { _, done in
      // Celebrate only on a live check. `onChange` skips first render, so a
      // list of already-done rows (Logbook) never fires a wall of ripples.
      guard done else { resetFeel(); return }
      guard !reduceMotion, animationsEnabled || ignoresUserPreference else { return }
      playFeel()
    }
    .onChange(of: promotePulseTrigger) { old, new in
      guard new > old, !reduceMotion, animationsEnabled else { return }
      playTodayPromotePulse()
    }
  }

  /// One ring pulse from the box outward. `reach` tunes how far it travels —
  /// the splash of a drop stays tighter than a stamp's pulse.
  private func pulse(color: Color? = nil, reach: CGFloat = 1.9) {
    ringStroke = color
    ringScale = 0.9
    ringOpacity = 0.55
    ringDrift = 0
    a11yAnimate(.easeOut(duration: 0.4)) {
      ringScale = reach
      ringOpacity = 0
    }
  }

  /// A quiet amber ring when a task is pinned to Today.
  private func playTodayPromotePulse() {
    pulse(color: Theme.todayAccent, reach: 1.6)
  }

  /// The per-feel choreography. Imperative (like the flourish renderers) so
  /// beats can be sequenced; everything resolves within ~0.6s and ends at
  /// rest, so nothing lingers and rapid checking never queues motion.
  ///
  /// The four are separated by RHYTHM (the same axis the haptics use):
  /// stamp = one beat · echo = two spaced beats · drop = fall-then-thud ·
  /// tuck = thud then a slow settle down. Loudness stays near-constant.
  private func playFeel() {
    switch feel {
    case .stamp:
      // One beat: a single immediate pulse. The reference the others
      // deviate from.
      pulse()

    case .echo:
      // Two beats: the first ring tight and quick, the echo clearly
      // separated (+0.18s), smaller and softer — today's mark answered by
      // the days behind it. Timed to the haptic's second beat.
      pulse(reach: 1.7)
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(180))
        echoScale = 0.9
        echoOpacity = 0.4
        a11yAnimate(.easeOut(duration: 0.4)) {
          echoScale = 1.45
          echoOpacity = 0
        }
      }

    case .drop:
      // Fall → thud: a taller fall than feels polite, so the landing reads —
      // deep squash on impact, a tight splash, then spring back round.
      bodyDrop = -11
      a11yAnimate(.spring(response: 0.34, dampingFraction: 0.62)) { bodyDrop = 0 }
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(140))
        a11yAnimate(.easeOut(duration: 0.08)) { bodySquash = 0.78 }
        pulse(reach: 1.5)
        try? await Task.sleep(for: .milliseconds(90))
        a11yAnimate(.spring(response: 0.2, dampingFraction: 0.5)) { bodySquash = 1 }
      }

    case .tuck:
      // Thud → slow close: the ring drifts well downward as it fades —
      // filed onto the pile — and the box takes a deep, unhurried dip
      // (+0.22s, matching the haptic's close) before recovering.
      ringScale = 0.95
      ringOpacity = 0.5
      ringDrift = 0
      a11yAnimate(.easeOut(duration: 0.55)) {
        ringScale = 1.3
        ringOpacity = 0
        ringDrift = 11
      }
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(180))
        a11yAnimate(.easeOut(duration: 0.14)) { bodyDip = 4 }
        a11yAnimate(.spring(response: 0.3, dampingFraction: 0.65).delay(0.14)) { bodyDip = 0 }
      }
    }
  }

  /// Snap every feel value back to rest, unanimated. Called on uncheck so an
  /// undo mid-celebration can't strand a half-played ring or squash.
  private func resetFeel() {
    ringScale = 1
    ringOpacity = 0
    ringStroke = nil
    ringDrift = 0
    echoScale = 1
    echoOpacity = 0
    bodyDrop = 0
    bodySquash = 1
    bodyDip = 0
  }
}

// MARK: - Completion celebration
//
// Tasks celebrate at the checkbox (the `.stamp` feel above) — with ONE
// exception that earns the canvas. The celebration-budget rule: if a moment
// can fire twice in an hour, it never gets the screen. Clearing the last
// open Today task fires at most once a day, so it plays `.arc` — a comet
// arcing across the screen, the day's arc completed (Today's glyph is the
// sun; the metaphor comes free). Everything else scales the *haptic* only:
//
//   • ordinary task          → the plain stamp — crisp, quiet
//   • Today task             → stamp + a low, soft "filed" after-beat
//   • the LAST Today task    → the `.arc` flourish + its matched sweep haptic
//
// Owned by the toggle call sites (same pattern as ChoreRow / HabitRow):
// only they know their list context, so they pass `clearedToday`. `logCommit`
// is nil-safe — hosts outside the root env keep the haptic, skip the visual.

@MainActor
enum TaskCelebration {
  static func completed(isToday: Bool,
                        clearedToday: Bool,
                        accent: Color,
                        logCommit: LogCommitCenter?) {
    if clearedToday {
      // A canvas moment by the containment policy (see CommitFeedback.commit):
      // clearing the last open Today task fires at most once a day, so it earns
      // the `.arc` flourish + its matched sweep haptic.
      Haptics.play(CommitMotion.arc.hapticSpec(intensity: 1))
      logCommit?.fire(.flourish(motion: .arc, accent: accent, intensity: 1))
    } else if isToday {
      // A Today task: the stamp, then a rounder, lower "filed" beat.
      Haptics.play(HapticPatternSpec(beats: [
        HapticBeat(kind: .transient, time: 0.04, intensity: 0.45, sharpness: 0.7),
        HapticBeat(kind: .transient, time: 0.16, intensity: 0.22, sharpness: 0.3),
      ], fallback: .tick))
    } else {
      Haptics.play(CheckFeel.stamp.hapticSpec())
    }
  }
}
