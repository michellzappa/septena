import Foundation

// Source adapters (ADR 0021, docs/MOVING_IN_SPEC.md §3). An adapter reads one
// source and returns one `ImportBundle`. It never writes Septena data, never
// matches titles, and never knows what the user already has: that is the
// engine's job (`ImportPlanner`). Adding a source = one adapter + its
// row in `registry/import-sources.json`.

/// How an adapter reaches its data.
enum ImportInputKind: String, Codable, Sendable, Hashable {
  /// The user picks a file or bundle (Things database, a CSV, a JSON export).
  case file
  /// A library on this device the app reads with permission (Reminders).
  case localLibrary
  /// The user signs in to the source (OAuth, read-only scope, token stays on
  /// the device and is dropped after the read).
  case account
}

/// What happens to one bundle field when it reaches Septena.
enum ImportFieldDisposition: String, Codable, Sendable, Hashable {
  /// Lands in a Septena field of the same meaning.
  case mapped
  /// Rewritten into another field (for example a link appended to notes).
  case transformed
  /// Kept in the batch ledger only, recoverable, not visible in the app yet.
  case preserved
  /// The source has it, but the adapter cannot read it.
  case unsupported
}

/// One line of an adapter's declared coverage: a source field and what the
/// adapter does with it. The moving-in UI and the site table read these.
struct ImportCoverage: Sendable, Hashable {
  var field: String
  var disposition: ImportFieldDisposition
  var note: String?

  init(_ field: String, _ disposition: ImportFieldDisposition, _ note: String? = nil) {
    self.field = field
    self.disposition = disposition
    self.note = note
  }
}

/// Where a source stands in the app.
enum ImportSourceState: String, Codable, Sendable, Hashable {
  case available = "ships"
  case planned
  /// No structured route; the guide walks the user through a manual path.
  case assisted
}

struct ImportSourceDescriptor: Sendable, Hashable, Identifiable {
  /// Stable catalog id, written into `ImportBundleSource.app` and into the
  /// `source` of every imported row as `import:<id>`.
  let id: String
  let displayName: String
  let inputKind: ImportInputKind
  let state: ImportSourceState
  /// Tracking issue on septena/septena.
  let issue: Int?
  /// What moving in does, shown on an available source's row.
  let detail: String?
  let coverage: [ImportCoverage]

  /// A row of `registry/import-sources.json`, with the adapter's coverage.
  init(_ row: RegistryImportSource, coverage: [ImportCoverage] = []) {
    id = row.id
    displayName = row.name
    inputKind = ImportInputKind(rawValue: row.input) ?? .file
    state = ImportSourceState(rawValue: row.status) ?? .planned
    issue = row.issue
    detail = row.detail
    self.coverage = coverage
  }

  /// The `TaskEntity.source` value for rows this source creates.
  var taskSource: String { "import:\(id)" }
}

/// What a file adapter needs from the UI. `localLibrary` and `account`
/// adapters ignore it.
struct ImportReadRequest: Sendable {
  var fileURL: URL?
}

protocol ImportSource: Sendable {
  /// The source's id in `registry/import-sources.json`.
  var id: String { get }
  var coverage: [ImportCoverage] { get }
  /// Reads the whole source. Filtering (completed, trashed) is the engine's
  /// job, so an adapter returns everything it can read.
  func read(_ request: ImportReadRequest) async throws -> ImportBundle
}

/// Every source Septena knows about, built or not. The list, its order and
/// each status come from `registry/import-sources.json`, which the site reads
/// too. An available source with no adapter has its own screen (Reminders).
enum ImportSourceCatalog {
  static let adapters: [any ImportSource] = [
    ThingsImportSource(),
  ]

  static var all: [ImportSourceDescriptor] {
    RegistryImportSources.all.map { row in
      ImportSourceDescriptor(row, coverage: adapter(id: row.id)?.coverage ?? [])
    }
  }

  static func descriptor(id: String) -> ImportSourceDescriptor? {
    RegistryImportSources.all.first { $0.id == id }.map {
      ImportSourceDescriptor($0, coverage: adapter(id: id)?.coverage ?? [])
    }
  }

  static func adapter(id: String) -> (any ImportSource)? {
    adapters.first { $0.id == id }
  }
}
