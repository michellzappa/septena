import SwiftUI

// MARK: - Checkbox feel
//
// The checkbox's celebration vocabulary — the checkbox-local counterpart of
// `CommitMotion`. Checkable rows celebrate *at the box*, never on the canvas
// (checking things off is the app's highest-frequency action; full-screen
// flourishes there would wear out fast). Each checkable type gets its own
// feel so completing a habit reads differently from finishing a chore:
//
//   • .stamp (tasks)        — a crisp stamp + one pulse ring. Done.
//   • .echo  (habits)       — the pulse answers itself: one more mark on the
//                             streak, today echoed by the days behind it.
//   • .drop  (supplements)  — the fill falls in and lands with a soft
//                             splash. One more capsule down.
//   • .tuck  (chores)       — stamps, dips, and files the ring downward.
//                             Put away, onto the pile.
//
// Every feel lives in the box's own geometry and resolves within ~0.45s,
// with a matched CoreHaptics pattern timed to its visual beats — quiet
// transients and faint swells, never a flat buzz. Past-day backfill rows
// keep the default `.stamp`: a correction shouldn't claim a streak echo.
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

// MARK: - Checkbox

struct TaskCheckbox: View {
  @Environment(SectionTheme.self) private var theme
  /// Optional override — used by non-task items (habits/supplements/chores)
  /// to wear their section accent. `nil` means inherit list tint.
  var tint: Color? = nil
  let isDone: Bool
  /// When true (and not done), the checkbox stroke/fill switch to
  /// `Theme.todayAccent` to signal a task 'promoted to Today' — folding the
  /// today indicator into the checkbox itself, so it no longer sits as a
  /// separate glyph inline with the title.
  var isToday: Bool = false
  /// When true (and not done and not today), the checkbox stroke switches to
  /// `Theme.somedayAccent` (muted indigo) to signal a parked/deferred task.
  var isSomeday: Bool = false
  /// Which celebration plays on check — the row's type picks it (tasks
  /// `.stamp`, habits `.echo`, supplements `.drop`, chores `.tuck`).
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

