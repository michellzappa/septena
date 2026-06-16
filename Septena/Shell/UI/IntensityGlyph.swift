import SwiftUI

// Text-free indicators for difficulty and cardio level — Swift sibling of
// the webapp's `components/intensity-glyph.tsx`. Both ramp the section's
// accent by opacity so a single chromatic axis carries intensity. The
// previous green→amber→red ramp introduced a second hue that fought the
// section accent in the log list.

struct DifficultyGlyph: View {
  let difficulty: String?
  /// Section accent — defaults to the inherited tint so callers can let
  /// `SectionTheme` flow through without thinking about it.
  var accent: Color = .accentColor

  private struct Spec {
    let filled: Int
    let opacity: Double
    let label: String
  }

  private var spec: Spec? {
    // Canonicalize first so legacy ("medium") and current ("moderate")
    // spellings share one ramp. Only three dots, so the two hardest rungs
    // (hard / max) both fill all three — max is the to-failure extreme.
    switch TrainingEffort.canonicalKey(difficulty) {
    case "easy":     return Spec(filled: 1, opacity: 0.30, label: "Easy")
    case "moderate": return Spec(filled: 2, opacity: 0.65, label: "Moderate")
    case "hard":     return Spec(filled: 3, opacity: 1.00, label: "Hard")
    case "max":      return Spec(filled: 3, opacity: 1.00, label: "Max")
    default:         return nil
    }
  }

  var body: some View {
    if let spec {
      HStack(spacing: 2) {
        ForEach(0..<3, id: \.self) { i in
          Circle()
            .fill(i < spec.filled ? accent.opacity(spec.opacity) : accent.opacity(0.10))
            .frame(width: 5, height: 5)
        }
      }
      .accessibilityLabel("Difficulty \(spec.label)")
    }
  }
}

struct LevelGlyph: View {
  let level: Int?
  var max: Int = 10
  var accent: Color = .accentColor

  private let bars = 5

  var body: some View {
    if let level {
      let lit = Swift.min(bars, Swift.max(1, Int((Double(level) / Double(max) * Double(bars)).rounded())))
      HStack(alignment: .bottom, spacing: 1.5) {
        ForEach(0..<bars, id: \.self) { i in
          let isLit = i < lit
          // Opacity ramps with how many bars are lit so higher levels read
          // as a denser accent stack. Empty bars keep a faint accent ghost
          // (no extra hue) so the glyph still reads as one chromatic axis.
          let opacity = 0.25 + 0.15 * Double(lit - 1)
          RoundedRectangle(cornerRadius: 0.75, style: .continuous)
            .fill(isLit ? accent.opacity(opacity) : accent.opacity(0.10))
            .frame(width: 3, height: CGFloat(4 + i * 2))
        }
      }
      .accessibilityLabel("Level \(level)")
    }
  }
}

#Preview {
  VStack(alignment: .leading, spacing: 10) {
    HStack(spacing: 12) {
      DifficultyGlyph(difficulty: "easy")
      DifficultyGlyph(difficulty: "medium")
      DifficultyGlyph(difficulty: "hard")
    }
    HStack(spacing: 12) {
      LevelGlyph(level: 1, accent: .orange)
      LevelGlyph(level: 4, accent: .orange)
      LevelGlyph(level: 7, accent: .orange)
      LevelGlyph(level: 10, accent: .orange)
    }
  }
  .padding()
}
