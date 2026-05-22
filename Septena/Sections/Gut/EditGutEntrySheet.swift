import SwiftUI

// Edit sheet for a logged gut entry. Same pattern as
// `EditCaffeineEntrySheet` — standard SwiftUI `Form` in a `NavigationStack`
// presented via `.sheet(item:)`, save enqueues `PUT /api/gut/entry/{id}`
// through HTTPOutbox.

struct EditGutEntrySheet: View {
  @Environment(HTTPOutbox.self) private var outbox
  @Environment(\.dismiss) private var dismiss

  let date: String
  let original: GutEntry
  let onSave: (GutEntry) -> Void

  @State private var time: Date = Date()
  @State private var bristol: Int = 4
  @State private var blood: Int = 0
  @State private var volume: String = ""       // "" | small | medium | large
  @State private var discomfortLevel: String = ""  // "" | low | med | high
  @State private var discomfortHoursString: String = ""
  @State private var note: String = ""

  private static let volumes: [(String, String)] = [
    ("", "—"), ("small", "Small"), ("medium", "Medium"), ("large", "Large"),
  ]
  private static let discomfortLevels: [(String, String)] = [
    ("", "—"), ("low", "Low"), ("med", "Med"), ("high", "High"),
  ]

  var body: some View {
    NavigationStack {
      Form {
        Section("When") {
          DatePicker("Time",
                     selection: $time,
                     displayedComponents: .hourAndMinute)
        }
        Section("Bristol") {
          // Bristol Stool Scale 1–7. `Stepper` is the standard SwiftUI
          // control for a small ordinal range with a numeric anchor.
          Stepper(value: $bristol, in: 1...7) {
            Text("Type \(bristol) · \(bristolShort(bristol))")
          }
        }
        Section("Blood") {
          Stepper(value: $blood, in: 0...3) {
            Text(blood == 0 ? "None" : "Level \(blood)")
          }
        }
        Section("Volume") {
          Picker("Volume", selection: $volume) {
            ForEach(Self.volumes, id: \.0) { v in
              Text(v.1).tag(v.0)
            }
          }
          .pickerStyle(.segmented)
        }
        Section("Discomfort") {
          Picker("Level", selection: $discomfortLevel) {
            ForEach(Self.discomfortLevels, id: \.0) { l in
              Text(l.1).tag(l.0)
            }
          }
          .pickerStyle(.segmented)
          TextField("Hours", text: $discomfortHoursString)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
        }
        Section("Note") {
          TextField("Note", text: $note, axis: .vertical)
            .lineLimit(1...4)
        }
      }
      .navigationTitle("Edit gut entry")
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
      .onAppear { seed() }
    }
  }

  private func bristolShort(_ b: Int) -> String {
    switch b {
    case 1: return "hard lumps"
    case 2: return "lumpy"
    case 3: return "cracked"
    case 4: return "smooth"
    case 5: return "soft blobs"
    case 6: return "mushy"
    case 7: return "liquid"
    default: return "—"
    }
  }

  private func seed() {
    bristol = original.bristol
    blood = original.blood
    volume = original.volume ?? ""
    discomfortLevel = original.discomfortLevel ?? ""
    discomfortHoursString = original.discomfortHours.map {
      $0 == $0.rounded() ? String(Int($0)) : String(format: "%.1f", $0)
    } ?? ""
    note = original.note ?? ""
    let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
    time = fmt.date(from: original.time) ?? Date()
  }

  private func save() {
    let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
    let hhmm = fmt.string(from: time)
    let hoursValue: Double? = {
      let t = discomfortHoursString.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: ",", with: ".")
      return Double(t)
    }()
    let noteValue: String? = {
      let t = note.trimmingCharacters(in: .whitespacesAndNewlines)
      return t.isEmpty ? nil : t
    }()
    let volumeValue: String? = volume.isEmpty ? nil : volume
    let discomfortLvlValue: String? = discomfortLevel.isEmpty ? nil : discomfortLevel

    // Server keys are snake_case. `NSNull` clears a field; absent keys
    // leave it unchanged. We always send every editable field so the
    // semantics from this sheet are predictable.
    var body: [String: Any] = [
      "time": hhmm,
      "bristol": bristol,
      "blood": blood,
    ]
    body["volume"]            = volumeValue ?? NSNull()
    body["discomfort_level"]  = discomfortLvlValue ?? NSNull()
    body["discomfort_hours"]  = hoursValue ?? 0
    body["note"]              = noteValue ?? NSNull()

    outbox.enqueue(
      method: "PUT",
      path: "/api/gut/entry/\(original.id)?date=\(date)",
      body: body,
      kind: "gut.update"
    )
    GutBristolRecorder.record(bristol)
    Haptics.tick()

    let rebuilt = GutEntry(
      id: original.id,
      date: original.date,
      time: hhmm,
      bristol: bristol,
      blood: blood,
      volume: volumeValue,
      discomfortLevel: discomfortLvlValue,
      discomfortHours: hoursValue,
      note: noteValue
    )
    onSave(rebuilt)
    dismiss()
  }
}