  /// Checkbox chrome is neutral gray by default; Today rows swap stroke
  /// and fill to `Theme.todayAccent`; Someday rows use `Theme.somedayAccent`.
  private var boxStrokeColor: Color {
    if isToday   { return Theme.todayAccent }
    if isSomeday { return Theme.somedayAccent }
    return Theme.inkSecondary.opacity(0.55)
  }
  private var boxFillColor: Color {
    if isToday   { return Theme.todayAccent }
    if isSomeday { return Theme.somedayAccent }
    return Theme.inkSecondary.opacity(0.85)
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
  @State private var ringDrift: CGFloat = 0    // tuck: ring files downward
  @State private var echoScale: CGFloat = 1    // echo: the second, quieter ring
  @State private var echoOpacity: Double = 0
  @State private var bodyDrop: CGFloat = 0     // drop: fill falls in from above
  @State private var bodySquash: CGFloat = 1   // drop: impact squash
  @State private var bodyDip: CGFloat = 0      // tuck: box dips, then recovers

  var body: some View {
    Button(action: onToggle) {
      ZStack {
        // Echo ring (habits) — the second, quieter pulse behind the main one.
        RoundedRectangle(cornerRadius: Self.boxCorner, style: .continuous)
          .strokeBorder((tint ?? boxFillColor).opacity(echoOpacity), lineWidth: 1.2)
          .frame(width: Self.boxSize, height: Self.boxSize)
          .scaleEffect(echoScale)
        // Main pulse ring — every feel throws exactly one (tuck's drifts
        // down as it fades). Local and brief on purpose: checkable rows
        // celebrate at the box, never on the canvas.
        RoundedRectangle(cornerRadius: Self.boxCorner, style: .continuous)
          .strokeBorder((tint ?? boxFillColor).opacity(ringOpacity), lineWidth: 1.5)
          .frame(width: Self.boxSize, height: Self.boxSize)
          .scaleEffect(ringScale)
          .offset(y: ringDrift)
        // Open chrome — fades out under the arriving fill.
        RoundedRectangle(cornerRadius: Self.boxCorner, style: .continuous)
          .strokeBorder(boxStrokeColor, lineWidth: Self.boxStroke)
          .frame(width: Self.boxSize, height: Self.boxSize)
          .opacity(isDone ? 0 : 1)
          .a11yAnimation(Theme.Motion.quick, value: isDone)
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
      }
      .frame(width: Theme.checkboxTap, height: Theme.checkboxTap)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onChange(of: isDone) { _, done in
      // Celebrate only on a live check. `onChange` skips first render, so a
      // list of already-done rows (Logbook) never fires a wall of ripples.
      guard done else { resetFeel(); return }
      guard !reduceMotion, animationsEnabled || ignoresUserPreference else { return }
      playFeel()
    }
  }

  /// One ring pulse from the box outward. `reach` tunes how far it travels —
  /// the splash of a drop stays tighter than a stamp's pulse.
  private func pulse(reach: CGFloat = 1.9) {
    ringScale = 0.9
    ringOpacity = 0.55
    ringDrift = 0
    withAnimation(.easeOut(duration: 0.4)) {
      ringScale = reach
      ringOpacity = 0
    }
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
// subtitle/notes glyph + trailing date. Used by the Tasks drawer
// (`TasksDestinationView`) and intended to become the single row the deep
// `TaskListView` surface renders too, so both surfaces stay visually
// identical. Carries its own h/v padding so it drops straight into a
// `DrawerSection(padding: .none)` the same way `LogEntryRow` does.

/// Leading provenance cue for an MCP/Claude-created row the user hasn't
/// engaged yet. Calm and peripheral (Things-style): it clears on contact via
/// `TaskMutator.acknowledge` and auto-decays after `AgentCue.decayWindow`.
/// Deliberately NOT a sparkle — a small accent dot reads as an unread marker.
/// To change the glyph, swap the `Circle()` for an `Image(systemName:)` here.
struct AgentCueMarker: View {
  var tint: Color
  var body: some View {
    Circle()
      .fill(tint)
      .frame(width: 6, height: 6)
      .accessibilityLabel(Text("Added by Claude, not yet seen"))
  }
}

// MARK: - Checkable row primitive
//
// The shared skeleton behind every row with a checkbox — tasks, habits,
// supplements, chores. Owns the checkbox (+ baseline guide), the leading glyph
// (an agent-cue dot for tasks, an emoji for the checklist sections), the title
// with its inactive (done / skipped / deferred / cancelled) treatment, an
// optional subtitle, and the h/v padding so it drops into a
// `DrawerSection(padding: .none)` the same way `LogEntryRow` does. The only
// genuinely per-type piece — the trailing region (dates, time, badges) — is a
// `@ViewBuilder` slot the caller fills. Per-type toggle side-effects
// (celebrations, haptics) live in `onToggle`; per-type long-press actions are
// attached by the caller via `.contextMenu` on the returned row.
struct CheckableRow<Trailing: View>: View {
  var tint: Color
  var isDone: Bool
  var isToday: Bool = false
  var isSomeday: Bool = false
  /// The checkbox celebration this row's type plays on check (see
  /// `CheckFeel`). Tasks keep the default `.stamp`; habits pass `.echo`,
  /// supplements `.drop`, chores `.tuck`.
  var feel: CheckFeel = .stamp
  /// Strikethrough + dimmed title. Usually `isDone`, but habits fold in
  /// skipped and chores fold in deferred, so the caller decides.
  var isInactive: Bool
  /// Leading glyph. `showsAgentCue` wins (tasks); otherwise `leadingEmoji`
  /// renders (checklist sections). Both off → title sits next to the box.
  var showsAgentCue: Bool = false
  var leadingEmoji: String? = nil
  let title: String
  var subtitle: String? = nil
  /// Paints the row's active/selected highlight (tint at low opacity) while its
  /// detail/edit modal is open, so the surface that opened the modal keeps a
  /// visible anchor. Mirrors the deep `TaskListView` active-row treatment.
  var isSelected: Bool = false
  @ViewBuilder var trailing: () -> Trailing
  let onToggle: () -> Void
  var onTap: (() -> Void)? = nil

  @Environment(\.rowHInset) private var rowHInset

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.iconTextGap) {
      TaskCheckbox(
        tint: tint,
        isDone: isDone,
        isToday: isToday,
        isSomeday: isSomeday,
        feel: feel,
        onToggle: onToggle
      )
      .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }

      if showsAgentCue {
        AgentCueMarker(tint: tint)
          .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }
      } else if let leadingEmoji {
        Text(leadingEmoji).font(.body)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.septenaTaskTitle)
          .foregroundStyle(isInactive ? Theme.inkSecondary : Theme.inkPrimary)
          .strikethrough(isInactive)
          .opacity(isInactive ? 0.5 : 1)
          .lineLimit(1)
          .truncationMode(.tail)
          .fixedSize(horizontal: false, vertical: true)
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
    .padding(.vertical, Theme.rowVPadding)
    .background(selectionHighlight)
    .contentShape(Rectangle())
    .modifier(OptionalTap(action: onTap))
  }

  @ViewBuilder private var selectionHighlight: some View {
    if isSelected {
      RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
        .fill(tint.opacity(0.18))
        .padding(.horizontal, max(0, rowHInset - 6))
    }
  }
}

extension CheckableRow where Trailing == EmptyView {
  init(tint: Color, isDone: Bool, isToday: Bool = false, isSomeday: Bool = false,
       isInactive: Bool, showsAgentCue: Bool = false, leadingEmoji: String? = nil,
       title: String, subtitle: String? = nil, isSelected: Bool = false,
       onToggle: @escaping () -> Void, onTap: (() -> Void)? = nil) {
    self.init(tint: tint, isDone: isDone, isToday: isToday, isSomeday: isSomeday,
              isInactive: isInactive, showsAgentCue: showsAgentCue,
              leadingEmoji: leadingEmoji, title: title, subtitle: subtitle,
              isSelected: isSelected,
              trailing: { EmptyView() }, onToggle: onToggle, onTap: onTap)
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

// MARK: - Task row
//
// The single closed (non-editing) task row used by every task surface — the
// Tasks drawer, the deep `TaskListView`, and the dashboard Next feed — so a
// task looks identical wherever it appears. A thin, data-driven wrapper over
// `CheckableRow`: it owns the canonical trailing (notes / recurrence glyphs +
// the due / scheduled date treatment) and resolves the project→area subtitle.
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
  var showsSomedayIndicator: Bool = true
  /// Highlight this row while its edit modal is open (see `CheckableRow`).
  var isSelected: Bool = false
  let onToggle: () -> Void
  var onTap: (() -> Void)? = nil

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
    CheckableRow(
      tint: accent,
      isDone: task.status == .done,
      isToday: task.isOnToday && showsTodayIndicator,
      isSomeday: task.status == .someday && showsSomedayIndicator,
      isInactive: isInactive,
      showsAgentCue: task.showsAgentCue(),
      title: task.title,
      subtitle: subtitle,
      isSelected: isSelected,
      trailing: { trailing },
      onToggle: onToggle,
      onTap: onTap
    )
  }

