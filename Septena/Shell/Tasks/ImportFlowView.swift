import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// The moving-in UI on the import engine (docs/MOVING_IN_SPEC.md §4, phase I1):
// source picker from `ImportSourceCatalog`, preview from `ImportPlanner`,
// apply with progress through `ImportApplier`, and the batch list from
// `ImportLedger` with Undo per batch. Every source runs the same flow; only
// the file help text knows a source by id.

// MARK: - Source picker

/// The "Move from another app" rows: every catalog source, built or planned.
struct ImportSourcesSection: View {
  private static let section = RegistrySettings.section("move_in", page: RegistrySettings.PageID.importExport)

  var body: some View {
    Section {
      ForEach(ImportSourceCatalog.all) { source in
        if source.state == .available, ImportSourceCatalog.adapter(id: source.id) != nil {
          NavigationLink {
            ImportFlowView(sourceID: source.id)
          } label: {
            Label(source.displayName, systemImage: RegistryIcons.sfSymbols["settings.import"] ?? "square.and.arrow.down")
          }
        } else {
          LabeledContent {
            Text(ImportCopy.plannedLabel(source))
              .foregroundStyle(.secondary)
          } label: {
            Label(source.displayName, systemImage: "clock")
              .foregroundStyle(.secondary)
          }
        }
      }
      NavigationLink {
        ImportBatchListView()
      } label: {
        Label("Past imports", systemImage: "clock.arrow.circlepath")
      }
    } header: {
      Text(Self.section?.header ?? "")
    } footer: {
      if let footer = Self.section?.footer { Text(footer) }
    }
  }
}

// MARK: - One source: pick, preview, apply

struct ImportFlowView: View {
  let sourceID: String

  @Environment(\.modelContext) private var modelContext
  @Environment(TaskMutator.self) private var taskMutator
  @Environment(AreasMutator.self) private var areasMutator
  @Environment(ProjectsMutator.self) private var projectsMutator

  @State private var options = ImportOptions()
  @State private var bundle: ImportBundle?
  @State private var existing: ImportExisting?
  @State private var plan: ImportPlan?
  @State private var result: ImportLedgerBatch?
  @State private var readError: String?
  @State private var planError: String?
  @State private var applyError: String?
  @State private var isReading = false
  @State private var isApplying = false
  @State private var progress: Double = 0
  @State private var showFileImporter = false
  @State private var pickedName: String?

  private var descriptor: ImportSourceDescriptor? {
    ImportSourceCatalog.all.first { $0.id == sourceID }
  }

  private var displayName: String { descriptor?.displayName ?? sourceID }

