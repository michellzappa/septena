import SwiftUI

// The small "which model answered" caption shown next to AI outputs during the
// iOS-27 beta. Reads `AIModelTag.isVisible` itself, so callers can drop it in
// unconditionally — it renders nothing when the beta toggle is off. Shared UI
// (compiles into Septena and Septask via Shell/UI).

struct AIModelTagBadge: View {
  let tag: AIModelTag
  /// Tint for the glyph + text; defaults to secondary so it stays quiet.
  var tint: Color = .secondary

  var body: some View {
    if AIModelTag.isVisible {
      Label {
        Text(tag.label)
      } icon: {
        Image(systemName: tag.systemImage)
      }
      .font(.caption2.weight(.medium))
      .foregroundStyle(tint)
      .labelStyle(.titleAndIcon)
      .accessibilityLabel("Answered by \(tag.label)")
    }
  }
}
