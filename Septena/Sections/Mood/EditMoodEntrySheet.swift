import SwiftUI

// Edit one logged check-in. Picks the same emotion grid as the add flow
// but defaults to the original quadrant + word. Quadrant change is
// possible — switching it resets the emotion to the cell at the same
// (arousal, valence) coordinates in the new quadrant if it exists.

struct EditMoodEntrySheet: View {
  @Environment(\.dismiss) private var dismiss

  let date: String
  let original: MoodEntry
  let onSave: () -> Void

  private var mood: MoodMutator { SeptenaServices.shared.moodMutator }

  @State private var quadrant: MoodQuadrant
  @State private var selected: MoodEmotion
  @State private var time: Date
  @State private var note: String

  init(date: String, original: MoodEntry, onSave: @escaping () -> Void) {
    self.date = date
    self.original = original
    self.onSave = onSave
    let q = MoodQuadrant(rawValue: original.quadrant) ?? .hap
    _quadrant = State(initialValue: q)
    let initialEmotion = MoodCatalog.grid(for: q).first {
      $0.arousal == original.arousal && $0.valence == original.valence
    } ?? MoodCatalog.grid(for: q)[4]   // center cell fallback
    _selected = State(initialValue: initialEmotion)
    let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss"
    _time = State(initialValue: fmt.date(from: original.time) ?? Date())
    _note = State(initialValue: original.note ?? "")
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Quadrant") {
          Picker("", selection: $quadrant) {
            ForEach(MoodQuadrant.allCases) { q in
              Text(q.title).tag(q)
            }
          }
          .pickerStyle(.inline)
          .labelsHidden()
          .onChange(of: quadrant) { _, new in
            selected = MoodCatalog.grid(for: new).first {
              $0.arousal == selected.arousal && $0.valence == selected.valence
            } ?? MoodCatalog.grid(for: new)[4]
          }
        }
        Section("Feeling") {
          let cols = [GridItem(.flexible(), spacing: 10),
                      GridItem(.flexible(), spacing: 10),
                      GridItem(.flexible(), spacing: 10)]
          LazyVGrid(columns: cols, spacing: 10) {
            ForEach(MoodCatalog.grid(for: quadrant)) { e in
              Button { selected = e } label: {
                EmotionPill(emotion: e, isSelected: e == selected)
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.vertical, 4)
        }
        Section("When") {
          DatePicker("Time", selection: $time,
                     displayedComponents: .hourAndMinute)
        }
        Section("Note") {
          TextField("Note", text: $note, axis: .vertical)
            .lineLimit(1...4)
        }
      }
      .navigationTitle("Edit check-in")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { save() }
        }
      }
      .tint(quadrant.color)
    }
  }

  private func save() {
    let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss"
    let hhmmss = fmt.string(from: time)
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    mood.updateEntry(id: original.id,
                     time: hhmmss,
                     quadrant: selected.quadrant.rawValue,
                     arousal: selected.arousal,
                     valence: selected.valence,
                     emotion: selected.word,
                     note: .some(trimmed.isEmpty ? nil : trimmed))
    Haptics.tick()
    onSave()
    dismiss()
  }
}

private struct EmotionPill: View {
  let emotion: MoodEmotion
  let isSelected: Bool
  var body: some View {
    Text(emotion.word)
      .font(.system(.footnote, design: .rounded).weight(.semibold))
      .foregroundStyle(.black.opacity(0.9))
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 10)
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(emotion.quadrant.color.opacity(isSelected ? 0.95 : 0.55))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .strokeBorder(isSelected ? Color.white : Color.clear, lineWidth: 2)
      )
  }
}