  var body: some View {
    Form {
      if let result {
        ImportResultSection(batch: result)
      } else if let plan {
        previewSections(plan)
      } else {
        pickSection
        if let planError {
          Section { Text(planError).foregroundStyle(.red).font(.callout) }
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(String(localized: "Import from \(displayName)"))
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .fileImporter(
      isPresented: $showFileImporter,
      allowedContentTypes: Self.fileTypes,
      allowsMultipleSelection: false
    ) { picked in
      switch picked {
      case .success(let urls):
        guard let url = urls.first else { return }
        Task { await read(url) }
      case .failure(let error):
        readError = error.localizedDescription
      }
    }
    .onChange(of: options) { _, _ in replan() }
    .disabled(isApplying || isReading)
  }

  // MARK: Pick

  private var pickSection: some View {
    Section {
      Button {
        showFileImporter = true
      } label: {
        Label(String(localized: "Choose \(displayName) file"), systemImage: "doc.badge.plus")
      }
      if isReading {
        ProgressView(String(localized: "Reading \(pickedName ?? "")"))
      } else if let pickedName {
        Text(pickedName).font(.callout).foregroundStyle(.secondary)
      }
      if let readError {
        Text(readError).foregroundStyle(.red).font(.callout)
      }
    } header: {
      Text("File")
    } footer: {
      fileHelp
    }
  }

  @ViewBuilder
  private var fileHelp: some View {
    if sourceID == ThingsImportSource.id {
      VStack(alignment: .leading, spacing: 8) {
        Text("Select main.sqlite or a Things Database.thingsdatabase bundle exported from Things.")
        Link("How to export from Things",
             destination: URL(string: "https://culturedcode.com/things/support/articles/2982272/")!)
        #if os(iOS)
        Text("On iPhone or iPad: Things → Settings → General → Diagnostics → Enter Code → 491348 → Send Things Database. Save the file, then pick it here.")
          .padding(.top, 4)
        #else
        Text("On Mac: quit Things, copy Things Database.thingsdatabase from ~/Library/Group Containers/JLMPQHK86H.com.culturedcode.ThingsMac/, then choose it here.")
          .padding(.top, 4)
        #endif
      }
    }
  }

  // MARK: Preview

  @ViewBuilder
  private func previewSections(_ plan: ImportPlan) -> some View {
    ImportReportSections(report: plan.report, descriptor: descriptor)
    optionsSection
    applySection(plan)
  }

  private var optionsSection: some View {
    Section {
      Toggle("Include completed", isOn: $options.includeCompleted)
      Toggle("Include cancelled", isOn: $options.includeCancelled)
      Toggle("Include trashed", isOn: $options.includeTrashed)
      Toggle("Match areas and projects by name", isOn: $options.mergeMatchingTitles)
      Toggle("Write checklists into notes", isOn: $options.checklistIntoNotes)
      Toggle("Write tags into notes", isOn: $options.tagsIntoNotes)
      Toggle("Bring back items you deleted", isOn: $options.reimportDeleted)
    } header: {
      Text("Options")
    } footer: {
      Text("A matched area or project takes the imported items into the one you already have. Items imported before stay skipped unless you deleted them and turn on Bring back.")
    }
  }

  @ViewBuilder
  private func applySection(_ plan: ImportPlan) -> some View {
    if let applyError {
      Section { Text(applyError).foregroundStyle(.red).font(.callout) }
    }
    Section {
      if isApplying {
        ProgressView(value: progress) { Text("Importing") }
      } else {
        let count = plan.report.tasksToCreate
        Button {
          Task { await apply(plan) }
        } label: {
          Text(count == 1 ? String(localized: "Import 1 task") : String(localized: "Import \(count) tasks"))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!Self.hasWork(plan))

        Button("Choose a different file") {
          reset()
          showFileImporter = true
        }
      }
    }
  }

  private static func hasWork(_ plan: ImportPlan) -> Bool {
    !plan.areas.filter { $0.action == .create }.isEmpty
      || !plan.projects.filter { $0.action == .create }.isEmpty
      || !plan.headings.isEmpty || !plan.tasks.isEmpty
  }

  // MARK: Actions

  private func read(_ url: URL) async {
    guard let adapter = ImportSourceCatalog.adapter(id: sourceID) else { return }
    readError = nil
    planError = nil
    pickedName = url.lastPathComponent
    isReading = true
    let accessed = url.startAccessingSecurityScopedResource()
    defer {
      if accessed { url.stopAccessingSecurityScopedResource() }
      isReading = false
    }
    do {
      bundle = try await adapter.read(ImportReadRequest(fileURL: url))
      existing = ImportApplier.existing(context: modelContext)
      replan()
    } catch {
      readError = error.localizedDescription
      bundle = nil
      plan = nil
    }
  }

  private func replan() {
    guard let bundle, let existing else { return }
    do {
      plan = try ImportPlanner.plan(bundle: bundle, existing: existing, options: options)
      planError = nil
    } catch {
      plan = nil
      planError = error.localizedDescription
    }
  }

  private func apply(_ plan: ImportPlan) async {
    applyError = nil
    isApplying = true
    progress = 0
    await SeptenaServices.shared.start()
    do {
      result = try await ImportApplier.apply(
        plan: plan,
        context: modelContext,
        taskMutator: taskMutator,
        areasMutator: areasMutator,
        projectsMutator: projectsMutator
      ) { value in
        progress = value
      }
      TaskNotices.completeStep(.importTasks)
    } catch {
      // A partial batch is in the ledger; running the import again resumes it.
      applyError = error.localizedDescription
      existing = ImportApplier.existing(context: modelContext)
      replan()
    }
    isApplying = false
  }

  private func reset() {
    bundle = nil
    existing = nil
    plan = nil
    result = nil
    readError = nil
    planError = nil
    applyError = nil
    pickedName = nil
  }

  private static var fileTypes: [UTType] {
    var types: [UTType] = [.data, .folder]
    for ext in ["sqlite", "sqlite3", "thingsdatabase"] {
      if let type = UTType(filenameExtension: ext) { types.append(type) }
    }
    return types
  }
}

// MARK: - Preview report

/// Counts, field dispositions, dangling references and losses for one plan.
struct ImportReportSections: View {
  let report: ImportReport
  let descriptor: ImportSourceDescriptor?

  private var unsupportedCoverage: [ImportCoverage] {
    descriptor?.coverage.filter { $0.disposition == .unsupported } ?? []
  }

  var body: some View {
    Section("What comes in") {
      ForEach(ImportEntity.allCases, id: \.self) { entity in
        if let counts = report.counts[entity], counts.inSource > 0 {
          VStack(alignment: .leading, spacing: 2) {
            Text(ImportCopy.entityName(entity))
            Text(ImportCopy.countsLine(counts))
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
      }
      if report.danglingReferences > 0 {
        Text(report.danglingReferences == 1
             ? String(localized: "1 task points to a project or section that is not in the file. It lands in its area or the Inbox.")
             : String(localized: "\(report.danglingReferences) tasks point to a project or section that is not in the file. They land in their area or the Inbox."))
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }

    if !report.fields.isEmpty {
      Section("Fields") {
        ForEach(report.fields, id: \.field) { field in
          VStack(alignment: .leading, spacing: 2) {
            LabeledContent(ImportCopy.fieldName(field.field)) {
              Text("\(ImportCopy.dispositionName(field.disposition)), \(field.count)")
            }
            if let note = field.note {
              Text(note).font(.callout).foregroundStyle(.secondary)
            }
          }
        }
      }
    }

    if !report.adapterUnsupported.isEmpty || !unsupportedCoverage.isEmpty {
      Section {
        ForEach(Array(report.adapterUnsupported.enumerated()), id: \.offset) { _, loss in
          LabeledContent(loss.note ?? "\(loss.entity) \(loss.field)") {
            Text("\(loss.count)")
          }
        }
        ForEach(unsupportedCoverage, id: \.field) { item in
          VStack(alignment: .leading, spacing: 2) {
            Text(ImportCopy.fieldName(item.field))
            if let note = item.note {
              Text(note).font(.callout).foregroundStyle(.secondary)
            }
          }
        }
      } header: {
        Text("Not imported")
      }
    }
  }
}

// MARK: - Apply result

/// Planned against written counts for a finished (or stopped) batch.
struct ImportResultSection: View {
  let batch: ImportLedgerBatch

  var body: some View {
    Section {
      ForEach(ImportEntity.allCases, id: \.self) { entity in
        let planned = batch.report.counts[entity].map { $0.create + $0.merge } ?? 0
        let items = batch.items.filter { $0.entity == entity }
        let created = items.filter { $0.action == .create }.count
        let merged = items.filter { $0.action == .merge }.count
        if planned > 0 || !items.isEmpty {
          LabeledContent(ImportCopy.entityName(entity)) {
            Text(ImportCopy.resultLine(created: created, merged: merged, planned: planned))
          }
        }
      }
      if let error = batch.lastError {
        Text(error).foregroundStyle(.red).font(.callout)
      }
    } header: {
      Text(batch.state == .partial
           ? String(localized: "Import stopped early")
           : String(localized: "Import complete"))
    } footer: {
      Text(batch.state == .partial
           ? String(localized: "Run the import again with the same file to finish it. Items already imported are skipped.")
           : String(localized: "The other app was not changed. You can undo this import in Past imports."))
    }
  }
}

// MARK: - Past imports

struct ImportBatchListView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(TaskMutator.self) private var taskMutator
  @Environment(AreasMutator.self) private var areasMutator
  @Environment(ProjectsMutator.self) private var projectsMutator

  @State private var batches: [ImportLedgerBatch] = []
  @State private var loaded = false
  @State private var undoResults: [String: ImportUndoResult] = [:]
  @State private var confirming: ImportLedgerBatch?
  @State private var undoingID: String?
  @State private var undoError: String?

  var body: some View {
    Form {
      if let undoError {
        Section { Text(undoError).foregroundStyle(.red).font(.callout) }
      }
      if loaded, batches.isEmpty {
        Section { Text("No imports on this device yet.").foregroundStyle(.secondary) }
      }
      ForEach(batches) { batch in
        Section { batchRow(batch) }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Past imports")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .task { await reload() }
    .confirmationDialog(
      "Undo this import?",
      isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
      presenting: confirming
    ) { batch in
      Button("Undo Import", role: .destructive) {
        Task { await undo(batch) }
      }
    } message: { _ in
      Text("What this import created moves to Recently Deleted. Anything you changed since, and areas or projects that now hold your own tasks, stay.")
    }
  }

  @ViewBuilder
  private func batchRow(_ batch: ImportLedgerBatch) -> some View {
    let name = ImportSourceCatalog.all.first { $0.id == batch.source.app }?.displayName ?? batch.source.app
    VStack(alignment: .leading, spacing: 4) {
      Text(name).font(.headline)
      if batch.isLegacy {
        Text("Imported before Septena kept a record of imports. Septena remembers these items so a new import skips them. This import cannot be undone.")
          .font(.callout).foregroundStyle(.secondary)
      } else {
        Text(batch.startedAt, format: .dateTime.day().month().year().hour().minute())
          .font(.callout).foregroundStyle(.secondary)
        Text(ImportCopy.batchCounts(batch)).font(.callout)
      }
      if let state = ImportCopy.stateLine(batch, undoResult: undoResults[batch.id]) {
        Text(state).font(.callout).foregroundStyle(.secondary)
      }
    }
    if !batch.isLegacy, batch.state != .undone {
      if undoingID == batch.id {
        ProgressView()
      } else {
        Button("Undo Import", role: .destructive) { confirming = batch }
          .disabled(undoingID != nil)
      }
    }
  }

  private func reload() async {
    ImportLegacyThingsLineage.migrateIfNeeded(context: modelContext)
    // Batches hold the whole bundle; decode them off the main actor.
    batches = await Task.detached(priority: .userInitiated) { ImportLedger.all() }.value
    loaded = true
  }

  private func undo(_ batch: ImportLedgerBatch) async {
    undoError = nil
    undoingID = batch.id
    await SeptenaServices.shared.start()
    do {
      undoResults[batch.id] = try await ImportApplier.undo(
        batchID: batch.id, context: modelContext, taskMutator: taskMutator,
        areasMutator: areasMutator, projectsMutator: projectsMutator)
    } catch {
      undoError = error.localizedDescription
    }
    undoingID = nil
    await reload()
  }
}

// MARK: - Copy

/// Labels for engine values. The engine keeps raw field keys; the UI names them.
enum ImportCopy {
  static func plannedLabel(_ source: ImportSourceDescriptor) -> String {
    if let issue = source.issue { return String(localized: "Planned, #\(issue)") }
    return String(localized: "Planned")
  }

  static func entityName(_ entity: ImportEntity) -> String {
    switch entity {
    case .area: String(localized: "Areas")
    case .project: String(localized: "Projects")
    case .heading: String(localized: "Sections")
    case .task: String(localized: "Tasks")
    }
  }

  static func countsLine(_ c: ImportEntityCounts) -> String {
    var parts: [String] = []
    if c.create > 0 { parts.append(String(localized: "\(c.create) new")) }
    if c.merge > 0 { parts.append(String(localized: "\(c.merge) matched to yours")) }
    if c.alreadyImported > 0 { parts.append(String(localized: "\(c.alreadyImported) already imported")) }
    if c.filtered > 0 { parts.append(String(localized: "\(c.filtered) left out")) }
    return parts.isEmpty ? String(localized: "Nothing to add") : parts.joined(separator: ", ")
  }

  static func resultLine(created: Int, merged: Int, planned: Int) -> String {
    merged > 0
      ? String(localized: "\(created) created, \(merged) matched, of \(planned) planned")
      : String(localized: "\(created) created of \(planned) planned")
  }

  static func batchCounts(_ batch: ImportLedgerBatch) -> String {
    let tasks = batch.items.filter { $0.entity == .task && $0.action == .create }.count
    let containers = batch.items.filter { ($0.entity == .area || $0.entity == .project) && $0.action == .create }.count
    return String(localized: "\(tasks) tasks, \(containers) areas and projects created")
  }

  static func stateLine(_ batch: ImportLedgerBatch, undoResult: ImportUndoResult?) -> String? {
    switch batch.state {
    case .applying, .partial:
      return String(localized: "Stopped early. Run the import again to finish it.")
    case .applied:
      return nil
    case .undone:
      if let r = undoResult {
        let kept = r.keptEdited + r.keptNonEmpty
        return kept > 0
          ? String(localized: "Undone. \(r.deleted) removed, \(kept) kept because you changed them or they hold your own tasks.")
          : String(localized: "Undone. \(r.deleted) removed.")
      }
      let kept = batch.keptOnUndo?.count ?? 0
      return kept > 0
        ? String(localized: "Undone. \(kept) kept because you changed them or they hold your own tasks.")
        : String(localized: "Undone.")
    }
  }

  static func dispositionName(_ d: ImportFieldDisposition) -> String {
    switch d {
    case .mapped: String(localized: "Imported")
    case .transformed: String(localized: "Changed to fit")
    case .preserved: String(localized: "Kept with the import")
    case .unsupported: String(localized: "Not imported")
    }
  }

  static func fieldName(_ field: String) -> String {
    switch field {
    case "checklist": String(localized: "Checklists")
    case "tags": String(localized: "Tags")
    case "starred": String(localized: "Stars")
    case "sourceURL": String(localized: "Links")
    case "completedAt": String(localized: "Completion dates")
    case "reminder": String(localized: "Reminders")
    case "recurrence": String(localized: "Repeats")
    case "someday": String(localized: "Someday (now Anytime)")
    case "reminderTime": String(localized: "Reminder times")
    case "repeating": String(localized: "Repeating tasks")
    case "trashedAreasProjects": String(localized: "Trashed areas and projects")
    default: field
    }
  }
}
