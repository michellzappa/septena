import SwiftUI

// Edit sheet for a logged gut entry. Same pattern as
// `EditCaffeineEntrySheet` — standard SwiftUI `Form` in a `NavigationStack`
// presented via `.sheet(item:)`; saves go through the local-first gut mutator.

struct EditGutEntrySheet: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?

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
  @State private var volume: String = ""       // "" | small | medium | large
  @State private var note: String = ""

  private static let volumes: [(String, String)] = [
    ("", "—"), ("small", "Small"), ("medium", "Medium"), ("large", "Large"),
  ]

  private var navTitle: String { isCreating ? "New gut entry" : "Edit gut entry" }

  var body: some View {
    AdaptiveEditScaffold(title: navTitle, onSave: save) {
      formBody.onAppear { seed() }
    }
  }

  @ViewBuilder private var formBody: some View {
    Form {
        Section("When") {
          SteppedDatePicker("Date & time",
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
        Section("Volume") {
          Picker("Volume", selection: $volume) {
            ForEach(Self.volumes, id: \.0) { v in
              Text(v.1).tag(v.0)
            }
          }
          .pickerStyle(.segmented)
        }
        Section("Note") {
          TextField("Note", text: $note, axis: .vertical)
            .lineLimit(1...4)
        }
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
      volume = ""
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
    volume = original.volume ?? ""
    note = original.note ?? ""
    when = EventTimestamp.from(date: original.date, time: original.time)
  }

  private func save() {
    let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"
    let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH:mm"
    let newDate = dayFmt.string(from: when)
    let hhmm = timeFmt.string(from: when)
    let noteValue: String? = {
      let t = note.trimmingCharacters(in: .whitespacesAndNewlines)
      return t.isEmpty ? nil : t
    }()
    let volumeValue: String? = volume.isEmpty ? nil : volume

    // Both branches funnel through SectionLog (quiet edit, restrained sink
    // for a new log). Dismissal is owned by AdaptiveEditScaffold.
    let savedID: String
    if let original {
      SectionLog.edit {
        gut.updateEntry(
          id: original.id,
          date: newDate,
          time: hhmm,
          bristol: bristol,
          volume: .some(volumeValue),
          note: .some(noteValue)
        )
        GutBristolRecorder.record(bristol)
        AddInfoSection.gut.notifyTilesChanged()
      }
      savedID = original.id
    } else {
      var newID = ""
      SectionLog.newLog(section: "gut", accent: theme.color(for: "gut"),
                        logCommit: logCommit) {
        let entity = gut.addEntry(
          date: newDate,
          time: hhmm,
          bristol: bristol,
          volume: volumeValue,
          note: noteValue
        )
        newID = entity.id
        GutBristolRecorder.record(bristol)
        AddInfoSection.gut.notifyTilesChanged()
      }
      savedID = newID
    }

    // Symptom-shaped fields (blood, discomfort) are retired from Gut — the
    // rebuilt display row carries their empty defaults.
    let rebuilt = GutEntry(
      id: savedID,
      date: newDate,
      time: hhmm,
      bristol: bristol,
      blood: 0,
      volume: volumeValue,
      discomfortLevel: nil,
      discomfortStart: nil,
      discomfortEnd: nil,
      discomfortHours: nil,
      note: noteValue
    )
    onSave(rebuilt)
  }
}
