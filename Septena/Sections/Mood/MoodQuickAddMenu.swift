import SwiftUI

// Mood QuickAdd menu — single "Check in" affordance plus jump-to-section.
// Repeating a check-in doesn't make sense (the whole point is naming
// what's true *now*), so there's no Repeat-last like Caffeine has.

struct MoodQuickAddMenu: View {
  let onCheckIn: () -> Void

  var body: some View {
    Button {
      onCheckIn()
    } label: {
      Label("New check-in", systemImage: "face.smiling")
    }
  }
}
