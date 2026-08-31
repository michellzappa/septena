import SwiftUI
import SwiftData
import EventKit
import CloudKit
import CoreLocation
import StoreKit
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

struct ImportExportSettingsPane: View {
  /// Which face of this pane to render. `.full` is the everyday "Data" pane
  /// (export / import / format reference); `.dataTools` is the power-user
  /// surface (CloudKit repair + LLM schema prompts) that lives under
  /// About ▸ Advanced. Both share one struct so the import/export state and
  /// helpers aren't duplicated.
  enum Mode { case full, dataTools }
  var mode: Mode = .full

  @Environment(SettingsStore.self) private var store
  @Environment(CKEngine.self) private var ckEngine
  @Environment(\.modelContext) private var modelContext
  @State private var exportError: String? = nil
  @State private var importDoc: ImportExportEnvelope? = nil
  @State private var importMessage: String? = nil
  @State private var importIsError: Bool = false
  @State private var showingPaste = false
  @State private var showingFilePicker = false
  @State private var pasteBuffer: String = ""
  @State private var repairState: RepairState = .idle
  // Training-history (CSV) import — kept separate from the JSON envelope above:
  // different file type, different parser, different merge rule.
  @State private var showingTrainingPicker = false
  @State private var trainingPlan: TrainingImportPlan? = nil
  @State private var trainingSourceText: String = ""
  @State private var trainingMessage: String? = nil
  @State private var trainingIsError: Bool = false
  @State private var trainingUnit: WeightImportUnit = WeightUnit.current == .lb ? .lb : .kg
  @State private var trainingBusy = false

  enum RepairState: Equatable {
    case idle
    case running
    case success(recordCount: Int, typeCount: Int)
    case failure(message: String)
  }

  var body: some View {
    Form {
      switch mode {
      case .full:
        storageSection
        exportSection
        importSection
        trainingImportSection
        formatSection
      case .dataTools:
        repairSection
        schemaPromptsSection
      }
    }
    .formStyle(.grouped)
    .sheet(isPresented: $showingPaste) {
      pasteSheet
    }
    .fileImporter(isPresented: $showingFilePicker,
                  allowedContentTypes: [.json],
                  allowsMultipleSelection: false) { result in
      handleFileImport(result)
    }
    // `.text` alongside `.commaSeparatedText` because a few exporters hand out
    // a .txt, and a picker that greys out the user's actual file reads as
    // "unsupported" when it is only mislabelled.
    .fileImporter(isPresented: $showingTrainingPicker,
                  allowedContentTypes: [.commaSeparatedText, .text],
                  allowsMultipleSelection: false) { result in
      handleTrainingFileImport(result)
    }
  }

  // MARK: Export

