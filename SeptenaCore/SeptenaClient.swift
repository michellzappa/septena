import Foundation

// Septena REST client — talks to the FastAPI backend in /api/tasks.
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
    // Cheap reachability check via the sections endpoint (still on FastAPI).
    _ = try await sections()
    return "OK — Septena reachable"
  }

  /// Delta-sync endpoint. Pass the `serverTime` returned from the previous
  /// call as `since` to get only records changed (or tombstoned) since
  /// that watermark. Pass nil on first sync to fetch a full snapshot.
  /// Tasks are no longer pulled through this path (CloudKit owns them);
  /// the projects + areas slices are still consumed by `Syncer.apply`.
  func changes(since: String? = nil) async throws -> ChangesResponse {
    var query: [URLQueryItem] = []
    if let since { query.append(URLQueryItem(name: "since", value: since)) }
    return try await getJSON("/api/tasks/changes", query: query, as: ChangesResponse.self)
  }

  // MARK: - Habits / Supplements / Chores (toggleable on Today)

  func habitsDay(date: String) async throws -> HabitsDayResponse {
    try await getJSON("/api/habits/day/\(date)", as: HabitsDayResponse.self)
  }

  func habitsRange(days: Int = 14) async throws -> HabitsRangeResponse {
    try await getJSON("/api/habits/range",
                      query: [URLQueryItem(name: "days", value: String(days))],
                      as: HabitsRangeResponse.self)
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

  func supplementsRange(days: Int = 14) async throws -> SupplementsRangeResponse {
    try await getJSON("/api/supplements/range",
                      query: [URLQueryItem(name: "days", value: String(days))],
                      as: SupplementsRangeResponse.self)
  }

  func toggleSupplement(id: String, date: String, done: Bool) async throws {
    let body: [String: Any] = ["supplement_id": id, "date": date, "done": done]
    _ = try await postJSON("/api/supplements/toggle", body: body, as: EmptyResponse.self)
  }

  /// N-day done/total history for supplements; powers the Supplements tile
  /// histogram.
  func supplementsHistory(days: Int = 7) async throws -> SupplementHistoryResponse {
    try await getJSON("/api/supplements/history",
                      query: [URLQueryItem(name: "days", value: String(days))],
                      as: SupplementHistoryResponse.self)
  }

  func chores() async throws -> [ChoreItem] {
    try await getJSON("/api/chores/list", as: ChoresListResponse.self).chores
  }

  func choresExport(days: Int = 3650) async throws -> ChoresExportResponse {
    try await getJSON("/api/chores/export",
                      query: [URLQueryItem(name: "days", value: String(days))],
                      as: ChoresExportResponse.self)
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

  // MARK: - Training

  /// Flat list of logged exercise entries since the given YYYY-MM-DD.
  /// Server returns most-recent-first by date; group client-side into
  /// session blocks (same date + session string).
  func trainingEntries(since: String? = nil) async throws -> [ExerciseEntry] {
    let q: [URLQueryItem] = since.map { [URLQueryItem(name: "since", value: $0)] } ?? []
    return try await getJSON("/api/training/entries", query: q, as: [ExerciseEntry].self)
  }

  /// Per-day cardio minutes + the user's configured weekly Z2 target.
  /// Drives the Training tile's histogram + Z2 progress bar.
  func trainingCardioHistory(days: Int = 7) async throws -> CardioHistoryResponse {
    try await getJSON("/api/training/cardio-history",
                      query: [URLQueryItem(name: "days", value: String(days))],
                      as: CardioHistoryResponse.self)
  }

  /// Per-exercise progression series (one point per logged date).
  func trainingProgression(exercise: String) async throws -> [ProgressionPoint] {
    let encoded = exercise.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? exercise
    let response = try await getJSON("/api/training/progression/\(encoded)",
                                     as: ProgressionResponse.self)
    return response.data
  }

  /// Exercises summary since a YYYY-MM-DD cutoff (or all-time if nil),
  /// with per-exercise counts. Drives the exercise pills.
  func trainingSummary(since: String? = nil) async throws -> [ExerciseSummary] {
    let q: [URLQueryItem] = since.map { [URLQueryItem(name: "since", value: $0)] } ?? []
    return try await getJSON("/api/training/summary", query: q, as: [ExerciseSummary].self)
  }

  // MARK: - Nutrition

  /// Logged nutrition entries since the given YYYY-MM-DD.
  func nutritionEntries(since: String? = nil) async throws -> [NutritionEntry] {
    let q: [URLQueryItem] = since.map { [URLQueryItem(name: "since", value: $0)] } ?? []
    return try await getJSON("/api/nutrition/entries", query: q, as: [NutritionEntry].self)
  }

  /// Per-day macro totals + today summary. Powers the Nutrition tile
  /// histogram and the destination's daily averages.
  func nutritionStats(days: Int = 7) async throws -> NutritionStatsResponse {
    try await getJSON("/api/nutrition/stats",
                      query: [URLQueryItem(name: "days", value: String(days))],
                      as: NutritionStatsResponse.self)
  }

  /// User's configured macro targets (protein/fat/carbs/kcal ranges).
  func nutritionMacrosConfig() async throws -> MacrosConfig {
    try await getJSON("/api/nutrition/macros-config", as: MacrosConfig.self)
  }

  // MARK: - Settings

  /// User's full Septena configuration (targets, units, theme, time, etc).
  /// Decoded with our trimmed AppSettings — extra server fields ignored.
  func settings() async throws -> AppSettings {
    try await getJSON("/api/settings", as: AppSettings.self)
  }

  // MARK: - Caffeine

  func caffeineDay(date: String) async throws -> CaffeineDayResponse {
    try await getJSON("/api/caffeine/day/\(date)", as: CaffeineDayResponse.self)
  }

  func caffeineHistory(days: Int = 7) async throws -> CaffeineHistoryResponse {
    try await getJSON("/api/caffeine/history",
                      query: [URLQueryItem(name: "days", value: String(days))],
                      as: CaffeineHistoryResponse.self)
  }

  func caffeineEntries(days: Int = 7) async throws -> CaffeineEntriesResponse {
    try await getJSON("/api/caffeine/entries",
                      query: [URLQueryItem(name: "days", value: String(days))],
                      as: CaffeineEntriesResponse.self)
  }

  // MARK: - Cannabis

  func cannabisDay(date: String) async throws -> CannabisDayResponse {
    try await getJSON("/api/cannabis/day/\(date)", as: CannabisDayResponse.self)
  }

  func cannabisHistory(days: Int = 7) async throws -> CannabisHistoryResponse {
    try await getJSON("/api/cannabis/history",
                      query: [URLQueryItem(name: "days", value: String(days))],
                      as: CannabisHistoryResponse.self)
  }

  func cannabisEntries(days: Int = 7) async throws -> CannabisEntriesResponse {
    try await getJSON("/api/cannabis/entries",
                      query: [URLQueryItem(name: "days", value: String(days))],
                      as: CannabisEntriesResponse.self)
  }

  // MARK: - Air

  /// Snapshot for the Air mini-app — latest reading + today / last-24h
  /// CO2/temp/humidity averages and CO2 band.
  func airSummary() async throws -> AirSummary {
    try await getJSON("/api/air/summary", as: AirSummary.self)
  }

  /// Per-day air stats; powers the Air tile histogram (CO2 average bars).
  func airHistory(days: Int = 7) async throws -> AirHistoryResponse {
    try await getJSON("/api/air/history",
                      query: [URLQueryItem(name: "days", value: String(days))],
                      as: AirHistoryResponse.self)
  }

  // MARK: - Goals

  func goals() async throws -> [Goal] {
    try await getJSON("/api/goals", as: GoalsList.self).goals
  }

  func createGoal(text: String, sections: [String] = []) async throws -> Goal {
    let body: [String: Any] = ["text": text, "sections": sections]
    return try await postJSON("/api/goals", body: body, as: GoalMutation.self).goal
  }

  func updateGoal(id: String, text: String? = nil, sections: [String]? = nil) async throws -> Goal {
    var body: [String: Any] = [:]
    if let text { body["text"] = text }
    if let sections { body["sections"] = sections }
    return try await putJSON("/api/goals/\(id)", body: body, as: GoalMutation.self).goal
  }

  func deleteGoal(id: String) async throws {
    try await deleteRaw("/api/goals/\(id)")
  }

  // MARK: - Groceries

  /// The current pantry list — both "in stock" and "running low" items.
  /// Sorted client-side; server returns them in storage order.
  func groceries() async throws -> [GroceryItem] {
    try await getJSON("/api/groceries", as: GroceriesResponse.self).items
  }

  /// Full groceries payload: items + user-defined categories (in display order).
  /// Older servers may omit `categories`; callers should fall back to
  /// `DEFAULT_GROCERY_CATEGORIES` in that case.
  func groceriesFull() async throws -> (items: [GroceryItem], categories: [GroceryCategory]) {
    let res = try await getJSON("/api/groceries", as: GroceriesResponse.self)
    let cats = res.categories?.isEmpty == false ? res.categories! : DEFAULT_GROCERY_CATEGORIES
    return (res.items, cats)
  }

  /// Flip an item's `low` flag (the shopping-list state). Body matches
  /// the webapp's PATCH /api/groceries/item/{id} signature.
  func patchGroceryItem(id: String, low: Bool) async throws {
    let path = "/api/groceries/item/\(id)"
    let body: [String: Any] = ["low": low]
    guard var comps = URLComponents(url: baseURL.appendingPathComponent(path),
                                    resolvingAgainstBaseURL: false) else {
      throw SeptenaError.invalidURL
    }
    comps.queryItems = nil
    guard let u = comps.url else { throw SeptenaError.invalidURL }
    var req = URLRequest(url: u)
    req.httpMethod = "PATCH"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, resp) = try await session.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code >= 400 {
      throw SeptenaError.server(code, String(data: data, encoding: .utf8) ?? "")
    }
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

  // MARK: - Gut

  func gutDay(date: String) async throws -> GutDayResponse {
    try await getJSON("/api/gut/day/\(date)", as: GutDayResponse.self)
  }

  func gutHistory(days: Int = 7) async throws -> GutHistoryResponse {
    try await getJSON("/api/gut/history",
                      query: [URLQueryItem(name: "days", value: String(days))],
                      as: GutHistoryResponse.self)
  }

  func gutExport() async throws -> GutExportResponse {
    try await getJSON("/api/gut/export", as: GutExportResponse.self)
  }

  func caffeineExport() async throws -> CaffeineExportResponse {
    try await getJSON("/api/caffeine/export", as: CaffeineExportResponse.self)
  }

  func cannabisExport() async throws -> CannabisExportResponse {
    try await getJSON("/api/cannabis/export", as: CannabisExportResponse.self)
  }

  func trainingExport() async throws -> TrainingExportResponse {
    try await getJSON("/api/training/export", as: TrainingExportResponse.self)
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

  // MARK: - Add Info: create / log mutators

  /// Define a new habit. Bucket is `"morning" | "afternoon" | "evening"`.
  func createHabit(name: String, bucket: String, emoji: String? = nil) async throws {
    var body: [String: Any] = ["name": name, "bucket": bucket]
    if let emoji { body["emoji"] = emoji }
    _ = try await postJSON("/api/habits/new", body: body, as: EmptyResponse.self)
  }

  /// Define a new supplement. Bucket is `"morning" | "afternoon" | "evening"`.
  func createSupplement(name: String, bucket: String, emoji: String? = nil) async throws {
    var body: [String: Any] = ["name": name, "bucket": bucket]
    if let emoji { body["emoji"] = emoji }
    _ = try await postJSON("/api/supplements/new", body: body, as: EmptyResponse.self)
  }

  /// Define a new recurring chore. Cadence is in days.
  func createChoreDefinition(name: String, cadenceDays: Int, emoji: String? = nil) async throws {
    var body: [String: Any] = ["name": name, "cadence_days": cadenceDays]
    if let emoji { body["emoji"] = emoji }
    _ = try await postJSON("/api/chores/definitions", body: body, as: EmptyResponse.self)
  }

  /// Log a Bristol-scale entry. Blood defaults to 0 (none).
  func addGutEntry(date: String, time: String, bristol: Int, blood: Int = 0) async throws {
    let body: [String: Any] = [
      "date": date, "time": time, "bristol": bristol, "blood": blood,
    ]
    _ = try await postJSON("/api/gut/entry", body: body, as: EmptyResponse.self)
  }

  /// Log a meal. `foods` is a non-empty list; macros are optional and
  /// inherited from the source entry when duplicating a recent meal.
  func addNutritionEntry(date: String,
                         time: String,
                         foods: [String],
                         proteinG: Double? = nil,
                         fatG: Double? = nil,
                         carbsG: Double? = nil,
                         fiberG: Double? = nil,
                         kcal: Double? = nil,
                         emoji: String? = nil) async throws {
    var body: [String: Any] = ["date": date, "time": time, "foods": foods]
    if let proteinG { body["protein_g"] = proteinG }
    if let fatG     { body["fat_g"]     = fatG }
    if let carbsG   { body["carbs_g"]   = carbsG }
    if let fiberG   { body["fiber_g"]   = fiberG }
    if let kcal     { body["kcal"]      = kcal }
    if let emoji    { body["emoji"]     = emoji }
    _ = try await postJSON("/api/nutrition/entries", body: body, as: EmptyResponse.self)
  }

  /// Caffeine config — beans + method list. Optional endpoint; the page
  /// falls back gracefully when this 404s.
  func caffeineConfig() async throws -> CaffeineConfig {
    try await getJSON("/api/caffeine/config", as: CaffeineConfig.self)
  }

  func addCaffeineEntry(date: String,
                        time: String,
                        method: String,
                        beans: String? = nil,
                        grams: Double? = nil,
                        note: String? = nil) async throws {
    var body: [String: Any] = [
      "date": date, "time": time, "method": method,
      "timezone": TimeZone.current.identifier,
    ]
    if let beans { body["beans"] = beans }
    if let grams { body["grams"] = grams }
    if let note  { body["note"]  = note  }
    _ = try await postJSON("/api/caffeine/entry", body: body, as: EmptyResponse.self)
  }

  /// Cannabis config — strain list + uses-per-capsule cap.
  func cannabisConfig() async throws -> CannabisConfig {
    try await getJSON("/api/cannabis/config", as: CannabisConfig.self)
  }

  func addCannabisEntry(date: String,
                        time: String,
                        method: String,
                        strain: String? = nil,
                        hit: Int? = nil) async throws {
    var body: [String: Any] = ["date": date, "time": time, "method": method]
    if let strain { body["strain"] = strain }
    if let hit    { body["hit"]    = hit    }
    _ = try await postJSON("/api/cannabis/entry", body: body, as: EmptyResponse.self)
  }

  /// Append a new grocery item; default category mirrors the webapp ("other").
  func addGroceryItem(name: String, category: String = "other", emoji: String? = nil) async throws {
    var body: [String: Any] = ["name": name, "category": category]
    if let emoji { body["emoji"] = emoji }
    _ = try await postJSON("/api/groceries/item", body: body, as: EmptyResponse.self)
  }

  /// Suggested workout type for the next training session.
  func suggestedWorkout() async throws -> SuggestedWorkoutResponse {
    try await getJSON("/api/training/suggested-workout", as: SuggestedWorkoutResponse.self)
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

  private func postJSON<T: Decodable>(_ path: String,
                                      body: [String: Any],
                                      as type: T.Type) async throws -> T {
    let u = try url(path)
    var req = URLRequest(url: u)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    SeptenaLog.info("POST \(u.path)")
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

  /// Execute an arbitrary HTTP request without decoding the response.
  /// Used by `HTTPOutbox` to drain queued non-task mutations through the
  /// same transport (offline detection, header conventions, error codes)
  /// as everything else.
  func executeRaw(method: String, path: String, bodyData: Data? = nil) async throws {
    let u = try url(path)
    var req = URLRequest(url: u)
    req.httpMethod = method
    if let bodyData {
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
      req.httpBody = bodyData
    }
    SeptenaLog.info("\(method) \(u.path)")
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
    if path.hasPrefix("/api/tasks") {
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    } else if path.hasPrefix("/api/") {
      NotificationCenter.default.post(name: .septenaDataChanged, object: nil)
    }
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
      SeptenaLog.error("HTTP \(code)")
      throw SeptenaError.server(code, body)
    }
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      SeptenaLog.error("decode \(T.self) failed", error)
      throw SeptenaError.decoding(String(describing: error))
    }
  }
}

// MARK: - Training: session start / save
//
// Three endpoints power the iOS logger:
//   • `session-types` returns the user's configured Upper/Lower/Cardio/Yoga
//     (plus any custom splits). Server-owned so changes don't need an app
//     update.
//   • `last-entries` is a batch prefill — give it the exercise list and it
//     returns last-logged values per exercise to seed the inputs.
//   • `sessions` accepts one-or-many entries; the logger POSTs as the user
//     marks each exercise "Done" so a mid-workout crash never loses work.

extension SeptenaClient {
  /// User-configurable session-type list. Returned by FastAPI so a user
  /// can rename "Upper" → "Push", reorder, or add custom splits without
  /// shipping a new app. Each entry carries its canonical exercise list
  /// (may be empty for free-form types).
  func sessionTypes() async throws -> [SessionTypeConfig] {
    try await getJSON("/api/training/session-types",
                      as: SessionTypesResponse.self).sessionTypes
  }

  /// Look up last-logged values for a batch of exercises so the logger
  /// pre-fills weight/sets/reps (or duration/distance/level for cardio).
  /// Mirrors the webapp's `getLastEntries` call right before draft start.
  func lastEntries(exercises: [String]) async throws -> [String: LastEntryValues] {
    // Hand-rolled — response is a free-form dict (keys = exercise names,
    // values may be null for exercises never logged before). The generic
    // postJSON helper can't express that.
    let body: [String: Any] = ["exercises": exercises]
    let u = try url("/api/training/last-entries")
    var req = URLRequest(url: u)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    SeptenaLog.info("POST \(u.path)")
    let data: Data; let resp: URLResponse
    do {
      (data, resp) = try await session.data(for: req)
      isOffline = false
    } catch let urlError as URLError {
      isOffline = true; throw urlError
    }
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code >= 400 {
      throw SeptenaError.server(code, String(data: data, encoding: .utf8) ?? "")
    }
    let map = try JSONDecoder().decode([String: LastEntryValues?].self, from: data)
    return map.compactMapValues { $0 }
  }

  /// Persist one or more entries from an in-progress session. Called
  /// incrementally as the user marks each exercise "Done" — same shape as
  /// the webapp's `postSession`. Skipped entries are filtered server-side.
  /// `savedFile` (when set on an entry) overwrites a previous save for
  /// the same exercise — used when the user re-edits a done card.
  @discardableResult
  func postTrainingSession(date: String,
                           time: String,
                           sessionType: String,
                           entries: [DraftEntry]) async throws -> [String] {
    struct WriteResponse: Decodable { let written: [String] }
    let payload: [[String: Any]] = entries.map { e in
      var d: [String: Any] = [
        "exercise": e.exercise,
        "skipped": e.status == .skipped,
        "note": e.note,
      ]
      if e.isCardio {
        if let dm = e.durationMin { d["duration_min"] = dm }
        if let m  = e.distanceM   { d["distance_m"]   = m }
        if let l  = e.level       { d["level"]        = l }
      } else {
        if let w = e.weight { d["weight"] = w }
        if let s = e.sets   { d["sets"]   = s }
        if let r = e.reps   { d["reps"]   = r }
        if !e.difficulty.isEmpty { d["difficulty"] = e.difficulty }
      }
      if let rf = e.savedFile { d["replace_file"] = rf }
      return d
    }
    let body: [String: Any] = [
      "date": date,
      "time": time,
      "session_type": sessionType,
      "entries": payload,
    ]
    return try await postJSON("/api/training/sessions",
                              body: body, as: WriteResponse.self).written
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
