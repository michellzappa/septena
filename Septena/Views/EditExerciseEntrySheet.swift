import SwiftUI

// Edit sheet for a logged training entry. Standard SwiftUI `Form` in a
// `NavigationStack` presented via `.sheet(item:)`. Save enqueues
// `PUT /api/training/entries` through HTTPOutbox. The server identifies
// the entry by its filename (`file` field in the JSON body) and
// branches on cardio vs strength fields based on exercise type.

struct EditExerciseEntrySheet: View {
  @Environment(HTTPOutbox.self) private var outbox
  @Environment(\.dismiss) private var dismiss

  let original: ExerciseEntry
  let onSave: (ExerciseEntry) -> Void

  // Strength fields
  @State private var weight: String = ""
  @State private var sets: String = ""
  @State private var reps: String = ""
  @State private var difficulty: String = ""

  // Cardio fields
  @State private var durationMin: String = ""
  @State private var distanceM: String = ""
  @State private var level: String = ""

  @State private var note: String = ""

  /// Cardio if the loaded entry already carries any cardio-shaped field.
  private var isCardio: Bool {
    original.durationMin != nil || original.distanceM != nil || original.level != nil
  }

  private static let difficulties: [(String, String)] = [
    ("", "—"),
    ("easy", "Easy"),
    ("moderate", "Moderate"),
    ("hard", "Hard"),
    ("max", "Max"),
  ]

  var body: some View {
    NavigationStack {
      Form {
        Section(original.exercise ?? "Exercise") {
          Text(original.session.capitalized.isEmpty ? "Session" : original.session.capitalized)
            .foregroundStyle(.secondary)
        }
        if isCardio {
          Section("Cardio") {
            numberRow("Duration (min)", text: $durationMin)
            numberRow("Distance (m)", text: $distanceM)
            numberRow("Level", text: $level)
          }
        } else {
          Section("Strength") {
            numberRow("Weight (kg)", text: $weight)
            numberRow("Sets", text: $sets)
            numberRow("Reps", text: $reps)
            Picker("Difficulty", selection: $difficulty) {
              ForEach(Self.difficulties, id: \.0) { d in
                Text(d.1).tag(d.0)
              }
            }
            .pickerStyle(.segmented)
          }
        }
        Section("Note") {
          TextField("Note", text: $note, axis: .vertical)
            .lineLimit(1...4)
        }
      }
      .navigationTitle("Edit entry")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { save() }
            .disabled(original.file == nil)
        }
      }
      .onAppear { seed() }
    }
  }

  private func numberRow(_ label: String, text: Binding<String>) -> some View {
    HStack {
      Text(label)
      Spacer()
      TextField("", text: text)
        #if os(iOS)
        .keyboardType(.decimalPad)
        #endif
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: 100)
    }
  }

  private func seed() {
    weight = original.weight.map(numString) ?? ""
    sets = original.sets ?? ""
    reps = original.reps ?? ""
    difficulty = original.difficulty ?? ""
    durationMin = original.durationMin.map(numString) ?? ""
    distanceM = original.distanceM.map(numString) ?? ""
    level = original.level.map(numString) ?? ""
  }

  private func numString(_ d: Double) -> String {
    d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d)
  }

  private func parseDouble(_ s: String) -> Double? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: ",", with: ".")
    return t.isEmpty ? nil : Double(t)
  }

  private func parseInt(_ s: String) -> Int? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : Int(t)
  }

  private func save() {
    guard let file = original.file else { return }
    var body: [String: Any] = ["file": file]
    if isCardio {
      body["duration_min"] = parseDouble(durationMin) ?? ""
      body["distance_m"]   = parseInt(distanceM) ?? ""
      body["level"]        = parseInt(level) ?? ""
    } else {
      body["weight"] = parseDouble(weight) ?? ""
      body["sets"]   = parseInt(sets) ?? ""
      body["reps"]   = parseInt(reps) ?? reps.trimmingCharacters(in: .whitespacesAndNewlines)
      body["difficulty"] = difficulty
    }
    let noteValue = note.trimmingCharacters(in: .whitespacesAndNewlines)
    body["note"] = noteValue

    outbox.enqueue(
      method: "PUT",
      path: "/api/training/entries",
      body: body,
      kind: "training.update"
    )
    Haptics.tick()

    // Build optimistic local entry. `ExerciseEntry` has a custom decoder
    // but no matching memberwise init exposed; we re-encode and decode to
    // produce the updated value, keeping the same shape as a server
    // round-trip.
    var dict: [String: Any] = [
      "date": original.date,
      "session": original.session,
      "exercise": original.exercise ?? "",
      "file": file,
    ]
    if let c = original.concludedAt { dict["concluded_at"] = c }
    if let l = original.loggedAt    { dict["logged_at"]    = l }
    if isCardio {
      if let v = parseDouble(durationMin) { dict["duration_min"] = v }
      if let v = parseInt(distanceM)      { dict["distance_m"]   = v }
      if let v = parseInt(level)          { dict["level"]        = v }
    } else {
      if let v = parseDouble(weight) { dict["weight"] = v }
      if let v = parseInt(sets)      { dict["sets"]   = v }
      if let v = parseInt(reps)      { dict["reps"]   = v } else if !reps.trimmingCharacters(in: .whitespaces).isEmpty {
        dict["reps"] = reps
      }
      if !difficulty.isEmpty { dict["difficulty"] = difficulty }
    }
    if let data = try? JSONSerialization.data(withJSONObject: dict),
       let rebuilt = try? JSONDecoder().decode(ExerciseEntry.self, from: data) {
      onSave(rebuilt)
    }
    dismiss()
  }
}
