import Charts
import SwiftData
import SwiftUI

struct SymptomsDestinationView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme
  @Environment(DayClock.self) private var clock

  @Query(sort: \SymptomDefinitionEntity.sortIndex)
  private var definitions: [SymptomDefinitionEntity]
  @Query(sort: \SymptomEventEntity.occurredAt, order: .reverse)
  private var events: [SymptomEventEntity]

  @State private var viewingDate = ""
  @State private var editing: SymptomEventEntity?
  @State private var creating = false
  /// Symptom whose per-symptom detail (severity heatmap + history) is open.
  @State private var viewingSymptom: SymptomDefinitionEntity?
  /// Symptom definition being renamed/retagged from its detail's "Edit".
  @State private var editingDefinition: SymptomDefinitionEntity?
  // Symptoms is an editable dual section, but an event log (not a checklist):
  // Log = the day's events (time-travelable); Patterns = 30-day severity trend +
  // a timing rhythm wheel. Default Log — an empty symptom day is good news, so
  // no empty-state nudge to Patterns.
  @State private var mode: DrawerMode = .remembered(for: "symptoms", default: .log)

  private var accent: Color { theme.color(for: "symptoms") }
  private var mutator: SymptomsMutator { SeptenaServices.shared.symptomsMutator }

  private var isViewingToday: Bool { viewingDate == clock.today }

  private var activeDefinitions: [SymptomDefinitionEntity] {
    definitions.filter { !$0.archived }
  }

  private var dayEvents: [SymptomEventEntity] {
    events.filter { $0.date == viewingDate }
  }

  var body: some View {
    SectionDrawer(sectionKey: "symptoms",
                  quickAdd: DrawerQuickAdd("Log symptom", systemImage: "waveform.path.ecg") { creating = true },
                  currentDate: $viewingDate,
                  mode: $mode,
                  log: {
      DrawerSection("Log", padding: .none) {
        if dayEvents.isEmpty {
          DrawerEmptyLogLine(isToday: isViewingToday)
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
    }, patterns: {
      if events.isEmpty {
        DrawerSection("Patterns") {
          Text("Log a few symptoms and your severity trend and timing pattern appear here.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      } else {
        severityTrendSection
        rhythmSection
        bySymptomSection
      }
    })
    .tint(accent)
    .task { if viewingDate.isEmpty { viewingDate = clock.today } }
    .onChange(of: clock.today) { _, newToday in
      if isViewingToday { viewingDate = newToday }
    }
    .sectionReload(on: viewingDate, onDataChange: true,
                   forSections: ["symptoms"]) {}
    .drawerDetail(edit: $editing, create: $creating) { event in
      SymptomEventEditor(date: viewingDate,
                         definitions: activeDefinitions,
                         event: event)
    }
    // Tapping a symptom opens its per-symptom detail — severity heatmap, headline
    // stats, and recent occurrences. "Edit" there edits the symptom *type*
    // (rename/retag), mirroring how habit/supplement/chore detail "Edit" works.
    .adaptiveDetail(item: $viewingSymptom) { def in
      SymptomDetailView(
        symptomID: def.id,
        title: def.title,
        emoji: def.emoji,
        accent: accent,
        onEdit: { viewingSymptom = nil; editingDefinition = def }
      )
    }
    .sheet(item: $editingDefinition) { def in
      SymptomDefinitionEditor(definition: def)
    }
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

  // MARK: - Patterns

  private struct SeverityDay: Identifiable {
    let date: String
    let peak: Int
    var id: String { date }
  }

  /// Daily peak severity (0–10) over the trailing 30 days, gap-filled so empty
  /// days read as zero rather than vanishing.
  private var severityDays: [SeverityDay] {
    var peakByDate: [String: Int] = [:]
    for e in events { peakByDate[e.date] = max(peakByDate[e.date] ?? 0, e.severity) }
    return CompletionDateRange.lastNDates(30, now: clock.now).map {
      SeverityDay(date: $0, peak: peakByDate[$0] ?? 0)
    }
  }

  @ViewBuilder
  private var severityTrendSection: some View {
    let days = severityDays
    DrawerSection("Severity") {
      Chart(days) { d in
        BarMark(x: .value("Day", d.date),
                y: .value("Peak", d.peak),
                width: .ratio(0.6))
          .foregroundStyle(d.peak == 0 ? Color.secondary.opacity(0.2) : accent.opacity(0.85))
          .cornerRadius(2)
          .accessibilityLabel(d.date)
          .accessibilityValue(d.peak == 0 ? "no symptoms" : "peak severity \(d.peak) of 10")
      }
      .chartYScale(domain: 0...10)
      .chartXScale(domain: days.map(\.date))
      .chartXAxis(.hidden)
      .frame(height: 120)
    }
  }

  /// Trailing-30-day timing wheel — when symptoms tend to strike. The shared
  /// `TimeOfDayWheel` filters to its window, so passing every event is fine.
  private var wheelEvents: [TimeOfDayWheel.Event] {
    let todayStart = Calendar.current.startOfDay(for: clock.now)
    return events.compactMap {
      TimeOfDayWheel.Event(id: $0.id, occurredAt: $0.occurredAt,
                           todayStart: todayStart, windowDays: 30)
    }
  }

  private var nowFraction: Double {
    let c = Calendar.current.dateComponents([.hour, .minute], from: clock.now)
    return (Double(c.hour ?? 0) * 60 + Double(c.minute ?? 0)) / 1440
  }

  @ViewBuilder
  private var rhythmSection: some View {
    let wheel = wheelEvents
    if wheel.count >= 3 {
      DrawerSection("When symptoms occur", padding: .tight) {
        TimeOfDayWheel(events: wheel, accent: accent, windowDays: 30,
                       nowFraction: nowFraction, aggregate: true)
          .frame(maxWidth: .infinity)
      }
    }
  }

  // MARK: - Per-symptom breakdown

  private struct SymptomTally { let count: Int; let peak: Int }

  /// Event count + peak severity per symptomID, across all history.
  private var tallies: [String: SymptomTally] {
    var counts: [String: Int] = [:]
    var peaks: [String: Int] = [:]
    for e in events {
      counts[e.symptomID, default: 0] += 1
      peaks[e.symptomID] = max(peaks[e.symptomID] ?? 0, e.severity)
    }
    return counts.reduce(into: [:]) { acc, kv in
      acc[kv.key] = SymptomTally(count: kv.value, peak: peaks[kv.key] ?? 0)
    }
  }

  /// One tappable row per active symptom that has any history — tap to open its
  /// own severity heatmap. The shared `SectionBreakdownList` is the same drill-in
  /// surface habits/supplements/chores/medications use. Sorted most-logged first
  /// (symptom catalogs are uncurated and can be long).
  private var bySymptomSection: some View {
    let tally = tallies
    let rows = activeDefinitions
      .filter { (tally[$0.id]?.count ?? 0) > 0 }
      .sorted { (tally[$0.id]?.count ?? 0) > (tally[$1.id]?.count ?? 0) }
      .map { def -> BreakdownRow in
        let t = tally[def.id]!
        return BreakdownRow(id: def.id,
                            title: definitionTitle(def),
                            detail: "\(t.count) logged · peak \(t.peak)/10")
      }
    return SectionBreakdownList(
      title: "By symptom", rows: rows, accent: accent,
      selectedID: viewingSymptom?.id,
      onTap: { id in viewingSymptom = activeDefinitions.first { $0.id == id } }
    )
  }

  private func definitionTitle(_ def: SymptomDefinitionEntity) -> String {
    if let emoji = def.emoji, !emoji.isEmpty { return "\(emoji) \(def.title)" }
    return def.title
  }
}

private struct SymptomEventEditor: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?
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
  @State private var showingDefinitions = false
  @State private var showingAdvanced = false

  private var mutator: SymptomsMutator { SeptenaServices.shared.symptomsMutator }
  private var accent: Color { theme.color(for: "symptoms") }
  private var selectedDefinition: SymptomDefinitionEntity? {
    definitions.first { $0.id == symptomID }
  }

  var body: some View {
    AdaptiveEditScaffold(title: event == nil ? "Log Symptom" : "Edit Symptom",
                         accent: accent,
                         canSave: !symptomID.isEmpty,
                         onSave: save) {
      Form { formContent }
        .task { seed() }
        .onChange(of: symptomID) { _, _ in
          if event == nil, bodyRegion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            bodyRegion = selectedDefinition?.defaultBodyRegion ?? ""
          }
        }
        .sheet(isPresented: $showingDefinitions) {
          SymptomDefinitionsSheet()
        }
    }
  }

  @ViewBuilder
  private var formContent: some View {
    if definitions.isEmpty {
      ContentUnavailableView("No symptoms yet",
                             systemImage: "waveform.path.ecg",
                             description: Text("Add symptom definitions in Settings first."))
      Button {
        showingDefinitions = true
      } label: {
        Label("Create symptoms", systemImage: "plus")
      }
    } else {
      Section("Symptom") {
        Picker("Symptom", selection: $symptomID) {
          ForEach(definitions) { def in
            Text(def.title).tag(def.id)
          }
        }
        SteppedDatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Severity")
            Spacer()
            Text("\(Int(severity))/10")
              .font(.septenaMetric)
              .foregroundStyle(.secondary)
          }
          Slider(value: $severity, in: 0...10, step: 1)
        }
        TextField("Body region", text: $bodyRegion)
        TextField("Note", text: $note, axis: .vertical)
      }

      Section {
        DisclosureGroup("More context", isExpanded: $showingAdvanced) {
          TextField("Duration minutes", text: $duration)
            #if os(iOS)
            .keyboardType(.numberPad)
            #endif
          Picker("Side", selection: $side) {
            Text("None").tag("none")
            Text("Left").tag("left")
            Text("Right").tag("right")
            Text("Both").tag("both")
          }
          Picker("Quality", selection: $quality) {
            Text("Unset").tag("")
            Text("Ache").tag("ache")
            Text("Sharp").tag("sharp")
            Text("Burning").tag("burning")
            Text("Throbbing").tag("throbbing")
            Text("Pressure").tag("pressure")
            Text("Cramp").tag("cramp")
            Text("Tingling").tag("tingling")
          }
          TextField("Trigger", text: $triggerNote, axis: .vertical)
          TextField("Relief", text: $reliefNote, axis: .vertical)
        }
      }
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
      bodyRegion = definitions.first?.defaultBodyRegion ?? ""
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
      SectionLog.edit {
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
      }
    } else {
      SectionLog.newLog(section: "symptoms",
                        accent: accent,
                        announce: "Logged symptom.",
                        logCommit: logCommit) {
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
    }
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
  /// The definition being renamed, if any. Editing the title (or glyph/region)
  /// runs through `updateDefinition`, which keeps the frozen `id` — every logged
  /// event references that id, so the rename lands everywhere with no re-linking.
  @State private var editing: SymptomDefinitionEntity?
  @State private var showingAdvanced = false

  private var mutator: SymptomsMutator { SeptenaServices.shared.symptomsMutator }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          ForEach(SymptomStarter.all) { starter in
            starterRow(starter)
          }
        } header: {
          Text("Quick add")
        }
        Section("Custom symptom") {
          TextField("Name", text: $title)
          TextField("Default region", text: $region)
          DisclosureGroup("Advanced", isExpanded: $showingAdvanced) {
            LabeledContent("Glyph") { EmojiSlotPicker(emoji: $emoji) }
            TextField("Body system", text: $bodySystem)
          }
          Button {
            add()
          } label: {
            Label("Add", systemImage: "plus")
          }
          .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Section {
          ForEach(definitions) { def in
            HStack {
              // Tap the name to rename — the row's leading content is the edit
              // affordance; the trailing Archive button stays separate.
              Button {
                editing = def
              } label: {
                HStack {
                  if let emoji = def.emoji, !emoji.isEmpty {
                    Text(emoji)
                  }
                  VStack(alignment: .leading) {
                    Text(def.title).foregroundStyle(.primary)
                    if let system = def.bodySystem, !system.isEmpty {
                      Text(system).font(.caption).foregroundStyle(.secondary)
                    }
                  }
                  Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              Button(def.archived ? "Unarchive" : "Archive") {
                mutator.updateDefinition(id: def.id, archived: !def.archived)
              }
              .buttonStyle(.borderless)
            }
          }
        } header: {
          Text("Symptoms")
        } footer: {
          Text("Tap a symptom to rename it — the new name updates every logged entry automatically.")
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Symptoms")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .sheet(item: $editing) { def in
        SymptomDefinitionEditor(definition: def)
      }
    }
    .macSheetFrame()
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

  @ViewBuilder
  private func starterRow(_ starter: SymptomStarter) -> some View {
    let exists = definitions.contains { $0.title.localizedCaseInsensitiveCompare(starter.title) == .orderedSame }
    Button {
      guard !exists else { return }
      mutator.addDefinition(title: starter.title,
                            emoji: starter.emoji,
                            bodySystem: starter.bodySystem,
                            defaultBodyRegion: starter.region)
      Haptics.success()
    } label: {
      HStack(spacing: 12) {
        Text(starter.emoji).font(.title3).opacity(exists ? 0.4 : 1)
        VStack(alignment: .leading, spacing: 2) {
          Text(starter.title)
            .foregroundStyle(exists ? .secondary : .primary)
            .strikethrough(exists, color: .secondary)
          Text(starter.region)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: exists ? "checkmark.circle.fill" : "plus.circle")
          .foregroundStyle(exists ? Color.secondary : Color.accentColor)
      }
    }
    .buttonStyle(.plain)
    .disabled(exists)
  }
}

/// Rename / re-tag one symptom definition. Saving routes through
/// `updateDefinition`, which only changes the title/glyph/system/region and
/// leaves the definition's frozen `id` intact — so every `SymptomEvent` that
/// references that id (including the migrated gut rows) inherits the new name
/// centrally, with no re-linking and no data migration.
private struct SymptomDefinitionEditor: View {
  @Environment(\.dismiss) private var dismiss
  let definition: SymptomDefinitionEntity

  @State private var title: String
  @State private var emoji: String
  @State private var bodySystem: String
  @State private var region: String

  private var mutator: SymptomsMutator { SeptenaServices.shared.symptomsMutator }

  init(definition: SymptomDefinitionEntity) {
    self.definition = definition
    _title = State(initialValue: definition.title)
    _emoji = State(initialValue: definition.emoji ?? "")
    _bodySystem = State(initialValue: definition.bodySystem ?? "")
    _region = State(initialValue: definition.defaultBodyRegion ?? "")
  }

  private var trimmedTitle: String {
    title.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Symptom") {
          TextField("Name", text: $title)
          LabeledContent("Glyph") { EmojiSlotPicker(emoji: $emoji) }
          TextField("Body system", text: $bodySystem)
          TextField("Default region", text: $region)
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Edit Symptom")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { save() }
            .disabled(trimmedTitle.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
      }
    }
  }

  private func nilIfEmpty(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func save() {
    guard !trimmedTitle.isEmpty else { return }
    mutator.updateDefinition(id: definition.id,
                             title: trimmedTitle,
                             emoji: .some(nilIfEmpty(emoji)),
                             bodySystem: .some(nilIfEmpty(bodySystem)),
                             defaultBodyRegion: .some(nilIfEmpty(region)))
    dismiss()
  }
}
