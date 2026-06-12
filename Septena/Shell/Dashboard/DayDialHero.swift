import SwiftUI
import SwiftData

// The front door's hero object: today as a living 24-hour dial.
//
// Septena's unique asset is the whole day across every domain — meals, mood,
// coffee, training, sleep — and this is where that integration becomes
// visible. The dial sits between the greeting and the layout grid: dots
// bloom in as you log, sleep arcs the night side, the now-hand sweeps, and
// the `.arc` comet (clearing the last Today task) orbits this very circle —
// the hero publishes its ring as `DayDialAnchor` so the flourish can land
// on it. The signature object the tiles can't be.
//
// Composition, not invention: the same `TimeOfDayWheel` the Rhythm layout
// mode and the section detail views use, fed by the same `RhythmData`
// snapshot — opening focused on today (the wheel's default), with the
// week overlay one tap away. `AmbientGlow` behind it gives the dial the
// day's light; the wheel's `heroDate` rim wash paints the same phases on
// the face itself.

struct DayDialHero: View {
  /// Section keys currently visible on the homepage — drives which sections
  /// plot, mirroring the Rhythm mode's visibility rule.
  let visibleSections: Set<String>
  /// Oura nights already loaded by the dashboard; sleep plots as a band.
  var sleepNights: [OuraNight] = []

  @Environment(\.modelContext) private var modelContext
  @Environment(DayClock.self) private var clock
  @Environment(SectionTheme.self) private var theme
  // Optional — the hero lives under the root env, but stays nil-safe like
  // the rows do. nil just means the comet never learns where the dial is.
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Same opt-out the commit flourishes honor — gates the dot blooms only;
  /// the dial itself (and its data) always renders.
  @AppStorage(SettingsKey.loggingAnimationsEnabled) private var animationsEnabled = true

  @State private var snapshot = RhythmData.Snapshot()
  /// One-shot ring pulses over dots that just landed (see `reload`).
  @State private var blooms: [DotBloom] = []
  /// Today-event ids seen by the previous reload — the diff is what blooms.
  @State private var knownTodayIDs: Set<String> = []
  /// First reload seeds `knownTodayIDs` silently so opening the dashboard
  /// never blooms the whole morning at once.
  @State private var seeded = false

  private let windowDays = 7
  private let dialDiameter: CGFloat = 270

  private var todayStart: Date {
    SeptenaDate.parse(clock.today).map { Calendar.current.startOfDay(for: $0) }
      ?? Calendar.current.startOfDay(for: clock.now)
  }

  /// Reading `clock.now` here means the 60s tick re-renders only the hero
  /// (the now-hand advances), never the parent dashboard — the same
  /// isolation `WelcomeHeaderSection` uses.
  private var nowFraction: Double {
    let c = Calendar.current.dateComponents([.hour, .minute], from: clock.now)
    return (Double(c.hour ?? 0) * 60 + Double(c.minute ?? 0)) / 1440
  }

  var body: some View {
    TimeOfDayWheel(
      events: snapshot.events,
      // Neutral frame — the dots and bands carry the section colors, same
      // as the Rhythm mode's overlay dial.
      accent: Theme.inkSecondary,
      bands: snapshot.bands,
      todayBands: snapshot.calendarBands,
      windowDays: windowDays,
      nowFraction: nowFraction,
      diameter: dialDiameter,
      heroDate: todayStart
    )
    // Fresh-dot blooms ride on top of the canvas dot at the same angle —
    // a single expanding ring that says "this one just landed."
    .overlay {
      ForEach(blooms) { b in
        DotBloomRing(color: b.color)
          .position(dotPosition(b.fraction))
      }
      .allowsHitTesting(false)
    }
    // The glow is a background so it bleeds past the dial (toward the
    // greeting above) without claiming layout height.
    .background {
      AmbientGlow()
        .frame(width: 460, height: 460)
    }
    // Publish the dot ring's circle (global coords) so the `.arc` comet can
    // orbit the dial instead of sweeping the screen. Cleared on disappear —
    // tab switches and navigation must not leave a stale circle behind.
    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
      logCommit?.dayDialAnchor = DayDialAnchor(
        center: CGPoint(x: frame.midX, y: frame.midY),
        radius: TimeOfDayWheel.dotRing(forDiameter: dialDiameter)
      )
    }
    .onDisappear { logCommit?.dayDialAnchor = nil }
    .frame(maxWidth: .infinity)
    .task(id: clock.today) { reload() }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in
      reload()
    }
  }

  private func reload() {
    var colors: [String: Color] = [:]
    for key in visibleSections { colors[key] = theme.color(for: key) }
    snapshot = RhythmData.load(
      visible: visibleSections,
      colors: colors,
      sleepNights: sleepNights,
      todayStart: todayStart,
      now: clock.now,
      windowDays: windowDays,
      calendarFallback: theme.color(for: "calendar"),
      context: modelContext
    )

    // Diff today's dots against the last reload; only the genuinely new
    // ones bloom (capped so a bulk sync can't ring the whole dial).
    let today = snapshot.events.filter { $0.daysAgo == 0 }
    let todayIDs = Set(today.map(\.id))
    defer { knownTodayIDs = todayIDs; seeded = true }
    guard seeded, !reduceMotion, animationsEnabled else { return }
    let fresh = today.filter { !knownTodayIDs.contains($0.id) }.prefix(4)
    guard !fresh.isEmpty else { return }
    let newBlooms = fresh.map {
      DotBloom(id: $0.id, fraction: $0.fraction, color: $0.color ?? Theme.inkSecondary)
    }
    blooms.append(contentsOf: newBlooms)
    let ids = Set(newBlooms.map(\.id))
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(700))
      blooms.removeAll { ids.contains($0.id) }
    }
  }

  /// Where a dot at `fraction` sits on the dial, in the wheel's own
  /// coordinate space — same angle convention as the Canvas.
  private func dotPosition(_ fraction: Double) -> CGPoint {
    let r = TimeOfDayWheel.dotRing(forDiameter: dialDiameter)
    let a = fraction * 2 * .pi
    return CGPoint(x: dialDiameter / 2 + r * CGFloat(sin(a)),
                   y: dialDiameter / 2 - r * CGFloat(cos(a)))
  }
}

private struct DotBloom: Identifiable {
  let id: String
  let fraction: Double
  let color: Color
}

/// One expanding, fading ring — the dial-local cousin of the checkbox
/// `pulse()`. Plays once on appear; the host removes it after ~0.7s.
private struct DotBloomRing: View {
  let color: Color
  @State private var scale: CGFloat = 0.4
  @State private var opacity: Double = 0.75

  var body: some View {
    Circle()
      .strokeBorder(color.opacity(opacity), lineWidth: 1.5)
      .frame(width: 26, height: 26)
      .scaleEffect(scale)
      .onAppear {
        withAnimation(.easeOut(duration: 0.6)) {
          scale = 2.0
          opacity = 0
        }
      }
      .accessibilityHidden(true)
  }
}
