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
/// alpha stacking. Hour labels follow the user's system 24-hour setting.
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

  /// Margin between the dial's square and its tick ring (full rendering).
  /// Shared with `dotRing(forDiameter:)` so external geometry — the `.arc`
  /// comet orbiting the hero dial — lands exactly on the drawn ring.
  static let fullMargin: CGFloat = 20

  /// The hero glass donut's hole, as a fraction of the disc radius. ONE
  /// definition shared by the `AnnulusShape` glass mask and the Canvas (the
  /// now-hand starts at this edge; the date floats in the hollow).
  static let heroHoleFraction: CGFloat = 0.42

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

  /// Whether to label hours 0–23 (true) or 12-hour a/p (false) — follows the
  /// device's locale hour cycle, so a 24-hour region never sees "am/pm".
  private var uses24Hour: Bool {
    switch Locale.current.hourCycle {
    case .zeroToTwentyThree, .oneToTwentyFour: return true
    default: return false
    }
  }

  private func hourLabel(_ hour: Int) -> String {
    // Bare numerals ("0", "6"), not zero-padded clock digits ("00", "06") —
    // these are axis labels on a dial, not a time readout.
    if uses24Hour { return String(hour) }
    let h = hour % 12 == 0 ? 12 : hour % 12
    return "\(h)\(hour < 12 ? "a" : "p")"
  }

  /// Shared defaults key for the today ⇄ week window, public so co-presenting
  /// views (the hero's `AmbientHalo` style) can key off the same state.
  static let windowDefaultsKey = "timeOfDayWheel.todayOnly"

  /// Tap picks the window: just today (the default — a dense week can be
  /// confusing, so the dial opens focused on today) or the full window. The
  /// week's data is always loaded; the tap just reveals it. Stored in
  /// `@AppStorage` under one shared key, so flipping the window on any dial
  /// flips every other dial too (and the choice persists across launches).
  @AppStorage(Self.windowDefaultsKey) private var todayOnly = true

  /// The resolved focus: compact tiles always show the full week (the overlay
  /// *is* the point of a thumbnail); the full dial honors the tap toggle.
  private var focusToday: Bool { compact ? false : todayOnly }
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

      // LAYER 1 — the machinery, UNDER the glass: ticks and duration bands.
      // On the hero these pick up the donut's frost, so sleep and the day's
      // schedule read as depth inside the glass rather than marks on it.
      Canvas { ctx, size in
      let side = min(size.width, size.height)
      let center = CGPoint(x: size.width / 2, y: size.height / 2)
      let ringR = side / 2 - margin        // margin for the bolder labels
      guard ringR > 8 else { return }

      func point(_ fraction: Double, _ r: CGFloat) -> CGPoint {
        let a = fraction * 2 * .pi          // 0 at top, clockwise
        return CGPoint(x: center.x + r * CGFloat(sin(a)),
                       y: center.y - r * CGFloat(cos(a)))
      }

      // Arc path from `start` to `end` (clockwise, wrapping midnight if end < start).
      func arc(_ start: Double, _ end: Double, _ r: CGFloat) -> Path {
        var span = end - start
        if span <= 0 { span += 1 }          // wrap through midnight
        let steps = max(2, Int(span * 120))
        var p = Path()
        for i in 0...steps {
          let f = (start + span * Double(i) / Double(steps)).truncatingRemainder(dividingBy: 1)
          let pt = point(f, r)
          if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
      }

      // The clock's outline + ticks. On compact tiles these read as neutral
      // (the section accent is carried by the dots), so the frame doesn't
      // double up on color; the full dial keeps the accent frame.
      let lineColor = compact ? Theme.inkSecondary : accent

      // Everything in this layer sits UNDER the hero's glass donut
      // (ultraThinMaterial) — it still softens what's beneath; draw the
      // machinery a touch louder so it lands at the intended strength
      // through the blur. Flat-disc dials stay at 1×.
      let underBoost: Double = heroDate != nil ? 1.3 : 1.0

      // Full dial: the white disc's edge (above) *is* the outer circle. Compact
      // has no disc, so draw a frame ring here to anchor the angles. Matches the
      // disc border's 1.5pt weight.
      if compact {
        ctx.stroke(Path(ellipseIn: CGRect(x: center.x - ringR, y: center.y - ringR,
                                          width: ringR * 2, height: ringR * 2)),
                   with: .color(lineColor.opacity(0.22)), lineWidth: 1.5)
      }

      // Hour ticks — quarter-marks longest/darkest, 3-hour marks medium, every
      // other hour a short minor. Compact uses tiny ticks so the thumbnail reads
      // the full 24-hour grid without clutter.
      for h in 0..<24 {
        let f = Double(h) / 24
        let major = (h % 6 == 0)
        let mid = (h % 3 == 0)
        let length: CGFloat = compact ? (major ? 5 : mid ? 3 : 2) : (major ? 11 : mid ? 7 : 5)
        var tick = Path()
        tick.move(to: point(f, ringR - length))
        tick.addLine(to: point(f, ringR))
        ctx.stroke(tick,
                   with: .color(lineColor.opacity(
                     min(1, (major ? 0.55 : mid ? 0.34 : 0.26) * underBoost))),
                   lineWidth: major ? 2 : 1)
      }

      // The single ring everything sits on — bands and dots share it so the
      // whole dial reads at one consistent distance from center.
      let dotRing = ringR * 0.82

      // Duration bands (sleep, fasting; calendar pills in today view), under
      // the dots, as long rounded arcs.
      let bandsToDraw = todayOnly ? shownBands + todayBands : shownBands
      for b in bandsToDraw.sorted(by: { $0.daysAgo > $1.daysAgo }) {
        ctx.stroke(arc(b.start, b.end, dotRing),
                   with: .color((b.color ?? accent).opacity(
                     min(1, fade(b.daysAgo) * 0.55 * underBoost))),
                   style: StrokeStyle(lineWidth: b.thin ? 4 : 9, lineCap: .round))
      }
      }

      // The hero's glass donut — between machinery and data. The base is
      // `.ultraThinMaterial` for the adaptive translucency + a faint blur
      // of the machinery beneath; but the GLASS itself is the hand-drawn
      // `AnnulusGlass` lighting on top — over a flat page the system blur
      // materials have nothing to refract and read as plain gray, so the
      // curvature body + crisp lit rims are what sell it. The shape's own
      // shadow lifts the donut off the page (hole edge included).
      if !compact && heroDate != nil {
        AnnulusShape(holeFraction: Self.heroHoleFraction)
          .fill(.ultraThinMaterial)
          .overlay {
            AnnulusGlass(holeFraction: Self.heroHoleFraction)
          }
          .shadow(color: .black.opacity(0.12), radius: 11, y: 4)
          .padding(20)
      }

      // LAYER 2 — the data, ON TOP of the glass: dots stay crisp on the
      // surface, the hour labels sit outside the disc, the now-hand rides
      // the band, and the date/chip floats in the open hole.
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

      let dotRing = ringR * 0.82

      // Quadrant labels just outside the disc, on the page background — softer
      // (secondary) so they frame the dial without competing with the data.
      // Compact thumbnails drop them (no room, and the four ticks suffice).
      if !compact {
        for h in [0, 6, 12, 18] {
          ctx.draw(Text(hourLabel(h)).font(.caption.weight(.semibold)).foregroundStyle(.secondary),
                   at: point(Double(h) / 24, ringR + 12))
        }
      }

      // "Now" hand — a true 1pt hairline. On the hero it starts at the
      // glass donut's inner edge (the hole is open — nothing to cap it),
      // running only across the glass band; flat-disc dials run it from
      // center and let the hub disc cap it.
      if let nowFraction {
        let handStart = heroDate != nil
          ? point(nowFraction, ringR * Self.heroHoleFraction)
          : center
        var hand = Path()
        hand.move(to: handStart)
        hand.addLine(to: point(nowFraction, ringR - 2))
        ctx.stroke(hand, with: .color(accent.opacity(0.6)), lineWidth: 1)
      }

      // Local density (within the shown window): events sharing a 30-minute
      // slot grow the dot, so a repeated time-of-day reads as a bigger blob.
      let slots = 48
      var density: [Int: Int] = [:]
      for e in shownEvents {
        density[Int(e.fraction * Double(slots)) % slots, default: 0] += 1
      }
      let maxCount = Double(density.values.max() ?? 1)

      // Dots, oldest first so today lands on top. In today-only mode density
      // isn't meaningful (one day rarely repeats a time), so dots take a
      // comfortable fixed size; in week mode size is *relative* to the busiest
      // slot — a one-off is the smallest dot, the most-repeated the biggest.
      for e in shownEvents.sorted(by: { $0.daysAgo > $1.daysAgo }) {
        let count = Double(density[Int(e.fraction * Double(slots)) % slots] ?? 1)
        let norm = maxCount > 1 ? (count - 1) / (maxCount - 1) : 0
        // Today mode mirrors the horizontal day-timeline's bubble sizing
        // exactly — `min(8, 5 + (count-1))` diameter (5pt single, +1pt per
        // extra event in the slot, capped at 8) — so the two of-today views
        // read the same. Week mode keeps its relative-to-busiest-slot scaling
        // for the denser overlay (there's no timeline equivalent of a week).
        // Week mode: max radius trimmed 30% (8.5 → ~5.95) so dense clusters
        // read as firm dots, not heavy blobs. Floor stays at 2.2 for one-offs.
        let dotR: CGFloat = effectiveWindow == 1
          ? min(8, 4 + count) / 2
          : (2.2 + norm * 3.75)
        let p = point(e.fraction, dotRing)
        let rect = CGRect(x: p.x - dotR, y: p.y - dotR, width: dotR * 2, height: dotR * 2)
        ctx.fill(Path(ellipseIn: rect), with: .color((e.color ?? accent).opacity(fade(e.daysAgo))))
      }

      // Center. The hero's glass donut leaves the middle genuinely OPEN —
      // the date (today) or scope chip (week) floats in the hollow with
      // the ambient glow behind it, no disc; the now-hand already stops at
      // the glass's inner edge. Flat-disc dials keep a small hub disc that
      // caps the hand and seats the chip. Compact thumbnails: nothing.
      if !compact {
        if heroDate == nil {
          let hubR: CGFloat = 30
          let hub = CGRect(x: center.x - hubR, y: center.y - hubR,
                           width: hubR * 2, height: hubR * 2)
          ctx.fill(Path(ellipseIn: hub), with: .color(Theme.cardSurface))
          ctx.stroke(Path(ellipseIn: hub),
                     with: .color(Theme.inkSecondary.opacity(0.18)), lineWidth: 1)
        }
        if let heroDate, todayOnly {
          ctx.draw(
            Text(heroDate.formatted(.dateTime.weekday(.abbreviated)).uppercased())
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary),
            at: CGPoint(x: center.x, y: center.y - 11)
          )
          ctx.draw(
            Text(heroDate.formatted(.dateTime.day()))
              .font(.system(.title3, design: .rounded).weight(.semibold))
              .monospacedDigit()
              .foregroundStyle(.primary),
            at: CGPoint(x: center.x, y: center.y + 8)
          )
        } else {
          let scope = todayOnly ? "Today" : "\(windowDays) days"
          ctx.draw(Text(scope).font(.caption2.weight(.medium)).foregroundStyle(.secondary),
                   at: center)
        }
      }
    }
    }
    .frame(width: diameter, height: diameter)
    .contentShape(Circle())
    .modifier(WheelTapToggle(enabled: !compact) { todayOnly.toggle() })
    .accessibilityElement()
    .accessibilityAddTraits(compact ? [] : .isButton)
    .accessibilityLabel(Text("Time-of-day wheel"))
    .accessibilityValue(Text(focusToday
      ? "Today, \(shownEvents.count) events"
      : "\(events.count) events over the last \(windowDays) days"))
    .accessibilityHint(compact
      ? Text("")
      : Text("Double tap to switch between today and the last \(windowDays) days"))
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

