import WidgetKit
import SwiftUI

extension Color {
  /// Parse a "#RRGGBB" / "#RGB" hex token (the per-metric Settings colors the
  /// rings carry) into a Color, or nil for anything unparseable so callers fall
  /// back to a fixed hue. watchOS-safe — `AdaptiveColor`'s dynamic provider is
  /// unavailable here, and the watch face is dark, so no light/dark adaptation
  /// is needed.
  init?(hexToken: String?) {
    guard var s = hexToken?.trimmingCharacters(in: .whitespaces), !s.isEmpty
    else { return nil }
    if s.hasPrefix("#") { s.removeFirst() }
    if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
    self = Color(red:   Double((v >> 16) & 0xff) / 255,
                 green: Double((v >> 8)  & 0xff) / 255,
                 blue:  Double( v        & 0xff) / 255)
  }
}

/// Apple-Activity-style concentric rings — one per metric, each filling toward
/// its target. Built on the vendored `WolfActivityRing` (`ActivityRing`) with its
/// stock rendering; progress is clamped to the ring's 0…100% range so an over-goal
/// metric reads as a full ring (the real over-target value shows in the legend).
/// Generic over any rings-style complication; the caller supplies the per-key color.
struct RingsView: View {
  let rings: [ComplicationRing]
  var color: (String) -> Color
  var lineWidth: CGFloat
  var spacing: CGFloat
  /// When true, a ring with no progress (nothing logged toward it yet) is dropped
  /// entirely — no dim "remaining" track — and the rings that *do* have data pack
  /// outward to fill the dial. The in-app summary pages use this so the stack
  /// shows only real data (the legend below still lists every target); the
  /// complications leave it off, where an empty ring reads as a target to fill.
  var hidesEmptyRings: Bool = false

  var body: some View {
    GeometryReader { geo in
      let side = min(geo.size.width, geo.size.height)
      let outerRadius = (side - lineWidth) / 2
      // Drop no-data rings up front so the survivors pack outward from the rim
      // (no black gap where an empty ring used to sit), rather than just blanking
      // a fixed slot. Off by default → complications keep every ring as a target.
      let shown = hidesEmptyRings ? rings.filter { progress($0) > 0 } : rings
      ZStack {
        ForEach(Array(shown.enumerated()), id: \.element.key) { idx, ring in
          let radius = outerRadius - CGFloat(idx) * (lineWidth + spacing)
          if radius >= lineWidth * 0.75 {
            // Fill toward the goal only — an over-target metric reads as a full
            // ring, not a washed-out lap. The true value lives in the legend.
            let p = min(progress(ring), 1)
            ActivityRing(progress: p, options: options(ring, radius: radius))
          }
        }
      }
      .frame(width: side, height: side)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func progress(_ ring: ComplicationRing) -> Double {
    guard let goal = ring.goal, goal > 0 else { return 0 }
    return ring.value / goal
  }

  private func options(_ ring: ComplicationRing, radius: CGFloat) -> ActivityRingOptions {
    // The metric's authored Settings color when present (matches the section),
    // else the domain's fixed fallback hue. Everything else is WolfActivityRing's
    // stock look: solid arc, a dim neutral "remaining" track, subtle head cap.
    let c = Color(hexToken: ring.colorHex) ?? color(ring.key)
    var o = ActivityRingOptions()
    o.radius = Double(radius)
    o.thickness = Double(lineWidth)
    o.color = c
    // Thin concentric rings read cleaner without the library's double edge-line.
    o.outlineColor = .clear
    return o
  }
}