  @ViewBuilder private var trailing: some View {
    ConvoBadgeView(convo: task.conversation)
    if hasNotes {
      Image(systemName: "text.alignleft")
        .scaledFont(size: 12)
        .foregroundStyle(Theme.inkSecondary)
    }
    if task.recurrence != nil {
      Image(systemName: "arrow.triangle.2.circlepath")
        .scaledFont(size: 12)
        .foregroundStyle(Theme.inkSecondary)
    }
    trailingDate
  }

  /// Date treatment, lifted from the old `TaskListView.trailingDate`:
  ///   • `due ≤ today` → red bold date (`Today` / `May 14`).
  ///   • `due > today` → gray flag + date (marked, not urgent).
  ///   • no `due`, scheduled, not a Today surface → muted calendar + date.
  @ViewBuilder private var trailingDate: some View {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    // Completed tasks show WHEN they were done (the Completed view reads as a
    // dated archive); the date prefix strips the time off `completedAt`.
    if task.status == .done, let done = task.completedAt.flatMap({ SeptenaDate.parse(String($0.prefix(10))) }) {
      HStack(spacing: 4) {
        Image(systemName: "checkmark").scaledFont(size: 11)
        Text(Self.shortDate(done)).font(.septenaMeta)
      }
      .foregroundStyle(Theme.inkSecondary)
    } else if let due = task.due.flatMap(SeptenaDate.parse) {
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
    } else if showsTodayIndicator, let scheduled = task.scheduled.flatMap(SeptenaDate.parse) {
      HStack(spacing: 4) {
        Image(systemName: "calendar").scaledFont(size: 11)
        Text(Self.shortDate(scheduled)).font(.septenaMeta)
      }
      .foregroundStyle(Theme.inkSecondary)
    }
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
  /// Currently-selected day (start-of-day), or nil for none.
  let selected: Date?
  /// Window the strip spans. Defaults to `.upcoming` so existing
  /// scheduling callers are unaffected.
  var range: WeekStripRange = .upcoming
  let onPick: (Date) -> Void

  private static let cal = Calendar.current
  private static let weekdayFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "EEEEE"; return f   // single letter
  }()

