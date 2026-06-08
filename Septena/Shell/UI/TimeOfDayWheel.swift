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
    if uses24Hour { return String(format: "%02d", hour) }
    let h = hour % 12 == 0 ? 12 : hour % 12
    return "\(h)\(hour < 12 ? "a" : "p")"
  }

  /// Tap toggles between just today (the default — a dense week can be
  /// confusing, so the dial opens focused on today) and the full window. The
  /// week's data is always loaded; the tap just reveals it.
  @State private var todayOnly = true

  private var effectiveWindow: Int { todayOnly ? 1 : windowDays }
  private var shownEvents: [Event] { todayOnly ? events.filter { $0.daysAgo == 0 } : events }
  private var shownBands: [Band] { todayOnly ? bands.filter { $0.daysAgo == 0 } : bands }

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
      // White "clock face": a filled disc whose edge lands exactly on the
      // tick ring, so the hour numbers sit *outside* it on the page (like a
      // real clock face). The 20pt inset matches the Canvas `ringR` margin.
      Circle()
        .fill(Theme.cardSurface)
        .overlay(Circle().strokeBorder(Theme.inkSecondary.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.07), radius: 5, y: 2)
        .padding(20)
      Canvas { ctx, size in
      let side = min(size.width, size.height)
      let center = CGPoint(x: size.width / 2, y: size.height / 2)
      let ringR = side / 2 - 20            // margin for the bolder labels
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

      // No separate track ring here — the white disc's edge (above) *is* the
      // outer circle, landing on `ringR`.

      // Hour ticks — quarter-marks longest/darkest, 3-hour marks medium.
      for h in 0..<24 {
        let f = Double(h) / 24
        let major = (h % 6 == 0)
        let mid = (h % 3 == 0)
        var tick = Path()
        tick.move(to: point(f, ringR - (major ? 11 : mid ? 7 : 4)))
        tick.addLine(to: point(f, ringR))
        ctx.stroke(tick,
                   with: .color(accent.opacity(major ? 0.55 : mid ? 0.30 : 0.18)),
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
                   with: .color((b.color ?? accent).opacity(fade(b.daysAgo) * 0.55)),
                   style: StrokeStyle(lineWidth: 9, lineCap: .round))
      }

      // Quadrant labels just outside the disc, on the page background — softer
      // (secondary) so they frame the dial without competing with the data.
      for h in [0, 6, 12, 18] {
        ctx.draw(Text(hourLabel(h)).font(.caption.weight(.semibold)).foregroundStyle(.secondary),
                 at: point(Double(h) / 24, ringR + 12))
      }

      // "Now" hand — a faint radial hairline.
      if let nowFraction {
        var hand = Path()
        hand.move(to: center)
        hand.addLine(to: point(nowFraction, ringR - 2))
        ctx.stroke(hand, with: .color(accent.opacity(0.6)), lineWidth: 2)
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
        let dotR: CGFloat = effectiveWindow == 1
          ? min(8, 4 + count) / 2
          : (2.2 + norm * 6.3)
        let p = point(e.fraction, dotRing)
        let rect = CGRect(x: p.x - dotR, y: p.y - dotR, width: dotR * 2, height: dotR * 2)
        ctx.fill(Path(ellipseIn: rect), with: .color((e.color ?? accent).opacity(fade(e.daysAgo))))
      }

      // Center scope chip — names the current view and signals the dial is
      // tappable ("Today" ⇄ "7 days").
      let scope = todayOnly ? "Today" : "\(windowDays) days"
      ctx.draw(Text(scope).font(.caption2.weight(.medium)).foregroundStyle(.secondary),
               at: center)
    }
    }
    .frame(width: diameter, height: diameter)
    .contentShape(Circle())
    .onTapGesture { todayOnly.toggle() }
    .accessibilityElement()
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel(Text("Time-of-day wheel"))
    .accessibilityValue(Text(todayOnly
      ? "Today, \(shownEvents.count) events"
      : "\(events.count) events over the last \(windowDays) days"))
    .accessibilityHint(Text("Double tap to switch between today and the last \(windowDays) days"))
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
