import SwiftUI

/// A 24-hour radial "rhythm" dial. Plots a trailing window of timestamped
/// events as dots around a clock face — midnight at top, clockwise — faded by
/// recency so the most recent day reads bright and older days recede to a
/// ghost. Where a behavior is consistent the dots stack on the same angle, the
/// accent deepens (alpha compositing) *and* the dots grow (local density), so
/// clusters read as bigger, darker blobs. No averaging — the eye does the
/// aggregation, which keeps midnight-wrap and twice-a-day habits honest.
///
/// Durations (sleep, fasting) plot as `Band`s — arcs from a start to an end
/// fraction, wrapping midnight when needed — drawn on an inner ring so seven
/// overlaid nights pool into a natural "usual sleep window" without averaging.
///
/// The host computes `(fraction, daysAgo)` per event from each row's *local*
/// time-of-day and calendar-day distance. Read-only, Canvas-drawn for cheap
/// alpha stacking.
struct TimeOfDayWheel: View {
  struct Event: Identifiable {
    let id: String
    /// Time of day as 0..<1 (0 = local midnight, 0.5 = noon).
    let fraction: Double
    /// Calendar days before today: 0 = today (brightest) … `windowDays-1`.
    let daysAgo: Int
    /// Per-event tint. `nil` falls back to the wheel's `accent` (single-section
    /// detail use); the holistic homepage wheel sets each dot's section color.
    var color: Color? = nil
  }

  /// A duration drawn as an arc (e.g. a night's sleep, bedtime → wake).
  struct Band: Identifiable {
    let id: String
    /// Start of the arc as 0..<1 (e.g. bedtime).
    let start: Double
    /// End of the arc as 0..<1 (e.g. wake). May be < `start` — the arc then
    /// wraps clockwise through midnight (top).
    let end: Double
    let daysAgo: Int
    var color: Color? = nil
    /// Half-weight stroke — calendar events render thinner than logged
    /// durations (sleep, fasting), matching the day timeline's thin pills.
    var thin: Bool = false
    /// Solid (not washed) — for activities like training that should read as
    /// a present thing, not an ambient window. Sleep stays translucent (the
    /// soft "usual sleep window" pool).
    var opaque: Bool = false
  }