  private var days: [Date] {
    let today = Self.cal.startOfDay(for: Date())
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
        let isToday = Self.cal.isDateInToday(d)
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
                    : (isToday ? theme.accent.opacity(0.12) : Color.clear))
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
/// strip up top for the common case; "Pick a Date…" reveals a compact
/// date field for anything further out. Only the title, button labels, and
/// clear semantics differ between the two — layout is identical.
struct DatePickerSheet: View {
  @Environment(SectionTheme.self) private var theme
  let title: String
  let initialDate: Date?
  let setLabel: String        // e.g. "Set Date" / "Set Deadline"
  let updateLabel: String     // e.g. "Update Date" / "Update Deadline"
  let clearLabel: String      // e.g. "No Date" / "Remove Deadline"
  let onPick: (Date?) -> Void
  @Environment(\.dismiss) private var dismiss
  @Environment(\.a11yMotion) private var motion
  @State private var date: Date
  @State private var showingCalendar: Bool

  /// Fitted sheet height. Content is fixed (the "Pick a Date…" row and the
  /// compact-field row share a height), so the sheet need not open half-screen.
  /// `.large` stays available as a drag-up fallback for big Dynamic Type.
  static let sheetHeight: CGFloat = 320

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
    let seed = initialDate ?? Calendar.current.startOfDay(for: Date())
    _date = State(initialValue: seed)
    // Open the calendar up-front only when the existing date sits
    // outside the strip — the strip already covers the next 7 days.
    let today = Calendar.current.startOfDay(for: Date())
    let inStripRange: Bool = {
      guard let initialDate else { return true }
      let day = Calendar.current.startOfDay(for: initialDate)
      let days = Calendar.current.dateComponents([.day], from: today, to: day).day ?? 0
      return days >= 0 && days < 7
    }()
    _showingCalendar = State(initialValue: !inStripRange)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        WeekStrip(selected: initialDate.map { Calendar.current.startOfDay(for: $0) }) { d in
          onPick(d); dismiss()
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 6)
        .padding(.bottom, 8)

        Hairline()

