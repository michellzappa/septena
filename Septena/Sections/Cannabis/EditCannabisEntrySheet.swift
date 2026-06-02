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
  /// `nil` puts the sheet in create mode — save calls `addEntry` and
  /// onSave fires with the newly-minted entry. Non-nil edits in place.
  let original: CannabisEntry?
  /// In create mode, seed `method` with this preset (e.g. "vape",
  /// "edible") so a quick-log action from `CannabisPlugin.logActions`
  /// can skip the method picker. Ignored when `original` is non-nil.
  var presetMethod: String? = nil
  let onSave: (CannabisEntry) -> Void

  private var isCreating: Bool { original == nil }

  // Single `Date` covering both day and time-of-day; split on save into
  // the entity's "YYYY-MM-DD" + "HH:mm" fields. Editing the date is how
  // you backfill a forgotten log onto the right day.
  @State private var when: Date = Date()
  @State private var method: String = "vape"
  @State private var hit: Int = 1
  @State private var note: String = ""
  @State private var effect: String = ""

  private static let methods: [(String, String)] = [
    ("vape", "Vape"),
    ("edible", "Edible"),
  ]

  var body: some View {
    NavigationStack {
      Form {
        Section("When") {
          DatePicker("Date & time",
                     selection: $when,
                     displayedComponents: [.date, .hourAndMinute])
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
      .navigationTitle(isCreating ? "New cannabis entry" : "Edit cannabis entry")
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
      .task { seed() }
    }
  }

  private func seed() {
    guard let original else {
      // Create mode: pre-fill from preset, then smart-default hit from the
      // most recent entry of the same method so the common path is one tap.
      // Effect/note stay empty — those are per-session.
      method = presetMethod ?? "vape"
      let lastSame = lastEntry(method: method)
      hit = lastSame?.hit ?? 1
      note = ""
      effect = ""
      let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"
      let day = dayFmt.date(from: date) ?? Date()
      let now = Date()
      let cal = Calendar.current
      let comps = cal.dateComponents([.hour, .minute], from: now)
      when = cal.date(bySettingHour: comps.hour ?? 0,
                      minute: comps.minute ?? 0,
                      second: 0,
                      of: day) ?? now
      return
    }
    method = original.method
    hit = original.hit ?? 1
    note = original.note ?? ""
    effect = original.effect ?? ""
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm"
    when = fmt.date(from: "\(date) \(original.time)") ?? Date()
  }

  /// Most recent cannabis event with the given method in the last 30
  /// days — feeds the create sheet's smart defaults so "Log vape" with
  /// the same strain you used yesterday is one tap.
  private func lastEntry(method: String) -> CannabisEventEntity? {
    let cutoff: String = {
      let d = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
      let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
      return f.string(from: d)
    }()
    var descriptor = FetchDescriptor<CannabisEventEntity>(
      predicate: #Predicate { $0.method == method && $0.date >= cutoff },
      sortBy: [
        SortDescriptor(\.date, order: .reverse),
        SortDescriptor(\.time, order: .reverse),
      ]
    )
    descriptor.fetchLimit = 1
    return try? modelContext.fetch(descriptor).first
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
    let effectValue: String? = {
      let t = effect.trimmingCharacters(in: .whitespacesAndNewlines)
      return t.isEmpty ? nil : t
    }()

    let hitValue: Int? = method == "vape" ? hit : nil
    // Recompute grams from the method on edit — switching to edible clears
    // grams; switching to vape stamps the constant 0.05g.
    let gramsValue: Double? = method == "vape" ? CannabisMutator.gramsPerVapeUse : nil

    let savedID: String
    let savedGrams: Double?
    if let original {
      cannabis.updateEntry(id: original.id,
                           date: newDate,
                           time: hhmm,
                           method: method,
                           hit: .some(hitValue),
                           grams: .some(gramsValue),
                           effect: .some(effectValue),
                           note: .some(noteValue))
      savedID = original.id
      savedGrams = method == "vape" ? original.grams : nil
    } else {
      let entity = cannabis.addEntry(date: newDate,
                                     time: hhmm,
                                     method: method,
                                     hit: hitValue,
                                     grams: gramsValue,
                                     effect: effectValue,
                                     note: noteValue)
      savedID = entity.id
      savedGrams = entity.grams
    }
    Haptics.tick()

    let rebuilt = CannabisEntry(
      id: savedID,
      time: hhmm,
      method: method,
      strain: original?.strain,
      hit: method == "vape" ? hit : nil,
      grams: method == "vape" ? savedGrams : nil,
      note: noteValue,
      effect: effectValue
    )
    onSave(rebuilt)
    dismiss()
  }
}