  let events: [Event]
  let accent: Color
  var bands: [Band] = []
  /// Bands shown only in the today-focused view (e.g. today's calendar events
  /// as time-block pills). Hidden in the week overlay so it stays uncluttered.
  var todayBands: [Band] = []
  /// How many trailing days the fade spans. Day 0 is full strength; day
  /// `windowDays-1` is the faintest ghost.
  var windowDays: Int = 7
  /// Optional current-time hand (0..<1) — a hairline from center marking "now".
  var nowFraction: Double? = nil
  /// Tint for the hero's now-hand — the current hour's ambient phase color, so
  /// the hand glows with the day's light and ends in a luminous tip. `nil`
  /// keeps the plain neutral hairline (section-detail and compact dials).
  var nowColor: Color? = nil
  /// Square side of the dial.
  var diameter: CGFloat = 240
  /// Compact tile rendering (the homepage Wheel mode's per-section mini wheels):
  /// drops the hour labels, "…" menu, center hub, "now" hand and the heavy white
  /// disc, and locks to the full-week overlay (no window picker — a thumbnail
  /// isn't an interactive control). Ticks stay as a faint frame so the angles
  /// still read.
  var compact: Bool = false
  /// Hero treatment (`DayDialHero`): set to the day being shown. Replaces
  /// the center scope chip with the date while focused on today (a clock
  /// face shows its day); the week overlay keeps the "7 days" chip so that
  /// state stays labeled. The sky itself (solar band) lives entirely in the
  /// halo BEHIND the dial (`AmbientHalo`) — the face stays clean. Ignored
  /// when `compact`.
  var heroDate: Date? = nil
  /// The night arc as `(start, end)` fractions (sunset → sunrise, wrapping
  /// midnight). When set on the hero, the glass donut itself tints dark over
  /// these hours — stained-glass night, drawn on the face — instead of a dark
  /// wash behind it. `nil` keeps the plain clear-glass donut.
  var nightArc: (start: Double, end: Double)? = nil
  /// The hue the night arc wears instead of the fixed slate-indigo. The hero
  /// passes the user's Sleep section color so that in dark mode the night reads
  /// as a tint against the dark glass rather than muddy dark-on-dark. `nil`
  /// keeps the static `nightTone` (the widget, section dials).
  var nightColor: Color? = nil
  /// Locks the dial to a single day — no today⇄week tap toggle, always
  /// focused on `heroDate`. The hero uses this so its tap and swipe are free
  /// for navigation (tap → Next) and day-scrubbing (swipe → prev/next day);
  /// section-detail dials leave it `false` and keep the week-overlay toggle.
  var lockToday: Bool = false
  /// When set (0..<1), the whole dial rotates so this fraction sits at the top
  /// (north) — the hero passes `nowFraction` so "now" is always at 12 o'clock
  /// and the clock turns slowly through the day. The centre labels are drawn
  /// in a separate, un-rotated layer so they stay upright. `nil` keeps the
  /// fixed midnight-at-top orientation (section dials, past days).
  var northFraction: Double? = nil
  /// Optional sleep window as `(bedtime, wake)` fractions — drawn as a moon
  /// (bedtime) and sun (wake) on the inner/scheduled track, upright and
  /// outside the rotation so the glyphs stay readable as the dial turns.
  var sleepMarks: (bed: Double, wake: Double)? = nil
  /// Fades the data layers (dots, ticks, now-hand, bands, sleep glyphs) — the
  /// hero drops this to 0 during a day-swipe so the marks are hidden while the
  /// dial reorients, then back to 1 to reveal the new day. Avoids trying to
  /// spin every layer in unison (only the night wedge turns, visibly).
  var marksOpacity: Double = 1
  /// Renders the hero face *flat* — a solid disc instead of the live Liquid
  /// Glass donut. For the widget snapshot, where `.glassEffect` can't render
  /// (a static archived view); the night wedge still paints on top so the
  /// solar hours read. No-op unless `heroDate` is set. App surfaces leave this
  /// `false` and keep the real glass.
  var flatGlass: Bool = false

  /// Target degrees to spin the dial content so `northFraction` lands at the
  /// top. The *applied* rotation is `displayedRotation`, which tracks this by
  /// the SHORTEST path so a reorientation never spins the long way round.
  private var northRotation: Double { northFraction.map { -$0 * 360 } ?? 0 }

  /// The actually-applied rotation, accumulated so each change to
  /// `northRotation` moves by the shortest signed delta (±180° max).
  @State private var displayedRotation: Double = 0

  /// Drives the night arc's tone: dark mode swaps the muddy slate-indigo for
  /// the Sleep-colored tint (see `resolvedNightTone`).
  @Environment(\.colorScheme) private var colorScheme

  /// Base (un-rotated) position of a clock `fraction` on the ring at
  /// `radiusFactor`. The dial's rotation is applied by the enclosing
  /// `rotationEffect` (so glyphs orbit on the ring's arc, in harmony with the
  /// rest of the dial), not baked into this coordinate.
  private func ringPoint(_ fraction: Double, _ radiusFactor: CGFloat, in side: CGFloat) -> CGPoint {
    let ringR = side / 2 - margin
    let r = ringR * radiusFactor
    let a = fraction * 2 * .pi
    return CGPoint(x: side / 2 + r * CGFloat(sin(a)),
                   y: side / 2 - r * CGFloat(cos(a)))
  }

  /// Margin between the dial's square and its tick ring (full rendering).
  /// Shared with `dotRing(forDiameter:)` so external geometry — the `.arc`
  /// comet orbiting the hero dial — lands exactly on the drawn ring.
  static let fullMargin: CGFloat = 20

  /// The hero glass donut's hole, as a fraction of the disc radius. ONE
  /// definition shared by the `AnnulusShape` glass mask and the Canvas (the
  /// now-hand starts at this edge; the date floats in the hollow).
  static let heroHoleFraction: CGFloat = 0.42