        if showingCalendar {
          // Compact field: a tidy row that pops Apple's native calendar
          // overlay. Fits the medium detent without the graphical grid's
          // clipping/scroll fight, and picks up the accent tint.
          HStack(spacing: 14) {
            Image(systemName: "calendar")
              .scaledFont(size: 18)
              .foregroundStyle(Theme.inkSecondary)
              .frame(width: 24)
            Text("Date")
              .font(.septenaSidebarRow)
              .foregroundStyle(.primary)
            Spacer()
            DatePicker("", selection: $date, displayedComponents: [.date])
              .labelsHidden()
              .datePickerStyle(.compact)
              .tint(theme.accent)
          }
          .padding(.horizontal, Theme.hPadding)
          .frame(height: Theme.sidebarRowHeight)
        } else {
          Button {
            motion.run(.easeInOut(duration: 0.18)) { showingCalendar = true }
          } label: {
            HStack(spacing: 14) {
              Image(systemName: "calendar")
                .scaledFont(size: 18)
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: 24)
              Text("Pick a Date…")
                .font(.septenaSidebarRow)
                .foregroundStyle(.primary)
              Spacer()
            }
            .padding(.horizontal, Theme.hPadding)
            .frame(height: Theme.sidebarRowHeight)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }

        Spacer(minLength: 0)

        VStack(spacing: 6) {
          Button {
            onPick(Calendar.current.startOfDay(for: date))
            dismiss()
          } label: {
            Text(initialDate == nil ? setLabel : updateLabel)
              .scaledFont(size: 16, weight: .semibold)
              .foregroundStyle(.white)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 12)
              .background(theme.accent)
              .clipShape(Capsule())
          }
          .buttonStyle(.plain)

          Button {
            Haptics.warning()
            onPick(nil)
            dismiss()
          } label: {
            Text(clearLabel)
              .scaledFont(size: 15, weight: .medium)
              .foregroundStyle(initialDate == nil ? Theme.inkSecondary : Theme.overdueRed)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 8)
          }
          .buttonStyle(.plain)
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
  let onPick: (_ areaId: String?, _ projectId: String?) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          // Inbox first — drop both area and project.
          if matches("Inbox") {
            row(.inbox, title: "Inbox",
                selected: currentAreaId == nil && currentProjectId == nil) {
              onPick(nil, nil); dismiss()
            }
          }

          // Top-level projects (no area)
          ForEach(filteredTopProjects) { p in
            row(.project, title: p.title,
                selected: p.id == currentProjectId) {
              onPick(nil, p.id); dismiss()
            }
          }

          // Areas with their projects nested directly underneath, mirroring
          // the sidebar's hierarchy.
          ForEach(filteredAreas) { area in
            row(.area, title: area.title,
                selected: currentProjectId == nil && area.id == currentAreaId) {
              onPick(area.id, nil); dismiss()
            }
            ForEach(projectsIn(area.id)) { p in
              row(.project, title: p.title,
                  selected: p.id == currentProjectId, indent: true) {
                onPick(area.id, p.id); dismiss()
              }
            }
          }
        }
        .padding(.vertical, 8)
      }
      .background(Theme.paperBackground)
      .septenaAlwaysVisibleSearch(text: $query)
      .navigationTitle("Move")
      .septenaInlineTitle()
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  // MARK: - Filtering

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

  // MARK: - Row primitive

  private enum RowKind { case inbox, area, project }

  @ViewBuilder
  private func row(_ kind: RowKind, title: String, selected: Bool,
                   indent: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: { Haptics.pick(); action() }) {
      HStack(spacing: 12) {
        icon(for: kind)
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
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private func icon(for kind: RowKind) -> some View {
    switch kind {
    case .inbox:
      Image(systemName: "tray.fill")
        .scaledFont(size: 16)
        .foregroundStyle(Theme.iconMuted)
    case .area:
      AreaIcon(diameter: 14, lineWidth: 1.5)
    case .project:
      // Pie glyph — same component as sidebar / detail page.
      ProjectProgressIcon(progress: 0.25, tint: Theme.iconMuted, diameter: 14)
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
        .buttonStyle(.plain)
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
