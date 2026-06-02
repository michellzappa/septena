import SwiftUI

// Edit sheet for a logged gut entry. Same pattern as
// `EditCaffeineEntrySheet` — standard SwiftUI `Form` in a `NavigationStack`
// presented via `.sheet(item:)`, save enqueues `PUT /api/gut/entry/{id}`
// through HTTPOutbox.

struct EditGutEntrySheet: View {
  @Environment(\.dismiss) private var dismiss
  // Set when hosted by `.adaptiveDetail` (docked inspector on regular
  // width), where `dismiss()` is a no-op. Falls back to `dismiss()` when
  // the form is presented as a plain sheet.
  @Environment(\.adaptiveDetailClose) private var adaptiveClose

  private func close() { (adaptiveClose ?? { dismiss() })() }

  let date: String
  /// `nil` puts the sheet in create mode — save calls `addEntry` and
  /// onSave fires with the newly-minted entity. Non-nil edits in place.
  let original: GutEntry?
  let onSave: (GutEntry) -> Void

  private var isCreating: Bool { original == nil }

  private var gut: GutMutator { SeptenaServices.shared.gutMutator }

  // Single `Date` covering both day and time-of-day; split on save into
  // the entity's "YYYY-MM-DD" + "HH:mm" fields. Editing the date is how
  // you backfill a forgotten log onto the right day.
  @State private var when: Date = Date()
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
          DatePicker("Date & time",
                     selection: $when,
                     displayedComponents: [.date, .hourAndMinute])
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
      .navigationTitle(isCreating ? "New gut entry" : "Edit gut entry")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { close() }
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
    guard let original else {
      // Create mode: default Bristol 4 (smooth) at the current moment on
      // the host's date. Everything else stays empty so the user can
      // accept-and-go without confirming defaults they didn't pick.
      bristol = 4
      blood = 0
      volume = ""
      discomfortLevel = ""
      discomfortHoursString = ""
      note = ""
      let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
      let day = fmt.date(from: date) ?? Date()
      let now = Date()
      let cal = Calendar.current
      let comps = cal.dateComponents([.hour, .minute], from: now)
      when = cal.date(bySettingHour: comps.hour ?? 0,
                      minute: comps.minute ?? 0,
                      second: 0,
                      of: day) ?? now
      return
    }
    bristol = original.bristol
    blood = original.blood
    volume = original.volume ?? ""
    discomfortLevel = original.discomfortLevel ?? ""
    discomfortHoursString = original.discomfortHours.map {
      $0 == $0.rounded() ? String(Int($0)) : String(format: "%.1f", $0)
    } ?? ""
    note = original.note ?? ""
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm"
    when = fmt.date(from: "\(original.date) \(original.time)") ?? Date()
  }

  private func save() {
    let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"
    let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH:mm"
    let newDate = dayFmt.string(from: when)
    let hhmm = timeFmt.string(from: when)
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

    // Translate the hours-string into start/end timestamps. The server's
    // old PUT-handler did this server-side; on CK we own that math.
    var startISO: String? = nil
    var endISO: String? = nil
    if let h = hoursValue, h > 0 {
      let calFmt = DateFormatter()
      calFmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
      calFmt.calendar = Calendar(identifier: .gregorian)
      calFmt.locale = Locale(identifier: "en_US_POSIX")
      calFmt.timeZone = TimeZone.current
      if let start = calFmt.date(from: "\(newDate)T\(hhmm)") {
        let end = start.addingTimeInterval(h * 3600)
        startISO = calFmt.string(from: start)
        endISO = calFmt.string(from: end)
      }
    }

    let savedID: String
    if let original {
      gut.updateEntry(
        id: original.id,
        date: newDate,
        time: hhmm,
        bristol: bristol,
        blood: blood,
        volume: .some(volumeValue),
        discomfortLevel: .some(discomfortLvlValue),
        discomfortStart: .some(startISO),
        discomfortEnd: .some(endISO),
        note: .some(noteValue)
      )
      savedID = original.id
    } else {
      let entity = gut.addEntry(
        date: newDate,
        time: hhmm,
        bristol: bristol,
        blood: blood,
        volume: volumeValue,
        discomfortLevel: discomfortLvlValue,
        discomfortStart: startISO,
        discomfortEnd: endISO,
        note: noteValue
      )
      savedID = entity.id
    }
    GutBristolRecorder.record(bristol)
    Haptics.tick()

    let rebuilt = GutEntry(
      id: savedID,
      date: newDate,
      time: hhmm,
      bristol: bristol,
      blood: blood,
      volume: volumeValue,
      discomfortLevel: discomfortLvlValue,
      discomfortStart: startISO,
      discomfortEnd: endISO,
      discomfortHours: hoursValue,
      note: noteValue
    )
    onSave(rebuilt)
    close()
  }
}
