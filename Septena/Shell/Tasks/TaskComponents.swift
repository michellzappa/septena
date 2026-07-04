import SwiftUI
import UniformTypeIdentifiers

// MARK: - Task drag payload (sidebar re-home + in-list reorder)

/// Drag payload for re-homing one or more tasks onto a sidebar destination,
/// or reordering them within a manually-ordered list (`TaskReorderDrop`).
struct TaskDragIDs: Codable, Hashable, Transferable {
  let ids: [String]

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .septenaTaskDragIDs)
  }
}

extension UTType {
  static let septenaTaskDragIDs = UTType(exportedAs: "com.septena.task-drag-ids")
}

/// Row-level reorder target for manually-ordered lists — the in-list
/// counterpart of the sidebar's `SidebarTaskDrop`, same `TaskDragIDs`
/// payload. While a drag hovers, the row parts an animated gap on the side
/// the drop would land (top half = insert above, bottom half = below) —
/// pushing the rows beneath out of the way — with an accent insertion line
/// in the opening. `perform` is nil on rows that aren't reorderable
/// (date/tier-sorted lists), which makes the modifier a pass-through.
///
/// Uses `onDrop(of:delegate:)` rather than `.dropDestination` deliberately:
/// only `DropDelegate.dropUpdated` exposes the hover location live (needed
/// for the insertion side) and the drop proposal (`.move`, so the cursor
/// doesn't wear the green copy badge).
struct TaskReorderDrop: ViewModifier {
  static let gapHeight: CGFloat = 14

  let perform: ((_ ids: [String], _ before: Bool) -> Bool)?
  /// nil = no drag hovering; true = would insert above this row; false = below.
  @State private var hoverBefore: Bool? = nil
  @State private var rowHeight: CGFloat = 0

  func body(content: Content) -> some View {
    if let perform {
      content
        // Height of the un-parted row — captured before the gap padding so
        // the delegate's midline compare doesn't shift when the gap opens.
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { rowHeight = $0 }
        .padding(.top, hoverBefore == true ? Self.gapHeight : 0)
        .padding(.bottom, hoverBefore == false ? Self.gapHeight : 0)
        .overlay(alignment: .top) { if hoverBefore == true { insertionLine } }
        .overlay(alignment: .bottom) { if hoverBefore == false { insertionLine } }
        .animation(.easeOut(duration: 0.14), value: hoverBefore)
        .onDrop(of: [.septenaTaskDragIDs],
                delegate: TaskReorderDropDelegate(hoverBefore: $hoverBefore,
                                                  rowHeight: { rowHeight },
                                                  perform: perform))
    } else {
      content
    }
  }

  /// A 3pt accent capsule centered in the parted gap.
  private var insertionLine: some View {
    Capsule()
      .fill(Color.accentColor)
      .frame(height: 3)
      .padding(.horizontal, 20)
      .frame(height: Self.gapHeight)
  }
}

private struct TaskReorderDropDelegate: DropDelegate {
  @Binding var hoverBefore: Bool?
  let rowHeight: () -> CGFloat
  let perform: (_ ids: [String], _ before: Bool) -> Bool

  func validateDrop(info: DropInfo) -> Bool {
    info.hasItemsConforming(to: [.septenaTaskDragIDs])
  }

  func dropEntered(info: DropInfo) { update(info) }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    update(info)
    return DropProposal(operation: .move)
  }

  func dropExited(info: DropInfo) { hoverBefore = nil }

  func performDrop(info: DropInfo) -> Bool {
    let before = hoverBefore ?? true
    hoverBefore = nil
    // A drag carries ONE payload holding the whole selection (see
    // `dragPayload(for:)`), so the first provider is the drop.
    guard let provider = info.itemProviders(for: [.septenaTaskDragIDs]).first
    else { return false }
    provider.loadDataRepresentation(forTypeIdentifier: UTType.septenaTaskDragIDs.identifier) { data, _ in
      guard let data,
            let payload = try? JSONDecoder().decode(TaskDragIDs.self, from: data)
      else { return }
      DispatchQueue.main.async { _ = perform(payload.ids, before) }
    }
    return true
  }

  /// Which side of the row the pointer is on. The open gap pads the content
  /// down, so subtract it before the midline compare; the flip then moves the
  /// content *away* from the pointer, so the side is hysteresis-stable (no
  /// flicker at the midline).
  private func update(_ info: DropInfo) {
    let adjusted = info.location.y - (hoverBefore == true ? TaskReorderDrop.gapHeight : 0)
    hoverBefore = adjusted < rowHeight() / 2
  }
}

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
  /// Language v2: amber checkbox marking a task that newly *landed on Today on
  /// its own* (a scheduled/due plan that rolled in at the day boundary —
  /// Things-style "new on Today"). Transient; self-clears at the next rollover.
  /// This is the one place amber rides the control: it's the app's temporal
  /// identity color, and the trigger is recency, surfaced only as it arrives.
  var arrivedToday: Bool = false
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
  private static let tenureMaxOpacity: Double = 0.9

  /// Checkbox chrome is neutral gray by default; Today rows swap stroke
  /// and fill to `Theme.todayAccent`.
  private var boxStrokeColor: Color {
    // Legacy: amber box meant "is on Today" on off-Today surfaces.
    if !TaskRowFlags.languageV2, isToday { return Theme.todayAccent }
    // Language v2: the box stroke turns amber for a Today task — either seen on
    // an off-Today surface (project/area), where it marks "this is on Today"
    // (presence, `isToday`), or once it has carried over and carries a tenure
    // fill, so the warming gold interior reads against an amber edge rather than
    // a neutral one.
    if TaskRowFlags.languageV2, isToday || tenureFill != nil { return Theme.todayAccent }
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
        // fill's opacity. Sits behind the open stroke; hidden once done.
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
    withAnimation(.easeOut(duration: 0.4)) {
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
        withAnimation(.easeOut(duration: 0.4)) {
          echoScale = 1.45
          echoOpacity = 0
        }
      }

    case .drop:
      // Fall → thud: a taller fall than feels polite, so the landing reads —
      // deep squash on impact, a tight splash, then spring back round.
      bodyDrop = -11
      withAnimation(.spring(response: 0.34, dampingFraction: 0.62)) { bodyDrop = 0 }
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(140))
        withAnimation(.easeOut(duration: 0.08)) { bodySquash = 0.78 }
        pulse(reach: 1.5)
        try? await Task.sleep(for: .milliseconds(90))
        withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { bodySquash = 1 }
      }

    case .tuck:
      // Thud → slow close: the ring drifts well downward as it fades —
      // filed onto the pile — and the box takes a deep, unhurried dip
      // (+0.22s, matching the haptic's close) before recovering.
      ringScale = 0.95
      ringOpacity = 0.5
      ringDrift = 0
      withAnimation(.easeOut(duration: 0.55)) {
        ringScale = 1.3
        ringOpacity = 0
        ringDrift = 11
      }
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(180))
        withAnimation(.easeOut(duration: 0.14)) { bodyDip = 4 }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.65).delay(0.14)) { bodyDip = 0 }
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

// MARK: - Shared task row
//
// Canonical closed (non-editing) task row: checkbox + title + optional
// inline notes glyph + trailing date. Used by the Tasks drawer
// (`TasksDestinationView`) and intended to become the single row the deep
// `TaskListView` surface renders too, so both surfaces stay visually
// identical. Carries its own h/v padding so it drops straight into a
// `DrawerSection(padding: .none)` the same way `LogEntryRow` does.

