import SwiftUI
import SwiftData

// Edit sheet for a logged cannabis session. Standard SwiftUI `Form` hosted by
// `AdaptiveEditScaffold`, presented via `.adaptiveDetail(item:)`. Writes go
// through CannabisMutator (SwiftData + CloudKit).

struct EditCannabisEntrySheet: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?

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

  private static let methods: [(String, String)] = [
    ("vape", "Vape"),
    ("edible", "Edible"),
  ]

  var body: some View {
    AdaptiveEditScaffold(title: isCreating ? "New cannabis entry" : "Edit cannabis entry",
                         onSave: save) {
      formBody.onAppear { seed() }
    }
  }

  @ViewBuilder private var formBody: some View {
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
    }
  }

  private func seed() {
    guard let original else {
      // Create mode: pre-fill from preset, then smart-default hit from the
      // most recent entry of the same method so the common path is one tap.
      // Note stays empty — it's per-session.
      method = presetMethod ?? "vape"
      let lastSame = lastEntry(method: method)
      hit = lastSame?.hit ?? 1
      note = ""
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
    when = EventTimestamp.from(date: date, time: original.time)
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
      sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
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

    let hitValue: Int? = method == "vape" ? hit : nil
    // Recompute grams from the method on edit — switching to edible clears
    // grams; switching to vape stamps the constant 0.05g.
    let gramsValue: Double? = method == "vape" ? CannabisMutator.gramsPerVapeUse : nil

    // Both branches funnel through SectionLog so the haptic + tile refresh
    // stay identical to every other cannabis log site. A new entry
    // celebrates (the section's mellow bloom); an edit is a quiet
    // correction. Dismissal is owned by AdaptiveEditScaffold.
    let savedID: String
    let savedGrams: Double?
    if let original {
      SectionLog.edit {
        cannabis.updateEntry(id: original.id,
                             date: newDate,
                             time: hhmm,
                             method: method,
                             hit: .some(hitValue),
                             grams: .some(gramsValue),
                             note: .some(noteValue))
        AddInfoSection.cannabis.notifyTilesChanged()
      }
      savedID = original.id
      savedGrams = method == "vape" ? original.grams : nil
    } else {
      var newID = ""
      var newGrams: Double? = nil
      SectionLog.newLog(
        section: "cannabis",
        accent: theme.color(for: "cannabis"),
        logCommit: logCommit
      ) {
        let entity = cannabis.addEntry(date: newDate,
                                       time: hhmm,
                                       method: method,
                                       hit: hitValue,
                                       grams: gramsValue,
                                       note: noteValue)
        newID = entity.id
        newGrams = entity.grams
        AddInfoSection.cannabis.notifyTilesChanged()
      }
      savedID = newID
      savedGrams = newGrams
    }

    let rebuilt = CannabisEntry(
      id: savedID,
      time: hhmm,
      method: method,
      strain: original?.strain,
      hit: method == "vape" ? hit : nil,
      grams: method == "vape" ? savedGrams : nil,
      note: noteValue
    )
    onSave(rebuilt)
  }
}
