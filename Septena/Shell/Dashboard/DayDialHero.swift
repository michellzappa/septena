import SwiftUI
import SwiftData
#if os(iOS)
import CoreMotion
#endif

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

/// How the front door renders "today at a glance" between the greeting and
/// the layout grid: the circular day dial, the linear timeline strip, or
/// neither. One picker (Settings ▸ Home) — replaced the old pair of
/// independent show-dial / show-timeline toggles, since they're two shapes
/// of the same information.
enum DayViewStyle: String, CaseIterable, Identifiable {
  case dial, linear, hidden
  var id: String { rawValue }

  var label: String {
    switch self {
    case .dial:   return String(localized: "Dial")
    case .linear: return String(localized: "Timeline")
    case .hidden: return String(localized: "Hidden")
    }
  }

  var icon: String {
    switch self {
    case .dial:   return "dial.medium"
    case .linear: return "timeline.selection"
    case .hidden: return "eye.slash"
    }
  }
}

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
  /// Switches tabs from inside the dashboard — tapping the dial opens Next.
  @Environment(TabSelection.self) private var tabSelection

  @State private var snapshot = RhythmData.Snapshot()
  /// Days back from today the dial is scrubbed to (0 = today, negative = past).
  /// Swiping the dial steps this; capped at today and ~a month back. Local to
  /// the hero — scrubbing previews a past day's rhythm without moving the rest
  /// of the dashboard off today.
  @State private var dayOffset = 0
  /// Live horizontal follow while swiping — the "turn the page" feel.
  @State private var dragX: CGFloat = 0
  #if os(iOS)
  @State private var tilt = TiltSource()
  #endif

  private static let maxDaysBack = 30

  /// The light layer's parallax offset — device tilt on iOS, static on
  /// macOS (no motion hardware) and under Reduce Motion.
  private var glowParallax: CGSize {
    #if os(iOS)
    reduceMotion ? .zero : tilt.offset
    #else
    .zero
    #endif
  }

  private let windowDays = 7
  private let dialDiameter: CGFloat = 270

  private var todayStart: Date {
    SeptenaDate.parse(clock.today).map { Calendar.current.startOfDay(for: $0) }
      ?? Calendar.current.startOfDay(for: clock.now)
  }

  /// Start-of-day of the day the dial currently shows (today, or a scrubbed
  /// past day).
  private var displayedStart: Date {
    Calendar.current.date(byAdding: .day, value: dayOffset, to: todayStart) ?? todayStart
  }
  private var isToday: Bool { dayOffset == 0 }

  /// Step the scrubbed day, clamped to [today − maxDaysBack, today].
  private func stepDay(_ delta: Int) {
    dayOffset = max(-Self.maxDaysBack, min(0, dayOffset + delta))
  }

  /// The displayed day's sleep window (bedtime, wake) as dial fractions —
  /// read off the already-computed sleep band so the dial can mark bedtime
  /// with a moon and wake with a sun. nil when there's no night for the day.
  private var sleepMarks: (bed: Double, wake: Double)? {
    guard let b = snapshot.bandsBySection["sleep"]?.first(where: { $0.daysAgo == 0 }) else { return nil }
    return (b.start, b.end)
  }

  /// Reading `clock.now` here means the 60s tick re-renders only the hero
  /// (the now-hand advances), never the parent dashboard — the same
  /// isolation `WelcomeHeaderSection` uses.
  private var nowFraction: Double {
    let c = Calendar.current.dateComponents([.hour, .minute], from: clock.now)
    return (Double(c.hour ?? 0) * 60 + Double(c.minute ?? 0)) / 1440
  }

  /// The night arc (sunset → sunrise) as dial fractions, from the solar times
  /// of the *displayed* day — so scrubbing back also shifts the dark glass.
  private var nightArc: (start: Double, end: Double) {
    let t = SolarClock.today(now: displayedStart.addingTimeInterval(43_200))
    return (start: t.sunsetHour / 24, end: t.sunriseHour / 24)
  }

  var body: some View {
    TimeOfDayWheel(
      events: snapshot.events,
      // Neutral frame — the dots and bands carry the section colors, same
      // as the Rhythm mode's overlay dial.
      accent: Theme.inkSecondary,
      bands: snapshot.bands,
      // The scheduled (calendar) lane — loaded for the displayed day, so a
      // scrubbed past day shows that day's real meetings, not today's.
      todayBands: snapshot.calendarBands,
      windowDays: windowDays,
      // The now-hand only belongs on today — a past day has no "now".
      nowFraction: isToday ? nowFraction : nil,
      // The now-hand wears the current hour's ambient phase color, so it
      // glows with the same light as the halo behind the glass.
      nowColor: AmbientLight.Phase.from(date: clock.now).tint.inner,
      diameter: dialDiameter,
      heroDate: displayedStart,
      // The glass donut tints dark across the night hours (sunset → sunrise):
      // a crisp dark wedge sits BEHIND the clear glass (inside the wheel) so
      // the glass frosts and refracts it into real dark glass — night on the
      // face itself, not a wash behind it.
      nightArc: nightArc,
      // Single-day dial: no week overlay. Tap and swipe drive navigation and
      // day-scrubbing instead (handled below).
      lockToday: true,
      // Spin the dial so "now" is always at the top — today only; a past day
      // has no "now", so it rests at the fixed midnight-top orientation.
      northFraction: isToday ? nowFraction : nil,
      // Moon at bedtime, sun at wake, on the inner track.
      sleepMarks: sleepMarks
    )
    // A wide soft backwash for depth, drifting a few points against device
    // tilt (iOS) while the glass stays put — the parallax that makes the
    // donut read as glass with light floating behind it. (Night lives on the
    // donut now, so no disc-edge halo.)
    .background {
      AmbientGlow()
        .frame(width: 460, height: 460)
        .offset(glowParallax)
    }
    // Swipe ← → to scrub days; tap opens the Next feed. The dial follows the
    // finger a touch (resisted) and springs back on release — the "turning a
    // page" cue that the day is changing; the centre date is the confirmation.
    .offset(x: dragX)
    .contentShape(Circle())
    // `.gesture` (not high-priority) so the dashboard's vertical scroll still
    // wins a vertical drag; the dial only claims a horizontal swipe.
    .gesture(
      DragGesture(minimumDistance: 12)
        .onChanged { v in
          if abs(v.translation.width) > abs(v.translation.height) {
            dragX = v.translation.width * 0.35
          }
        }
        .onEnded { v in
          let dx = v.translation.width
          let horizontal = abs(dx) > abs(v.translation.height)
          withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            if horizontal && dx > 40 { stepDay(-1) }        // swipe right → previous day
            else if horizontal && dx < -40 { stepDay(1) }   // swipe left → next day
            dragX = 0
          }
        }
    )
    .onTapGesture { tabSelection.current = .next }
    // Off-today: a small "Today" affordance both signals you've scrubbed and
    // jumps back. Bottom-left so it clears the dial face.
    .overlay(alignment: .bottomLeading) {
      if !isToday {
        Button {
          withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { dayOffset = 0 }
        } label: {
          Image(systemName: "arrow.uturn.left")
            .font(.caption.weight(.semibold))
            .padding(7)
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Today")
        .transition(.opacity.combined(with: .scale))
      }
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
    .task(id: displayedStart) { reload() }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in
      reload()
    }
    #if os(iOS)
    // Motion runs only while the hero is actually on screen (TabView fires
    // onDisappear on tab switches), and not under Reduce Motion.
    .onAppear { if !reduceMotion { tilt.start() } }
    .onDisappear { tilt.stop() }
    .onChange(of: reduceMotion) { _, reduced in
      reduced ? tilt.stop() : tilt.start()
    }
    #endif
  }

  private func reload() {
    var colors: [String: Color] = [:]
    for key in visibleSections { colors[key] = theme.color(for: key) }
    snapshot = RhythmData.load(
      visible: visibleSections,
      colors: colors,
      sleepNights: sleepNights,
      // Load relative to the *displayed* day so scrubbing back shows that
      // day's dots/bands (the wheel plots its `daysAgo == 0` slice).
      todayStart: displayedStart,
      now: clock.now,
      windowDays: windowDays,
      calendarFallback: theme.color(for: "calendar"),
      context: modelContext
    )
  }
}

