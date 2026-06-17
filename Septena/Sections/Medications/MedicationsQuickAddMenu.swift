import SwiftUI

// Quick-add menu for the Medications tile — mirrors Supplements. Lists doses
// due *now* that haven't hit their daily target yet; tapping marks one taken at
// the medication's default dose. As-needed meds are always loggable; daily meds
// drop once today's taken count reaches their `targetDosesPerDay`. Bucket-gated
// the same way the section's day model is: anytime shows all day, a bucketed med
// shows once its window has arrived. The caller does the filtering so this view
// stays dumb — it only renders and dispatches.

struct MedicationQuickItem: Identifiable {
  let id: String      // medication definition id
  let title: String
  let detail: String? // default-dose summary, e.g. "20 mg"
}

struct MedicationsQuickAddMenu: View {
  /// Already filtered to "due now, not yet at target."
  let medications: [MedicationQuickItem]
  /// Shown when nothing is due — distinguishes "no meds yet" from "none due now."
  let emptyLabel: String
  let onTake: (MedicationQuickItem) -> Void

  var body: some View {
    if medications.isEmpty {
      Button {} label: { Label(emptyLabel, systemImage: "checkmark.circle") }
        .disabled(true)
    } else {
      ForEach(medications) { item in
        Button { onTake(item) } label: {
          Label(item.detail.map { "\(item.title) · \($0)" } ?? item.title,
                systemImage: "pills")
        }
      }
    }
  }
}
