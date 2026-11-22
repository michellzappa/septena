import Foundation

// Source adapters (ADR 0021, docs/MOVING_IN_SPEC.md §3). An adapter reads one
// source and returns one `ImportBundle`. It never writes Septena data, never
// matches titles, and never knows what the user already has: that is the
// engine's job (`ImportPlanner`). Adding a source = one adapter + its
// descriptor row in `ImportSourceCatalog`.

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
  case available
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
  /// Tracking issue on michellzappa/septena.
  let issue: Int?
  let coverage: [ImportCoverage]

  /// The `TaskEntity.source` value for rows this source creates.
  var taskSource: String { "import:\(id)" }
}

/// What a file adapter needs from the UI. `localLibrary` and `account`
/// adapters ignore it.
struct ImportReadRequest: Sendable {
  var fileURL: URL?
}

protocol ImportSource: Sendable {
  var descriptor: ImportSourceDescriptor { get }
  /// Reads the whole source. Filtering (completed, trashed) is the engine's
  /// job, so an adapter returns everything it can read.
  func read(_ request: ImportReadRequest) async throws -> ImportBundle
}

/// Every source Septena knows about, built or not. One list, read by the
/// moving-in UI. The `planned` rows carry their issue so the UI can say when.
enum ImportSourceCatalog {
  static let adapters: [any ImportSource] = [
    ThingsImportSource(),
  ]

  static let planned: [ImportSourceDescriptor] = [
    ImportSourceDescriptor(id: "reminders", displayName: "Apple Reminders",
                           inputKind: .localLibrary, state: .planned, issue: 99, coverage: []),
    ImportSourceDescriptor(id: "microsoft-todo", displayName: "Microsoft To Do",
                           inputKind: .account, state: .planned, issue: 52, coverage: []),
    ImportSourceDescriptor(id: "todoist", displayName: "Todoist",
                           inputKind: .account, state: .planned, issue: 100, coverage: []),
    ImportSourceDescriptor(id: "ticktick", displayName: "TickTick",
                           inputKind: .account, state: .planned, issue: 100, coverage: []),
    ImportSourceDescriptor(id: "superlist", displayName: "Superlist",
                           inputKind: .file, state: .planned, issue: 101, coverage: []),
    ImportSourceDescriptor(id: "omnifocus", displayName: "OmniFocus",
                           inputKind: .file, state: .planned, issue: 102, coverage: []),
    ImportSourceDescriptor(id: "anydo", displayName: "Any.do",
                           inputKind: .file, state: .assisted, issue: 102, coverage: []),
  ]

  static var all: [ImportSourceDescriptor] {
    adapters.map(\.descriptor) + planned
  }

  static func adapter(id: String) -> (any ImportSource)? {
    adapters.first { $0.descriptor.id == id }
  }
}
