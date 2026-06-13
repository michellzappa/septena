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
      let dotR: CGFloat = effectiveWindow == 1 ? min(8, 4 + count) / 2 : (2.2 + norm * 3.75)
      return DotMark(id: e.id, center: point(e.fraction, dotRing),
                     diameter: dotR * 2, color: e.color ?? accent,
                     opacity: fade(e.daysAgo))
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
      if !compact && heroDate != nil {
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

      // The single ring bands and dots share.
      let dotRing = ringR * 0.82

      // Duration bands (sleep, fasting; calendar pills today) — under the
      // dots, on top of the glass so they stay legible.
      let bandsToDraw = todayOnly ? shownBands + todayBands : shownBands
      for b in bandsToDraw.sorted(by: { $0.daysAgo > $1.daysAgo }) {
        ctx.stroke(arc(b.start, b.end, dotRing),
                   with: .color((b.color ?? accent).opacity(fade(b.daysAgo) * 0.6)),
                   style: StrokeStyle(lineWidth: b.thin ? 4 : 9, lineCap: .round))
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
          // Luminous tip: a soft radial glow plus a solid core, marking
          // "now" in the current hour's color where the hand meets the ring.
          let glowR: CGFloat = 7
          ctx.fill(Path(ellipseIn: CGRect(x: tip.x - glowR, y: tip.y - glowR,
                                          width: glowR * 2, height: glowR * 2)),
                   with: .radialGradient(Gradient(colors: [nowColor.opacity(0.50), .clear]),
                                         center: tip, startRadius: 0, endRadius: glowR))
          let coreR: CGFloat = 2.5
          ctx.fill(Path(ellipseIn: CGRect(x: tip.x - coreR, y: tip.y - coreR,
                                          width: coreR * 2, height: coreR * 2)),
                   with: .color(nowColor))
        } else {
          ctx.stroke(hand, with: .color(accent.opacity(0.6)), lineWidth: 1)
        }
      }

      // Dots — clean solid section-colored marks. Content that sits ON glass
      // is solid and crisp (Apple's own rule: glass is chrome, the symbols
      // and indicators on it are opaque); glass-on-glass is for layered
      // chrome, not data. Tried tinted-glass beads (went black) and drawn
      // gloss (read as candy) — solid is right.
      for m in dotMarks(side: side) {
        let r = m.diameter / 2
        let rect = CGRect(x: m.center.x - r, y: m.center.y - r,
                          width: m.diameter, height: m.diameter)
        ctx.fill(Path(ellipseIn: rect), with: .color(m.color.opacity(m.opacity)))
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
