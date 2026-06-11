import SwiftData
import SwiftUI

struct SymptomsDestinationView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme

  @Query(sort: \SymptomDefinitionEntity.sortIndex)
  private var definitions: [SymptomDefinitionEntity]
  @Query(sort: \SymptomEventEntity.occurredAt, order: .reverse)
  private var events: [SymptomEventEntity]

  @State private var viewingDate = SeptenaDate.today
  @State private var editing: SymptomEventEntity?
  @State private var creating = false

  private var accent: Color { theme.color(for: "symptoms") }
  private var mutator: SymptomsMutator { SeptenaServices.shared.symptomsMutator }

  private var activeDefinitions: [SymptomDefinitionEntity] {
    definitions.filter { !$0.archived }
  }

  private var dayEvents: [SymptomEventEntity] {
    events.filter { $0.date == viewingDate }
  }

  var body: some View {
    SectionDrawer(sectionKey: "symptoms",
                  onLog: { _ in creating = true },
                  currentDate: $viewingDate) {
      DrawerSection("Log", padding: .none) {
        if dayEvents.isEmpty {
          Text("Nothing logged yet.")
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        } else {
          ForEach(dayEvents) { event in
            LogEntryRow(
              title: title(for: event),
              detail: detail(for: event),
              trailing: EventTimestamp.hhmm(from: event.occurredAt),
              tint: accent,
              isSelected: editing?.id == event.id,
              onEdit: { editing = event },
              onDelete: { delete(event) }
            )
          }
        }
      }

      DrawerSection("Summary") {
        StatStrip(stats: [
          Stat(value: "\(dayEvents.count)", label: "events", tint: accent),
          Stat(value: "\(dayEvents.map(\.severity).max() ?? 0)", label: "peak", tint: accent),
          Stat(value: averageSeverityText, label: "average", tint: accent),
        ])
      }
    }
    .tint(accent)
    .sectionReload(on: viewingDate, onDataChange: true,
                   forSections: ["symptoms"]) {}
    .sheet(isPresented: $creating) {
      SymptomEventEditor(date: viewingDate,
                         definitions: activeDefinitions,
                         event: nil)
    }
    .sheet(item: $editing) { event in
      SymptomEventEditor(date: viewingDate,
                         definitions: activeDefinitions,
                         event: event)
    }
  }

  private var averageSeverityText: String {
    guard !dayEvents.isEmpty else { return "0" }
    let avg = Double(dayEvents.reduce(0) { $0 + $1.severity }) / Double(dayEvents.count)
    return avg.decimalString(1)
  }

  private func title(for event: SymptomEventEntity) -> String {
    guard let def = definitions.first(where: { $0.id == event.symptomID }) else {
      return "Symptom"
    }
    if let emoji = def.emoji, !emoji.isEmpty {
      return "\(emoji) \(def.title)"
    }
    return def.title
  }

  private func detail(for event: SymptomEventEntity) -> String? {
    var parts = ["severity \(event.severity)/10"]
    if let region = event.bodyRegion, !region.isEmpty { parts.append(region) }
    if let side = event.side, !side.isEmpty, side != "none" { parts.append(side) }
    if let quality = event.quality, !quality.isEmpty { parts.append(quality) }
    if let minutes = event.durationMinutes, minutes > 0 { parts.append("\(minutes)m") }
    if let note = event.note, !note.isEmpty { parts.append(note) }
    return parts.joined(separator: " · ")
  }

  private func delete(_ event: SymptomEventEntity) {
    mutator.deleteEvent(id: event.id)
    Haptics.warning()
  }
}

private struct SymptomEventEditor: View {
  @Environment(\.dismiss) private var dismiss
  let date: String
  let definitions: [SymptomDefinitionEntity]
  let event: SymptomEventEntity?

  @State private var symptomID: String = ""
  @State private var time = Date()
  @State private var severity = 5.0
  @State private var duration = ""
  @State private var bodyRegion = ""
  @State private var side = "none"
  @State private var quality = ""
  @State private var triggerNote = ""
  @State private var reliefNote = ""
  @State private var note = ""

  private var mutator: SymptomsMutator { SeptenaServices.shared.symptomsMutator }

