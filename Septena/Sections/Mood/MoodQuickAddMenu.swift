import SwiftUI

// Mood QuickAdd menu — name what's true *now* in two taps, without the full
// check-in sheet. Like Symptoms (which nests severity under each symptom), the
// menu nests the 4 quadrants of Russell's Circumplex, each opening its 3×3
// emotion grid — the full 4×3×3 vocabulary as nested submenus, so any one of
// the 36 emotions is a faithful, direct log. "Full check-in…" still drops into
// AddMoodPage for a note or a back-dated time.

struct MoodQuickAddMenu: View {
  /// Logs one emotion immediately at the current moment.
  let onLog: (MoodEmotion) -> Void
  /// Opens AddMoodPage for a note / custom time.
  let onCheckIn: () -> Void

  var body: some View {
    ForEach(MoodQuadrant.allCases) { quadrant in
      Menu {
        ForEach(MoodCatalog.grid(for: quadrant)) { emotion in
          Button { onLog(emotion) } label: {
            Text(emotion.displayWord)
          }
        }
      } label: {
        Label(quadrant.title, systemImage: "face.smiling")
      }
    }
    Divider()
    Button {
      onCheckIn()
    } label: {
      Label("Full check-in…", systemImage: "ellipsis")
    }
  }
}
