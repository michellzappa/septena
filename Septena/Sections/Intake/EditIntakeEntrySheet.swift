import SwiftUI
import SwiftData

// Create / edit one intake event. Same form for both, hosted by
// AdaptiveEditScaffold (inspector on iPad/macOS, sheet on iPhone) — the form
// owns no NavigationStack and never dismisses. Fields are driven by the kind's
// config: method always, amount/count by doseStyle, variety by catalog.

struct EditIntakeEntrySheet: View {
  let kindID: String
  let date: String
  let original: IntakeEntryDTO?
  var presetMethod: String? = nil
  var onSave: () -> Void

  @State private var kind: IntakeKindDTO? = nil
  @State private var items: [IntakeItemDTO] = []
  @State private var loaded = false

  @State private var method = ""
  @State private var amount: Double? = nil
  @State private var count: Int = 1
  @State private var itemID: String? = nil
  @State private var note = ""
  @State private var when: Date = Date()

  private var mutator: IntakeMutator { SeptenaServices.shared.intakeMutator }
  private var accent: Color { kind.flatMap { AdaptiveColor.adaptive($0.color) } ?? .accentColor }
  private var isEditing: Bool { original != nil }
  private var canSave: Bool { !method.isEmpty }

  var body: some View {
    AdaptiveEditScaffold(title: isEditing ? "Edit entry" : "New entry",
                         saveTitle: isEditing ? "Save" : "Add",
                         accent: accent,
                         canSave: canSave,
                         onSave: save) {
      Form {
        if let kind {
          Section("When") {
            DatePicker("Date & time", selection: $when,
                       displayedComponents: [.date, .hourAndMinute])
          }
          Section {
            Picker("Method", selection: $method) {
              ForEach(kind.methods, id: \.token) { Text($0.label).tag($0.token) }
            }
            if kind.showsAmount {
              HStack {
                Text(kind.unit.map { "Amount (\($0))" } ?? "Amount")
                Spacer()
                TextField("0", value: $amount, format: .number)
                  #if os(iOS)
                  .keyboardType(.decimalPad)
                  #endif
                  .multilineTextAlignment(.trailing)
                  .frame(maxWidth: 100)
              }
            }
            if kind.showsCount {
              Stepper("\(kind.countNoun?.capitalized ?? "Count"): \(count)",
                      value: $count, in: 1...99)
            }
          }
          if kind.hasCatalog, !items.isEmpty {
            Section(kind.catalogNoun ?? "Variety") {
              Picker(kind.catalogNoun ?? "Variety", selection: $itemID) {
                Text("None").tag(String?.none)
                ForEach(items) { Text($0.name).tag(String?.some($0.id)) }
              }
            }
          }
          Section("Note") {
            TextField("Optional", text: $note, axis: .vertical)
          }
        } else {
          ProgressView()
        }
      }
      .task { await load() }
    }
  }

  private func save() {
    guard let kind else { return }
    let amt = kind.showsAmount ? amount : nil
    let cnt = kind.showsCount ? count : nil
    let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"
    let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH:mm"
    let newDate = dayFmt.string(from: when)
    let hhmm = timeFmt.string(from: when)
    if let original {
      mutator.updateEntry(id: original.id, date: newDate, time: hhmm,
                          method: method, itemID: .some(itemID),
                          amount: .some(amt), count: .some(cnt),
                          note: .some(note))
    } else {
      mutator.addEntry(kindID: kindID, date: newDate, time: hhmm,
                       method: method, itemID: itemID, amount: amt,
                       count: cnt, note: note)
    }
    Haptics.success()
    onSave()
  }

  private func load() async {
    guard !loaded else { return }
    let id = kindID
    let bundle = await MirrorReader.shared.read { ctx -> (IntakeKindDTO?, [IntakeItemDTO]) in
      (IntakeReader.loadKind(context: ctx, id: id),
       IntakeReader.loadItems(context: ctx, kindID: id))
    }
    kind = bundle.0
    items = bundle.1
    seed()
    loaded = true
  }

  private func seed() {
    guard let kind else { return }
    if let original {
      method = original.method
      amount = original.amount
      count = original.count ?? 1
      itemID = original.itemID
      note = original.note ?? ""
      when = original.occurredAt
    } else {
      method = presetMethod ?? kind.methods.first?.token ?? ""
      amount = kind.methods.first { $0.token == method }?.defaultAmount
      // Land a new entry on the day being viewed, at the current time.
      when = EventTimestamp.from(date: date, time: EventTimestamp.hhmm(from: Date()))
    }
  }
}
