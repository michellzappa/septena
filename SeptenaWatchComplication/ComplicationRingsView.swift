import WidgetKit
import SwiftUI

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
    let c = color(ring.key)
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
