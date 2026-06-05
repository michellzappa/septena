import SwiftUI

// Edit one logged check-in. Picks the same emotion grid as the add flow
// but defaults to the original quadrant + word. Quadrant change is
// possible — switching it resets the emotion to the cell at the same
// (arousal, valence) coordinates in the new quadrant if it exists.

struct EditMoodEntrySheet: View {
  let date: String
  let original: MoodEntry
  let onSave: () -> Void

  private var mood: MoodMutator { SeptenaServices.shared.moodMutator }

  @State private var quadrant: MoodQuadrant
  @State private var selected: MoodEmotion
  // Single `Date` covering both day and time-of-day; split on save into
  // the entity's "YYYY-MM-DD" + "HH:mm:ss" fields. Editing the date is
  // how you backfill a forgotten check-in onto the right day.
  @State private var when: Date
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
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
    _when = State(initialValue: fmt.date(from: "\(date) \(original.time)") ?? Date())
    _note = State(initialValue: original.note ?? "")
  }

  var body: some View {
    AdaptiveEditScaffold(title: "Edit check-in", onSave: save) {
      formBody
    }
  }

  @ViewBuilder private var formBody: some View {
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
          DatePicker("Date & time", selection: $when,
                     displayedComponents: [.date, .hourAndMinute])
        }
        Section("Note") {
          TextField("Note", text: $note, axis: .vertical)
            .lineLimit(1...4)
        }
      }
      .tint(quadrant.color)
  }

  private func save() {
    let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"
    let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH:mm:ss"
    let newDate = dayFmt.string(from: when)
    let hhmmss = timeFmt.string(from: when)
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    mood.updateEntry(id: original.id,
                     date: newDate,
                     time: hhmmss,
                     quadrant: selected.quadrant.rawValue,
                     arousal: selected.arousal,
                     valence: selected.valence,
                     emotion: selected.word,
                     note: .some(trimmed.isEmpty ? nil : trimmed))
    Haptics.tick()
    onSave()
  }
}

private struct EmotionPill: View {
  let emotion: MoodEmotion
  let isSelected: Bool
  var body: some View {
    Text(emotion.displayWord)
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
