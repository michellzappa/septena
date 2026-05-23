import SwiftUI
import SwiftData

// Edit sheet for a logged cannabis session. Standard SwiftUI `Form` in a
// `NavigationStack` presented via `.sheet(item:)`. Writes go through
// CannabisMutator (SwiftData + CloudKit).

struct EditCannabisEntrySheet: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss

  private var cannabis: CannabisMutator { SeptenaServices.shared.cannabisMutator }

  let date: String
  let original: CannabisEntry
  let onSave: (CannabisEntry) -> Void

  @State private var time: Date = Date()
  @State private var method: String = "vape"
  @State private var strainChoice: String = ""
  @State private var strainFreeform: String = ""
  @State private var hit: Int = 1
  @State private var note: String = ""
  @State private var effect: String = ""
  @State private var strains: [CannabisStrain] = []

  private static let methods: [(String, String)] = [
    ("vape", "Vape"),
    ("edible", "Edible"),
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
            ForEach(Self.methods, id: \.0) { m in
              Text(m.1).tag(m.0)
            }
          }
          .pickerStyle(.segmented)
        }
        if method == "vape" {
          Section("Strain") {
            if !strains.isEmpty {
              Picker("Strain", selection: $strainChoice) {
                Text("None").tag("")
                ForEach(strains) { s in
                  Text(s.name).tag(s.name)
                }
                Text("Custom…").tag("__custom__")
              }
            }
            if strainChoice == "__custom__" || strains.isEmpty {
              TextField("Strain name", text: $strainFreeform)
            }
          }
          Section("Hit") {
            Stepper(value: $hit, in: 1...10) {
              Text("\(hit)")
            }
          }
        }
        Section("Note") {
          TextField("Note", text: $note, axis: .vertical)
            .lineLimit(1...4)
        }
        Section("Effect") {
          TextField("Effect", text: $effect, axis: .vertical)
            .lineLimit(1...4)
        }
      }
      .navigationTitle("Edit cannabis entry")
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
      .task { await loadStrains(); seed() }
    }
  }

  private func seed() {
    method = original.method
    if let s = original.strain, !s.isEmpty {
      if strains.contains(where: { $0.name == s }) {
        strainChoice = s
      } else {
        strainChoice = "__custom__"
        strainFreeform = s
      }
    } else {
      strainChoice = ""
    }
    hit = original.hit ?? 1
    note = original.note ?? ""
    effect = original.effect ?? ""
    let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
    time = fmt.date(from: original.time) ?? Date()
  }

  private func loadStrains() async {
    strains = ChecklistMirror.loadCannabisStrains(context: modelContext)
  }

  private func save() {
    let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
    let hhmm = fmt.string(from: time)
    let strainValue: String? = {
      guard method == "vape" else { return nil }
      switch strainChoice {
      case "":
        return nil
      case "__custom__":
        let t = strainFreeform.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
      default:
        return strainChoice
      }
    }()
    let noteValue: String? = {
      let t = note.trimmingCharacters(in: .whitespacesAndNewlines)
      return t.isEmpty ? nil : t
    }()
    let effectValue: String? = {
      let t = effect.trimmingCharacters(in: .whitespacesAndNewlines)
      return t.isEmpty ? nil : t
    }()

    let hitValue: Int? = method == "vape" ? hit : nil
    // Recompute grams from the method on edit — switching to edible clears
    // grams; switching to vape stamps the constant 0.05g.
    let gramsValue: Double? = method == "vape" ? CannabisMutator.gramsPerVapeUse : nil

    cannabis.updateEntry(id: original.id,
                         time: hhmm,
                         method: method,
                         strain: .some(strainValue),
                         hit: .some(hitValue),
                         grams: .some(gramsValue),
                         effect: .some(effectValue),
                         note: .some(noteValue))
    Haptics.tick()

    let rebuilt = CannabisEntry(
      id: original.id,
      time: hhmm,
      method: method,
      strain: strainValue,
      hit: method == "vape" ? hit : nil,
      grams: method == "vape" ? original.grams : nil,
      note: noteValue,
      effect: effectValue
    )
    onSave(rebuilt)
    dismiss()
  }
}
