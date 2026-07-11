// Settings-root chrome shared by both shells (docs/SEPTASK.md): the disc
// tile for About rows, the top luminance wash, and the root-row accent
// palette — extracted from SettingsView.swift so Septask's Settings can
// mirror the full app's look without compiling its destination graph.

import SwiftUI

/// The seven root-row tints, in row order — Septena's section rainbow.
enum SettingsAccentPalette {
  static let colors: [Color] = [
    parseHexColor("#ef4444"), // red
    parseHexColor("#f97316"), // orange
    parseHexColor("#eab308"), // yellow
    parseHexColor("#22c55e"), // green
    parseHexColor("#06b6d4"), // cyan
    parseHexColor("#3b82f6"), // blue
    parseHexColor("#8b5cf6"), // purple
  ]
}

/// The Settings-row icon for an About page: the seven Septena discs in white
/// on a neutral gray tile, matching `ColoredGlyph`'s shape and sheen (white
/// glyph on a saturated fill) so it sits flush with the colored rows above it.
/// Gray (not a brand accent) marks About as a utility row, while the white
/// discs keep it unmistakably the app's own mark. Disc placement reuses the
/// shared `SeptenaPlus` constants so the emblem can't drift.
struct SeptenaDiscTile: View {
  var size: CGFloat = 29
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
    let gray = Color(white: colorScheme == .dark ? 0.32 : 0.55)
    ZStack {
      shape.fill(gray)
      shape.fill(
        LinearGradient(
          colors: [Color.white.opacity(0.26), .clear, Color.black.opacity(0.07)],
          startPoint: .top, endPoint: .bottom
        )
      )
      ForEach(Array(SeptenaPlus.discCenters.enumerated()), id: \.offset) { _, center in
        Circle()
          .fill(Color.white)
          .frame(width: size * 0.168, height: size * 0.168)
          .position(x: size * center.x, y: size * center.y)
      }
    }
    .frame(width: size, height: size)
  }
}

/// Soft top-down luminance wash behind the Settings list — the same
/// subtle lift Apple's Settings.app draws under the title. A near-white
/// (or, in dark mode, a faint white) band fades into the grouped
/// background over the first ~300pt, so the top of the list reads a touch
/// brighter without changing the rest of the surface.
struct SettingsTopGradient: View {
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    ZStack(alignment: .top) {
      Theme.groupedBackground
      LinearGradient(
        colors: [scheme == .dark ? Color.white.opacity(0.06)
                                 : Color.white.opacity(0.9),
                 .clear],
        startPoint: .top, endPoint: .bottom
      )
      .frame(height: 300)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .ignoresSafeArea()
  }
}