  /// The dark tone the night arc wears behind the glass — a soft slate-indigo
  /// (lighter than a true night so the frosted glass stays gentle). Tune this
  /// for a darker/lighter night.
  static let nightTone = Color(red: 0.26, green: 0.28, blue: 0.40).opacity(0.72)

  /// The night arc's tone, resolved against the color scheme. In dark mode the
  /// fixed slate-indigo reads as muddy dark-on-dark, so the night is tinted
  /// with the user's Sleep color instead (`nightColor`) — a hue against the
  /// dark glass, not more darkness. Light mode keeps the slate-indigo, which
  /// reads fine on the bright donut. Falls back to the static tone when no
  /// Sleep color is supplied (widget, section dials).
  private var resolvedNightTone: Color {
    guard colorScheme == .dark, let nightColor else { return Self.nightTone }
    return nightColor.opacity(0.55)
  }

  /// Conic shading for the night arc, filled on the whole band behind the
  /// glass: transparent through the day, ramping to the night tone over ~1h at
  /// sunset (dusk) and back to clear over ~1h before sunrise (dawn), so the
  /// terminators feather instead of cutting hard. Angle −90° puts midnight
  /// (location 0) at the top, sweeping clockwise — the dial's convention.
  private func nightShading(_ arc: (start: Double, end: Double)) -> AngularGradient {
    let feather = 1.0 / 24          // ~1 hour, as dial fraction
    let sunset = arc.start, sunrise = arc.end
    let tone = resolvedNightTone
    let stops: [Gradient.Stop] = [
      .init(color: tone,   location: 0),
      .init(color: tone,   location: max(0, sunrise - feather)),
      .init(color: .clear, location: sunrise),
      .init(color: .clear, location: sunset),
      .init(color: tone,   location: min(1, sunset + feather)),
      .init(color: tone,   location: 1),
    ]
    return AngularGradient(gradient: Gradient(stops: stops),
                           center: .center, angle: .degrees(-90))
  }

  /// Radius of the ring the dots and bands sit on, for a full (non-compact)
  /// dial of `diameter`. The Canvas derives the same value from its live
  /// size; this exists so `DayDialHero` can publish the circle the `.arc`
  /// flourish traces (`DayDialAnchor`).
  static func dotRing(forDiameter d: CGFloat) -> CGFloat {
    (d / 2 - fullMargin) * 0.82
  }

  // Brightest (today) → faintest (oldest day in the window).
  private let maxOpacity: Double = 0.92
  private let minOpacity: Double = 0.12

  /// Ceiling on a dot's alpha — the brightest (today) dots render translucent
  /// so the glass donut reads through them. Over the near-white donut a high
  /// value barely reads (and dense slots stack toward opaque anyway), so this
  /// sits low. The recency fade for older days is unchanged (only the top of
  /// the range, which today occupies, is clamped); size/density math is intact.
  private let dotMaxOpacity: Double = 0.5

  /// Ceiling on an opaque duration band's alpha (training). Like the dots, it
  /// stays semitransparent so the whole donut reads as glass — but sits a touch
  /// above the soft sleep wash (~0.55) so training still reads as the more
  /// "present" activity rather than an ambient window.
  private let bandMaxOpacity: Double = 0.6

  /// Shared defaults key for the today ⇄ week window, public so co-presenting
  /// views (the hero's `AmbientHalo` style) can key off the same state.
  static let windowDefaultsKey = "timeOfDayWheel.todayOnly"

  /// Tap picks the window: just today (the default — a dense week can be
  /// confusing, so the dial opens focused on today) or the full window. The
  /// week's data is always loaded; the tap just reveals it. Stored in
  /// `@AppStorage` under one shared key, so flipping the window on any dial
  /// flips every other dial too (and the choice persists across launches).
  @AppStorage(Self.windowDefaultsKey) private var todayOnly = true

