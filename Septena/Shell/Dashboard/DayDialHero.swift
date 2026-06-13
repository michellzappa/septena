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
  /// The dial's today ⇄ week window (the wheel owns the tap; same shared key)
  /// — today lets the donut carry night itself; week adds the current-hour
  /// glow halo.
  @AppStorage(TimeOfDayWheel.windowDefaultsKey) private var todayOnly = true

  @State private var snapshot = RhythmData.Snapshot()
  #if os(iOS)
  @State private var tilt = TiltSource()
  #endif

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

  /// Reading `clock.now` here means the 60s tick re-renders only the hero
  /// (the now-hand advances), never the parent dashboard — the same
  /// isolation `WelcomeHeaderSection` uses.
  private var nowFraction: Double {
    let c = Calendar.current.dateComponents([.hour, .minute], from: clock.now)
    return (Double(c.hour ?? 0) * 60 + Double(c.minute ?? 0)) / 1440
  }

  /// The night arc (sunset → sunrise) as dial fractions, from the device's
  /// real solar times — the glass donut tints dark across these hours.
  private var nightArc: (start: Double, end: Double) {
    let t = SolarClock.today(now: clock.now)
    return (start: t.sunsetHour / 24, end: t.sunriseHour / 24)
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
      // The now-hand wears the current hour's ambient phase color, so it
      // glows with the same light as the halo behind the glass.
      nowColor: AmbientLight.Phase.from(date: clock.now).tint.inner,
      diameter: dialDiameter,
      heroDate: todayStart,
      // The glass donut tints dark across the night hours (sunset → sunrise):
      // a crisp dark wedge sits BEHIND the clear glass (inside the wheel) so
      // the glass frosts and refracts it into real dark glass — night on the
      // face itself, not a wash behind it.
      nightArc: nightArc
    )
    // The light is a background so it bleeds past the dial (toward the
    // greeting above) without claiming layout height: a wide soft backwash
    // for depth. On today the donut carries night itself, so the disc-edge
    // halo would only re-add the dark shadow we removed — it's kept for the
    // week view (a uniform current-hour glow). The whole light layer drifts
    // a few points against device tilt (iOS) while the glass stays put — the
    // parallax that makes the donut read as glass with light floating behind.
    .background {
      ZStack {
        AmbientGlow()
          .frame(width: 460, height: 460)
        if !todayOnly {
          AmbientHalo(diameter: dialDiameter - 2 * TimeOfDayWheel.fullMargin,
                      style: .now)
        }
      }
      .offset(glowParallax)
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
      todayStart: todayStart,
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
