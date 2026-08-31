import SwiftData
import SwiftUI

struct MedicationsDestinationView: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(DayClock.self) private var clock

  @Query(sort: \MedicationDefinitionEntity.sortIndex)
  private var definitions: [MedicationDefinitionEntity]
  @Query(sort: \MedicationDoseEventEntity.occurredAt, order: .reverse)
  private var doses: [MedicationDoseEventEntity]

  @State private var viewingDate = ""
  @State private var editing: MedicationDoseEventEntity?
  @State private var creating = false
  /// Medication whose per-item detail (adherence heatmap + history) is open.
  @State private var viewingMed: MedicationDefinitionEntity?
  /// Whether the medication-type management sheet is open (from detail "Edit").
  @State private var managingDefs = false
  // Medications is an editable dual section: Log = the day's dose list
  // (time-travelable); Patterns = adherence heatmap (taken vs daily target).
  // Default Log — the dose list is what you act on.
  @State private var mode: DrawerMode = .remembered(for: "medications", default: .log)

  private var accent: Color { theme.color(for: "medications") }
  private var mutator: MedicationsMutator { SeptenaServices.shared.medicationsMutator }

  private var isViewingToday: Bool { viewingDate == clock.today }

  private var activeDefinitions: [MedicationDefinitionEntity] {
    definitions.filter { !$0.archived }
  }

  /// Sum of daily-schedule dose targets across active meds — the adherence
  /// denominator. As-needed meds carry no target, so they don't inflate it.
  private var dailyDoseTarget: Int {
    activeDefinitions
      .filter { $0.scheduleKind == "daily" }
      .reduce(0) { $0 + ($1.targetDosesPerDay ?? 1) }
  }

  /// Daily taken-vs-target series for the adherence heatmap (trailing ~17
  /// weeks). When no daily target exists (only as-needed meds), each logged day
  /// reads as "full" so the heatmap still shows when meds were taken.
  private var adherenceDays: [CompletionDay] {
    var takenByDate: [String: Int] = [:]
    for d in doses where d.status == "taken" { takenByDate[d.date, default: 0] += 1 }
    let target = dailyDoseTarget
    return CompletionDateRange.lastNDates(119, now: clock.now).map { iso in
      let done = takenByDate[iso] ?? 0
      let total = target > 0 ? target : done
      return CompletionDay(date: iso, done: min(done, max(total, 0)), total: total)
    }
  }

  private var dayDoses: [MedicationDoseEventEntity] {
    doses.filter { $0.date == viewingDate }
  }

  var body: some View {
    SectionDrawer(sectionKey: "medications",
                  quickAdd: DrawerQuickAdd("Log dose") { creating = true },
                  currentDate: $viewingDate,
                  mode: $mode,
                  log: {
      DrawerSection("Doses", padding: .none) {
        if dayDoses.isEmpty {
          DrawerEmptyLogLine(isToday: isViewingToday)
        } else {
          ForEach(dayDoses) { dose in
            LogEntryRow(
              title: title(for: dose),
              detail: detail(for: dose),
              trailing: EventTimestamp.hhmm(from: dose.occurredAt),
              tint: accent,
              isSelected: editing?.id == dose.id,
              onEdit: { editing = dose },
              onDelete: { delete(dose) }
            )
          }
        }
      }
    }, patterns: {
      CompletionPatternsSection(title: "Adherence", accent: accent, days: adherenceDays)
      byMedicationSection
    })
    .tint(accent)
    .task { if viewingDate.isEmpty { viewingDate = clock.today } }
    .onChange(of: clock.today) { _, newToday in
      if isViewingToday { viewingDate = newToday }
    }
    .sectionReload(on: viewingDate, onDataChange: true,
                   forSections: ["medications"]) {}
    .drawerDetail(edit: $editing, create: $creating) { dose in
      MedicationDoseEditor(date: viewingDate,
                           definitions: activeDefinitions,
                           dose: dose)
    }
    // Tapping a medication opens its per-item detail — adherence heatmap, taken
    // count, recent doses. "Edit" there opens medication-type management
    // (rename/archive), mirroring how habit/supplement/chore detail "Edit" works.
    .adaptiveDetail(item: $viewingMed) { def in
      LoggableDetailView(
        title: def.title,
        emoji: nil,
        accent: accent,
        doneVerb: "taken",
        fetch: { ChecklistMirror.medicationTakenDates(context: $0, medicationID: def.id) },
        onEdit: { viewingMed = nil; managingDefs = true }
      )
    }
    .sheet(isPresented: $managingDefs) {
      MedicationDefinitionsSheet()
    }
  }

  /// Per-medication drill-in for Patterns mode — every active med, tap to open
  /// its adherence heatmap. Subtitle counts taken doses from the in-memory
  /// dose list, so no extra query.
  private var byMedicationSection: some View {
    var takenByMed: [String: Int] = [:]
    for d in doses where d.status == "taken" { takenByMed[d.medicationID, default: 0] += 1 }
    let rows = activeDefinitions.map { def in
      BreakdownRow(id: def.id,
                   title: def.title,
                   detail: "\(takenByMed[def.id] ?? 0) taken")
    }
    return SectionBreakdownList(
      title: "By medication", rows: rows, accent: accent,
      selectedID: viewingMed?.id,
      onTap: { id in viewingMed = activeDefinitions.first { $0.id == id } }
    )
  }

  private func definition(for dose: MedicationDoseEventEntity) -> MedicationDefinitionEntity? {
    definitions.first { $0.id == dose.medicationID }
  }

  private func title(for dose: MedicationDoseEventEntity) -> String {
    definition(for: dose)?.title ?? "Medication"
  }

  private func detail(for dose: MedicationDoseEventEntity) -> String? {
    var parts: [String] = [dose.status.capitalized]
    if let value = dose.doseValue {
      let unit = dose.doseUnit.map { " \($0)" } ?? ""
      parts.append("\(value.decimalString(2))\(unit)")
    } else if let def = definition(for: dose),
              let value = def.defaultDoseValue {
      let unit = def.defaultDoseUnit.map { " \($0)" } ?? ""
      parts.append("\(value.decimalString(2))\(unit)")
    }
    if let reason = dose.reason, !reason.isEmpty { parts.append(reason) }
    if let effect = dose.effectNote, !effect.isEmpty { parts.append(effect) }
    if let side = dose.sideEffectNote, !side.isEmpty { parts.append("side effect: \(side)") }
    return parts.joined(separator: " · ")
  }

  private func delete(_ dose: MedicationDoseEventEntity) {
    mutator.deleteDose(id: dose.id)
    Haptics.warning()
  }
}

