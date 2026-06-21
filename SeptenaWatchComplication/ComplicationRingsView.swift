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
  /// When true, a ring with no progress (nothing logged toward it yet) is dropped
  /// entirely — no dim "remaining" track — and the rings that *do* have data pack
  /// outward to fill the dial. The in-app summary pages use this so the stack
  /// shows only real data (the legend below still lists every target); the
  /// complications leave it off, where an empty ring reads as a target to fill.
  var hidesEmptyRings: Bool = false

  // On a tinted watch face the rings render `.widgetAccentable(false)` → WidgetKit
  // *vibrant* mode, which maps content to a luminance × alpha mask on the face's
  // single-color ramp. A saturated-hue track (`c.opacity(0.22)`) collapses to ≈
  // background there (the hue's own luminance is too low), so we use a dim *neutral*
  // gray instead — low enough to recede as a faint "remaining" ring (the Apple
  // Activity empty-track look, so the filled arc pops), high enough to survive the
  // mask. In `.fullColor` the track is the section hue at low alpha.
  @Environment(\.widgetRenderingMode) private var renderingMode

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
    // The unfilled track is a dim "remaining" ring (Apple-Activity style), not a
    // bright loop — the empty part should read as low-alpha so the fill stands
    // out. Full color: a faint tint of the section hue. Vibrant / accented (tinted
    // faces): the hue desaturates away, so luminance is the only lever — a dim
    // neutral gray, kept just bright enough to survive the vibrant mask.
    o.backgroundColor = renderingMode == .fullColor
      ? c.opacity(0.22)
      : Color(white: 0.18)
    // A small black wedge ahead of the head marks the divider so completion stays
    // legible even when the track and fill desaturate to the same tint. An angular
    // (not pixel) gap, so it reads consistently across the concentric rings.
    o.trackGap = 0.04
    o.outlineColor = .clear
    return o
  }
}