  var body: some View {
    NavigationStack {
      Form {
        if definitions.isEmpty {
          ContentUnavailableView("No symptoms yet",
                                 systemImage: "waveform.path.ecg",
                                 description: Text("Add symptom definitions in Settings first."))
        } else {
          Section("Symptom") {
            Picker("Symptom", selection: $symptomID) {
              ForEach(definitions) { def in
                Text(def.title).tag(def.id)
              }
            }
            DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Text("Severity")
                Spacer()
                Text("\(Int(severity))/10")
                  .font(.body.monospacedDigit())
                  .foregroundStyle(.secondary)
              }
              Slider(value: $severity, in: 0...10, step: 1)
            }
          }
          Section("Detail") {
            TextField("Duration minutes", text: $duration)
              #if os(iOS)
              .keyboardType(.numberPad)
              #endif
            TextField("Body region", text: $bodyRegion)
            Picker("Side", selection: $side) {
              Text("None").tag("none")
              Text("Left").tag("left")
              Text("Right").tag("right")
              Text("Both").tag("both")
            }
            TextField("Quality", text: $quality)
          }
          Section("Notes") {
            TextField("Trigger", text: $triggerNote, axis: .vertical)
            TextField("Relief", text: $reliefNote, axis: .vertical)
            TextField("Note", text: $note, axis: .vertical)
          }
        }
      }
      .navigationTitle(event == nil ? "Log Symptom" : "Edit Symptom")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { save() }
            .disabled(symptomID.isEmpty)
        }
      }
      .task { seed() }
    }
  }

  private func seed() {
    if let event {
      symptomID = event.symptomID
      time = event.occurredAt == .distantPast ? Date() : event.occurredAt
      severity = Double(event.severity)
      duration = event.durationMinutes.map(String.init) ?? ""
      bodyRegion = event.bodyRegion ?? ""
      side = event.side ?? "none"
      quality = event.quality ?? ""
      triggerNote = event.triggerNote ?? ""
      reliefNote = event.reliefNote ?? ""
      note = event.note ?? ""
    } else if symptomID.isEmpty {
      symptomID = definitions.first?.id ?? ""
    }
  }

  private func nilIfEmpty(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func save() {
    let timeString = EventTimestamp.hhmm(from: time)
    let minutes = Int(duration.trimmingCharacters(in: .whitespacesAndNewlines))
    if let event {
      mutator.updateEvent(id: event.id,
                          date: date,
                          time: timeString,
                          symptomID: symptomID,
                          severity: Int(severity),
                          durationMinutes: minutes,
                          bodyRegion: nilIfEmpty(bodyRegion),
                          side: nilIfEmpty(side),
                          quality: nilIfEmpty(quality),
                          triggerNote: nilIfEmpty(triggerNote),
                          reliefNote: nilIfEmpty(reliefNote),
                          note: nilIfEmpty(note))
    } else {
      mutator.addEvent(symptomID: symptomID,
                       date: date,
                       time: timeString,
                       severity: Int(severity),
                       durationMinutes: minutes,
                       bodyRegion: nilIfEmpty(bodyRegion),
                       side: nilIfEmpty(side),
                       quality: nilIfEmpty(quality),
                       triggerNote: nilIfEmpty(triggerNote),
                       reliefNote: nilIfEmpty(reliefNote),
                       note: nilIfEmpty(note))
    }
    dismiss()
  }
}

struct SymptomDefinitionsSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Query(sort: \SymptomDefinitionEntity.sortIndex)
  private var definitions: [SymptomDefinitionEntity]

  @State private var title = ""
  @State private var emoji = ""
  @State private var bodySystem = ""
  @State private var region = ""

  private var mutator: SymptomsMutator { SeptenaServices.shared.symptomsMutator }

  var body: some View {
    NavigationStack {
      Form {
        Section("Add Symptom") {
          TextField("Name", text: $title)
          TextField("Glyph", text: $emoji)
          TextField("Body system", text: $bodySystem)
          TextField("Default region", text: $region)
          Button {
            add()
          } label: {
            Label("Add", systemImage: "plus")
          }
          .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Section("Symptoms") {
          ForEach(definitions) { def in
            HStack {
              if let emoji = def.emoji, !emoji.isEmpty {
                Text(emoji)
              }
              VStack(alignment: .leading) {
                Text(def.title)
                if let system = def.bodySystem, !system.isEmpty {
                  Text(system).font(.caption).foregroundStyle(.secondary)
                }
              }
              Spacer()
              Button(def.archived ? "Unarchive" : "Archive") {
                mutator.updateDefinition(id: def.id, archived: !def.archived)
              }
              .buttonStyle(.borderless)
            }
          }
        }
      }
      .navigationTitle("Symptoms")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  private func nilIfEmpty(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func add() {
    mutator.addDefinition(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                          emoji: nilIfEmpty(emoji),
                          bodySystem: nilIfEmpty(bodySystem),
                          defaultBodyRegion: nilIfEmpty(region))
    title = ""
    emoji = ""
    bodySystem = ""
    region = ""
  }
}
