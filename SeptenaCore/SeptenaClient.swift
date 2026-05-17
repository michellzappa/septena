import Foundation

// Septena REST client — talks to the FastAPI backend in /api/tasks.
// No auth; base URL is set via Settings (defaults to http://100.74.150.55:7000).

// MARK: - Change notification

extension Notification.Name {
  /// Posted by SeptenaClient after any task / project / area mutation
  /// completes. Sidebar (and any other observer) subscribes to refresh
  /// counts without having to know about each individual mutation path.
  static let septenaTasksChanged = Notification.Name("septena.tasksChanged")
  /// Posted by the macOS menu bar's "New To-Do" item. ContentView
  /// listens and starts an inline draft on Inbox — same flow as ⌘N.
  static let septenaOpenQuickAdd = Notification.Name("septena.openQuickAdd")
}

// MARK: - Logger

enum SeptenaLog {
  static var enabled = true

  static func info(_ msg: String) {
    guard enabled else { return }
    print("[Septena] \(msg)")
  }

  static func error(_ msg: String, _ error: Error? = nil) {
    guard enabled else { return }
    if let error { print("[Septena] ❌ \(msg) → \(error.localizedDescription)") }
    else { print("[Septena] ❌ \(msg)") }
  }
}

// MARK: - Empty / discard response

/// For endpoints whose response body we don't need. Decodes any JSON object.
struct EmptyResponse: Decodable {
  init(from decoder: Decoder) throws {
    // Discard whatever's in the body — we just want the HTTP status.
    _ = try? decoder.singleValueContainer()
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
    _ = try await getJSON("/api/tasks/counts", as: TasksCounts.self)
    return "OK — Septena reachable"
  }

  func counts() async throws -> TasksCounts {
    try await getJSON("/api/tasks/counts", as: TasksCounts.self)
  }

  // MARK: - Tasks: list views

  /// Server-derived view. Pass `area` or `project` to scope (ignored for `logbook`).
  func list(view: String = "today",
            area: String? = nil,
            project: String? = nil,
            days: Int = 90) async throws -> TasksListResponse {
    var q: [URLQueryItem] = [URLQueryItem(name: "view", value: view)]
    if let area { q.append(URLQueryItem(name: "area", value: area)) }
    if let project { q.append(URLQueryItem(name: "project", value: project)) }
    if view == "logbook" { q.append(URLQueryItem(name: "days", value: String(days))) }
    return try await getJSON("/api/tasks/list", query: q, as: TasksListResponse.self)
  }

  // MARK: - Tasks: mutate

  func create(title: String,
              area: String? = nil,
              project: String? = nil,
              scheduled: Date? = nil,
              due: Date? = nil,
              today: Bool = false,
              notes: String? = nil) async throws -> SeptenaTask {
    var body: [String: Any] = [
      "title": title,
      "today": today,
      "status": "open",
    ]
    if let area { body["area"] = area }
    if let project { body["project"] = project }
    if let scheduled { body["scheduled"] = SeptenaDate.format(scheduled)! }
    if let due { body["due"] = SeptenaDate.format(due)! }
    if let notes { body["notes"] = notes }
    return try await postJSON("/api/tasks/create", body: body, as: SeptenaTask.self)
  }

  /// PATCH semantics — only included keys mutate. Use `Optional<Optional<Date>>`
  /// at call sites isn't ergonomic in Swift, so each clear-able field gets a
  /// dedicated helper below (`schedule`, `setDue`, `moveToArea`, `moveToProject`).
  func update(id: String,
              title: String? = nil,
              notes: String? = nil) async throws -> SeptenaTask {
    var body: [String: Any] = ["id": id]
    if let title { body["title"] = title }
    if let notes { body["notes"] = notes }
    return try await postJSON("/api/tasks/update", body: body, as: SeptenaTask.self)
  }

  func complete(id: String) async throws {
    _ = try await postJSON("/api/tasks/complete", body: ["id": id], as: SeptenaTask.self)
  }

  func uncomplete(id: String) async throws {
    _ = try await postJSON("/api/tasks/uncomplete", body: ["id": id], as: SeptenaTask.self)
  }

