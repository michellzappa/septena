import SwiftUI

// Edit sheet for a single logged caffeine entry. Standard SwiftUI Form
// presented via `.sheet(item:)` — same affordance Apple uses across
// Reminders, Calendar, and Notes for editing list items. Save enqueues a
// PUT via HTTPOutbox; cancel discards. Delete lives on the row's swipe
// action, not in the sheet.

struct EditCaffeineEntrySheet: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(HTTPOutbox.self) private var outbox
  @Environment(\.dismiss) private var dismiss

  /// Day the entry belongs to (path query param). Caller passes the day
  /// from the surrounding `CaffeineDayResponse`.
  let date: String
  let original: CaffeineEntry
  /// Invoked with the new entry shape so the destination view can swap it
  /// in optimistically; the server write rides the outbox.
  let onSave: (CaffeineEntry) -> Void

  // Editable state — seeded from `original` on first appearance.
  @State private var time: Date = Date()
  @State private var method: String = "v60"
  @State private var beansChoice: String = "" // empty = "no preset"
  @State private var beansFreeform: String = ""
  @State private var gramsString: String = ""
  @State private var note: String = ""
  @State private var beans: [CaffeineBean] = []

  private static let methods: [(value: String, label: String)] = [
    ("v60", "V60"),
    ("matcha", "Matcha"),
    ("other", "Other"),
  ]

  var body: some View {
    NavigationStack {
      Form {
        Section("When") {
          DatePicker("Time",
                     selection: $time,
                     displayedComponents: .hourAndMinute)
        }
        Section("Method") {
          Picker("Method", selection: $method) {
            ForEach(Self.methods, id: \.value) { m in
              Text(m.label).tag(m.value)
            }
          }
          .pickerStyle(.segmented)
        }
        Section("Beans") {
          if !beans.isEmpty {
            Picker("Preset", selection: $beansChoice) {
              Text("None").tag("")
              ForEach(beans) { b in
                Text(b.name).tag(b.name)
              }
              Text("Custom…").tag("__custom__")
            }
          }
          if beansChoice == "__custom__" || beans.isEmpty {
            TextField("Bean name", text: $beansFreeform)
          }
        }
        Section("Amount") {
          TextField("Grams", text: $gramsString)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
        }
        Section("Note") {
          TextField("Note", text: $note, axis: .vertical)
            .lineLimit(1...4)
        }
      }
      .navigationTitle("Edit caffeine entry")
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
      .task { await loadBeans(); seed() }
    }
  }

  private func seed() {
    method = original.method
    if let b = original.beans, !b.isEmpty {
      if beans.contains(where: { $0.name == b }) {
        beansChoice = b
      } else {
        beansChoice = "__custom__"
        beansFreeform = b
      }
    } else {
      beansChoice = ""
    }
    gramsString = original.grams.map {
      $0 == $0.rounded() ? String(Int($0)) : String(format: "%.1f", $0)
    } ?? ""
    note = original.note ?? ""
    // Parse "HH:mm" into a Date anchored on today; only the time
    // components are sent back to the server.
    let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
    time = fmt.date(from: original.time) ?? Date()
  }

  private func loadBeans() async {
    if let cfg = try? await client.caffeineConfig() {
      beans = cfg.beans
    }
  }

  private func save() {
    let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
    let hhmm = fmt.string(from: time)

    let beansValue: String? = {
      switch beansChoice {
      case "":           return nil
      case "__custom__":
        let t = beansFreeform.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
      default:           return beansChoice
      }
    }()
    let gramsValue: Double? = {
      let t = gramsString.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: ",", with: ".")
      return Double(t)
    }()
    let noteValue: String? = {
      let t = note.trimmingCharacters(in: .whitespacesAndNewlines)
      return t.isEmpty ? nil : t
    }()

    var body: [String: Any] = [
      "time": hhmm,
      "method": method,
      "timezone": TimeZone.current.identifier,
    ]
    if let beansValue { body["beans"] = beansValue } else { body["beans"] = NSNull() }
    if let gramsValue { body["grams"] = gramsValue } else { body["grams"] = NSNull() }
    if let noteValue  { body["note"]  = noteValue  } else { body["note"]  = NSNull() }

    outbox.enqueue(
      method: "PUT",
      path: "/api/caffeine/entry/\(original.id)?date=\(date)",
      body: body,
      kind: "caffeine.update"
    )
    Haptics.tick()

    var updated = original
    updated.method = method
    updated.beans  = beansValue
    updated.grams  = gramsValue
    updated.note   = noteValue
    // `time` is a `let` on CaffeineEntry, so we can't mutate it directly;
    // rebuild via the memberwise init.
    let rebuilt = CaffeineEntry(
      id: updated.id,
      time: hhmm,
      method: updated.method,
      beans: updated.beans,
      grams: updated.grams,
      note: updated.note
    )
    onSave(rebuilt)
    dismiss()
  }
}
