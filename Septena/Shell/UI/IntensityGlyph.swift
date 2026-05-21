import SwiftUI

// Text-free indicators for difficulty and cardio level — Swift sibling of
// the webapp's `components/intensity-glyph.tsx`. Difficulty is a row of
// three pips on a green → amber → red ramp (easy=1, medium=2, hard=3).
// Level is a five-bar signal-strength glyph, lit proportional to value.

struct DifficultyGlyph: View {
  let difficulty: String?

  private struct Spec {
    let filled: Int
    let color: Color
    let label: String
  }

  private var spec: Spec? {
    switch (difficulty ?? "").lowercased() {
    case "easy":   return Spec(filled: 1, color: Color(red: 0.13, green: 0.77, blue: 0.37), label: "Easy")
    case "medium": return Spec(filled: 2, color: Color(red: 0.96, green: 0.62, blue: 0.04), label: "Medium")
    case "hard":   return Spec(filled: 3, color: Color(red: 0.94, green: 0.27, blue: 0.27), label: "Hard")
    default:       return nil
    }
  }

  var body: some View {
    if let spec {
      HStack(spacing: 2) {
        ForEach(0..<3, id: \.self) { i in
          Circle()
            .fill(i < spec.filled ? spec.color : Color.secondary.opacity(0.18))
            .frame(width: 5, height: 5)
            .overlay(
              Circle()
                .stroke(Color.secondary.opacity(0.35), lineWidth: i < spec.filled ? 0 : 0.5)
            )
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
          RoundedRectangle(cornerRadius: 0.75, style: .continuous)
            .fill(isLit ? accent : Color.secondary.opacity(0.18))
            .frame(width: 3, height: CGFloat(4 + i * 2))
            .overlay(
              RoundedRectangle(cornerRadius: 0.75, style: .continuous)
                .stroke(Color.secondary.opacity(0.35), lineWidth: isLit ? 0 : 0.5)
            )
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