  func cancel(id: String) async throws {
    _ = try await postJSON("/api/tasks/cancel", body: ["id": id], as: SeptenaTask.self)
  }

  func delete(id: String) async throws {
    try await deleteRaw("/api/tasks/\(id)")
  }

  func moveToToday(id: String, today: Bool = true) async throws {
    _ = try await postJSON("/api/tasks/move-to-today",
                           body: ["id": id, "today": today],
                           as: SeptenaTask.self)
  }

  /// Pass `nil` to clear the scheduled date.
  func schedule(id: String, date: Date?) async throws {
    var body: [String: Any] = ["id": id]
    body["scheduled"] = SeptenaDate.format(date) ?? NSNull()
    _ = try await postJSON("/api/tasks/schedule", body: body, as: SeptenaTask.self)
  }

  /// Pass `nil` to clear the due date.
  func setDue(id: String, date: Date?) async throws {
    var body: [String: Any] = ["id": id]
    body["due"] = SeptenaDate.format(date) ?? NSNull()
    _ = try await postJSON("/api/tasks/set-due", body: body, as: SeptenaTask.self)
  }

  /// Set or clear a recurrence rule. Pass `nil` to clear. Server spawns the
  /// next instance automatically on `/complete` when a rule is present.
  func setRecurrence(id: String, recurrence: Recurrence?) async throws -> SeptenaTask {
    var body: [String: Any] = ["id": id]
    if let r = recurrence {
      body["recurrence"] = [
        "unit": r.unit.rawValue,
        "interval": r.interval,
        "after_completion": r.afterCompletion,
      ]
    } else {
      body["recurrence"] = NSNull()
    }
    return try await postJSON("/api/tasks/update", body: body, as: SeptenaTask.self)
  }

  /// Septena's update endpoint clears area when explicit `null` is sent. Pass
  /// nil here to clear.
  func moveToArea(id: String, area: String?) async throws -> SeptenaTask {
    var body: [String: Any] = ["id": id]
    body["area"] = area ?? NSNull()
    return try await postJSON("/api/tasks/update", body: body, as: SeptenaTask.self)
  }

  func moveToProject(id: String, project: String?) async throws -> SeptenaTask {
    var body: [String: Any] = ["id": id]
    body["project"] = project ?? NSNull()
    return try await postJSON("/api/tasks/update", body: body, as: SeptenaTask.self)
  }

  // MARK: - Habits / Supplements / Chores (toggleable on Today)

  func habitsDay(date: String) async throws -> HabitsDayResponse {
    try await getJSON("/api/habits/day/\(date)", as: HabitsDayResponse.self)
  }

  func toggleHabit(id: String, date: String, done: Bool) async throws {
    let body: [String: Any] = ["habit_id": id, "date": date, "done": done]
    _ = try await postJSON("/api/habits/toggle", body: body, as: EmptyResponse.self)
  }

  /// Mark/unmark a habit as skipped for the given day. Skipped sits next to
  /// done — the user has decided "not today" and the row should render as
  /// inactive but visible.
  func skipHabit(id: String, date: String, skipped: Bool) async throws {
    let body: [String: Any] = ["habit_id": id, "date": date, "skipped": skipped]
    _ = try await postJSON("/api/habits/skip", body: body, as: EmptyResponse.self)
  }

  func supplementsDay(date: String) async throws -> SupplementsDayResponse {
    try await getJSON("/api/supplements/day/\(date)", as: SupplementsDayResponse.self)
  }

  func toggleSupplement(id: String, date: String, done: Bool) async throws {
    let body: [String: Any] = ["supplement_id": id, "date": date, "done": done]
    _ = try await postJSON("/api/supplements/toggle", body: body, as: EmptyResponse.self)
  }

  func chores() async throws -> [ChoreItem] {
    try await getJSON("/api/chores/list", as: ChoresListResponse.self).chores
  }

  /// N-day completion/total history for chores; powers the Week tile
  /// histogram.
  func choresHistory(days: Int = 7) async throws -> ChoreHistoryResponse {
    try await getJSON("/api/chores/history",
                      query: [URLQueryItem(name: "days", value: String(days))],
                      as: ChoreHistoryResponse.self)
  }

