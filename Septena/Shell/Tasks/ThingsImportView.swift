import SwiftUI
import UniformTypeIdentifiers

// One-shot migration wizard: Things SQLite → Septena tasks via mutators.

struct ThingsImportView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(TaskMutator.self) private var taskMutator
  @Environment(AreasMutator.self) private var areasMutator
  @Environment(ProjectsMutator.self) private var projectsMutator
  @Environment(SectionTheme.self) private var theme

  @State private var options = ThingsImportOptions()
  @State private var snapshot: ThingsDatabaseSnapshot?
  @State private var plan: ThingsImportPlan?
  @State private var collisionOverrides: [String: ThingsCollisionAction] = [:]
  @State private var parseError: String?
  @State private var applyError: String?
  @State private var applyResult: ThingsImportApplyResult?
  @State private var isApplying = false
  @State private var applyProgress: Double = 0
  @State private var showFileImporter = false
  @State private var pickedDatabaseURL: URL?
  @State private var scratchpadURL: URL?

  var body: some View {
    Form {
      if let applyResult {
        resultSection(applyResult)
      } else if let plan, snapshot != nil {
        previewSection(plan)
      } else {
        sourceSection
        optionsSection
        if let parseError {
          Section {
            Text(parseError)
              .foregroundStyle(.red)
              .font(.callout)
          }
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Import from Things")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .fileImporter(
      isPresented: $showFileImporter,
      allowedContentTypes: Self.importContentTypes,
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        guard let url = urls.first else { return }
        loadDatabase(from: url)
      case .failure(let error):
        parseError = error.localizedDescription
      }
    }
    .disabled(isApplying)
  }

  // MARK: - Source

  private var sourceSection: some View {
    Section {
      Button {
        showFileImporter = true
      } label: {
        Label("Choose Things database…", systemImage: "doc.badge.plus")
      }

      if let pickedDatabaseURL {
        Text(pickedDatabaseURL.lastPathComponent)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    } header: {
      Text("Database file")
    } footer: {
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

  private var optionsSection: some View {
    Section {
      Toggle("Include completed", isOn: $options.includeCompleted)
      Toggle("Include cancelled", isOn: $options.includeCancelled)
      Toggle("Include trashed", isOn: $options.includeTrashed)
      Toggle("Merge matching area & project names", isOn: $options.mergeMatchingTitles)
      Toggle("Append tags to notes", isOn: $options.appendTagsToNotes)
      Toggle("Append checklists to notes", isOn: $options.appendChecklistToNotes)
      Toggle("Re-import previously deleted tasks", isOn: $options.reimportDeleted)
    } header: {
      Text("Options")
    } footer: {
      Text("Things tags and headings are not first-class in Septena. Tasks filed in a project without a today, scheduled, or deadline date land in Inbox — preview shows where items will appear.")
    }
    .onChange(of: options) { _, _ in
      if scratchpadURL != nil { rebuildPlanFromScratchpad() }
      else if let url = pickedDatabaseURL { loadDatabase(from: url) }
    }
  }

  // MARK: - Preview

  @ViewBuilder
  private func previewSection(_ plan: ThingsImportPlan) -> some View {
    Section("Summary") {
      LabeledContent("Areas to create", value: "\(plan.areasToCreate.count)")
      LabeledContent("Projects to create", value: "\(plan.projectsToCreate.count)")
      LabeledContent("Tasks to import", value: "\(plan.tasksToImport.count)")
      if plan.skippedDuplicates > 0 {
        LabeledContent("Skipped (already imported)", value: "\(plan.skippedDuplicates)")
      }
    }

    Section("Where tasks will land") {
      LabeledContent("Inbox", value: "\(plan.viewCounts.inbox)")
      LabeledContent("Today", value: "\(plan.viewCounts.today)")
      LabeledContent("Upcoming", value: "\(plan.viewCounts.upcoming)")
      LabeledContent("Anytime", value: "\(plan.viewCounts.anytime)")
      if options.includeCompleted {
        LabeledContent("Logbook", value: "\(plan.viewCounts.logbook)")
      }
      if options.includeTrashed {
        LabeledContent("Recently Deleted", value: "\(plan.viewCounts.recentlyDeleted)")
      }
    }

    if !plan.collisions.isEmpty {
      Section {
        ForEach(plan.collisions) { collision in
          collisionRow(collision)
        }
      } header: {
        Text("Name matches")
      } footer: {
        Text("Merge reuses your existing area or project. Create new adds a separate copy.")
      }
    }

    if let applyError {
      Section {
        Text(applyError).foregroundStyle(.red).font(.callout)
      }
    }

    Section {
      if isApplying {
        ProgressView(value: applyProgress) {
          Text("Importing…")
        }
      } else {
        Button {
          Task { await runImport(plan) }
        } label: {
          Text("Import \(plan.tasksToImport.count) task\(plan.tasksToImport.count == 1 ? "" : "s")")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(theme.accent)

        Button("Choose a different file") {
          reset()
          showFileImporter = true
        }
      }
    }
  }

  private func collisionRow(_ collision: ThingsCollision) -> some View {
    let binding = Binding<ThingsCollisionAction>(
      get: { collisionOverrides[collision.thingsID] ?? collision.action },
      set: { newValue in
        collisionOverrides[collision.thingsID] = newValue
        rebuildPlan()
      }
    )
    return VStack(alignment: .leading, spacing: 6) {
      Text(collision.thingsTitle)
        .font(.headline)
      if let existing = collision.existingSeptenaTitle {
        Text("Matches “\(existing)”")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Picker("Action", selection: binding) {
        Text("Merge").tag(ThingsCollisionAction.merge)
        Text("Create new").tag(ThingsCollisionAction.createNew)
        Text("Skip").tag(ThingsCollisionAction.skip)
      }
      .pickerStyle(.segmented)
    }
    .padding(.vertical, 4)
  }

  private func resultSection(_ result: ThingsImportApplyResult) -> some View {
    Section {
      LabeledContent("Areas created", value: "\(result.areasCreated)")
      if result.areasMerged > 0 {
        LabeledContent("Areas merged", value: "\(result.areasMerged)")
      }
      LabeledContent("Projects created", value: "\(result.projectsCreated)")
      if result.projectsMerged > 0 {
        LabeledContent("Projects merged", value: "\(result.projectsMerged)")
      }
      LabeledContent("Tasks imported", value: "\(result.tasksImported)")
      if result.tasksSkipped > 0 {
        LabeledContent("Tasks skipped", value: "\(result.tasksSkipped)")
      }
    } header: {
      Text("Import complete")
    } footer: {
      Text("Your Things data was not modified. Check Inbox and Today in the Tasks tab to verify routing.")
    }
  }

  // MARK: - Actions

  private func loadDatabase(from url: URL) {
    parseError = nil
    applyResult = nil
    pickedDatabaseURL = url
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }

    do {
      let resolved = try ThingsImportParser.resolveDatabaseURL(url)
      let scratch = try ThingsImportScratchpad.prepareForParsing(source: resolved)
      scratchpadURL = scratch
      let parsed = try ThingsImportParser.parseResolvedDatabase(at: scratch, options: options)
      snapshot = parsed
      rebuildPlan()
    } catch {
      parseError = error.localizedDescription
      snapshot = nil
      plan = nil
      scratchpadURL = nil
    }
  }

  private func rebuildPlanFromScratchpad() {
    guard let scratchpadURL else {
      if let url = pickedDatabaseURL { loadDatabase(from: url) }
      return
    }
    do {
      let parsed = try ThingsImportParser.parseResolvedDatabase(at: scratchpadURL, options: options)
      snapshot = parsed
      rebuildPlan()
    } catch {
      parseError = error.localizedDescription
    }
  }

  private func rebuildPlan() {
    guard let snapshot else { return }
    let existing = ThingsImportSupport.existingState(context: modelContext)
    plan = ThingsToSeptenaMapper.buildPlan(
      snapshot: snapshot,
      existing: existing,
      options: options,
      collisionOverrides: collisionOverrides
    )
  }

  private func runImport(_ plan: ThingsImportPlan) async {
    applyError = nil
    isApplying = true
    applyProgress = 0
    await SeptenaServices.shared.start()
    do {
      let result = try await ThingsImportApply.apply(
        plan: plan,
        taskMutator: taskMutator,
        areasMutator: areasMutator,
        projectsMutator: projectsMutator
      ) { progress in
        applyProgress = progress
      }
      applyResult = result
      snapshot = nil
      self.plan = nil
    } catch {
      applyError = error.localizedDescription
    }
    isApplying = false
  }

  private func reset() {
    snapshot = nil
    plan = nil
    applyResult = nil
    parseError = nil
    applyError = nil
    pickedDatabaseURL = nil
    scratchpadURL = nil
    collisionOverrides = [:]
  }

  private static var importContentTypes: [UTType] {
    var types: [UTType] = [.data, .folder]
    if let sqlite = UTType(filenameExtension: "sqlite") { types.append(sqlite) }
    if let sqlite3 = UTType(filenameExtension: "sqlite3") { types.append(sqlite3) }
    if let bundle = UTType(filenameExtension: "thingsdatabase") { types.append(bundle) }
    return types
  }
}