  @ViewBuilder
  private var storageSection: some View {
    let summary = SeptenaServices.shared.taskAttachmentStore.storageSummary
    Section {
      LabeledContent("Task attachments", value: "\(summary.count)")
      LabeledContent("Attachment data",
                     value: ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file))
    } header: {
      Text("Storage")
    } footer: {
      Text("Attachments are private, synced through iCloud, and included in Everything and Tasks exports.")
    }
  }

  @ViewBuilder
  private var exportSection: some View {
    Section {
      exportRow(label: "Everything",
                systemImage: "tray.full",
                fileBase: "septena-export") {
        try ImportExportService.exportAll()
      }
      ForEach(exportableSectionKeys, id: \.self) { key in
        exportRow(label: sectionLabel(for: key),
                  systemImage: sectionGlyph(for: key),
                  fileBase: "septena-\(key)") {
          try ImportExportService.exportSection(key)
        }
      }
    } header: {
      Text("Export")
    } footer: {
      Text("JSON dumps of every record in the local store. Use these as a backup, to move to another device, or to feed into other tools.")
    }
  }

  @ViewBuilder
  private func exportRow(label: String,
                         systemImage: String,
                         fileBase: String,
                         build: @escaping () throws -> Data) -> some View {
    // Serialize lazily — the JSON blob is built only when the user actually
    // invokes the share sheet (ExportFile carries the closure, not the data).
    // Building eagerly here meant every body re-render of the Data pane ran a
    // full SwiftData fetch + JSON encode for all ~10 exports on the main
    // thread, which is why this pane loaded far slower than the others.
    let filename = "\(fileBase)-\(ImportExportService.todayStamp).json"
    ShareLink(item: ExportFile(suggestedName: filename, build: build),
              preview: SharePreview(filename, image: Image(systemName: systemImage))) {
      HStack {
        Label(label, systemImage: systemImage)
          .foregroundStyle(.primary)
        Spacer()
        Image(systemName: "square.and.arrow.up")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: Import

  @ViewBuilder
  private var importSection: some View {
    Section {
      Button {
        showingFilePicker = true
      } label: {
        Label("Choose JSON file…", systemImage: "doc.badge.plus")
      }
      Button {
        pasteBuffer = ""
        importMessage = nil
        importIsError = false
        showingPaste = true
      } label: {
        Label("Paste JSON…", systemImage: "doc.on.clipboard")
      }

      if let doc = importDoc {
        importPreview(doc)
      } else if let msg = importMessage {
        Label(msg, systemImage: importIsError ? "exclamationmark.triangle" : "checkmark.circle")
          .foregroundStyle(importIsError ? .red : .green)
          .font(.callout)
      }
    } header: {
      Text("Import")
    } footer: {
      Text("Provide JSON in the Septena export format. Records are merged by id — existing rows update in place, new rows are inserted. Definition tables (habits, supplements, chores, beans, grocery items) apply now; event/log tables preview only in this build.")
    }
  }

  @ViewBuilder
  private func importPreview(_ doc: ImportExportEnvelope) -> some View {
    let sectionName = doc.section == "all"
      ? "Everything"
      : sectionLabel(for: doc.section)
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Loaded — \(sectionName)", systemImage: "checkmark.seal")
          .foregroundStyle(.green)
        Spacer()
        Button("Clear", role: .destructive) {
          importDoc = nil
          importMessage = nil
        }
        .buttonStyle(.borderless)
        .font(.caption)
      }
      if let ts = doc.exportedAt {
        Text("Exported \(ts)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Divider()
      ForEach(doc.tables.keys.sorted(), id: \.self) { table in
        HStack {
          Text(table)
            .font(.callout.monospaced())
          Spacer()
          Text("\(doc.tables[table]?.count ?? 0) rows")
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      Divider()
      HStack {
        Spacer()
        Button {
          applyImport(doc)
        } label: {
          Label("Apply", systemImage: "tray.and.arrow.down")
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
      }
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private var pasteSheet: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 8) {
        Text("Paste a Septena JSON export below.")
          .font(.callout)
          .foregroundStyle(.secondary)
        TextEditor(text: $pasteBuffer)
          .font(.body.monospaced())
          .frame(minHeight: 240)
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .strokeBorder(.secondary.opacity(0.2))
          )
        if importIsError, let msg = importMessage {
          Text(msg).font(.callout).foregroundStyle(.red)
        }
      }
      .padding()
      .navigationTitle("Paste JSON")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { showingPaste = false }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Load") {
            handlePaste(pasteBuffer)
          }
          .disabled(pasteBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
  }

  // MARK: Schema prompts
  //
  // One copyable LLM prompt per section. Paste the prompt into Claude /
  // ChatGPT / etc. along with whatever source data you have (CSV, journal
  // entries, freeform notes) and the model produces a JSON envelope that
  // round-trips through this importer. The schema is generated from the
  // same field list the exporter uses, so the prompt is always in sync.

  // MARK: Repair

  // One-shot re-pull for records whose history may be missing locally
  // because CKSyncEngine's incremental fetch token advanced past records
  // the device couldn't yet decode (a record type arrived while this
  // device was running a build without the matching arm in
  // `applyFetchedRecord` — it happened with nutrition, then again with
  // intake). `fetchAllRecords` does a fresh nil-token zone replay so
  // every live record is redelivered regardless of the engine
  // checkpoint, and the absorb path upserts idempotently. Whole-zone on
  // purpose: a per-type picker would just recreate this bug for the
  // next record type.
  @ViewBuilder
  private var repairSection: some View {
    Section {
      Button {
        Task { await repairFromCloudKit() }
      } label: {
        HStack {
          Label("Repair data from CloudKit", systemImage: "stethoscope")
          Spacer()
          switch repairState {
          case .idle:
            EmptyView()
          case .running:
            ProgressView().controlSize(.small)
          case .success(let records, let types):
            Text("\(records) records · \(types) types")
              .font(.septenaMetaSmall)
              .foregroundStyle(.secondary)
          case .failure:
            Image(systemName: "exclamationmark.triangle")
              .foregroundStyle(.orange)
          }
        }
      }
      .disabled(repairState == .running)
      if case .failure(let message) = repairState {
        Text(message)
          .font(.caption)
          .foregroundStyle(.red)
      }
    } header: {
      Text("Repair")
    } footer: {
      Text("Re-pulls every record in this account's CloudKit zone and merges it into the local store. Use if a section's history looks empty on this device even though the data exists on another one. Cloud truth wins for any record that differs locally.")
    }
  }

  private func repairFromCloudKit() async {
    repairState = .running
    do {
      let records = try await ckEngine.fetchAllRecords()
      for record in records {
        await ckEngine.applyFetchedRecord?(record)
      }
      await ckEngine.applyDidFinishBatch?(true)
      let types = Set(records.map(\.recordType)).count
      repairState = .success(recordCount: records.count, typeCount: types)
    } catch {
      repairState = .failure(message: error.localizedDescription)
    }
  }

  @ViewBuilder
  private var schemaPromptsSection: some View {
    Section {
      ForEach(exportableSectionKeys, id: \.self) { key in
        schemaPromptRow(for: key)
      }
    } header: {
      Text("Schema prompts")
    } footer: {
      Text("Copy a prompt and paste it into an LLM along with the source data you want to import. The model returns JSON that pastes straight into Import above.")
    }
  }

  @ViewBuilder
  private func schemaPromptRow(for key: String) -> some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 8) {
        Text(ImportExportService.schemaPrompt(for: key))
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        Button {
          copyToPasteboard(ImportExportService.schemaPrompt(for: key))
        } label: {
          Label("Copy prompt", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
      }
      .padding(.vertical, 4)
    } label: {
      Label(sectionLabel(for: key), systemImage: sectionGlyph(for: key))
    }
  }

  private func copyToPasteboard(_ text: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = text
    #elseif canImport(AppKit)
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
    #endif
  }

  // MARK: Format reference

  @ViewBuilder
  private var formatSection: some View {
    Section {
      DisclosureGroup("Envelope") {
        Text(ImportExportService.envelopeReference)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    } header: {
      Text("Format")
    } footer: {
      Text("Format version \(importExportEnvelopeVersion). The exporter above produces files that round-trip through this importer unchanged.")
    }
  }

  // MARK: Handlers

  private func handlePaste(_ text: String) {
    do {
      importDoc = try ImportExportService.parseEnvelope(Data(text.utf8))
      importMessage = nil
      importIsError = false
      showingPaste = false
    } catch {
      importMessage = error.localizedDescription
      importIsError = true
    }
  }

  private func handleFileImport(_ result: Result<[URL], Error>) {
    importMessage = nil
    importIsError = false
    importDoc = nil
    switch result {
    case .success(let urls):
      guard let url = urls.first else { return }
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      do {
        importDoc = try ImportExportService.parseEnvelope(try Data(contentsOf: url))
      } catch {
        importMessage = error.localizedDescription
        importIsError = true
      }
    case .failure(let error):
      importMessage = error.localizedDescription
      importIsError = true
    }
  }

  private func applyImport(_ doc: ImportExportEnvelope) {
    do {
      let result = try ImportExportService.apply(doc)
      importDoc = nil
      importMessage = "Imported \(result.applied) row\(result.applied == 1 ? "" : "s"); skipped \(result.skipped) (unsupported table\(result.skipped == 1 ? "" : "s"))."
      importIsError = false
    } catch {
      importMessage = error.localizedDescription
      importIsError = true
    }
  }

  // MARK: Training history (CSV from another app)

  @ViewBuilder
  private var trainingImportSection: some View {
    Section {
      Button {
        trainingMessage = nil
        trainingIsError = false
        showingTrainingPicker = true
      } label: {
        Label("Choose CSV file…", systemImage: "figure.strengthtraining.traditional")
      }
      if let plan = trainingPlan {
        trainingPreview(plan)
      } else if let msg = trainingMessage {
        Label(msg, systemImage: trainingIsError ? "exclamationmark.triangle" : "checkmark.circle")
          .foregroundStyle(trainingIsError ? .red : .green)
          .font(.callout)
      }
    } header: {
      Text("Training history")
    } footer: {
      Text("Set-by-set exports from Strong, Hevy and FitNotes. Identical sets collapse into one entry (three rows of 60 × 10 become 3 × 10), warm-up sets are dropped because there is nowhere to mark them, and RPE/RIR becomes an effort rating. Days that already have training are left alone, so importing the same file twice changes nothing.")
    }
  }

  @ViewBuilder
  private func trainingPreview(_ plan: TrainingImportPlan) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label(plan.source.map { "Read — \($0)" } ?? "Read", systemImage: "checkmark.seal")
          .foregroundStyle(.green)
        Spacer()
        Button("Clear", role: .destructive) {
          trainingPlan = nil
          trainingSourceText = ""
          trainingMessage = nil
        }
        .buttonStyle(.borderless)
        .font(.caption)
      }
      if let from = plan.from, let to = plan.to {
        Text(from == to ? from : "\(from) → \(to)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Divider()
      LabeledContent("Sessions", value: "\(plan.sessionCount)")
      LabeledContent("Entries", value: "\(plan.entryCount)")
      LabeledContent("Sets read", value: "\(plan.setRows)")
      if plan.ratedSets > 0 {
        LabeledContent("With an effort rating", value: "\(plan.ratedSets)")
      }
      if plan.warmupRows > 0 {
        LabeledContent("Warm-up sets dropped", value: "\(plan.warmupRows)")
      }
      if plan.skippedRows > 0 {
        LabeledContent("Rows skipped", value: "\(plan.skippedRows)")
      }
      LabeledContent("Exercises matched", value: "\(plan.knownNames.count)")
      if !plan.unknownNames.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("New exercises (\(plan.unknownNames.count))")
            .font(.caption.weight(.medium))
          // Named rather than counted: these are the rows that will land under
          // a name the app has never seen, and seeing "Hack Squat (Machine)"
          // before importing is what lets someone fix it instead of finding it
          // in the catalog a week later.
          Text(plan.unknownNames.prefix(12).joined(separator: ", ")
               + (plan.unknownNames.count > 12 ? "…" : ""))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      // The unit only needs asking about when the file never said. Strong
      // writes a bare "Weight" column whose unit lives in that app's settings,
      // so importing on an assumption without showing it would silently rewrite
      // someone's numbers by a factor of 2.2.
      if plan.declaredUnit == nil && !plan.mixedUnits {
        Picker("Weights in", selection: $trainingUnit) {
          ForEach(WeightImportUnit.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .onChange(of: trainingUnit) { _, _ in reparseTrainingPlan() }
        Text("This file doesn't say which unit it used. Everything is stored in kg.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if plan.mixedUnits {
        Text("Mixed kg and lb — each row was converted using its own unit.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Divider()
      HStack {
        Spacer()
        Button {
          applyTrainingImport(plan)
        } label: {
          Label("Import", systemImage: "tray.and.arrow.down")
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .disabled(trainingBusy || plan.sessionCount == 0)
      }
    }
  }

  private func handleTrainingFileImport(_ result: Result<[URL], Error>) {
    trainingMessage = nil
    trainingIsError = false
    trainingPlan = nil
    switch result {
    case .success(let urls):
      guard let url = urls.first else { return }
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      do {
        let data = try Data(contentsOf: url)
        // Exports out of Windows tooling are routinely Latin-1; falling back
        // keeps a file with one "Curl à la…" in it from failing as a whole.
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
          trainingMessage = "Couldn't read that file as text."
          trainingIsError = true
          return
        }
        trainingSourceText = text
        reparseTrainingPlan()
      } catch {
        trainingMessage = error.localizedDescription
        trainingIsError = true
      }
    case .failure(let error):
      trainingMessage = error.localizedDescription
      trainingIsError = true
    }
  }

  private func reparseTrainingPlan() {
    guard !trainingSourceText.isEmpty else { return }
    do {
      trainingPlan = try TrainingHistoryImport.plan(
        csv: trainingSourceText,
        knownExerciseKeys: knownExerciseKeys(),
        assumedUnit: trainingUnit)
      trainingMessage = nil
      trainingIsError = false
    } catch TrainingImportError.empty {
      trainingPlan = nil
      trainingMessage = "That file has no rows in it."
      trainingIsError = true
    } catch {
      trainingPlan = nil
      trainingMessage = "Couldn't find a date and an exercise column in that file. Export a full workout history rather than a single workout or a summary."
      trainingIsError = true
    }
  }

  /// Every `exerciseKey` the app already answers to — the user's own catalog
  /// plus the curated library, so a name only counts as new when neither knows
  /// it.
  private func knownExerciseKeys() -> Set<String> {
    var keys = Set(DefaultExerciseLibrary.byKey.keys)
    let defs = (try? modelContext.fetch(FetchDescriptor<ExerciseDefinitionEntity>())) ?? []
    for def in defs {
      keys.insert(exerciseKey(def.id))
      keys.insert(exerciseKey(def.name))
      for alias in def.aliases { keys.insert(exerciseKey(alias)) }
    }
    keys.remove("")
    return keys
  }

  private func applyTrainingImport(_ plan: TrainingImportPlan) {
    trainingBusy = true
    let outcome = SeptenaServices.shared.trainingMutator.importHistory(plan.sessions)
    trainingBusy = false
    trainingPlan = nil
    trainingSourceText = ""
    var parts = ["Imported \(outcome.entriesAdded) entr\(outcome.entriesAdded == 1 ? "y" : "ies") across \(outcome.sessionsAdded) session\(outcome.sessionsAdded == 1 ? "" : "s")"]
    if outcome.definitionsCreated > 0 {
      parts.append("added \(outcome.definitionsCreated) new exercise\(outcome.definitionsCreated == 1 ? "" : "s") to the catalog")
    }
    if outcome.sessionsSkipped > 0 {
      parts.append("skipped \(outcome.sessionsSkipped) day\(outcome.sessionsSkipped == 1 ? "" : "s") that already had training")
    }
    trainingMessage = parts.joined(separator: ", ") + "."
    trainingIsError = false
  }

  // MARK: Helpers

  private func sectionLabel(for key: String) -> String {
    SectionManifest.displayLabel(
      key: key,
      stored: store.sections.first(where: { $0.key == key })?.label ?? "")
  }

  private func sectionGlyph(for key: String) -> String {
    if let m = SectionManifest.byKey[key] { return m.iconSymbol }
    return "circle.fill"
  }

}

// MARK: - ShareLink payload

struct ExportFile: Transferable {
  let suggestedName: String
  /// Deferred serializer. Held instead of the bytes so the (expensive,
  /// main-context) export only runs when the share sheet actually pulls the
  /// representation — not on every render of the row.
  let build: () throws -> Data

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: .json) { item in
      // The build touches `mainContext`; hop to the main actor to run it.
      try await MainActor.run { try item.build() }
    }
    .suggestedFileName { $0.suggestedName }
  }
}

// MARK: - Parsed envelope

struct ImportExportEnvelope {
  let version: Int
  let section: String
  let exportedAt: String?
  let appVersion: String?
  let tables: [String: [[String: Any]]]
}

// MARK: - Service
//
// Pure functions: build a JSON `Data` blob for a given section (or all),
// or parse an inbound `Data` blob into an `ImportExportEnvelope`. No UI
// state — the pane drives it.

enum ImportExportService {
  enum ImportError: LocalizedError {
    case notJSON
    case missingEnvelope
    case unsupportedVersion(Int)
    case unsupportedSection(String)
    case malformed(String)

    var errorDescription: String? {
      switch self {
      case .notJSON: return "File isn't valid JSON."
      case .missingEnvelope: return "Missing Septena export envelope (septena_export_version / section / tables)."
      case .unsupportedVersion(let v): return "Export version \(v) is newer than this build understands."
      case .unsupportedSection(let s): return "Unknown section: \(s)."
      case .malformed(let m): return m
      }
    }
  }

  static var todayStamp: String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: .now)
  }

  /// Skill-style LLM prompt for one section. Self-contained: states the
  /// goal, the exact envelope shape to produce, and every field expected
  /// in every table (with type + required/optional). Designed to be
  /// copy-pasted into Claude / ChatGPT with arbitrary source data
  /// appended underneath.
  @MainActor
  static func schemaPrompt(for sectionKey: String) -> String {
    let sectionLabel = SectionManifest.byKey[sectionKey]?.defaultLabel
      ?? sectionKey.capitalized
    let tables = schemaTables(for: sectionKey)
    var out = """
    # Septena \(sectionLabel) Import

    You convert source data into a JSON document that Septena's Settings → Import & Export pane can apply.

    ## Output

    Return **only** the JSON below — no commentary, no markdown fences. Wrap your records in this envelope verbatim, substituting only `tables`:

    ```
    {
      "septena_export_version": 1,
      "section": "\(sectionKey)",
      "exported_at": "<current ISO-8601 timestamp>",
      "tables": {
    """
    for (i, t) in tables.enumerated() {
      let comma = (i == tables.count - 1) ? "" : ","
      out += "\n    \"\(t.name)\": [ … ]\(comma)"
    }
    out += """

      }
    }
    ```

    ## Tables

    """
    for t in tables {
      out += "\n### `\(t.name)` — \(t.purpose)\n"
      for f in t.fields {
        let req = f.required ? "**required**" : "optional"
        let note = f.note.map { " — \($0)" } ?? ""
        out += "- `\(f.name)` (\(f.type), \(req))\(note)\n"
      }
    }
    out += """

    ## Rules
    - `id` is a stable string; reuse the same id to update an existing row, choose a new one to insert.
    - Dates: `YYYY-MM-DD`. Times: `HH:MM`. Timestamps: ISO-8601 (e.g. `2026-05-24T08:30:00Z`).
    - Omit optional fields you don't have rather than sending `null`.
    - Skip any record you can't confidently map; partial data is better than fabricated data.

    ## Source data
    <paste your source data below this line>
    """
    return out
  }

  /// Table schemas exposed to the prompt builder. Kept in sync with the
  /// entity → dict mappers above; if you add a field there, add it here.
  @MainActor
  private static func schemaTables(for sectionKey: String) -> [SchemaTable] {
    // Every section now lives in its plugin's exportContribution. If
    // the lookup fails, the section either doesn't exist or doesn't
    // participate in import/export — return [] so the prompt builder
    // emits an empty schema block instead of crashing.
    return SectionRegistry.plugin(forKey: sectionKey)?.exportContribution?.tables ?? []
  }

  // SchemaTable / SchemaField hoisted to top-level types (see end of
  // file) so plugin files can declare their own export contribution
  // without needing to reach into ImportExportService's nesting.

  static let envelopeReference = """
{
  "septena_export_version": 1,
  "section": "tasks" | "training" | … | "all",
  "exported_at": "<ISO-8601>",
  "app_version": "<short> (<build>)",
  "tables": {
    "task":    [{ "id": …, "title": …, … }],
    "project": [...],
    …
  }
}
"""

  // MARK: Build

  @MainActor
  static func exportAll() throws -> Data {
    var tables: [String: [[String: Any]]] = [:]
    for key in exportableSectionKeys {
      let sectionTables = try collectTables(for: key)
      for (k, v) in sectionTables { tables[k] = v }
    }
    return try encode(section: "all", tables: tables)
  }

  @MainActor
  static func exportSection(_ key: String) throws -> Data {
    let tables = try collectTables(for: key)
    return try encode(section: key, tables: tables)
  }

  @MainActor
  private static func collectTables(for key: String) throws -> [String: [[String: Any]]] {
    let ctx = LocalStore.shared.container.mainContext
    guard let contribution = SectionRegistry.plugin(forKey: key)?.exportContribution else {
      throw ImportError.unsupportedSection(key)
    }
    return try contribution.collect(ctx)
  }

  // fetchAll helper retired — plugins do their own ctx.fetch calls
  // inside their exportContribution.collect closures.

  private static func encode(section: String,
                             tables: [String: [[String: Any]]]) throws -> Data {
    let envelope: [String: Any] = [
      "septena_export_version": importExportEnvelopeVersion,
      "section": section,
      "exported_at": ISO8601DateFormatter().string(from: .now),
      "app_version": appVersion(),
      "tables": tables,
    ]
    return try JSONSerialization.data(withJSONObject: envelope,
                                      options: [.prettyPrinted, .sortedKeys])
  }

  private static func appVersion() -> String {
    let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    return "\(v) (\(b))"
  }

  // MARK: Parse

  static func parseEnvelope(_ data: Data) throws -> ImportExportEnvelope {
    let raw: Any
    do {
      raw = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
      throw ImportError.notJSON
    }
    guard let dict = raw as? [String: Any],
          let version = dict["septena_export_version"] as? Int,
          let section = dict["section"] as? String,
          let tablesRaw = dict["tables"] as? [String: Any]
    else { throw ImportError.missingEnvelope }
    if version > importExportEnvelopeVersion {
      throw ImportError.unsupportedVersion(version)
    }
    var typed: [String: [[String: Any]]] = [:]
    for (table, rows) in tablesRaw {
      guard let rows = rows as? [[String: Any]] else {
        throw ImportError.malformed("Table '\(table)' is not an array of objects.")
      }
      typed[table] = rows
    }
    return ImportExportEnvelope(
      version: version,
      section: section,
      exportedAt: dict["exported_at"] as? String,
      appVersion: dict["app_version"] as? String,
      tables: typed
    )
  }

  // MARK: Apply
  //
  // v1 limits write-back to the simple, idempotent definition rows that
  // are pure upserts by id and have a `noteXChange(id:)` on `CKEngine`.
  // Event/log rows (nutrition entries, caffeine events, training entries,
  // etc.) route through dedicated mutators that handle recurrence,
  // summaries, and CK fan-out — those land in a follow-up. Unsupported
  // tables are counted toward `skipped` so the user sees what landed.

  struct ApplyResult {
    var applied: Int
    var skipped: Int
  }

  @MainActor
  static func apply(_ doc: ImportExportEnvelope) throws -> ApplyResult {
    let ctx = LocalStore.shared.container.mainContext
    let engine = SeptenaServices.shared.ckEngine
    var applied = 0
    var skipped = 0
    for (table, rows) in doc.tables {
      switch table {
      case "habitDefinition":
        for r in rows { try upsertHabitDefinition(r, ctx: ctx, engine: engine); applied += 1 }
      case "supplementDefinition":
        for r in rows { try upsertSupplementDefinition(r, ctx: ctx, engine: engine); applied += 1 }
      case "choreDefinition":
        for r in rows { try upsertChoreDefinition(r, ctx: ctx, engine: engine); applied += 1 }
      case "groceryCategory":
        for r in rows { try upsertGroceryCategory(r, ctx: ctx, engine: engine); applied += 1 }
      case "groceryItem":
        for r in rows { try upsertGroceryItem(r, ctx: ctx, engine: engine); applied += 1 }
      case "task_attachment":
        for r in rows { try upsertTaskAttachment(r, ctx: ctx, engine: engine); applied += 1 }
      default:
        skipped += rows.count
      }
    }
    try StoreHealth.saveOrThrow(ctx, op: "ImportExport.apply")
    return ApplyResult(applied: applied, skipped: skipped)
  }
}

@MainActor
private func upsertTaskAttachment(_ r: [String: Any],
                                  ctx: ModelContext,
                                  engine: CKEngine) throws {
  guard let id = r["id"] as? String,
        let taskID = r["taskID"] as? String,
        let filename = r["filename"] as? String,
        let contentType = r["contentType"] as? String,
        let encoded = r["dataBase64"] as? String,
        let data = Data(base64Encoded: encoded)
  else { throw ImportExportService.ImportError.malformed("task_attachment row is missing file data or metadata") }
  guard data.count <= TaskAttachmentFiles.maxBytes else {
    throw ImportExportService.ImportError.malformed("attachment \(filename) is larger than 25 MB")
  }
  let existing = try ctx.fetch(FetchDescriptor<TaskAttachmentEntity>(
    predicate: #Predicate { $0.id == id })).first
  let entity = existing ?? TaskAttachmentEntity(id: id, taskID: taskID, filename: filename,
    contentType: contentType, byteCount: Int64(data.count))
  if existing == nil { ctx.insert(entity) }
  entity.taskID = taskID
  entity.filename = filename
  entity.contentType = contentType
  entity.byteCount = Int64(data.count)
  entity.position = r["position"] as? Double ?? 0
  if let stamp = r["createdAt"] as? String, let date = ISO8601DateFormatter().date(from: stamp) {
    entity.createdAt = date
  }
  let owned = TaskAttachmentFiles.ownedFilename(id: id, original: filename)
  try data.write(to: TaskAttachmentFiles.directory.appendingPathComponent(owned), options: .atomic)
  entity.localFilename = owned
  engine.noteTaskAttachmentChange(id: id)
}

// MARK: - Entity → dict mappers


// Internal (not private) so plugin export-contribution helpers in
// sibling files can reuse the same compaction + ISO-date primitives.
func isoDate(_ d: Date) -> String {
  ISO8601DateFormatter().string(from: d)
}

/// Strips nil values so the JSON stays compact and `JSONSerialization`
/// doesn't trip on `Any?`.
func compact(_ dict: [String: Any?]) -> [String: Any] {
  var out: [String: Any] = [:]
  for (k, v) in dict {
    guard let v else { continue }
    out[k] = v
  }
  return out
}

// MARK: - Upserts (definition tables only)

@MainActor
private func upsertHabitDefinition(_ r: [String: Any],
                                   ctx: ModelContext,
                                   engine: CKEngine) throws {
  guard let id = r["id"] as? String,
        let title = r["title"] as? String,
        let bucket = r["bucket"] as? String
  else { throw ImportExportService.ImportError.malformed("habitDefinition row missing id/title/bucket") }
  let existing = try ctx.fetch(FetchDescriptor<HabitDefinitionEntity>(
    predicate: #Predicate { $0.id == id })).first
  let e = existing ?? HabitDefinitionEntity(id: id, title: title, bucket: bucket)
  if existing == nil { ctx.insert(e) }
  e.title = title
  e.bucket = bucket
  e.emoji = r["emoji"] as? String
  e.sortIndex = r["sortIndex"] as? Int ?? 0
  e.updatedAt = .now
  engine.noteHabitDefinitionChange(id: id)
}

@MainActor
private func upsertSupplementDefinition(_ r: [String: Any],
                                        ctx: ModelContext,
                                        engine: CKEngine) throws {
  guard let id = r["id"] as? String, let title = r["title"] as? String
  else { throw ImportExportService.ImportError.malformed("supplementDefinition row missing id/title") }
  let existing = try ctx.fetch(FetchDescriptor<SupplementDefinitionEntity>(
    predicate: #Predicate { $0.id == id })).first
  let e = existing ?? SupplementDefinitionEntity(id: id, title: title)
  if existing == nil { ctx.insert(e) }
  e.title = title
  e.emoji = r["emoji"] as? String
  e.bucket = r["bucket"] as? String
  e.sortIndex = r["sortIndex"] as? Int ?? 0
  e.updatedAt = .now
  engine.noteSupplementDefinitionChange(id: id)
}

@MainActor
private func upsertChoreDefinition(_ r: [String: Any],
                                   ctx: ModelContext,
                                   engine: CKEngine) throws {
  guard let id = r["id"] as? String,
        let title = r["title"] as? String,
        let cadence = r["cadenceDays"] as? Int
  else { throw ImportExportService.ImportError.malformed("choreDefinition row missing id/title/cadenceDays") }
  let existing = try ctx.fetch(FetchDescriptor<ChoreDefinitionEntity>(
    predicate: #Predicate { $0.id == id })).first
  let e = existing ?? ChoreDefinitionEntity(id: id, title: title, cadenceDays: cadence)
  if existing == nil { ctx.insert(e) }
  e.title = title
  e.cadenceDays = cadence
  e.emoji = r["emoji"] as? String
  e.sortIndex = r["sortIndex"] as? Int ?? 0
  e.updatedAt = .now
  engine.noteChoreDefinitionChange(id: id)
}

@MainActor
private func upsertGroceryCategory(_ r: [String: Any],
                                   ctx: ModelContext,
                                   engine: CKEngine) throws {
  guard let id = r["id"] as? String, let name = r["name"] as? String
  else { throw ImportExportService.ImportError.malformed("groceryCategory row missing id/name") }
  let existing = try ctx.fetch(FetchDescriptor<GroceryCategoryEntity>(
    predicate: #Predicate { $0.id == id })).first
  let e = existing ?? GroceryCategoryEntity(id: id, name: name)
  if existing == nil { ctx.insert(e) }
  e.name = name
  e.sortIndex = r["sortIndex"] as? Int ?? 0
  e.updatedAt = .now
  engine.noteGroceryCategoryChange(id: id)
}

@MainActor
private func upsertGroceryItem(_ r: [String: Any],
                               ctx: ModelContext,
                               engine: CKEngine) throws {
  guard let id = r["id"] as? String,
        let name = r["name"] as? String,
        let category = r["category"] as? String
  else { throw ImportExportService.ImportError.malformed("groceryItem row missing id/name/category") }
  let existing = try ctx.fetch(FetchDescriptor<GroceryItemEntity>(
    predicate: #Predicate { $0.id == id })).first
  let e = existing ?? GroceryItemEntity(id: id, name: name, category: category)
  if existing == nil { ctx.insert(e) }
  e.name = name
  e.category = category
  e.emoji = r["emoji"] as? String ?? ""
  e.low = r["low"] as? Bool ?? false
  e.lastBought = r["lastBought"] as? String
  e.sortIndex = r["sortIndex"] as? Int ?? 0
  e.updatedAt = .now
  engine.noteGroceryItemChange(id: id)
}

// MARK: - Export schema types (top-level)
//
// Hoisted out of ImportExportService so plugin files can reference
// them when declaring per-section export contributions.

struct SchemaTable {
  let name: String
  let purpose: String
  let fields: [SchemaField]
}

struct SchemaField {
  let name: String
  let type: String
  let required: Bool
  let note: String?
  static func req(_ name: String, _ type: String, _ note: String? = nil) -> SchemaField {
    SchemaField(name: name, type: type, required: true, note: note)
  }
  static func opt(_ name: String, _ type: String, _ note: String? = nil) -> SchemaField {
    SchemaField(name: name, type: type, required: false, note: note)
  }
}

/// Per-section export contribution. A plugin returns this if it wants
/// to participate in Settings → Import & Export and the schema-prompt
/// generator. `tables` declares the JSON shape; `collect` returns a
/// freshly-built `[tableName: [row]]` dictionary for the user's data.
struct SectionExportContribution {
  let tables: [SchemaTable]
  let collect: @MainActor (ModelContext) throws -> [String: [[String: Any]]]
}