  /// N-day done/total history for habits; powers the Habits tile histogram.
  func habitsHistory(days: Int = 7) async throws -> HabitHistoryResponse {
    try await getJSON("/api/habits/history",
                      query: [URLQueryItem(name: "days", value: String(days))],
                      as: HabitHistoryResponse.self)
  }

  func completeChore(id: String, date: String) async throws {
    let body: [String: Any] = ["chore_id": id, "date": date]
    _ = try await postJSON("/api/chores/complete", body: body, as: EmptyResponse.self)
  }

  func uncompleteChore(id: String, date: String) async throws {
    let body: [String: Any] = ["chore_id": id, "date": date]
    _ = try await postJSON("/api/chores/uncomplete", body: body, as: EmptyResponse.self)
  }

  /// Defer a chore — `mode` is `"day"` (push to tomorrow) or `"weekend"`
  /// (push to the next Saturday). The server bumps the chore's due_date.
  func deferChore(id: String, mode: String) async throws {
    let body: [String: Any] = ["chore_id": id, "mode": mode]
    _ = try await postJSON("/api/chores/defer", body: body, as: EmptyResponse.self)
  }

  /// Server-aggregated "Next" list (habits + supplements + chores, with
  /// defers and bucket filters already applied). Used by the sidebar tile
  /// count and any client that wants the merged Next slice without doing
  /// its own four-fetch dance.
  func nextItems(date: String,
                 limit: Int? = nil,
                 bucket: String? = nil) async throws -> NextItemsResponse {
    var q: [URLQueryItem] = [URLQueryItem(name: "date", value: date)]
    if let limit { q.append(URLQueryItem(name: "limit", value: String(limit))) }
    if let bucket { q.append(URLQueryItem(name: "bucket", value: bucket)) }
    return try await getJSON("/api/next/items", query: q, as: NextItemsResponse.self)
  }

  // MARK: - Sections (for theme accent)

  /// Live section config from Septena. We only care about the Tasks entry's
  /// color, but the endpoint returns all sections — keep it generic.
  struct SectionConfig: Codable, Hashable {
    let key: String
    let label: String
    let color: String          // hex (e.g. "#ef4444") or "hsl(...)"
  }

  func sections() async throws -> [SectionConfig] {
    try await getJSON("/api/sections", as: [SectionConfig].self)
  }

  // MARK: - Areas

  func areas() async throws -> [Area] {
    struct Wrap: Codable { var areas: [Area] }
    return try await getJSON("/api/tasks/areas", as: Wrap.self).areas
  }

  /// Septena replaces the whole areas list atomically. Use this for create / rename / delete.
  func replaceAreas(_ areas: [Area]) async throws -> [Area] {
    struct Wrap: Codable { var areas: [Area] }
    let body: [String: Any] = ["areas": areas.map { area in
      var d: [String: Any] = ["id": area.id, "title": area.title]
      if let c = area.context { d["context"] = c }
      return d
    }]
    return try await putJSON("/api/tasks/areas", body: body, as: Wrap.self).areas
  }

  // MARK: - Projects

  func projects() async throws -> [Project] {
    struct Wrap: Codable { var projects: [Project] }
    return try await getJSON("/api/tasks/projects", as: Wrap.self).projects
  }

  func createProject(title: String,
                     id: String? = nil,
                     area: String? = nil,
                     notes: String? = nil,
                     context: String? = nil,
                     githubRepo: String? = nil) async throws -> Project {
    var body: [String: Any] = ["title": title]
    if let id { body["id"] = id }
    if let area { body["area"] = area }
    if let notes { body["notes"] = notes }
    if let context { body["context"] = context }
    if let githubRepo { body["github_repo"] = githubRepo }
    return try await postJSON("/api/tasks/projects", body: body, as: Project.self)
  }

