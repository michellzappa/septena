import SwiftUI

/// Rounded identity square + tinted SF Symbol — shared by sidebar rows,
/// homepage tiles, and the Section Tile widget.
struct SectionGlyph: View {
  let icon: String
  let accent: Color
  var size: CGFloat = 28
  var glyphRatio: CGFloat = 0.5

  var body: some View {
    RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
      .fill(accent.opacity(0.18))
      .frame(width: size, height: size)
      .overlay {
        Image(systemName: icon)
          .font(.system(size: size * glyphRatio, weight: .semibold))
          .foregroundStyle(accent)
      }
  }
}
