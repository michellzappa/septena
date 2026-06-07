import SwiftUI
import SwiftData

// Edit sheet for a single logged caffeine entry. Standard SwiftUI Form
// presented via `.sheet(item:)` — same affordance Apple uses across
// Reminders, Calendar, and Notes for editing list items. Save enqueues a
// PUT via HTTPOutbox; cancel discards. Delete lives on the row's swipe
// action, not in the sheet.

struct EditCaffeineEntrySheet: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?

  /// Day the entry belongs to (path query param). Caller passes the day
  /// from the surrounding `CaffeineDayResponse`.
  let date: String
  /// `nil` puts the sheet in create mode — save calls `addEntry` and
  /// onSave fires with the newly-minted entry. Non-nil edits in place.
  let original: CaffeineEntry?
  /// In create mode, seed `method` with this preset (e.g. "v60",
  /// "matcha") so the per-method quick-log actions from
  /// `CaffeinePlugin.logActions` skip a tap. Ignored when `original`
  /// is non-nil (edit mode seeds from the original entry).
  var presetMethod: String? = nil
  /// Invoked with the new entry shape so the destination view can swap it
  /// in optimistically; the server write rides the outbox.
  let onSave: (CaffeineEntry) -> Void

  private var isCreating: Bool { original == nil }

  // Editable state — seeded from `original` on first appearance. The
  // picker binds a single `Date` covering both day and time-of-day; on
  // save we split it back into the entity's "YYYY-MM-DD" + "HH:mm"
  // fields. Editing the date is how you backfill a forgotten log onto
  // the right day.
  @State private var when: Date = Date()
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

  private var navTitle: String {
    isCreating ? "New caffeine entry" : "Edit caffeine entry"
  }

  var body: some View {
    AdaptiveEditScaffold(title: navTitle, onSave: save) {
      formBody.task { await loadBeans(); seed() }
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
  }

  private func seed() {
    guard let original else {
      // Create mode: pre-fill method from preset and smart-default the
      // beans + grams from the most recent entry of that same method so
      // the common "same as last time" path is one tap. The user can
      // still override before save — no commit happens silently.
      method = presetMethod ?? "v60"
      let lastSame = lastEntry(method: method)
      if let last = lastSame, let b = last.beans, !b.isEmpty {
        if beans.contains(where: { $0.name == b }) {
          beansChoice = b
        } else {
          beansChoice = "__custom__"
          beansFreeform = b
        }
      } else {
        beansChoice = ""
        beansFreeform = ""
      }
      gramsString = lastSame?.grams.map {
        $0 == $0.rounded() ? String(Int($0)) : $0.decimalString()
      } ?? ""
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
      $0 == $0.rounded() ? String(Int($0)) : $0.decimalString()
    } ?? ""
    note = original.note ?? ""
    when = EventTimestamp.from(date: date, time: original.time)
  }

  private func loadBeans() async {
    beans = ChecklistMirror.loadCaffeineBeans(context: modelContext)
  }

  /// Most recent caffeine event with the given method, looking at the
  /// last 30 days so the smart-default doesn't reach back to ancient
  /// history when the user resumes a method after a long pause.
  private func lastEntry(method: String) -> CaffeineEventEntity? {
    let cutoff: String = {
      let d = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
      let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
      return f.string(from: d)
    }()
    var descriptor = FetchDescriptor<CaffeineEventEntity>(
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

    // Both branches funnel through CaffeineCommit so the write + haptic +
    // tile refresh stay identical to every other caffeine log site. A new
    // entry celebrates (affect-matched flourish); an edit is a quiet
    // correction. Dismissal is owned by AdaptiveEditScaffold — neither
    // branch dismisses here.
    let savedID: String
    if let original {
      CaffeineCommit.update(id: original.id, date: newDate, time: hhmm,
                            method: method, beans: beansValue,
                            grams: gramsValue, note: noteValue)
      savedID = original.id
    } else {
      savedID = CaffeineCommit.logNew(
        date: newDate, time: hhmm, method: method,
        beans: beansValue, grams: gramsValue, note: noteValue,
        accent: theme.color(for: "caffeine"), logCommit: logCommit)
    }

    let rebuilt = CaffeineEntry(
      id: savedID,
      time: hhmm,
      method: method,
      beans: beansValue,
      grams: gramsValue,
      note: noteValue
    )
    onSave(rebuilt)
  }
}