/// Hand-drawn glass treatment for the hero donut — the cues that read as a
/// curved glass band over a FLAT page, where the system blur materials have
/// nothing behind them to refract and collapse to plain gray. Everything
/// assumes one light source at the top:
///   • a tonal BODY gradient — lit on top, a faint shadow on the underside
///     — so the band reads as a rounded (convex) cross-section,
///   • a crisp OUTER rim: a bright catch-light at the top curving down to a
///     dark refracted edge at the bottom,
///   • a crisp INNER rim (the hole's wall): the OPPOSITE — a shadowed lip at
///     the top, a lit lip at the bottom, because the inner wall faces inward,
///   • a soft sheen pooling in the upper band.
/// Pure decoration; hit-testing off. This — not the base material — is what
/// makes the donut read as glass.
struct AnnulusGlass: View {
  var holeFraction: CGFloat
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    GeometryReader { geo in
      let side = min(geo.size.width, geo.size.height)
      let holeD = side * holeFraction
      let dark = scheme == .dark
      ZStack {
        // Band body — convex cross-section: lighter where it faces the top
        // light, a faint shadow underneath. This is what gives the band
        // dimension over a flat page.
        AnnulusShape(holeFraction: holeFraction)
          .fill(LinearGradient(
            colors: [.white.opacity(dark ? 0.12 : 0.32),
                     .white.opacity(0.0),
                     .black.opacity(dark ? 0.12 : 0.06)],
            startPoint: .top, endPoint: .bottom))
        // Sheen pooling in the upper band.
        AnnulusShape(holeFraction: holeFraction)
          .fill(LinearGradient(
            colors: [.white.opacity(dark ? 0.18 : 0.30), .clear],
            startPoint: .top, endPoint: .center))
        // Outer rim — the money cue: a crisp bright catch-light at the top
        // fading to a dark refracted edge at the bottom.
        Circle()
          .strokeBorder(LinearGradient(
            colors: [.white.opacity(0.95),
                     .white.opacity(0.22),
                     .black.opacity(0.20)],
            startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
        // Inner wall (hole) — opposite lighting: a shadowed lip at the top,
        // a lit lip at the bottom. The double-edge is what reads as glass
        // THICKNESS around the open center.
        Circle()
          .stroke(LinearGradient(
            colors: [.black.opacity(0.18),
                     .white.opacity(0.10),
                     .white.opacity(0.72)],
            startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
          .frame(width: holeD, height: holeD)
      }
      .frame(width: side, height: side)
      .position(x: geo.size.width / 2, y: geo.size.height / 2)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
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
  /// the trailing `windowDays`. `todayStart` is the start of *today* in the
  /// local calendar; the angle comes from the event's local hour/minute, the
  /// ring from its calendar-day distance.
  init?(id: String,
        occurredAt: Date,
        todayStart: Date,
        windowDays: Int = 7,
        color: Color? = nil,
        calendar: Calendar = .current) {
    guard occurredAt > .distantPast else { return nil }
    let dayStart = calendar.startOfDay(for: occurredAt)
    let daysAgo = calendar.dateComponents([.day], from: dayStart, to: todayStart).day ?? 0
    guard daysAgo >= 0, daysAgo < windowDays else { return nil }
    let c = calendar.dateComponents([.hour, .minute], from: occurredAt)
    self.init(id: id,
              fraction: (Double(c.hour ?? 0) * 60 + Double(c.minute ?? 0)) / 1440,
              daysAgo: daysAgo,
              color: color)
  }
}
