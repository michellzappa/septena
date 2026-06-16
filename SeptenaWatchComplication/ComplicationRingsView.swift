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
/// its target. A nil goal (no target set) draws just the faint track. Sized to
/// the smaller side of its frame so it stays circular in any family. Generic
/// over any rings-style complication; the caller supplies the per-key color.
struct RingsView: View {
  let rings: [ComplicationRing]
  var color: (String) -> Color
  var lineWidth: CGFloat
  var spacing: CGFloat

  var body: some View {
    GeometryReader { geo in
      let side = min(geo.size.width, geo.size.height)
      ZStack {
        ForEach(Array(rings.enumerated()), id: \.element.key) { idx, ring in
          let inset = CGFloat(idx) * (lineWidth + spacing)
          ringArc(ring)
            .frame(width: side - inset * 2, height: side - inset * 2)
        }
      }
      .frame(width: side, height: side)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder
  private func ringArc(_ ring: ComplicationRing) -> some View {
    // The metric's authored Settings color when present (matches the section),
    // else the domain's fixed fallback hue.
    let c = Color(hexToken: ring.colorHex) ?? color(ring.key)
    let fraction: Double = {
      guard let goal = ring.goal, goal > 0 else { return 0 }
      return min(ring.value / goal, 1)
    }()
    ZStack {
      Circle()
        .stroke(c.opacity(0.22), lineWidth: lineWidth)
      Circle()
        .trim(from: 0, to: fraction)
        .stroke(c, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        .rotationEffect(.degrees(-90))
    }
  }
}
