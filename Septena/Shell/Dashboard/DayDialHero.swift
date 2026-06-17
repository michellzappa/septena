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
  /// Goes non-`.active` exactly when iOS grabs the app-switcher thumbnail.
  @Environment(\.scenePhase) private var scenePhase

  @State private var snapshot = RhythmData.Snapshot()
  /// Days back from today the dial is scrubbed to (0 = today, negative = past).
  /// Swiping the dial steps this; capped at today and ~a month back. Local to
  /// the hero — scrubbing previews a past day's rhythm without moving the rest
  /// of the dashboard off today.
  @State private var dayOffset = 0
  /// Live horizontal follow while swiping — the "turn the page" feel.
  @State private var dragX: CGFloat = 0
  /// Hides the data layers (dots, ticks, now-hand, bands, sleep glyphs) mid
  /// day-swipe so the dial can reorient without trying to spin everything in
  /// unison; revealed again at the new day.
  @State private var marksVisible = true
  /// Debounce token for `.septenaDataChanged`-driven reloads — coalesces the
  /// optimistic post with CloudKit's echo. Cancelled and replaced per post.
  @State private var reloadTask: Task<Void, Never>?
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
  private let dialDiameter: CGFloat = 297

  /// Roll the dial over at wake (sleep → 4am cutoff → midnight) rather than
  /// calendar midnight, so a night that runs past midnight stays on one dial.
  /// Shared default with the Rhythm layout mode; off → plain midnight buckets.
  @AppStorage(SettingsKey.wheelWakingDay) private var wakingDayEnabled = true

  /// The dial's day boundary, built from the loaded Oura nights.
  private var wakingDay: WakingDay {
    WakingDay.from(nights: sleepNights, enabled: wakingDayEnabled)
  }

  /// `dayKey` of the current waking day — the dial's "today". In the small
  /// hours this is still yesterday's civil date until you wake.
  private var todayStart: Date {
    wakingDay.dayKey(containing: clock.now)
  }

  /// Start-of-day of the day the dial currently shows (today, or a scrubbed
  /// past day).
  private var displayedStart: Date {
    Calendar.current.date(byAdding: .day, value: dayOffset, to: todayStart) ?? todayStart
  }
  private var isToday: Bool { dayOffset == 0 }

  /// True while the app is leaving (or has left) the foreground — the window
  /// iOS uses to snapshot for the app switcher. The live `.glassEffect` can't
  /// render in that snapshot, so the dark night wedge it normally *frosts into
  /// glass* is left showing as a raw, hard slate-indigo gradient. In this state
  /// we hand the wheel `flatGlass`, which draws the opaque faux-glass face and
  /// (gated in the wheel) drops the unfrostable night wedge — a clean static
  /// dial in the thumbnail instead of a floating shadow.
  private var snapshotting: Bool { scenePhase != .active }

  /// Step the scrubbed day, clamped to [today − maxDaysBack, today].
  private func stepDay(_ delta: Int) {
    dayOffset = max(-Self.maxDaysBack, min(0, dayOffset + delta))
  }

  /// Day-swipe transition: fade the data out, reorient the dial (the night
  /// wedge turns; "now"-at-top only differs between today and a past day),
  /// then fade the new day's data in — rather than spinning every layer at
  /// once. Holds longer when crossing the today boundary, where the wedge has
  /// a real turn to make; a past↔past step is just a quick data swap.
  private func scrub(_ delta: Int) {
    let target = max(-Self.maxDaysBack, min(0, dayOffset + delta))
    guard target != dayOffset else { return }
    let crossesToday = (dayOffset == 0) != (target == 0)
    let holdMs = crossesToday ? 560 : 190
    withAnimation(.easeOut(duration: 0.14)) { marksVisible = false }
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(150))
      dayOffset = target                 // reorients (wedge animates) + reloads
      try? await Task.sleep(for: .milliseconds(holdMs))
      withAnimation(.easeIn(duration: 0.3)) { marksVisible = true }
    }
  }

  /// The displayed day's sleep window (bedtime, wake) as dial fractions —
  /// read off the already-computed sleep band so the dial can mark bedtime
  /// with a moon and wake with a sun. nil when there's no night for the day.
  private var sleepMarks: (bed: Double, wake: Double)? {
    guard let b = snapshot.bandsBySection["sleep"]?.first(where: { $0.daysAgo == 0 }) else { return nil }
    return (b.start, b.end)
  }

  /// Sleep is recovery info — most useful the moment you wake, and less so as
  /// the day fills with its own dots. On *today* the sleep arc fades out over
  /// the ~8 hours after wake (full at wake → gone by midday), so the
  /// dial turns from looking back to living forward. Scrubbed past days keep
  /// the full arc — you're reviewing them, not living them. Smoothstepped so
  /// the thinning reads as a fade, not a wipe.
  private var sleepArcOpacity: Double {
    guard isToday, let wake = sleepMarks?.wake else { return 1 }
    var delta = nowFraction - wake
    if delta < 0 { delta += 1 }            // before wake on the dial: treat as 0
    let t = max(0, min(1, (delta * 24) / 8))   // 0 at wake → 1 eight hours on
    return 1 - (t * t * (3 - 2 * t))
  }

  /// The bedtime moon is the arc's mirror image: hidden in the morning (the
  /// arc's own rounded cap already marks where you went to bed), it fades in
  /// as the arc clears so the lone glyph reads as *tonight's* expected bedtime
  /// rather than last night's. Position stays at last night's bedtime — a fair
  /// proxy for "about when you'll turn in" (could become a trailing usual
  /// bedtime later). Full on past days, where the moon bookends the night.
  private var moonOpacity: Double { isToday ? 1 - sleepArcOpacity : 1 }

  /// Today's sleep band, dimmed by `sleepArcOpacity`; every other band passes
  /// through untouched. The wake `sun` is unaffected — it stays as the day's
  /// origin all day.
  private var displayBands: [TimeOfDayWheel.Band] {
    guard sleepArcOpacity < 1,
          let sleepID = snapshot.bandsBySection["sleep"]?.first(where: { $0.daysAgo == 0 })?.id
    else { return snapshot.bands }
    return snapshot.bands.map { band in
      guard band.id == sleepID else { return band }
      var faded = band
      faded.color = (band.color ?? Theme.inkSecondary).opacity(sleepArcOpacity)
      return faded
    }
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
      bands: displayBands,
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
      // The night wedge wears the user's Sleep color in dark mode (where a
      // dark tone would read as muddy dark-on-dark); light mode keeps the
      // built-in slate-indigo.
      nightColor: theme.color(for: "sleep"),
      // Single-day dial: no week overlay. Tap and swipe drive navigation and
      // day-scrubbing instead (handled below).
      lockToday: true,
      // Spin the dial so "now" is always at the top — today only; a past day
      // has no "now", so it rests at the fixed midnight-top orientation.
      northFraction: isToday ? nowFraction : nil,
      // Moon at bedtime, sun at wake, on the inner track. The sun stays lit all
      // day (the day's origin); the moon crossfades in as the sleep arc fades,
      // turning bedtime from "last night" into "tonight's expected".
      sleepMarks: sleepMarks,
      moonOpacity: moonOpacity,
      sunOpacity: 1,
      // Hidden while a day-swipe reorients the dial, then revealed.
      marksOpacity: marksVisible ? 1 : 0,
      // In the app-switcher snapshot the live glass can't render — fall back to
      // the opaque faux-glass face so the donut reads as solid frosted glass
      // instead of a transparent hole.
      flatGlass: snapshotting
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
          withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { dragX = 0 }
          if horizontal && dx > 40 { scrub(-1) }        // swipe right → previous day
          else if horizontal && dx < -40 { scrub(1) }   // swipe left → next day
        }
    )
    .onTapGesture { tabSelection.current = .next }
    // Off-today: a small "Today" affordance both signals you've scrubbed and
    // jumps back. Bottom-left so it clears the dial face.
    .overlay(alignment: .bottomLeading) {
      if !isToday {
        Button {
          scrub(-dayOffset)
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
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { note in
      // Reload only when a section the dial plots changed (or the post is
      // unscoped — a CloudKit batch). Skips dial-less edits, and the debounce
      // coalesces the optimistic post with CloudKit's echo into one reload.
      guard note.affectsAnySection(of: dialSections) else { return }
      scheduleReload()
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

  /// Sections the dial can render — gates the data-changed listener so only
  /// relevant edits reload it. Visible sections cover the timed streams; the
  /// extras are the non-`LoggedEvent` streams `RhythmData` reads.
  private var dialSections: Set<String> {
    visibleSections.union(["tasks", "intake", "training", "sleep", "calendar"])
  }

  /// Coalesce the optimistic scoped post and CloudKit's unscoped echo (same
  /// local edit, a fraction of a second apart) into one reload — one
  /// cross-section fetch per toggle instead of two.
  private func scheduleReload() {
    reloadTask?.cancel()
    reloadTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
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
      // Load relative to the *displayed* day so scrubbing back shows that
      // day's dots/bands (the wheel plots its `daysAgo == 0` slice).
      todayStart: displayedStart,
      now: clock.now,
      windowDays: windowDays,
      calendarFallback: theme.color(for: "calendar"),
      wakingDay: wakingDay,
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