  /// The resolved focus: a locked dial (the hero) is always single-day;
  /// compact tiles always show the full week (the overlay *is* the point of a
  /// thumbnail); the full dial honors the tap toggle.
  private var focusToday: Bool { lockToday ? true : (compact ? false : todayOnly) }
  /// Outer margin for the labels/disc — collapses in compact so the dial fills
  /// its tile.
  private var margin: CGFloat { compact ? 5 : Self.fullMargin }

  private var effectiveWindow: Int { focusToday ? 1 : windowDays }
  private var shownEvents: [Event] { focusToday ? events.filter { $0.daysAgo == 0 } : events }
  private var shownBands: [Band] { focusToday ? bands.filter { $0.daysAgo == 0 } : bands }

  private func fade(_ daysAgo: Int) -> Double {
    let w = effectiveWindow
    let t = w > 1
      ? Double(min(max(daysAgo, 0), w - 1)) / Double(w - 1)
      : 0
    // Eased (not linear) so older days drop off faster and the dial stays
    // dominated by the last day or two — keeps a busy week readable.
    return minOpacity + (maxOpacity - minOpacity) * pow(1 - t, 1.7)
  }

  /// One plotted event dot — position (in the dial's `side`×`side` space),
  /// diameter, section color, recency opacity. The single source for both
  /// the Canvas flat fills and the hero's glass beads.
  struct DotMark: Identifiable {
    let id: String
    let center: CGPoint
    let diameter: CGFloat
    let color: Color
    let opacity: Double
  }

  /// Lay out the shown events as dots. Density (events sharing a 30-min
  /// slot) grows the dot: today uses the day-timeline's bubble sizing
  /// (5pt single → 8pt capped), week scales relative to the busiest slot.
  func dotMarks(side: CGFloat) -> [DotMark] {
    let center = CGPoint(x: side / 2, y: side / 2)
    let ringR = side / 2 - margin
    guard ringR > 8 else { return [] }
    let dotRing = ringR * 0.82
    func point(_ f: Double, _ r: CGFloat) -> CGPoint {
      let a = f * 2 * .pi
      return CGPoint(x: center.x + r * CGFloat(sin(a)),
                     y: center.y - r * CGFloat(cos(a)))
    }
    let slots = 48
    var density: [Int: Int] = [:]
    for e in shownEvents { density[Int(e.fraction * Double(slots)) % slots, default: 0] += 1 }
    let maxCount = Double(density.values.max() ?? 1)
    // Oldest first so today lands on top.
    return shownEvents.sorted { $0.daysAgo > $1.daysAgo }.map { e in
      let count = Double(density[Int(e.fraction * Double(slots)) % slots] ?? 1)
      let norm = maxCount > 1 ? (count - 1) / (maxCount - 1) : 0
      let dotR: CGFloat = effectiveWindow == 1 ? min(8, 4 + count) / 2 : (2.2 + norm * 1.8)
      return DotMark(id: e.id, center: point(e.fraction, dotRing),
                     diameter: dotR * 2, color: e.color ?? accent,
                     opacity: min(fade(e.daysAgo), dotMaxOpacity))
    }
  }

