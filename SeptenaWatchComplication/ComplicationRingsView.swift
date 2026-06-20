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
/// its target. Built on the vendored `WolfActivityRing` (`ActivityRing`), which
/// handles the over-100% lap via a `color → tipColor` angular gradient + a bright
/// tip cap — pure color contrast, so it survives the restricted watchOS
/// complication (WidgetKit) rendering mode where `.shadow()` is unreliable.
/// Generic over any rings-style complication; the caller supplies the per-key color.
struct RingsView: View {
  let rings: [ComplicationRing]
  var color: (String) -> Color
  var lineWidth: CGFloat
  var spacing: CGFloat

  var body: some View {
    GeometryReader { geo in
      let side = min(geo.size.width, geo.size.height)
      let outerRadius = (side - lineWidth) / 2
      ZStack {
        ForEach(Array(rings.enumerated()), id: \.element.key) { idx, ring in
          let radius = outerRadius - CGFloat(idx) * (lineWidth + spacing)
          if radius >= lineWidth * 0.75 {
            let p = progress(ring)
            ActivityRing(progress: p, options: options(ring, radius: radius, progress: p))
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

  private func options(_ ring: ComplicationRing, radius: CGFloat, progress: Double) -> ActivityRingOptions {
    // The metric's authored Settings color when present (matches the section),
    // else the domain's fixed fallback hue.
    let c = Color(hexToken: ring.colorHex) ?? color(ring.key)
    var o = ActivityRingOptions()
    o.radius = Double(radius)
    o.thickness = Double(lineWidth)
    // Under goal: a solid ring (matches the phone's macro tiles, reads as
    // "complete" at exactly 100%). Over goal: dim the tail and keep the head
    // full, so the overflow laps over the dimmed first lap and is unmistakable
    // — WolfActivityRing's own over-100% pattern, minus the shadow.
    if progress >= 1 {
      // Reached / passed goal. Keep the ring full-bright (completion should read
      // prominent, not faded) but brighten the HEAD toward white — the ring glows
      // to a light tip and the cap marks where the head met the start. Differentiates
      // a COMPLETED ring from an in-progress one, and the light head laps visibly
      // over the body when over goal. Color contrast carries it in the complication
      // (shadows are unreliable there); the shadow adds depth in-app.
      o.color = c
      o.tipColor = .white
      o.tipShadowColor = .black.opacity(0.5)
    } else {
      o.color = c
      o.tipColor = c
      o.tipShadowColor = .clear
    }
    o.backgroundColor = c.opacity(0.22)   // faint track
    o.outlineColor = .clear
    return o
  }
}