private struct MedicationDoseEditor: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?
  let date: String
  let definitions: [MedicationDefinitionEntity]
  let dose: MedicationDoseEventEntity?

  @State private var medicationID = ""
  @State private var time = Date()
  @State private var status = "taken"
  @State private var doseValue = ""
  @State private var doseUnit = ""
  @State private var reason = ""
  @State private var effectNote = ""
  @State private var sideEffectNote = ""
  @State private var showingDefinitions = false
  @State private var showingAdvanced = false

  private var mutator: MedicationsMutator { SeptenaServices.shared.medicationsMutator }
  private var accent: Color { theme.color(for: "medications") }
  private var selectedDefinition: MedicationDefinitionEntity? {
    definitions.first { $0.id == medicationID }
  }

  var body: some View {
    AdaptiveEditScaffold(title: dose == nil ? "Log Dose" : "Edit Dose",
                         accent: accent,
                         canSave: !medicationID.isEmpty,
                         onSave: save) {
      Form { formContent }
        .task { seed() }
        .onChange(of: medicationID) { _, _ in
          guard dose == nil, let def = selectedDefinition else { return }
          doseValue = def.defaultDoseValue.map { $0.decimalString(2) } ?? ""
          doseUnit = def.defaultDoseUnit ?? ""
        }
        .sheet(isPresented: $showingDefinitions) {
          MedicationDefinitionsSheet()
        }
    }
  }

  @ViewBuilder
  private var formContent: some View {
    if definitions.isEmpty {
      ContentUnavailableView("No medications yet",
                             systemImage: "cross.case",
                             description: Text("Add medications in Settings first."))
      Button {
        showingDefinitions = true
      } label: {
        Label("Create medications", systemImage: "plus")
      }
    } else {
      Section("Dose") {
        Picker("Medication", selection: $medicationID) {
          ForEach(definitions) { def in
            Text(def.title).tag(def.id)
          }
        }
        SteppedDatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
        Picker("Status", selection: $status) {
          Text("Taken").tag("taken")
          Text("Skipped").tag("skipped")
          Text("Missed").tag("missed")
        }
        .pickerStyle(.segmented)
        TextField("Dose value", text: $doseValue)
          #if os(iOS)
          .keyboardType(.decimalPad)
          #endif
        TextField("Dose unit", text: $doseUnit)
      }

      Section {
        DisclosureGroup("Notes and effects", isExpanded: $showingAdvanced) {
          TextField(status == "taken" ? "Context" : "Reason", text: $reason, axis: .vertical)
          TextField("Effect", text: $effectNote, axis: .vertical)
          TextField("Side effect", text: $sideEffectNote, axis: .vertical)
        }
      }
    }
  }

  private func seed() {
    if let dose {
      medicationID = dose.medicationID
      time = dose.occurredAt == .distantPast ? Date() : dose.occurredAt
      status = dose.status
      doseValue = dose.doseValue.map { $0.decimalString(2) } ?? ""
      doseUnit = dose.doseUnit ?? ""
      reason = dose.reason ?? ""
      effectNote = dose.effectNote ?? ""
      sideEffectNote = dose.sideEffectNote ?? ""
    } else if medicationID.isEmpty {
      let def = definitions.first
      medicationID = def?.id ?? ""
      doseValue = def?.defaultDoseValue.map { $0.decimalString(2) } ?? ""
      doseUnit = def?.defaultDoseUnit ?? ""
    }
  }

  private func nilIfEmpty(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func save() {
    let timeString = EventTimestamp.hhmm(from: time)
    let value = Double(doseValue.trimmingCharacters(in: .whitespacesAndNewlines))
    if let dose {
      SectionLog.edit {
        mutator.updateDose(id: dose.id,
                           date: date,
                           time: timeString,
                           medicationID: medicationID,
                           status: status,
                           doseValue: value,
                           doseUnit: nilIfEmpty(doseUnit),
                           reason: nilIfEmpty(reason),
                           effectNote: nilIfEmpty(effectNote),
                           sideEffectNote: nilIfEmpty(sideEffectNote))
      }
    } else {
      SectionLog.newLog(section: "medications",
                        accent: accent,
                        announce: "Logged medication dose.",
                        logCommit: logCommit) {
        mutator.addDose(medicationID: medicationID,
                        date: date,
                        time: timeString,
                        status: status,
                        doseValue: value,
                        doseUnit: nilIfEmpty(doseUnit),
                        reason: nilIfEmpty(reason),
                        effectNote: nilIfEmpty(effectNote),
                        sideEffectNote: nilIfEmpty(sideEffectNote))
      }
    }
  }
}

