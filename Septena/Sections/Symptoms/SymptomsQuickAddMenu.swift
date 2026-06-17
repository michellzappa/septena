import SwiftUI

// Quick-add menu for the Symptoms tile. Unlike a checkbox section, a symptom
// carries a severity, so one tap isn't enough to capture a real entry. Each
// recent/active symptom is a nested submenu of three calibrated severities
// (Mild / Moderate / Severe → 3 / 5 / 8 on the 0–10 scale the editor uses), so
// a faithful log is two taps. "More…" drops into the full editor for duration,
// body region, quality, and notes.

struct SymptomQuickItem: Identifiable {
  let id: String     // symptomID (definition id)
  let title: String  // emoji + title, ready to display
}

struct SymptomsQuickAddMenu: View {
  /// Recent-first, then the rest of the active catalog, capped by the caller.
  let symptoms: [SymptomQuickItem]
  let onLog: (_ symptomID: String, _ severity: Int) -> Void
  /// Opens the Symptoms destination — for the full editor, or to create the
  /// first symptom when the catalog is empty.
  let onOpen: () -> Void

  // Named severities map onto the same 0–10 scale the editor's slider uses.
  private static let levels: [(label: String, severity: Int)] = [
    ("Mild", 3), ("Moderate", 5), ("Severe", 8),
  ]

  var body: some View {
    if symptoms.isEmpty {
      Button { onOpen() } label: {
        Label("Log symptom…", systemImage: "waveform.path.ecg")
      }
    } else {
      ForEach(symptoms) { symptom in
        Menu {
          ForEach(Self.levels, id: \.severity) { level in
            Button { onLog(symptom.id, level.severity) } label: {
              Text(level.label)
            }
          }
        } label: {
          Label(symptom.title, systemImage: "waveform.path.ecg")
        }
      }
      Divider()
      Button { onOpen() } label: {
        Label("More…", systemImage: "ellipsis")
      }
    }
  }
}
