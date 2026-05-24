import Foundation

// Septena REST client — talks to the FastAPI backend in /api/tasks.
// Most domains have moved to CloudKit; what remains here is the
// not-yet-migrated read surface (areas/projects bootstrap for migration,
// settings/sections, the Today aggregator, health-integration proxies
// for Oura/Withings/Air, and the nutrition CK bootstrap).
// No auth; base URL is set via Settings (defaults to http://100.74.150.55:7000).

// MARK: - Change notification

extension Notification.Name {
  /// Posted after task mutations and CloudKit task-sync batches complete.
  static let septenaTasksChanged = Notification.Name("septena.tasksChanged")
  /// Posted after area / project structure changes and CloudKit batches
  /// that update those records. Lets task-centric views avoid reloading
  /// when only navigation structure changed.
  static let septenaStructureChanged = Notification.Name("septena.structureChanged")
  /// Generic mutation broadcast — fires after any non-task mutation (habits,
  /// supplements, chores, gut, nutrition, caffeine, cannabis, groceries).
  /// Destinations that show those sections subscribe to refresh themselves
  /// without each call site wiring its own reload. Tasks keep their own
  /// dedicated notification (above) so the overdue-badge path stays narrow.
  static let septenaDataChanged = Notification.Name("septena.dataChanged")
  /// Posted by the macOS menu bar's "New To-Do" item. ContentView
  /// listens and starts an inline draft on Inbox — same flow as ⌘N.
  static let septenaOpenQuickAdd = Notification.Name("septena.openQuickAdd")
}

// MARK: - Logger

enum SeptenaLog {
  #if DEBUG
  static var enabled = true
  #else
  static var enabled = false
  #endif

  static func info(_ msg: @autoclosure () -> String) {
    guard enabled else { return }
    print("[Septena] \(msg())")
  }

  static func error(_ msg: @autoclosure () -> String, _ error: Error? = nil) {
    guard enabled else { return }
    if let error { print("[Septena] ❌ \(msg()) → \(error.localizedDescription)") }
    else { print("[Septena] ❌ \(msg())") }
  }
}

// MARK: - Errors

enum SeptenaError: LocalizedError {
  case server(Int, String)
  case decoding(String)
  case invalidURL

  var errorDescription: String? {
    switch self {
    case .server(let code, let body): return "Server \(code): \(body)"
    case .decoding(let s): return "Decode failed: \(s)"
    case .invalidURL: return "Invalid URL"
    }
  }
}

// MARK: - Client

@MainActor
@Observable
final class SeptenaClient {
  private let baseURL: URL
  private let session: URLSession

  /// True after a transport-level failure (URLError) on the last network
  /// call; cleared on the next successful round-trip. HTTP status errors
  /// (4xx/5xx) and decoding failures don't flip this — they mean we did
  /// reach the server. OfflineBanner observes this for the global indicator.
  var isOffline: Bool = false

  /// Concurrent identical GETs share one in-flight Task. Different call
  /// sites (TaskListView.load, sidebar.load, ProjectDetailView.loadProgress
  /// all asking for `view=all&project=X` on the same navigation) fan into
  /// one network round-trip instead of N. Keyed by absolute URL string.
  private var inFlightGETs: [String: Task<Data, Error>] = [:]

  init(baseURL: URL) {
    self.baseURL = baseURL
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 10
    cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
    self.session = URLSession(configuration: cfg)
    SeptenaLog.info("init baseURL=\(baseURL.absoluteString)")
  }

  static let `default` = URL(string: "http://100.74.150.55:7000")!

  static let shared: SeptenaClient = {
    let raw = ProcessInfo.processInfo.environment["SEPTENA_URL"]
            ?? UserDefaults.standard.string(forKey: "septena.serverURL")
            ?? `default`.absoluteString
    return SeptenaClient(baseURL: URL(string: raw) ?? `default`)
  }()

  // MARK: - Connection test

  func ping() async throws -> String {
    // Cheap reachability check via an Oura probe (1 day = tiny payload).
    // Oura/Withings proxies are the only domains still on FastAPI, so
    // this is a useful real check rather than a synthetic /health hit.
    _ = try await ouraHistory(days: 1)
    return "OK — Septena reachable"
  }

  // MARK: - Health (Oura)

  /// N nights of Oura sleep data. Server returns newest-first via the
  /// `oura` array; the Sleep mini-app reverses for chronological charts.
  func ouraHistory(days: Int = 7) async throws -> [OuraNight] {
    try await getJSON("/api/health/oura",
                      query: [URLQueryItem(name: "days", value: String(days))],
                      as: OuraHistoryResponse.self).oura
  }

  /// N days of Withings weigh-ins. Same envelope as Oura.
  func withingsHistory(days: Int = 14) async throws -> [WithingsRow] {
    try await getJSON("/api/health/withings",
                      query: [URLQueryItem(name: "days", value: String(days))],
                      as: WithingsResponse.self).withings
  }

  // Insights compute lives client-side now (see CorrelationEngine).
  // No /api/insights/* endpoint is called — all data comes from SwiftData
  // (CloudKit-mirrored) plus the existing /api/health/oura read endpoint.

  // MARK: - Section config (color palette type — used by SectionTheme)

  /// In-memory shape for a single section's accent. Kept here (not in
  /// Models.swift) because SectionTheme's default palette and CK mirror
  /// both produce / consume values of this type. No HTTP endpoint reads
  /// or writes it anymore.
  struct SectionConfig: Codable, Hashable {
    let key: String
    let label: String
    let color: String          // hex (e.g. "#ef4444") or "hsl(...)"
  }

  // MARK: - HTTP helpers

  private func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
    var comps = URLComponents(url: baseURL.appendingPathComponent(path),
                              resolvingAgainstBaseURL: true)
    if !query.isEmpty { comps?.queryItems = query }
    guard let u = comps?.url else { throw SeptenaError.invalidURL }
    return u
  }

  private func getJSON<T: Decodable>(_ path: String,
                                     query: [URLQueryItem] = [],
                                     as type: T.Type) async throws -> T {
    let u = try url(path, query: query)
    let key = u.absoluteString
    let task: Task<Data, Error>
    let isCreator: Bool
    if let existing = inFlightGETs[key] {
      task = existing
      isCreator = false
    } else {
      var req = URLRequest(url: u)
      req.httpMethod = "GET"
      SeptenaLog.info("GET \(u.path)\(query.isEmpty ? "" : "?\(query.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&"))")")
      task = Task { [session] in
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code >= 400 {
          throw SeptenaError.server(code, String(data: data, encoding: .utf8) ?? "")
        }
        return data
      }
      inFlightGETs[key] = task
      isCreator = true
    }
    // Only the creator clears the slot — followers must not wipe a slot
    // that's been replaced by a later, distinct request for the same URL.
    defer { if isCreator { inFlightGETs[key] = nil } }
    let data: Data
    do {
      data = try await task.value
      isOffline = false
    } catch let urlError as URLError {
      isOffline = true
      throw urlError
    }
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      SeptenaLog.error("decode \(T.self) failed", error)
      throw SeptenaError.decoding(String(describing: error))
    }
  }
}

// MARK: - Shared provider so views can rebind on settings change

@MainActor
@Observable
final class ClientProvider {
  static let shared = ClientProvider()
  var client: SeptenaClient = .shared
  private init() {}

  func update(baseURL: URL) {
    UserDefaults.standard.set(baseURL.absoluteString, forKey: "septena.serverURL")
    client = SeptenaClient(baseURL: baseURL)
  }
}