#if os(iOS)
/// Device-tilt source for the hero's glass-vs-light parallax. Attitude only
/// (no permission, no location), 30 Hz while the hero is visible, stopped on
/// disappear. The baseline is captured on start so the drift is relative to
/// how the user is HOLDING the phone, not absolute gravity — flat on a
/// table and upright in a hand both rest at zero. Low-passed and clamped to
/// ±8pt: a touch of depth, never a gimbal.
@MainActor
@Observable
final class TiltSource {
  private let manager = CMMotionManager()
  private(set) var offset: CGSize = .zero
  private var baseRoll: Double?
  private var basePitch: Double?

  func start() {
    guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
    manager.deviceMotionUpdateInterval = 1.0 / 30.0
    manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
      MainActor.assumeIsolated {
        guard let self, let a = motion?.attitude else { return }
        if self.baseRoll == nil { self.baseRoll = a.roll; self.basePitch = a.pitch }
        let dr = a.roll - (self.baseRoll ?? 0)
        let dp = a.pitch - (self.basePitch ?? 0)
        // Negative mapping: the light layer shifts AGAINST the tilt, the
        // way a backdrop slides opposite your head when you look through a
        // window — that's what places it *behind* the glass. ±0.35 rad of
        // tilt spans the full travel.
        func map(_ v: Double) -> CGFloat {
          CGFloat(max(-8, min(8, -v / 0.35 * 8)))
        }
        let target = CGSize(width: map(dr), height: map(dp))
        // Light low-pass so the drift feels like liquid, not telemetry.
        self.offset = CGSize(
          width: self.offset.width + (target.width - self.offset.width) * 0.15,
          height: self.offset.height + (target.height - self.offset.height) * 0.15
        )
      }
    }
  }

  func stop() {
    manager.stopDeviceMotionUpdates()
    offset = .zero
    baseRoll = nil
    basePitch = nil
  }
}
#endif