/// Trailing provenance cue for an MCP/Claude-created row the user hasn't
/// engaged yet. Calm and peripheral (Things-style): it clears on contact via
/// `TaskMutator.acknowledge` and auto-decays after `AgentCue.decayWindow`.
/// Shares the row's single trailing agent-signal slot with `ConvoBadgeView` —
/// a live conversation's status badge wins, so the two never show at once.
/// Deliberately NOT a sparkle — a small accent dot reads as an unread marker,
/// drawn as a `circle.fill` at `.caption2` so it matches `ConvoBadgeView`'s
/// size and baseline exactly (they share the slot — all the dots read as one
/// family, differing only in color). To change the glyph, swap the symbol name.
struct AgentCueMarker: View {
  var tint: Color
  var body: some View {
    Image(systemName: "circle.fill")
      .font(.caption2)
      .foregroundStyle(tint)
      .accessibilityLabel(Text("Added by Claude, not yet seen"))
  }
}

/// Trailing cue for a row that *arrived in Today on its own* — a future-dated
/// plan whose day came, so it surfaced at the rollover rather than being added
/// by hand today (see `SeptenaTask.showsArrivedToday`). Same dot family as
/// `AgentCueMarker`/`ConvoBadgeView` so they read as one system, but drawn
/// hollow (`circle`) to say "newly here" rather than the agent cue's filled
/// "unseen by you". Calm and peripheral; it self-clears at the next rollover.
struct ArrivedTodayMarker: View {
  var tint: Color
  var body: some View {
    Image(systemName: "circle")
      .font(.caption2)
      .foregroundStyle(tint)
      .accessibilityLabel(Text("Arrived in Today"))
  }
}

// MARK: - Checkable row primitive
//
// The shared skeleton behind every row with a checkbox — tasks, habits,
// supplements, chores. Owns the checkbox (+ baseline guide), an optional
// leading emoji (the checklist sections), the title with its inactive
// (done / skipped / deferred / cancelled) treatment, an optional subtitle,
// and the h/v padding so it drops into a
// `DrawerSection(padding: .none)` the same way `LogEntryRow` does. The only
// genuinely per-type piece — the trailing region (dates, time, badges) — is a
// `@ViewBuilder` slot the caller fills. Per-type toggle side-effects
// (celebrations, haptics) live in `onToggle`; per-type long-press actions are
// attached by the caller via `.contextMenu` on the returned row.
extension VerticalAlignment {
  private enum RowTitleCenter: AlignmentID {
    static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
  }
  /// Vertical center of a row's *title* text. The checkbox pins to this so it
  /// stays optically centered whether the title is a single line or wraps to
  /// two — `.firstTextBaseline` only ever tracks the first line, so a two-line
  /// title left the checkbox riding high. A subtitle below the title does not
  /// pull the guide down, since it's set on the title line alone.
  static let rowTitleCenter = VerticalAlignment(RowTitleCenter.self)
}

struct CheckableRow<Trailing: View>: View {
  var tint: Color
  var isDone: Bool
  var isToday: Bool = false
  /// Readiness form (language v2) forwarded to `TaskCheckbox`: dashed = proposal,
  /// `cornerDot` = unread-context marker on a committed task.
  var dashed: Bool = false
  var cornerDot: Color? = nil
  var arrivedToday: Bool = false
  /// Forwarded to `TaskCheckbox`: fill (0…1) for the Today tenure dial, or nil.
  var tenureFill: Double? = nil
  /// The checkbox celebration this row plays on check (see `CheckFeel`).
  /// Standardized to the default `.stamp` across every checkable row.
  var feel: CheckFeel = .stamp
  /// Strikethrough + dimmed title. Usually `isDone`, but habits fold in
  /// skipped and chores fold in deferred, so the caller decides.
  var isInactive: Bool
  /// Optional leading emoji (checklist sections). Off → the title sits next
  /// to the box. Tasks leave this nil; their agent cue rides the trailing slot.
  var leadingEmoji: String? = nil
  let title: String
  /// Inline suffix hugging the title (e.g. the task notes glyph). Sits at the
  /// end of the title text — never in the right-aligned trailing slot.
  var showsNotesGlyph: Bool = false
  var subtitle: String? = nil
  /// Neutral selection capsule while this row's detail/edit modal is open
  /// (drawer surfaces — the deep list paints via `listRowBackground` instead).
  var isSelected: Bool = false
  /// Native `List(selection:)` cursor — keep title ink dark on the gray capsule.
  var isListSelected: Bool = false
  /// Rising-edge counter from `PromoteFlashStore` — plays a brief amber row wash.
  var promoteFlashTrigger: Int = 0
  /// Optional hero-animation anchors (`matchedGeometryEffect`): the Things-style
  /// inline editor reuses the same id + namespace on ITS title and checkbox, so
  /// on expand/collapse they GLIDE between the closed row and the open editor
  /// instead of cross-fading into a new position. Shared namespace, distinct
  /// ids. Nil everywhere else.
  var titleMatchID: String? = nil
  var checkboxMatchID: String? = nil
  var heroMatchNS: Namespace.ID? = nil
  /// Which endpoint of the hero glide is the `matchedGeometryEffect` source.
  /// Closed row and open editor must never both be `true` during a transition.
  var heroMatchIsSource: Bool = true
  @ViewBuilder var trailing: () -> Trailing
  let onToggle: () -> Void
  var onTap: (() -> Void)? = nil

  @Environment(\.rowHInset) private var rowHInset
  @Environment(\.rowVInset) private var rowVInset
  @Environment(\.a11yMotion) private var motion
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage(SettingsKey.loggingAnimationsEnabled) private var animationsEnabled = true
  @State private var washOpacity: Double = 0

  private var titleInk: Color {
    if isInactive { return Theme.inkSecondary }
    if isListSelected { return Theme.listSelectedInk }
    return Theme.inkPrimary
  }

  /// Title as inline `Text` so a notes glyph flows at the end of the last
  /// wrapped line (not parked beside line one in an `HStack`).
  private var titleLine: some View {
    titleText
      .font(.septenaTaskTitle)
      .strikethrough(isInactive)
      .opacity(isInactive ? 0.5 : 1)
      .lineLimit(2)
      .truncationMode(.tail)
      .fixedSize(horizontal: false, vertical: true)
      .matchedHeroGeometry(titleMatchID, heroMatchNS, isSource: heroMatchIsSource)
      .accessibilityLabel(showsNotesGlyph ? "\(title), has notes" : title)
  }

  private var titleText: Text {
    let head = Text(title).foregroundStyle(titleInk)
    guard showsNotesGlyph else { return head }
    return head + Text("\u{00a0}") + TaskNotesGlyph.inlineText()
  }