  var body: some View {
    ZStack {
      // The clock face. Non-hero dials get the flat card-surface disc here
      // at the bottom of the stack (section details sit on drawer cards,
      // where glass would stack a second translucent layer — spec §5.5).
      // The HERO's face is the Liquid Glass donut below, SANDWICHED between
      // the two drawing layers: machinery under the glass, data on top.
      // Both faces land their edge exactly on the tick ring (20pt inset =
      // the Canvas `ringR` margin). Compact draws no face at all.
      if !compact && heroDate == nil {
        Circle()
          .fill(Theme.cardSurface)
          .overlay(Circle().strokeBorder(Theme.inkSecondary.opacity(0.18), lineWidth: 1.5))
          .shadow(color: .black.opacity(0.07), radius: 5, y: 2)
          .padding(20)
      }

      // The hero's face is the REAL Liquid Glass donut, drawn BELOW the
      // marks. Real glass frosts whatever sits under it, so nothing
      // data-bearing goes there (the old "machinery under glass" sandwich
      // hid the sleep arc + calendar pills). Glass is just glass; every mark
      // renders crisp in the single Canvas ON TOP. `.interactive` gives the
      // press-lensing; the tilt parallax behind it supplies the motion that
      // makes Liquid Glass actually read as glass.
      // A dark conic wash over the night arc, BEHIND the glass, so the glass
      // has real dark content to frost and refract. It ROTATES with the clock
      // so the dark band tracks the (rotated) night hours; the glass refracts
      // whatever sits behind it, so night still reads as dark *glass*. The
      // dusk/dawn terminators feather over ~1h.
      // Widget snapshot: a flat solid disc stands in for the glass donut
      // (drawn first, so the night wedge below paints on top of it). The live
      // glass below is skipped when `flatGlass` is set.
      if !compact, heroDate != nil, flatGlass {
        AnnulusShape(holeFraction: Self.heroHoleFraction)
          .fill(Theme.cardSurface)
          .padding(20)
      }
      if !compact, heroDate != nil, let nightArc {
        AnnulusShape(holeFraction: Self.heroHoleFraction)
          .fill(nightShading(nightArc))
          .padding(20)
          .rotationEffect(.degrees(displayedRotation))
          .animation(.easeInOut(duration: 0.6), value: displayedRotation)
      }
      // The clear glass donut is a uniform ring, so it must NOT rotate —
      // `rotationEffect` disables `.glassEffect` (the live material can't
      // render through a rotation transform). Static glass; the rotated dark
      // wedge behind it supplies the night, the rotated marks above supply
      // the data. `.interactive` gives the press lensing; tilt parallax the
      // motion that makes it read as glass.
      if !compact && heroDate != nil && !flatGlass {
        Color.clear
          .glassEffect(.regular.interactive(),
                       in: AnnulusShape(holeFraction: Self.heroHoleFraction))
          .padding(20)
      }

      // All marks, on top of the face: ticks, duration bands, dots, hour
      // labels, the now-hand, and the centre date/chip — every one crisp
      // and legible, none fighting the glass.
      Canvas { ctx, size in
      let side = min(size.width, size.height)
      let center = CGPoint(x: size.width / 2, y: size.height / 2)
      let ringR = side / 2 - margin
      guard ringR > 8 else { return }

      func point(_ fraction: Double, _ r: CGFloat) -> CGPoint {
        let a = fraction * 2 * .pi          // 0 at top, clockwise
        return CGPoint(x: center.x + r * CGFloat(sin(a)),
                       y: center.y - r * CGFloat(cos(a)))
      }
      // Arc from `start` to `end` (clockwise, wrapping midnight if end < start).
      func arc(_ start: Double, _ end: Double, _ r: CGFloat) -> Path {
        var span = end - start
        if span <= 0 { span += 1 }
        let steps = max(2, Int(span * 120))
        var p = Path()
        for i in 0...steps {
          let f = (start + span * Double(i) / Double(steps)).truncatingRemainder(dividingBy: 1)
          let pt = point(f, r)
          if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
      }

      // Neutral grid on every dial — the section colors live in the dots and
      // bands, so the ticks frame the data without competing with it.
      let lineColor = Theme.inkSecondary

      // Compact tiles have no disc behind them — a faint frame ring anchors
      // the angles.
      if compact {
        ctx.stroke(Path(ellipseIn: CGRect(x: center.x - ringR, y: center.y - ringR,
                                          width: ringR * 2, height: ringR * 2)),
                   with: .color(lineColor.opacity(0.22)), lineWidth: 1.5)
      }

      // Hour ticks — quarter-marks longest/darkest, 3-hour medium, others minor.
      for h in 0..<24 {
        let f = Double(h) / 24
        let major = (h % 6 == 0)
        let mid = (h % 3 == 0)
        let length: CGFloat = compact ? (major ? 5 : mid ? 3 : 2) : (major ? 11 : mid ? 7 : 5)
        var tick = Path()
        tick.move(to: point(f, ringR - length))
        tick.addLine(to: point(f, ringR))
        ctx.stroke(tick,
                   with: .color(lineColor.opacity(major ? 0.42 : mid ? 0.28 : 0.20)),
                   lineWidth: major ? 2 : 1)
      }

      // Two lanes: things you logged share the OUTER ring with their dots;
      // scheduled (calendar) blocks pull into an INNER lane — "did" outside,
      // "planned" inside. Radius now carries that one distinction; angle still
      // means time, color still means section.
      let dotRing = ringR * 0.82            // outer: logged dots + durations
      let scheduledRing = ringR * 0.68      // inner: calendar / scheduled

      // Logged duration bands (sleep, training) on the outer ring, under the
      // dots, on top of the glass so they stay legible. Everything on the donut
      // is semitransparent so the glass reads through: sleep is a soft wash
      // (the ambient "usual window"); opaque bands (training) sit a touch more
      // present (capped at `bandMaxOpacity`) but still translucent.
      for b in shownBands.sorted(by: { $0.daysAgo > $1.daysAgo }) {
        // Sleep (the thin band here) sits a touch thicker than a calendar pill
        // — about the min dot diameter — so the night reads as a soft lane,
        // not a hairline. Training (opaque) keeps the heavy 9pt stroke.
        let lineW: CGFloat = b.thin ? 5 : 9
        let alpha = b.opaque ? min(bandMaxOpacity, fade(b.daysAgo) + 0.2) : fade(b.daysAgo) * 0.6
        ctx.stroke(arc(b.start, b.end, dotRing),
                   with: .color((b.color ?? accent).opacity(alpha)),
                   style: StrokeStyle(lineWidth: lineW, lineCap: .round))
      }
      // Scheduled (calendar) blocks on the inner lane — single-day view only.
      // Back-to-back events (one ends exactly when the next begins) would share
      // an endpoint angle and, with the round caps spilling half a line-width
      // past each end, merge into one continuous band. Inset each end by the
      // cap radius plus a hair so adjacent events pull apart into a `)(` — the
      // caps taper away from the boundary instead of overlapping across it.
      if focusToday {
        for b in todayBands.sorted(by: { $0.daysAgo > $1.daysAgo }) {
          let lineW: CGFloat = b.thin ? 4 : 9
          // Round-cap overhang (lineW/2) + a 1pt breathing gap, as a fraction
          // of the day at this ring's circumference.
          let insetPx = lineW / 2 + 1
          let insetFrac = Double(insetPx) / (2 * .pi * Double(scheduledRing))
          var span = b.end - b.start
          if span <= 0 { span += 1 }
          // Never eat more than 40% per side — short events keep a visible core.
          let inset = min(insetFrac, span * 0.4)
          let s = (b.start + inset).truncatingRemainder(dividingBy: 1)
          let e = (b.end - inset + 1).truncatingRemainder(dividingBy: 1)
          ctx.stroke(arc(s, e, scheduledRing),
                     with: .color((b.color ?? accent).opacity(fade(b.daysAgo) * 0.6)),
                     style: StrokeStyle(lineWidth: lineW, lineCap: .round))
        }
      }

      // "Now" hand. On the hero it starts at the glass donut's inner edge
      // (the hole is open — nothing to cap it) and runs to the ring, tinted
      // with the current hour's ambient phase color so it glows with the
      // day's light and ends in a luminous tip; a neutral base keeps it
      // legible when the tint goes pale at midday. Flat-disc dials keep the
      // plain accent hairline from center, capped by the hub disc.
      if let nowFraction {
        let handStart = heroDate != nil
          ? point(nowFraction, ringR * Self.heroHoleFraction)
          : center
        let tip = point(nowFraction, ringR - 2)
        var hand = Path()
        hand.move(to: handStart)
        hand.addLine(to: tip)
        if let nowColor {
          // Neutral base first — always visible, whatever the tint does.
          ctx.stroke(hand, with: .color(Theme.inkSecondary.opacity(0.40)), lineWidth: 2)
          // Phase-colored overlay — the day's light on the hand.
          ctx.stroke(hand, with: .color(nowColor.opacity(0.95)), lineWidth: 1.5)
        } else {
          ctx.stroke(hand, with: .color(accent.opacity(0.6)), lineWidth: 1)
        }
      }

      // Dots — clean solid section-colored marks, on every dial. Real
      // `.glassEffect` beads were tried at the hero scale: on top of the glass
      // donut they carried the material's built-in elevation shadow and read
      // as muddy smudges (glass-on-content, which Apple's HIG warns against).
      // Glass is the donut (chrome); the data on it stays solid and crisp.
      for m in dotMarks(side: side) {
        let r = m.diameter / 2
        let rect = CGRect(x: m.center.x - r, y: m.center.y - r,
                          width: m.diameter, height: m.diameter)
        ctx.fill(Path(ellipseIn: rect), with: .color(m.color.opacity(m.opacity)))
      }

      // Center. Section dials (no heroDate) draw a hub disc + scope chip here
      // in the Canvas. The HERO's centre is the upright overlay (`heroCenter`)
      // and NEVER the Canvas — so the date stays fixed and level while the
      // dial spins (drawing it in the rotating Canvas made it whirl). Compact
      // thumbnails: nothing.
      if !compact && heroDate == nil {
        let hubR: CGFloat = 30
        let hub = CGRect(x: center.x - hubR, y: center.y - hubR,
                         width: hubR * 2, height: hubR * 2)
        ctx.fill(Path(ellipseIn: hub), with: .color(Theme.cardSurface))
        ctx.stroke(Path(ellipseIn: hub),
                   with: .color(Theme.inkSecondary.opacity(0.18)), lineWidth: 1)
        let scope = todayOnly ? "Today" : "\(windowDays) days"
        ctx.draw(Text(scope).font(.caption2.weight(.medium)).foregroundStyle(.secondary),
                 at: center)
      }
    }
    // The marks (ticks, bands, dots, now-hand) sit at the dial's orientation
    // ("now" at the top). They DON'T animate their rotation — during a
    // day-swipe they're faded out (marksOpacity → 0), the dial reorients, and
    // they fade back in at the new angle, so there's no multi-layer spin to
    // fall out of sync. Only the night wedge turns visibly.
    .rotationEffect(.degrees(displayedRotation))
    .opacity(marksOpacity)

      // The hero's centre labels live OUTSIDE the rotation — always, so the
      // date stays upright and fixed whether the dial is at rest, drifting, or
      // mid-spin to another day. (Section dials draw their centre in the
      // Canvas above; they never rotate.)
      if let heroDate, focusToday {
        heroCenter(heroDate)
      }
      // Sleep moon/sun — on the inner track, but upright (outside rotation).
      sleepGlyphs
    }
    .frame(width: diameter, height: diameter)
    .contentShape(Circle())
    // A locked dial (the hero) handles its own tap/swipe in `DayDialHero`;
    // only the toggling dials wire the today⇄week tap here.
    .modifier(WheelTapToggle(enabled: !compact && !lockToday) { todayOnly.toggle() })
    .accessibilityElement()
    .accessibilityAddTraits(compact || lockToday ? [] : .isButton)
    .accessibilityLabel(Text("Time-of-day wheel"))
    .accessibilityValue(Text(focusToday
      ? "\(shownEvents.count) events"
      : "\(events.count) events over the last \(windowDays) days"))
    .accessibilityHint(compact || lockToday
      ? Text("")
      : Text("Double tap to switch between today and the last \(windowDays) days"))
    // Seed the applied rotation without animating in from 0 on first appear.
    .onAppear {
      var t = Transaction(); t.disablesAnimations = true
      withTransaction(t) { displayedRotation = northRotation }
    }
    // Track the target by the shortest signed delta, so the dial never spins
    // the long way round (e.g. 5pm → midnight turns 108°, not 252°).
    .onChange(of: northFraction) { _, _ in
      var delta = (northRotation - displayedRotation).truncatingRemainder(dividingBy: 360)
      if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
      displayedRotation += delta
    }
  }

  /// The centre date stack (weekday · day · month) for the rotating hero,
  /// drawn upright in a layer outside the dial's rotation so it never turns
  /// with the clock. Mirrors the in-Canvas stack used by non-rotating dials.
  private func heroCenter(_ date: Date) -> some View {
    VStack(spacing: -1) {
      Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
      Text(date.formatted(.dateTime.day()))
        .font(.system(.title3, design: .rounded).weight(.semibold))
        .monospacedDigit().foregroundStyle(.primary)
      Text(date.formatted(.dateTime.month(.abbreviated)).uppercased())
        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }
    .allowsHitTesting(false)
  }

  /// Moon at bedtime, sun at wake — on the inner/scheduled track. The whole
  /// group ORBITS with the dial (same `rotationEffect` + animation as the
  /// night wedge and marks, so they move in harmony along the ring's arc),
  /// while each glyph counter-rotates to stay upright and readable.
  @ViewBuilder private var sleepGlyphs: some View {
    if let s = sleepMarks {
      ZStack {
        Image(systemName: "moon.fill")
          .font(.system(size: 10))
          .foregroundStyle(Theme.inkSecondary)
          .rotationEffect(.degrees(-displayedRotation))
          .position(ringPoint(s.bed, 0.58, in: diameter))
        Image(systemName: "sun.max.fill")
          .font(.system(size: 11))
          .foregroundStyle(Theme.inkSecondary)
          .rotationEffect(.degrees(-displayedRotation))
          .position(ringPoint(s.wake, 0.58, in: diameter))
      }
      .frame(width: diameter, height: diameter)
      .rotationEffect(.degrees(displayedRotation))
      .opacity(marksOpacity)
      .allowsHitTesting(false)
    }
  }
}

/// Annulus (donut) — outer circle wound counterclockwise, inner wound
/// clockwise, so nonzero filling leaves the hole open. Shapes the hero
/// dial's glass face: glass band, open center.
struct AnnulusShape: Shape {
  /// Inner radius as a fraction of the outer radius.
  var holeFraction: CGFloat