  /// Pass `githubRepo: .some(nil)` to clear, `.some("owner/repo")` to set,
  /// or omit to leave unchanged — same double-Optional convention as `area`.
  func updateProject(id: String,
                     title: String? = nil,
                     status: String? = nil,
                     area: String?? = nil,
                     notes: String? = nil,
                     context: String? = nil,
                     githubRepo: String?? = nil) async throws -> Project {
    var body: [String: Any] = [:]
    if let title { body["title"] = title }
    if let status { body["status"] = status }
    if let area { body["area"] = area ?? NSNull() }
    if let notes { body["notes"] = notes }
    if let context { body["context"] = context }
    if let githubRepo { body["github_repo"] = githubRepo ?? NSNull() }
    return try await putJSON("/api/tasks/projects/\(id)", body: body, as: Project.self)
  }

  func deleteProject(id: String) async throws {
    try await deleteRaw("/api/tasks/projects/\(id)")
  }

  /// Atomic bulk update — Septena persists the array order, mirroring how
  /// `replaceAreas` works on the areas endpoint. Used by sidebar drag-to-
  /// reorder. Backend contract: `PUT /api/tasks/projects` accepts
  /// `{ "projects": [{id, title, status, area, notes, context}, ...] }`
  /// and returns the same shape it accepts. The server is responsible for
  /// preserving the order it received.
  func replaceProjects(_ projects: [Project]) async throws -> [Project] {
    struct Wrap: Codable { var projects: [Project] }
    let body: [String: Any] = ["projects": projects.map { p in
      var d: [String: Any] = [
        "id": p.id,
        "title": p.title,
        "status": p.status.rawValue,
      ]
      if let area = p.area       { d["area"] = area }
      if let notes = p.notes     { d["notes"] = notes }
      if let context = p.context { d["context"] = context }
      if let gh = p.githubRepo   { d["github_repo"] = gh }
      return d
    }]
    return try await putJSON("/api/tasks/projects", body: body, as: Wrap.self).projects
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
      let preview = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
      SeptenaLog.error("decode \(T.self) failed → \(preview)", error)
      throw SeptenaError.decoding(String(describing: error))
    }
  }

  private func postJSON<T: Decodable>(_ path: String,
                                      body: [String: Any],
                                      as type: T.Type) async throws -> T {
    let u = try url(path)
    var req = URLRequest(url: u)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    SeptenaLog.info("POST \(u.path) body=\(body)")
    let result: T = try await send(req, as: type)
    notifyChanged(for: path)
    return result
  }

  private func putJSON<T: Decodable>(_ path: String,
                                     body: [String: Any],
                                     as type: T.Type) async throws -> T {
    let u = try url(path)
    var req = URLRequest(url: u)
    req.httpMethod = "PUT"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    SeptenaLog.info("PUT \(u.path)")
    let result: T = try await send(req, as: type)
    notifyChanged(for: path)
    return result
  }

  private func deleteRaw(_ path: String) async throws {
    let u = try url(path)
    var req = URLRequest(url: u)
    req.httpMethod = "DELETE"
    SeptenaLog.info("DELETE \(u.path)")
    let data: Data; let resp: URLResponse
    do {
      (data, resp) = try await session.data(for: req)
      isOffline = false
    } catch let urlError as URLError {
      isOffline = true
      throw urlError
    }
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code >= 400 {
      throw SeptenaError.server(code, String(data: data, encoding: .utf8) ?? "")
    }
    notifyChanged(for: path)
  }

  /// Single fan-out point: any mutating HTTP call posts this so observers
  /// (sidebar counts, etc.) can refresh without each call site wiring its
  /// own reload. Scoped to /api/tasks/* — habits / supplements / chores
  /// don't affect sidebar counts or the overdue badge, and firing on every
  /// Next-view tap caused the sidebar to flicker.
  private func notifyChanged(for path: String) {
    guard path.hasPrefix("/api/tasks") else { return }
    NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
  }

  private func send<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
    let data: Data; let resp: URLResponse
    do {
      (data, resp) = try await session.data(for: req)
      isOffline = false
    } catch let urlError as URLError {
      isOffline = true
      throw urlError
    }
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code >= 400 {
      let body = String(data: data, encoding: .utf8) ?? ""
      SeptenaLog.error("HTTP \(code) — \(body.prefix(200))")
      throw SeptenaError.server(code, body)
    }
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      let preview = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
      SeptenaLog.error("decode \(T.self) failed → \(preview)", error)
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