  var body: some View {
    HStack(alignment: .rowTitleCenter, spacing: Theme.iconTextGap) {
      TaskCheckbox(
        tint: tint,
        isDone: isDone,
        dashed: dashed,
        cornerDot: cornerDot,
        arrivedToday: arrivedToday,
        isToday: isToday,
        tenureFill: tenureFill,
        promotePulseTrigger: promoteFlashTrigger,
        feel: feel,
        onToggle: onToggle
      )
      .matchedHeroGeometry(checkboxMatchID, heroMatchNS, isSource: heroMatchIsSource)
      .alignmentGuide(.rowTitleCenter) { d in d[VerticalAlignment.center] }

      if let leadingEmoji {
        Text(leadingEmoji).font(.body)
      }

      VStack(alignment: .leading, spacing: 4) {
        titleLine
          .alignmentGuide(.rowTitleCenter) { d in d[VerticalAlignment.center] }
        if let subtitle {
          Text(subtitle)
            .font(.septenaMeta)
            .foregroundStyle(Theme.inkSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      trailing()
    }
    .padding(.horizontal, rowHInset)
    .padding(.vertical, rowVInset)
    .background(selectionHighlight)
    .contentShape(Rectangle())
    .modifier(OptionalTap(action: onTap))
    .onChange(of: promoteFlashTrigger) { old, new in
      guard new > old, !reduceMotion, animationsEnabled else { return }
      playPromoteWash()
    }
  }

  private func playPromoteWash() {
    washOpacity = 0.22
    motion.run(Theme.Motion.promote) { washOpacity = 0 }
  }

  @ViewBuilder private var selectionHighlight: some View {
    ZStack {
      if isSelected {
        RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
          .fill(Theme.listSelectionFill)
          .padding(.horizontal, max(0, rowHInset - 6))
      }
      if washOpacity > 0 {
        RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
          .fill(Theme.todayAccent.opacity(washOpacity))
          .padding(.horizontal, max(0, rowHInset - 6))
      }
    }
  }
}

extension CheckableRow where Trailing == EmptyView {
  init(tint: Color, isDone: Bool, isToday: Bool = false,
       isInactive: Bool, leadingEmoji: String? = nil,
       title: String, subtitle: String? = nil, isSelected: Bool = false,
       onToggle: @escaping () -> Void, onTap: (() -> Void)? = nil) {
    self.init(tint: tint, isDone: isDone, isToday: isToday,
              isInactive: isInactive,
              leadingEmoji: leadingEmoji, title: title, subtitle: subtitle,
              isSelected: isSelected,
              trailing: { EmptyView() }, onToggle: onToggle, onTap: onTap)
  }
}

extension View {
  /// Conditionally tag a view as a `matchedGeometryEffect` source/target so it
  /// GLIDES between the closed row and the open inline editor instead of
  /// cross-fading. Only position is matched (`.position`) — e.g. the closed-row
  /// title `Text` and the editor's `TextField` have different intrinsic sizes —
  /// so we glide the top-leading corner and let each keep its own size. No-op
  /// when either arg is nil. Used for both the title and the checkbox.
  @ViewBuilder
  func matchedHeroGeometry(_ id: String?, _ ns: Namespace.ID?, isSource: Bool = true) -> some View {
    if let id, let ns {
      matchedGeometryEffect(
        id: id, in: ns, properties: .position, anchor: .topLeading, isSource: isSource)
    } else {
      self
    }
  }
}

/// Adds an `onTapGesture` only when an action is supplied. Rows inside a
/// SwiftUI `List` (the deep `TaskListView`) pass `nil` so the row's own tap
/// gesture never swallows List selection — they wire tap externally instead.
private struct OptionalTap: ViewModifier {
  let action: (() -> Void)?
  func body(content: Content) -> some View {
    if let action {
      content.onTapGesture(perform: action)
    } else {
      content
    }
  }
}

// MARK: - Task checkbox model
//
// The SINGLE source of truth for how a `SeptenaTask` maps to its checkbox
// chrome. Both the closed `TaskRow` and the open inline editor's title-line
// checkbox (`TaskComposerCard`) derive their box from this, so the two can
// never drift in logic — the box looks/behaves identically in view-row mode and
// edit mode. Pure derivation from the task + the surface's `showsTodayIndicator`
// (the one piece of context the box needs that isn't on the task itself).

struct TaskCheckboxModel {
  var tint: Color
  var isDone: Bool
  var isToday: Bool
  var dashed: Bool
  var cornerDot: Color?
  var arrivedToday: Bool
  var tenureFill: Double?

  init(task: SeptenaTask, accent: Color, showsTodayIndicator: Bool) {
    // A volunteered, still-unratified agent proposal — the dashed "not a task
    // yet" form. Human captures stay solid; only MCP triage-band rows read so.
    let isProposal = task.isInTriageBand && task.source == TaskSource.mcp
    tint = accent
    isDone = task.status == .done
    isToday = task.isOnToday && showsTodayIndicator
    dashed = TaskRowFlags.languageV2 && isProposal
    // Accent corner dot for a committed task carrying unread agent context.
    // Proposals are excluded (they already read as dashed).
    cornerDot = {
      guard TaskRowFlags.languageV2, !isProposal else { return nil }
      if task.conversation.hasStarted, deriveConvo(task.conversation).badge != nil { return accent }
      return nil
    }()
    arrivedToday = task.showsArrivedToday()
    tenureFill = TaskRowFlags.agingEnabled ? task.todayTenureFill() : nil
  }
}

extension TaskCheckbox {
  /// Build the row checkbox from the shared model. Selection / promote-pulse /
  /// feel stay per-call — they're surface chrome (list highlight, pin flash),
  /// not task identity, so they don't belong in the shared model.
  init(model: TaskCheckboxModel, promotePulseTrigger: Int = 0, feel: CheckFeel = .stamp,
       onToggle: @escaping () -> Void) {
    self.init(tint: model.tint, isDone: model.isDone, dashed: model.dashed,
              cornerDot: model.cornerDot, arrivedToday: model.arrivedToday,
              isToday: model.isToday, tenureFill: model.tenureFill,
              promotePulseTrigger: promotePulseTrigger,
              feel: feel, onToggle: onToggle)
  }
}

/// Compact notes marker that rides inline at the end of a task title.
enum TaskNotesGlyph {
  /// Vertical nudge so the glyph reads mid-aligned with the title's last line.
  static let baselineOffset: CGFloat = 3.5

  static func inlineText() -> Text {
    Text(Image(systemName: "text.alignleft"))
      .font(.system(size: 10))
      .foregroundStyle(Theme.inkSecondary)
      .baselineOffset(baselineOffset)
  }
}

// MARK: - Task row
//
// The single closed (non-editing) task row used by every task surface — the
// Tasks drawer, the deep `TaskListView`, and the dashboard Next feed — so a
// task looks identical wherever it appears. A thin, data-driven wrapper over
// `CheckableRow`: it owns the canonical trailing (recurrence glyph +
// the due / scheduled date treatment) and resolves the project→area subtitle.
// The notes glyph rides inline on the title via `showsNotesGlyph`.
struct TaskRow: View {
  let task: SeptenaTask
  var accent: Color
  /// Backing catalog for the project / area subtitle. Empty → no subtitle.
  var areas: [Area] = []
  var projects: [Project] = []
  /// Suppress the project / area chip when the surrounding context already
  /// shows it (a project page suppresses both; an area page suppresses area
  /// only). The deep list maps these from its `TaskFilter`.
  var suppressProject: Bool = false
  var suppressArea: Bool = false
  /// Show the "promoted to Today" accent in the checkbox, and the scheduled
  /// date in the trailing. Pass `false` on Today / Next surfaces (where every
  /// row is already today, so both are noise).
  var showsTodayIndicator: Bool = true
  /// Highlight this row while its edit modal is open (see `CheckableRow`).
  var isSelected: Bool = false
  /// Native `List(selection:)` cursor on the deep task list.
  var isListSelected: Bool = false
  /// Optional inboard-most trailing accessory — the deep list passes the Inbox
  /// "file here" capsule here so it sits left of the date (a variable-width
  /// element kept inboard of the fixed glyphs). Nil on every other surface.
  var accessory: AnyView? = nil
  /// Hero-animation anchors forwarded to `CheckableRow` so the closed row's
  /// title + checkbox glide into the inline editor. See `CheckableRow`.
  var titleMatchID: String? = nil
  var checkboxMatchID: String? = nil
  var heroMatchNS: Namespace.ID? = nil
  var heroMatchIsSource: Bool = true
  let onToggle: () -> Void
  var onTap: (() -> Void)? = nil

  @Environment(PromoteFlashStore.self) private var promoteFlash
  @Environment(DayClock.self) private var clock

  private var todayAnchor: Date {
    Calendar.current.startOfDay(for: SeptenaDate.parse(clock.today) ?? clock.now)
  }

  private var isInactive: Bool {
    task.status == .done || task.status == .cancelled
  }
  private var hasNotes: Bool {
    !(task.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Project wins over area (a task in a project implies its area), each
  /// honoring its suppression flag. Mirrors the old `TaskListView.metaLine`.
  private var subtitle: String? {
    if !suppressProject, let pid = task.project,
       let p = projects.first(where: { $0.id == pid }) { return p.title }
    if !suppressArea, let aid = task.area,
       let a = areas.first(where: { $0.id == aid }) { return a.title }
    return nil
  }

  var body: some View {
    // The box is derived once, in `TaskCheckboxModel`, shared with the inline
    // editor's checkbox so view-row and edit-row can't drift.
    let box = TaskCheckboxModel(task: task, accent: accent,
                                showsTodayIndicator: showsTodayIndicator)
    return CheckableRow(
      tint: box.tint,
      isDone: box.isDone,
      isToday: box.isToday,
      dashed: box.dashed,
      cornerDot: box.cornerDot,
      arrivedToday: box.arrivedToday,
      tenureFill: box.tenureFill,
      isInactive: isInactive,
      title: task.title,
      showsNotesGlyph: hasNotes,
      subtitle: subtitle,
      isSelected: isSelected,
      isListSelected: isListSelected,
      promoteFlashTrigger: promoteFlash.trigger(for: task.id),
      titleMatchID: titleMatchID,
      checkboxMatchID: checkboxMatchID,
      heroMatchNS: heroMatchNS,
      heroMatchIsSource: heroMatchIsSource,
      trailing: { trailing },
      onToggle: onToggle,
      onTap: onTap
    )
  }

  // Right-side order (left → right): variable-width elements inboard, fixed-width
  // pinned to the right edge so the row's right margin stays stable.
  //   accessory (Inbox "file here") · date  →  recurrence · status-dot
  // Notes ride inline at the end of the title (see `TaskNotesGlyph`). The
  // accessory and date flex with their content; recurrence and the agent/status
  // dot are fixed and anchor the trailing edge.
  @ViewBuilder private var trailing: some View {
    if let accessory { accessory }
    trailingDate
    if task.recurrence != nil {
      Image(systemName: "arrow.triangle.2.circlepath")
        .scaledFont(size: 12)
        .foregroundStyle(Theme.inkSecondary)
    }
    agentSignal
  }

  /// The single trailing signal dot, in priority order: a live conversation's
  /// status badge wins; absent that, the calm "unseen" cue for a Claude-created
  /// row the user hasn't engaged yet; absent that, the "arrived in Today on its
  /// own" cue for a future-dated plan whose day just came. Mutually exclusive —
  /// the row never shows two dots, and the cue rides the same right edge as
  /// every other row glyph. The `hasStarted && badge != nil` guard mirrors
  /// `ConvoBadgeView`'s own, so when it wins the badge always renders.
  @ViewBuilder private var agentSignal: some View {
    if TaskRowFlags.languageV2 {
      // Language v2: the agent signal rides the LEFT box — dashed = proposal,
      // corner dot = unread context. "Arrived in Today on its own" is now an
      // amber checkbox (Things-style "new on Today"), not a right-edge dot, so
      // the trailing edge carries nothing for these states.
      EmptyView()
    } else if task.conversation.hasStarted, deriveConvo(task.conversation).badge != nil {
      ConvoBadgeView(convo: task.conversation)
    } else if task.showsAgentCue() {
      AgentCueMarker(tint: accent)
    } else if task.showsArrivedToday() {
      // The "rolled into Today on its own" cue wears the Today accent (yellow),
      // not the section accent — it's a Today signal, matching the checkbox's
      // promoted-to-Today color.
      ArrivedTodayMarker(tint: Theme.todayAccent)
    }
  }

  /// Date treatment, lifted from the old `TaskListView.trailingDate`:
  ///   • `due ≤ today` → red bold date (`Today` / `May 14`).
  ///   • `due > today` → gray flag + date (marked, not urgent).
  ///   • no `due`, scheduled, not a Today surface → muted calendar + date.
  @ViewBuilder private var trailingDate: some View {
    let cal = Calendar.current
    let today = todayAnchor
    // Completed tasks show WHEN they were done (the Completed view reads as a
    // dated archive); the date prefix strips the time off `completedAt`.
    if task.status == .done, let done = task.completedAt.flatMap({ SeptenaDate.parse(String($0.prefix(10))) }) {
      HStack(spacing: 4) {
        Image(systemName: "checkmark").scaledFont(size: 11)
        Text(Self.shortDate(done)).font(.septenaMeta)
      }
      .foregroundStyle(Theme.inkSecondary)
    } else if let due = task.deadline.flatMap(SeptenaDate.parse) {
      let dueDay = cal.startOfDay(for: due)
      if dueDay <= today {
        Text(cal.isDateInToday(due) ? "Today" : Self.shortDate(due))
          .font(.septenaMeta.weight(.semibold))
          .foregroundStyle(Theme.overdueRed)
      } else {
        HStack(spacing: 4) {
          Image(systemName: "flag.fill").scaledFont(size: 12)
          Text(Self.shortDate(due)).font(.septenaMeta)
        }
        .foregroundStyle(Theme.inkSecondary)
      }
    } else if let scheduled = task.scheduled.flatMap(SeptenaDate.parse) {
      let schedDay = cal.startOfDay(for: scheduled)
      // On Today / Next, past/today When dates are noise (the row is already
      // on Today) — but a future When date should still read (sort + label).
      if showsTodayIndicator || schedDay > today {
        HStack(spacing: 4) {
          Image(systemName: "calendar").scaledFont(size: 11)
          Text(Self.shortDate(scheduled)).font(.septenaMeta)
        }
        .foregroundStyle(Theme.inkSecondary)
      }
    }
    // Language v2: an on-Today task seen on an off-Today surface is signalled by
    // the amber checkbox (see `boxStrokeColor`), not a right-edge "Today" chip.
  }

  private static func shortDate(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "Today" }
    if cal.isDateInTomorrow(d) { return "Tomorrow" }
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("MMMd")
    return f.string(from: d)
  }
}

// MARK: - Screen title

struct ScreenTitle: View {
  let icon: String
  let iconTint: Color
  let title: String

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.title2)
        .foregroundStyle(iconTint)
      Text(title)
        .font(.septenaScreenTitle)
        .foregroundStyle(.primary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, Theme.hPadding)
    .padding(.top, 12)
    .padding(.bottom, 18)
  }
}


// MARK: - Week strip

/// Which 7-day window a `WeekStrip` covers.
enum WeekStripRange {
  /// Today + the next 6 days. The scheduling default (When / Deadline).
  case upcoming
  /// The previous 6 days + today, with today rightmost. Used by the
  /// drawer time-travel picker, where you look *back* at past logs.
  case recent
}

/// Lean 7-day strip: today + next 6 days as Reminders-style chips
/// (weekday letter on top, day number below). One tap = one pick.
/// Used by both the When and Deadline pickers so quick scheduling
/// within the coming week never opens a full calendar.
struct WeekStrip: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(DayClock.self) private var clock
  /// Currently-selected day (start-of-day), or nil for none.
  let selected: Date?
  /// Window the strip spans. Defaults to `.upcoming` so existing
  /// scheduling callers are unaffected.
  var range: WeekStripRange = .upcoming
  let onPick: (Date) -> Void

  private static let cal = Calendar.current
  private static let weekdayFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "EEE"; return f   // Sun … Sat
  }()