struct MedicationDefinitionsSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Query(sort: \MedicationDefinitionEntity.sortIndex)
  private var definitions: [MedicationDefinitionEntity]

  @State private var title = ""
  @State private var genericName = ""
  @State private var form = ""
  @State private var route = ""
  @State private var strengthValue = ""
  @State private var strengthUnit = ""
  @State private var defaultDoseValue = ""
  @State private var defaultDoseUnit = ""
  @State private var bucket = "anytime"
  @State private var scheduleKind = "daily"
  @State private var targetDosesPerDay = "1"
  @State private var instructions = ""
  @State private var showingAdvanced = false

  private var mutator: MedicationsMutator { SeptenaServices.shared.medicationsMutator }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          ForEach(MedicationStarter.all) { starter in
            starterRow(starter)
          }
        } header: {
          Text("Quick add")
        } footer: {
          Text("Use custom medication for exact prescription names and strengths.")
        }
        Section("Custom medication") {
          TextField("Name", text: $title)
          TextField("Default dose value", text: $defaultDoseValue)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
          TextField("Default dose unit", text: $defaultDoseUnit)
          Picker("Schedule", selection: $scheduleKind) {
            Text("Daily").tag("daily")
            Text("As needed").tag("asNeeded")
          }
          .pickerStyle(.segmented)
          if scheduleKind == "daily" {
            TextField("Doses per day", text: $targetDosesPerDay)
              #if os(iOS)
              .keyboardType(.numberPad)
              #endif
          }
          Picker("Bucket", selection: $bucket) {
            Text(DayBucket.label(forKey: DayBucket.anytimeKey)).tag(DayBucket.anytimeKey)
            ForEach(DayBucket.allCases) { b in
              Text(b.title).tag(b.rawValue)
            }
          }
          DisclosureGroup("Advanced", isExpanded: $showingAdvanced) {
            TextField("Generic name", text: $genericName)
            TextField("Form", text: $form)
            TextField("Route", text: $route)
            TextField("Strength value", text: $strengthValue)
              #if os(iOS)
              .keyboardType(.decimalPad)
              #endif
            TextField("Strength unit", text: $strengthUnit)
            TextField("Instructions", text: $instructions, axis: .vertical)
          }
          Button {
            add()
          } label: {
            Label("Add", systemImage: "plus")
          }
          .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Section("Medications") {
          ForEach(definitions) { def in
            HStack {
              VStack(alignment: .leading) {
                Text(def.title)
                Text(subtitle(def))
                  .font(.caption)
                  .foregroundStyle(.secondary)
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
      .formStyle(.grouped)
      .navigationTitle("Medications")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .macSheetFrame()
  }

  private func nilIfEmpty(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func subtitle(_ def: MedicationDefinitionEntity) -> String {
    var parts: [String] = []
    if let generic = def.genericName, !generic.isEmpty { parts.append(generic) }
    if let value = def.defaultDoseValue {
      let unit = def.defaultDoseUnit.map { " \($0)" } ?? ""
      parts.append("\(value.decimalString(2))\(unit)")
    }
    parts.append(def.scheduleKind == "asNeeded" ? "as needed" : "daily")
    if let bucket = def.bucket, !bucket.isEmpty { parts.append(DayBucket.label(forKey: bucket)) }
    return parts.isEmpty ? "No default dose" : parts.joined(separator: " · ")
  }

  private func add() {
    mutator.addDefinition(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                          genericName: nilIfEmpty(genericName),
                          form: nilIfEmpty(form),
                          route: nilIfEmpty(route),
                          strengthValue: Double(strengthValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                          strengthUnit: nilIfEmpty(strengthUnit),
                          defaultDoseValue: Double(defaultDoseValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                          defaultDoseUnit: nilIfEmpty(defaultDoseUnit),
                          bucket: bucket == "anytime" ? nil : bucket,
                          scheduleKind: scheduleKind,
                          targetDosesPerDay: scheduleKind == "daily" ? Int(targetDosesPerDay.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1 : nil,
                          instructions: nilIfEmpty(instructions))
    title = ""
    genericName = ""
    form = ""
    route = ""
    strengthValue = ""
    strengthUnit = ""
    defaultDoseValue = ""
    defaultDoseUnit = ""
    bucket = "anytime"
    scheduleKind = "daily"
    targetDosesPerDay = "1"
    instructions = ""
  }

  @ViewBuilder
  private func starterRow(_ starter: MedicationStarter) -> some View {
    let exists = definitions.contains { $0.title.localizedCaseInsensitiveCompare(starter.title) == .orderedSame }
    Button {
      guard !exists else { return }
      mutator.addDefinition(title: starter.title,
                            genericName: starter.genericName,
                            form: starter.form,
                            route: starter.route,
                            defaultDoseValue: starter.doseValue,
                            defaultDoseUnit: starter.doseUnit,
                            bucket: starter.bucket,
                            scheduleKind: starter.scheduleKind,
                            targetDosesPerDay: starter.scheduleKind == "daily" ? 1 : nil)
      Haptics.success()
    } label: {
      HStack(spacing: 12) {
        Image(systemName: "pills")
          .font(.title3)
          .foregroundStyle(exists ? .secondary : Color.accentColor)
        VStack(alignment: .leading, spacing: 2) {
          Text(starter.title)
            .foregroundStyle(exists ? .secondary : .primary)
            .strikethrough(exists, color: .secondary)
          Text(starterSummary(starter))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: exists ? "checkmark.circle.fill" : "plus.circle")
          .foregroundStyle(exists ? Color.secondary : Color.accentColor)
      }
      // `.plain` opts the row out of the list cell's tap target, so without
      // this the Spacer and trailing gaps are dead zones.
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(exists)
  }

  private func starterSummary(_ starter: MedicationStarter) -> String {
    var parts = [starter.form, starter.route]
    if let value = starter.doseValue {
      parts.append("\(value.decimalString(2)) \(starter.doseUnit ?? "")".trimmingCharacters(in: .whitespaces))
    } else if let unit = starter.doseUnit {
      parts.append(unit)
    }
    if let bucket = starter.bucket { parts.append(bucket) }
    parts.append(starter.scheduleKind == "asNeeded" ? "as needed" : "daily")
    return parts.joined(separator: " · ")
  }
}