  func path(in rect: CGRect) -> Path {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let outerR = min(rect.width, rect.height) / 2
    let innerR = outerR * holeFraction
    var p = Path()
    p.addArc(center: center, radius: outerR,
             startAngle: .zero, endAngle: .degrees(360), clockwise: false)
    p.closeSubpath()
    p.addArc(center: center, radius: innerR,
             startAngle: .zero, endAngle: .degrees(360), clockwise: true)
    p.closeSubpath()
    return p
  }
}

/// Attaches the today/week tap toggle only when `enabled`. Compact tiles live
/// inside a launcher `Button`, so a child tap gesture there would swallow the
/// tile's tap — this keeps the thumbnail inert. (`todayOnly` is @AppStorage,
/// so the tapped window persists and every dial flips together.)
private struct WheelTapToggle: ViewModifier {
  let enabled: Bool
  let action: () -> Void
  func body(content: Content) -> some View {
    if enabled {
      content.onTapGesture(perform: action)
    } else {
      content
    }
  }
}

extension TimeOfDayWheel.Event {
  /// Build a wheel point from an absolute instant (an entity's `occurredAt`).
  /// Returns `nil` for undated sentinel rows (`.distantPast`) or events outside
  /// the trailing `windowDays`. `todayStart` is the `dayKey` of *today's* waking
  /// day; the angle comes from the event's local hour/minute, the ring from its
  /// waking-day distance (`WakingDay`). With `WakingDay(enabled: false)` this is
  /// exactly the legacy midnight-to-midnight bucketing.
  init?(id: String,
        occurredAt: Date,
        todayStart: Date,
        windowDays: Int = 7,
        color: Color? = nil,
        wakingDay: WakingDay = WakingDay(enabled: false),
        calendar: Calendar = .current) {
    guard occurredAt > .distantPast else { return nil }
    let daysAgo = wakingDay.daysAgo(occurredAt, todayKey: todayStart, calendar: calendar)
    guard daysAgo >= 0, daysAgo < windowDays else { return nil }
    let c = calendar.dateComponents([.hour, .minute], from: occurredAt)
    self.init(id: id,
              fraction: (Double(c.hour ?? 0) * 60 + Double(c.minute ?? 0)) / 1440,
              daysAgo: daysAgo,
              color: color)
  }
}