  private var anchorDay: Date {
    Self.cal.startOfDay(for: SeptenaDate.parse(clock.today) ?? clock.now)
  }

  private var days: [Date] {
    let today = anchorDay
    switch range {
    case .upcoming:
      return (0..<7).compactMap { Self.cal.date(byAdding: .day, value: $0, to: today) }
    case .recent:
      return (-6...0).compactMap { Self.cal.date(byAdding: .day, value: $0, to: today) }
    }
  }

  var body: some View {
    HStack(spacing: 6) {
      ForEach(days, id: \.self) { d in
        let isSelected = selected.map { Self.cal.isDate($0, inSameDayAs: d) } ?? false
        let isToday = Self.cal.isDate(d, inSameDayAs: anchorDay)
        let isWeekend = Self.cal.isDateInWeekend(d)
        Button {
          Haptics.pick()
          onPick(Self.cal.startOfDay(for: d))
        } label: {
          VStack(spacing: 2) {
            Text(Self.weekdayFmt.string(from: d))
              .scaledFont(size: 11, weight: .medium)
              .foregroundStyle(isSelected ? Color.white : Theme.inkSecondary)
            Text("\(Self.cal.component(.day, from: d))")
              .scaledFont(size: 17, weight: .semibold, design: .rounded)
              .foregroundStyle(isSelected ? Color.white
                               : (isToday ? theme.accent : Theme.inkPrimary))
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)
          .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(isSelected ? theme.accent
                    : (isToday ? theme.accent.opacity(0.12)
                       : (isWeekend ? Theme.inkSecondary.opacity(0.09) : Color.clear)))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .strokeBorder(isSelected ? Color.clear : Theme.inkSecondary.opacity(0.18),
                            lineWidth: 0.5)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
  }
}

// MARK: - Date picker sheet

/// Shared picker for both "When" (scheduled) and "Deadline" (due). 7-day
/// strip up top for the common case; a single capsule button pops the full
/// month calendar (popover on iPad/Mac, small sheet on iPhone) for anything
/// further out. Only the title, button labels, and clear semantics differ
/// between the two — layout is identical.
struct DatePickerSheet: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(DayClock.self) private var clock
  let title: String
  let initialDate: Date?
  let setLabel: String        // e.g. "Set Date" / "Set Deadline"
  let updateLabel: String     // e.g. "Update Date" / "Update Deadline"
  let clearLabel: String      // e.g. "No Date" / "Remove Deadline"
  let onPick: (Date?) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var date: Date
  @State private var showingCalendar: Bool
  @State private var configuredStrip = false

  private var cal: Calendar { Calendar.current }

  private var anchorDay: Date {
    cal.startOfDay(for: SeptenaDate.parse(clock.today) ?? clock.now)
  }
  private var tomorrow: Date { cal.date(byAdding: .day, value: 1, to: anchorDay) ?? anchorDay }
  /// The coming Saturday — or today, if today is already the weekend.
  private var weekend: Date {
    if cal.isDateInWeekend(anchorDay) { return anchorDay }
    var comps = DateComponents(); comps.weekday = 7   // Saturday
    let next = cal.nextDate(after: anchorDay, matching: comps, matchingPolicy: .nextTime)
    return cal.startOfDay(for: next ?? anchorDay)
  }
  /// The upcoming Monday.
  private var nextWeek: Date {
    var comps = DateComponents(); comps.weekday = 2   // Monday
    let next = cal.nextDate(after: anchorDay, matching: comps, matchingPolicy: .nextTime)
    return cal.startOfDay(for: next ?? anchorDay)
  }

  /// Fitted sheet height: a semantic pill row + 7-day strip + calendar button +
  /// actions. `.large` stays available as a drag-up fallback for big Dynamic
  /// Type (or when the pills wrap to a second row on a narrow phone).
  static let sheetHeight: CGFloat = 380

  /// Locale-ordered short date for the confirm button ("Wed, Jul 8").
  private static let setDateFmt: DateFormatter = {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("EEEMMMd")
    return f
  }()

  init(
    title: String,
    initialDate: Date? = nil,
    setLabel: String,
    updateLabel: String,
    clearLabel: String,
    onPick: @escaping (Date?) -> Void
  ) {
    self.title = title
    self.initialDate = initialDate
    self.setLabel = setLabel
    self.updateLabel = updateLabel
    self.clearLabel = clearLabel
    self.onPick = onPick
    _date = State(initialValue: initialDate ?? Date())
    _showingCalendar = State(initialValue: false)
  }

  private func configureStripIfNeeded() {
    guard !configuredStrip else { return }
    configuredStrip = true
    if initialDate == nil { date = anchorDay }
  }

  /// Language-first quick pick (Today / Tomorrow / This weekend / Next week).
  /// Same one-tap-and-dismiss contract as the day strip; highlights when the
  /// current value already lands on it. Matches the composer's `chip` capsule.
  @ViewBuilder
  private func quickChip(_ title: String, target: Date) -> some View {
    let active = initialDate.map { cal.isDate($0, inSameDayAs: target) } ?? false
    Button {
      Haptics.pick()
      onPick(cal.startOfDay(for: target)); dismiss()
    } label: {
      Text(title)
        .font(.septenaLabel)
        .foregroundStyle(active ? Theme.inkPrimary : Theme.inkSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .background(Capsule().fill(active ? theme.accent.opacity(0.42) : Theme.mutedSurface))
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        FlowLayout(spacing: 8) {
          quickChip("Today", target: anchorDay)
          quickChip("Tomorrow", target: tomorrow)
          quickChip("This weekend", target: weekend)
          quickChip("Next week", target: nextWeek)
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 10)
        .padding(.bottom, 8)

        WeekStrip(selected: initialDate.map { Calendar.current.startOfDay(for: $0) }) { d in
          onPick(d); dismiss()
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .onAppear { configureStripIfNeeded() }

        Hairline()

        // One prominent, capsule-weight button that pops Apple's month
        // calendar in a single tap — popover on iPad/Mac, a small sheet on
        // iPhone. No inline reveal; the strip already covers the common week.
        Button {
          Haptics.pick()
          showingCalendar = true
        } label: {
          HStack(spacing: 8) {
            Image(systemName: "calendar")
              .scaledFont(size: 17)
              .foregroundStyle(Theme.inkSecondary)
            Text("Pick another date")
              .scaledFont(size: 16, weight: .medium)
              .foregroundStyle(.primary)
            Image(systemName: "chevron.right")
              .scaledFont(size: 13, weight: .semibold)
              .foregroundStyle(Theme.iconMuted)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 13)
          .background(Capsule().fill(Theme.inkSecondary.opacity(0.08)))
          .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
          .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 12)
        .popover(isPresented: $showingCalendar) {
          DatePicker("", selection: $date, displayedComponents: [.date])
            .datePickerStyle(.graphical)
            .labelsHidden()
            .tint(theme.accent)
            .padding(8)
            .frame(minWidth: 300, idealWidth: 320, minHeight: 320)
            .presentationDetents([.medium])
            .presentationCompactAdaptation(.sheet)
            .onChange(of: date) { showingCalendar = false }
        }

        Spacer(minLength: 0)

        VStack(spacing: 6) {
          Button {
            onPick(Calendar.current.startOfDay(for: date))
            dismiss()
          } label: {
            Text("\(initialDate == nil ? setLabel : updateLabel) · \(Self.setDateFmt.string(from: date))")
              .scaledFont(size: 16, weight: .semibold)
              .foregroundStyle(.white)
              .lineLimit(1)
              .minimumScaleFactor(0.8)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 12)
              .background(theme.accent)
              .clipShape(Capsule())
          }
          .buttonStyle(.plain)

          // Only offer "remove" when there's actually a date to clear.
          if initialDate != nil {
            Button {
              Haptics.warning()
              onPick(nil)
              dismiss()
            } label: {
              Text(clearLabel)
                .scaledFont(size: 15, weight: .medium)
                .foregroundStyle(Theme.overdueRed)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.bottom, 12)
      }
      .navigationTitle(title)
      .septenaInlineTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
    .macSheetFrame(width: 420, height: Self.sheetHeight + 60)
  }
}

// MARK: - Recurrence picker sheet

/// "Repeat" — set or clear a recurrence rule. v1: daily / weekly / monthly,
/// interval stepper, and fixed-vs-after-completion toggle. the reference design's canonical
/// picker has more (weekday selection, ends-rules) — to be added when needed.
struct RecurrencePickerSheet: View {
  @Environment(SectionTheme.self) private var theme
  let initial: Recurrence?
  let onPick: (Recurrence?) -> Void
  @Environment(\.dismiss) private var dismiss

  @State private var unit: Recurrence.Unit
  @State private var interval: Int
  @State private var afterCompletion: Bool

  init(initial: Recurrence?, onPick: @escaping (Recurrence?) -> Void) {
    self.initial = initial
    self.onPick = onPick
    _unit = State(initialValue: initial?.unit ?? .day)
    _interval = State(initialValue: initial?.interval ?? 1)
    _afterCompletion = State(initialValue: initial?.afterCompletion ?? true)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        // Unit segmented
        Picker("Unit", selection: $unit) {
          Text("Day").tag(Recurrence.Unit.day)
          Text("Week").tag(Recurrence.Unit.week)
          Text("Month").tag(Recurrence.Unit.month)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 16)

        // Interval stepper
        HStack {
          Text("Every")
            .font(.septenaSidebarRow)
            .foregroundStyle(Theme.inkPrimary)
          Spacer()
          Stepper(value: $interval, in: 1...99) {
            Text(intervalLabel())
              .font(.septenaSidebarRow)
              .foregroundStyle(Theme.inkSecondary)
          }
          .labelsHidden()
          Text(intervalLabel())
            .font(.septenaSidebarRow)
            .foregroundStyle(Theme.inkSecondary)
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 18)

        // Fixed vs after-completion toggle
        Toggle(isOn: $afterCompletion) {
          VStack(alignment: .leading, spacing: 2) {
            Text("After completion")
              .font(.septenaSidebarRow)
              .foregroundStyle(Theme.inkPrimary)
            Text(afterCompletion
                 ? "Next instance \(intervalLabel()) after you mark this done."
                 : "Next instance \(intervalLabel()) after the previous scheduled date.")
              .font(.caption)
              .foregroundStyle(Theme.inkSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .tint(theme.accent)
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 18)

        Spacer()

        VStack(spacing: 10) {
          Button {
            onPick(Recurrence(unit: unit, interval: interval, afterCompletion: afterCompletion))
            dismiss()
          } label: {
            Text(initial == nil ? "Set Repeat" : "Update Repeat")
              .scaledFont(size: 16, weight: .semibold)
              .foregroundStyle(.white)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 14)
              .background(theme.accent)
              .clipShape(Capsule())
          }
          .buttonStyle(.plain)

          if initial != nil {
            Button {
              Haptics.warning()
              onPick(nil)
              dismiss()
            } label: {
              Text("Don't Repeat")
                .scaledFont(size: 15, weight: .medium)
                .foregroundStyle(Theme.overdueRed)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.bottom, 20)
      }
      .navigationTitle("Repeat")
      .septenaInlineTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
    .macSheetFrame(width: 420, height: 380)
  }

  /// Pluralized "N days/weeks/months" via the String Catalog (one/other).
  private func intervalLabel() -> String {
    switch unit {
    case .day:   return String(localized: "\(interval) days")
    case .week:  return String(localized: "\(interval) weeks")
    case .month: return String(localized: "\(interval) months")
    }
  }
}

// MARK: - Move picker sheet

struct MovePickerSheet: View {
  let areas: [Area]
  let projects: [Project]
  var currentAreaId: String? = nil
  var currentProjectId: String? = nil
  /// When moving multiple tasks, hides the single-row highlight and retitles the sheet.
  var bulkCount: Int = 1
  let onPick: (_ areaId: String?, _ projectId: String?) -> Void
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @State private var query = ""
  // Real done/(done+open) ratio per project id, so the pie glyph matches the
  // sidebar instead of a placeholder. Loaded once on appear.
  @State private var progressByProject: [String: Double] = [:]

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          // Inbox first — drop both area and project.
          if matches("Inbox") {
            row(.inbox, title: "Inbox",
                selected: showCurrentSelection && currentAreaId == nil && currentProjectId == nil) {
              onPick(nil, nil); dismiss()
            }
          }

          // Top-level projects (no area)
          ForEach(filteredTopProjects) { p in
            row(.project, title: p.title, projectId: p.id,
                selected: showCurrentSelection && p.id == currentProjectId) {
              onPick(nil, p.id); dismiss()
            }
          }

          // Areas with their projects nested directly underneath, mirroring
          // the sidebar's hierarchy.
          ForEach(filteredAreas) { area in
            row(.area, title: area.title, emoji: area.emoji,
                selected: showCurrentSelection && currentProjectId == nil && area.id == currentAreaId) {
              onPick(area.id, nil); dismiss()
            }
            ForEach(projectsIn(area.id)) { p in
              row(.project, title: p.title, projectId: p.id,
                  selected: showCurrentSelection && p.id == currentProjectId, indent: true) {
                onPick(area.id, p.id); dismiss()
              }
            }
          }
        }
        .padding(.vertical, 8)
      }
      .background(Theme.paperBackground)
      .task { loadProgress() }
      .septenaAlwaysVisibleSearch(text: $query)
      .navigationTitle(bulkCount > 1 ? "Move \(bulkCount) Tasks" : "Move")
      .septenaInlineTitle()
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .macSheetFrame(width: 460, height: 520)
  }

  // MARK: - Filtering

  private var showCurrentSelection: Bool { bulkCount == 1 }

  private var q: String { query.lowercased() }

  private func matches(_ s: String) -> Bool {
    q.isEmpty || s.lowercased().contains(q)
  }

  private var filteredTopProjects: [Project] {
    projects.filter { $0.area == nil && $0.status == .active && matches($0.title) }
  }

  private var filteredAreas: [Area] {
    areas.filter { area in
      matches(area.title) || !projectsIn(area.id).isEmpty
    }
  }

  private func projectsIn(_ areaId: String) -> [Project] {
    projects.filter { $0.area == areaId && $0.status == .active && matches($0.title) }
  }

  // MARK: - Progress

  // done / (done + open) per project, mirroring the sidebar's aggregate so the
  // pie glyph reads identically here. Cancelled tasks count toward neither side.
  private func loadProgress() {
    var done: [String: Int] = [:]
    var total: [String: Int] = [:]
    for t in LocalCache.tasksWithProject(in: modelContext) {
      guard let pid = t.project else { continue }
      switch t.status {
      case .done: done[pid, default: 0] += 1; total[pid, default: 0] += 1
      case .open: total[pid, default: 0] += 1
      case .cancelled: break
      }
    }
    progressByProject = total.reduce(into: [:]) { acc, kv in
      acc[kv.key] = Double(done[kv.key] ?? 0) / Double(kv.value)
    }
  }

  // MARK: - Row primitive

  private enum RowKind { case inbox, area, project }

  @ViewBuilder
  private func row(_ kind: RowKind, title: String, projectId: String? = nil,
                   emoji: String? = nil, selected: Bool,
                   indent: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: { Haptics.pick(); action() }) {
      HStack(spacing: 12) {
        icon(for: kind, projectId: projectId, emoji: emoji)
          .frame(width: 24, alignment: .center)
        Text(title)
          .scaledFont(size: 16, weight: kind == .area ? .semibold : .regular)
          .foregroundStyle(Theme.inkPrimary)
        Spacer()
        if selected {
          Image(systemName: "checkmark")
            .scaledFont(size: 14, weight: .semibold)
            .foregroundStyle(Theme.inkSecondary)
        }
      }
      .padding(.leading, indent ? Theme.hPadding + 24 : Theme.hPadding)
      .padding(.trailing, Theme.hPadding)
      .frame(height: 38)
      .contentShape(Rectangle())
      .background(selected ? Theme.mutedSurface : Color.clear)
    }
    .buttonStyle(PlainHoverRowButtonStyle())
  }

  @ViewBuilder
  private func icon(for kind: RowKind, projectId: String? = nil, emoji: String? = nil) -> some View {
    switch kind {
    case .inbox:
      Image(systemName: "tray.fill")
        .scaledFont(size: 16)
        .foregroundStyle(Theme.iconMuted)
    case .area:
      AreaIcon(diameter: 14, lineWidth: 1.5, emoji: emoji)
    case .project:
      // Pie glyph — same component as sidebar / detail page, driven by the
      // project's real done/open ratio.
      ProjectProgressIcon(progress: projectId.flatMap { progressByProject[$0] } ?? 0,
                          tint: Theme.iconMuted, diameter: 14)
    }
  }
}

// MARK: - Paper-themed action sheet
//
// iOS Menu pops with system materials (translucent gray) and can't be
// re-themed. For action lists ("Cancel / Delete") we want
// the same warm-paper surface as the rest of the app, so we present a
// custom bottom sheet of action rows instead of a Menu.

struct ActionSheet: View {
  struct Action: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    var role: ButtonRole? = nil          // .destructive renders red
    /// When true, renders a trailing checkmark in the section accent — used
    /// for sort-mode rows where one of N is the current selection.
    var selected: Bool = false
    let perform: () -> Void
  }

  let title: String?
  let actions: [Action]
  @Environment(SectionTheme.self) private var theme
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      if let title {
        Text(title)
          .font(.septenaSectionTitle)
          .foregroundStyle(Theme.inkPrimary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, Theme.hPadding)
          .padding(.top, 18)
          .padding(.bottom, 8)
        Hairline()
      }

      ForEach(actions) { action in
        Button {
          action.perform()
          dismiss()
        } label: {
          HStack(spacing: 14) {
            Image(systemName: action.icon)
              .scaledFont(size: 16)
              .foregroundStyle(action.role == .destructive ? Theme.overdueRed : Theme.inkSecondary)
              .frame(width: 22)
            Text(action.title)
              .font(.septenaSidebarRow)
              .foregroundStyle(action.role == .destructive ? Theme.overdueRed : Theme.inkPrimary)
            Spacer()
            if action.selected {
              Image(systemName: "checkmark")
                .scaledFont(size: 14, weight: .semibold)
                .foregroundStyle(theme.accent)
            }
          }
          .padding(.horizontal, Theme.hPadding)
          .frame(height: Theme.sidebarRowHeight)
          .contentShape(Rectangle())
        }
        .buttonStyle(PlainHoverRowButtonStyle())
        Hairline()
      }

      Button("Cancel") { dismiss() }
        .font(.septenaButton)
        .foregroundStyle(theme.accent)
        .frame(maxWidth: .infinity)
        .frame(height: 56)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Theme.paperBackground.ignoresSafeArea())
  }
}

