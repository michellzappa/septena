import Foundation
import SwiftData

// The Things importer before the engine (removed in I1, docs/MOVING_IN_SPEC.md
// §5) kept its Things uuid → Septena id table in the App Group defaults. This
// reads that table once and writes it as one ledger batch, so things imported
// before the engine keep their lineage and a re-import skips them instead of
// creating copies.
//
// The batch is `legacy`: every item is a `merge`, and undo refuses it. Undo of
// a batch drops its lineage, and these rows have no fingerprints, so an undo
// could only make the next import duplicate them.

@MainActor
enum ImportLegacyThingsLineage {
  static let batchID = "things-legacy"

  /// The old table, as `ThingsImportMapping` wrote it. The suite literal is
  /// the old one on purpose: on macOS `SeptenaAppGroup.defaults` is a
  /// different domain, and the old data lives in the group suite.
  private static let legacySuite = SeptenaAppGroup.suite
  private static let areasKey = "septena.thingsImport.areas"
  private static let projectsKey = "septena.thingsImport.projects"
  /// Tasks AND headings: the old importer kept both in one table.
  private static let tasksKey = "septena.thingsImport.tasks"

  /// Kept in this app's own defaults, so a finished migration never reads the
  /// group suite again (on macOS that read can raise a privacy prompt).
  private static let doneKey = "septena.import.thingsLegacyMigrated"

  /// Writes the legacy batch when the old table has rows and no batch exists
  /// yet. Safe to call often: after the first success it returns at once.
  static func migrateIfNeeded(context: ModelContext) {
    let local = UserDefaults.standard
    guard !local.bool(forKey: doneKey) else { return }
    if FileManager.default.fileExists(atPath: ImportLedger.url(for: batchID).path) {
      local.set(true, forKey: doneKey)
      return
    }

    let legacy = UserDefaults(suiteName: legacySuite) ?? .standard
    func table(_ key: String) -> [String: String] {
      legacy.dictionary(forKey: key) as? [String: String] ?? [:]
    }
    let areas = table(areasKey)
    let projects = table(projectsKey)
    let tasks = table(tasksKey)
    guard !(areas.isEmpty && projects.isEmpty && tasks.isEmpty) else {
      local.set(true, forKey: doneKey)
      return
    }

    // Tell headings from tasks by the row they became. A row that is gone
    // from the store is written under both entities: Things uuids are unique
    // across tasks and headings, so the extra key never matches anything else.
    let rowIDs = Array(tasks.values)
    let rows = (try? context.fetch(FetchDescriptor<TaskEntity>(
      predicate: #Predicate { rowIDs.contains($0.id) }))) ?? []
    let kindByID = Dictionary(rows.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })

    var items: [ImportLedgerItem] = []
    for (thingsID, septenaID) in areas.sorted(by: { $0.key < $1.key }) {
      items.append(ImportLedgerItem(entity: .area, sourceId: thingsID, septenaID: septenaID, action: .merge))
    }
    for (thingsID, septenaID) in projects.sorted(by: { $0.key < $1.key }) {
      items.append(ImportLedgerItem(entity: .project, sourceId: thingsID, septenaID: septenaID, action: .merge))
    }
    for (thingsID, septenaID) in tasks.sorted(by: { $0.key < $1.key }) {
      let entities: [ImportEntity] = switch kindByID[septenaID] {
      case .some(TaskKind.heading): [.heading]
      case .some: [.task]
      case .none: [.task, .heading]
      }
      for entity in entities {
        items.append(ImportLedgerItem(entity: entity, sourceId: thingsID, septenaID: septenaID, action: .merge))
      }
    }

    let source = ImportBundleSource(app: ThingsImportSource.id, adapter: "things-legacy",
                                    account: nil, exportedAt: Date())
    let batch = ImportLedgerBatch(
      id: batchID, source: source, options: ImportOptions(), state: .applied,
      startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 0),
      report: ImportReport(), items: items, bundle: ImportBundle(source: source), legacy: true)
    do {
      try ImportLedger.save(batch)
      local.set(true, forKey: doneKey)
    } catch {
      // Not marked done: the next plan tries again before it reads lineage.
      SeptenaLog.error("import: legacy Things lineage not saved", error)
    }
  }
}
