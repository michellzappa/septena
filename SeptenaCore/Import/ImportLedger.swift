import Foundation

// One JSON file per import batch (docs/MOVING_IN_SPEC.md §4.4):
// `Application Support/Septena/Imports/<batchID>.json`. It holds the lineage
// later plans skip on, the originals a `preserved` field is recovered from,
// and the fingerprints undo uses to tell an untouched row from an edited one.
// Plain JSON on purpose: a user (or support) can read what an import did.
// Per device by design (ADR 0021): undo works where the import ran.

enum ImportBatchState: String, Codable, Sendable, Hashable {
  case applying
  case applied
  /// The apply stopped early. Running the same source again resumes it.
  case partial
  case undone
}

struct ImportLedgerItem: Codable, Sendable, Hashable {
  var entity: ImportEntity
  var sourceId: String
  var septenaID: String
  var action: ImportItemAction
  /// The row's fields as the import wrote them. Undo deletes a created row
  /// only while it still matches.
  var fingerprint: String?
}

struct ImportLedgerBatch: Codable, Sendable, Hashable, Identifiable {
  var id: String
  var source: ImportBundleSource
  var options: ImportOptions
  var state: ImportBatchState
  var startedAt: Date
  var finishedAt: Date?
  var report: ImportReport
  var items: [ImportLedgerItem]
  /// The bundle as read, so every `preserved` field and every original stays
  /// recoverable after the import.
  var bundle: ImportBundle
  /// Set by undo: created rows kept because the user changed them.
  var keptOnUndo: [String]?
  var lastError: String?

  var counts: (created: Int, merged: Int) {
    (items.filter { $0.action == .create }.count, items.filter { $0.action == .merge }.count)
  }
}

enum ImportLedger {

  static var directory: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("Septena/Imports", isDirectory: true)
  }

  static func url(for batchID: String) -> URL {
    directory.appendingPathComponent("\(batchID).json")
  }

  static func save(_ batch: ImportLedgerBatch) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try ImportBundle.encoder.encode(batch)
    try data.write(to: url(for: batch.id), options: .atomic)
  }

  static func load(_ batchID: String) throws -> ImportLedgerBatch {
    let data = try Data(contentsOf: url(for: batchID))
    return try ImportBundle.decoder.decode(ImportLedgerBatch.self, from: data)
  }

  /// Every batch on this device, newest first. A file that does not decode is
  /// skipped, never deleted: it may come from a newer app version.
  static func all() -> [ImportLedgerBatch] {
    let files = (try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)) ?? []
    return files
      .filter { $0.pathExtension == "json" }
      .compactMap { try? ImportBundle.decoder.decode(ImportLedgerBatch.self, from: Data(contentsOf: $0)) }
      .sorted { $0.startedAt > $1.startedAt }
  }

  /// Source item → Septena id, from every batch that wrote rows (`applied`
  /// and `partial`; an `undone` batch no longer owns its rows).
  static func lineage() -> [ImportLineageKey: String] {
    var out: [ImportLineageKey: String] = [:]
    for batch in all().reversed() where batch.state == .applied || batch.state == .partial {
      for item in batch.items {
        let key = ImportLineageKey(app: batch.source.app, account: batch.source.account,
                                   entity: item.entity, sourceId: item.sourceId)
        out[key] = item.septenaID
      }
    }
    return out
  }
}