// MARK: - Hairline divider

struct Hairline: View {
  var leadingInset: CGFloat = Theme.hPadding
  var body: some View {
    Rectangle()
      .fill(Theme.divider)
      .frame(height: 0.5)
      .padding(.leading, leadingInset)
  }
}

// MARK: - Shared per-row task actions

/// The full task context menu + its picker sheets, bundled into one modifier so
/// any surface (the Tasks list, the Next feed) attaches the *same* menu — Edit
/// Details…, Copy, Duplicate, Move to / Remove from Today, When…, Deadline…,
/// Move…, Repeat…, Cancel, Delete. The menu body is `TaskListRowContextMenu` and the sheets are
/// `TaskListModalPresenter`, both shared with `TaskListView`, so the two
/// surfaces can't drift. Which picker is open is owned per-row.
///
/// Mutations go straight through `TaskMutator`; the surface refreshes off the
/// mutator's change notifications (same as the row's checkbox), so no explicit
/// reload is threaded here. The Inbox "file here" suggestions are a
/// Tasks-list-only affordance and stay nil elsewhere.
struct TaskRowActions: ViewModifier {
  let task: SeptenaTask
  var filter: TaskFilter = .today
  var areas: [Area] = []
  var projects: [Project] = []
  let mutator: TaskMutator
  /// Opens the task's edit / agent composer ("Edit Details…"). nil hides it.
  var onOpenDetail: ((SeptenaTask) -> Void)? = nil
  /// Fired after a menu mutation that can change which list a row belongs to
  /// (remove-from-today, reschedule, move, cancel, delete). Surfaces that hold
  /// their task arrays in @State — like the Tasks drawer — pass a reload here so
  /// the row leaves in real time. Surfaces that already refresh off
  /// `.septenaTasksChanged` (the full `TaskListView`) leave it nil.
  var onChange: (() -> Void)? = nil

  @State private var whenSheet: TaskListView.WhenSheet?
  @State private var showingMoveSheet = false
  @State private var moveTargetIds: [String] = []
  @State private var showingRepeatSheet = false
  @State private var repeatTargetId: String?

  @Environment(PromoteFlashStore.self) private var promoteFlash
  @Environment(\.septenaToast) private var toastStore

  func body(content: Content) -> some View {
    content
      .contextMenu {
        TaskListRowContextMenu(
          target: .single(task),
          filter: filter,
          rankedSuggestions: nil,
          onCopy: { target in
            let titles = target.tasks.map(\.title)
            guard !titles.isEmpty else { return }
            SeptenaPasteboard.copy(titles.joined(separator: "\n"))
            Haptics.tick()
          },
          onDuplicate: { _ in duplicateTask(task) },
          onOpenDetail: { onOpenDetail?($0) },
          onApplySuggestion: { _, _ in },
          onMoveToToday: { ids, today in
            Haptics.tick()
            if today {
              for id in ids {
                mutator.moveToToday(id: id, today: true)
                mutator.acknowledge(id: id)
                promoteFlash.flash(id)
              }
            } else {
              for id in ids {
                mutator.removeFromToday(id: id)
                mutator.acknowledge(id: id)
              }
            }
            onChange?()
          },
          onOpenWhen: { target in
            whenSheet = .init(taskIds: target.ids, kind: .scheduled)
          },
          onOpenDeadline: { target in
            whenSheet = .init(taskIds: target.ids, kind: .deadline)
          },
          onOpenMove: { target in
            moveTargetIds = target.ids
            showingMoveSheet = true
          },
          onMoveTo: { target, areaId, projectId in
            for id in target.ids { applyMove(id: id, areaId: areaId, projectId: projectId) }
          },
          moveAreas: areas,
          moveTopProjects: projects.filter { $0.area == nil && $0.status == .active },
          onOpenRepeat: { t in repeatTargetId = t.id; showingRepeatSheet = true },
          onCancel: { ids in Haptics.warning(); for id in ids { mutator.cancel(id: id) }; onChange?() },
          onDelete: { _ in applyDelete(task) }
        )
      }
      .modifier(TaskListModalPresenter(
        whenSheet: $whenSheet,
        showingMoveSheet: $showingMoveSheet,
        moveTargetIds: $moveTargetIds,
        showingRepeatSheet: $showingRepeatSheet,
        repeatTargetId: $repeatTargetId,
        areas: areas,
        projects: projects,
        currentTask: { _ in task },
        currentScheduled: { _ in task.scheduled.flatMap(SeptenaDate.parse) },
        currentDeadline: { _ in task.deadline.flatMap(SeptenaDate.parse) },
        currentRecurrence: { _ in task.recurrence },
        applyWhen: { ids, kind, date in
          for id in ids { applyWhen(id: id, kind: kind, date: date) }
        },
        applyMove: { ids, areaId, projectId in
          for id in ids { applyMove(id: id, areaId: areaId, projectId: projectId) }
        },
        applyRecurrence: { id, rule in Haptics.tick(); mutator.setRecurrence(id: id, recurrence: rule); onChange?() }
      ))
  }

  // Mirrors `TaskListView.applyWhen` — Things-style "Today" pin vs. future
  // scheduled date vs. cleared. Kept in lockstep with that method.
  private func applyWhen(id: String, kind: TaskListView.WhenKind, date: Date?) {
    Haptics.tick()
    switch kind {
    case .deadline:
      mutator.setDeadline(id: id, date: date)
    case .scheduled:
      if let d = date {
        if Calendar.current.isDateInToday(d) {
          mutator.schedule(id: id, date: nil)
          mutator.moveToToday(id: id, today: true)
          promoteFlash.flash(id)
        } else {
          mutator.moveToToday(id: id, today: false)
          mutator.schedule(id: id, date: d)
          toastStore?.show("Deferred to \(SeptenaDate.scheduleHeaderLabel(for: d))")
        }
      } else {
        mutator.schedule(id: id, date: nil)
        mutator.moveToToday(id: id, today: false)
      }
    }
    mutator.acknowledge(id: id)
    onChange?()
  }

  // Mirrors `TaskListView.duplicate` — clone into a new open task (new id).
  private func duplicateTask(_ task: SeptenaTask) {
    Haptics.tick()
    let copy = mutator.create(
      title: task.title,
      area: task.area,
      project: task.project,
      scheduled: SeptenaDate.parse(task.scheduled),
      deadline: SeptenaDate.parse(task.deadline),
      today: task.today,
      notes: task.notes
    )
    if let rule = task.recurrence {
      mutator.setRecurrence(id: copy.id, recurrence: rule)
    }
    onChange?()
  }

  // Mirrors `TaskListView.applyMove`, minus the Inbox suggestion-rejection
  // bookkeeping (no classifier on surfaces that use this).
  private func applyMove(id: String, areaId: String?, projectId: String?) {
    Haptics.tick()
    let prevArea = task.area
    let prevProject = task.project
    let wasInTriage = task.isInTriageBand
    if projectId != nil {
      mutator.moveToProject(id: id, project: projectId)
    } else {
      mutator.moveToArea(id: id, area: areaId)
      mutator.moveToProject(id: id, project: nil)
    }
    mutator.acknowledge(id: id)
    onChange?()
    let destName =
      projectId.flatMap { pid in projects.first { $0.id == pid }?.title }
      ?? areaId.flatMap { aid in areas.first { $0.id == aid }?.title }
      ?? "No Project"
    toastStore?.show("Moved to \(destName)") {
      if let prevProject {
        mutator.moveToProject(id: id, project: prevProject)
      } else {
        mutator.moveToArea(id: id, area: prevArea)
        mutator.moveToProject(id: id, project: nil)
      }
      if wasInTriage { mutator.moveToToday(id: id, today: false) }
      onChange?()
    }
  }

  private func applyDelete(_ task: SeptenaTask) {
    Haptics.warning()
    let title = task.title
    mutator.delete(id: task.id)
    onChange?()
    toastStore?.show(title.isEmpty ? "Task deleted" : "\"\(title)\" deleted") {
      mutator.restore(id: task.id)
      onChange?()
    }
  }
}

extension View {
  /// Attach the shared task context menu + picker sheets to a row — see
  /// `TaskRowActions`. Use this anywhere a task row appears so the menu stays
  /// identical to the Tasks list.
  func taskRowActions(task: SeptenaTask,
                      filter: TaskFilter = .today,
                      areas: [Area] = [],
                      projects: [Project] = [],
                      mutator: TaskMutator,
                      onOpenDetail: ((SeptenaTask) -> Void)? = nil,
                      onChange: (() -> Void)? = nil) -> some View {
    modifier(TaskRowActions(task: task, filter: filter, areas: areas,
                            projects: projects, mutator: mutator,
                            onOpenDetail: onOpenDetail, onChange: onChange))
  }
}
