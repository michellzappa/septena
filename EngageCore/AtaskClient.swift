import Foundation

// ─── Atask REST API Client ──────────────────────────────────────────────────────
// Bridges engage-app to the upstream atask Go backend (arthursoares/atask).
// Set ENGAGE_SERVER_URL and ENGAGE_API_KEY in Xcode scheme, or via Settings screen.
// Auth: Authorization: ApiKey <key>

// MARK: - Logger

/// Toggle verbose logging with: AtaskLog.enabled = true
enum AtaskLog {
    static var enabled = true
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ items: Any..., label: String = "🔵", file: String = #file, function: String = #function, line: Int = #line) {
        guard enabled else { return }
        let fileName = (file as NSString).lastPathComponent
        let timestamp = dateFormatter.string(from: Date())
        let msg = items.map { "\($0)" }.joined(separator: " ")
        print("[\(timestamp)] [AtaskClient] [\(label)] [\(fileName):\(line)] \(msg)")
    }

    static func request(_ method: String, _ path: String, body: [String: Any]? = nil) {
        log("➡️  \(method) \(path)", label: "REQ", file: #file, function: #function, line: #line)
        if let body = body {
            log("    body: \(body)", label: "REQ", file: #file, function: #function, line: #line)
        }
    }

    static func response(_ method: String, _ path: String, status: Int, duration: TimeInterval, body: String? = nil) {
        let label = status < 400 ? "RES" : "ERR"
        log("⬅️   \(method) \(path) → \(status) (\(String(format: "%.0f", duration * 1000))ms)", label: label, file: #file, function: #function, line: #line)
        if let body = body, !body.isEmpty {
            let preview = body.count > 200 ? String(body.prefix(200)) + "..." : body
            log("    body: \(preview)", label: label, file: #file, function: #function, line: #line)
        }
    }

    static func error(_ message: String, error: Error? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        var msg = message
        if let e = error { msg += " → \(e.localizedDescription)" }
        log(msg, label: "❌", file: file, function: function, line: line)
    }

    static func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, label: "ℹ️", file: file, function: function, line: line)
    }
}

// MARK: - Client

@MainActor
final class AtaskClient: ObservableObject {
    private let baseURL: URL
    private let apiKey: String

    init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        AtaskLog.info("AtaskClient init → baseURL=\(baseURL) keyPrefix=\(apiKey.prefix(8))...", file: #file, function: #function, line: #line)
    }

    static let shared: AtaskClient = {
        let url = URL(string: ProcessInfo.processInfo.environment["ENGAGE_SERVER_URL"] ?? "http://localhost:8080")!
        let key = ProcessInfo.processInfo.environment["ENGAGE_API_KEY"] ?? ""
        AtaskLog.info("shared init → baseURL=\(url) keyPrefix=\(key.prefix(8))...", file: #file, function: #function, line: #line)
        return AtaskClient(baseURL: url, apiKey: key)
    }()

    @MainActor
    func updateConfig(baseURL: URL, apiKey: String) {
        AtaskLog.info("updateConfig → baseURL=\(baseURL) keyPrefix=\(apiKey.prefix(8))...")
        ClientProvider.shared.client = AtaskClient(baseURL: baseURL, apiKey: apiKey)
        AtaskLog.info("updateConfig → done, ClientProvider.shared.client updated")
    }

    // MARK: - Connection test

    func ping() async throws -> String {
        AtaskLog.info("ping() — testing connection to \(baseURL)", file: #file, function: #function, line: #line)
        let start = Date()
        do {
            let data = try await get("/tasks?limit=1")
            let duration = Date().timeIntervalSince(start)
            AtaskLog.response("GET", "/tasks?limit=1", status: 200, duration: duration)
            AtaskLog.info("ping() → OK", file: #file, function: #function, line: #line)
            return "OK — server reachable, auth valid"
        } catch {
            AtaskLog.error("ping() failed", error: error, file: #file, function: #function, line: #line)
            throw error
        }
    }

    // MARK: - Auth

    func register(email: String, password: String, name: String) async throws -> User {
        AtaskLog.info("register(email: \(email), name: \(name)")
        let body: [String: Any] = ["email": email, "password": password, "name": name]
        let data = try await post("/auth/register", body: body)
        let user = try JSONDecoder.apiDecoder.decode(User.self, from: data)
        AtaskLog.info("register → user.id=\(user.id)", file: #file, function: #function, line: #line)
        return user
    }

    func login(email: String, password: String) async throws -> String {
        AtaskLog.info("login(email: \(email))")
        let body: [String: Any] = ["email": email, "password": password]
        let data = try await post("/auth/login", body: body)
        let resp = try JSONDecoder().decode([String: String].self, from: data)
        guard let token = resp["token"] else {
            AtaskLog.error("login → no token in response", file: #file, function: #function, line: #line)
            throw AtaskError.invalidResponse
        }
        AtaskLog.info("login → token=\(token.prefix(12))...", file: #file, function: #function, line: #line)
        return token
    }

    func me() async throws -> User {
        AtaskLog.info("me()", file: #file, function: #function, line: #line)
        let data = try await get("/auth/me")
        let user = try JSONDecoder.apiDecoder.decode(User.self, from: data)
        AtaskLog.info("me → user.id=\(user.id)", file: #file, function: #function, line: #line)
        return user
    }

    func createAPIKey(name: String) async throws -> String {
        AtaskLog.info("createAPIKey(name: \(name))")
        let body: [String: Any] = ["name": name]
        let data = try await post("/auth/api-keys", body: body)
        let resp = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        guard let key = resp["key"]?.value as? String else {
            AtaskLog.error("createAPIKey → no key in response", file: #file, function: #function, line: #line)
            throw AtaskError.invalidResponse
        }
        AtaskLog.info("createAPIKey → key=\(key.prefix(10))...", file: #file, function: #function, line: #line)
        return key
    }

    // MARK: - Tasks

    /// List tasks filtered by optional query params.
    /// Params: project_id, area_id, section_id, location_id, schedule, status
    func tasksList(
        projectId: String? = nil,
        areaId: String? = nil,
        sectionId: String? = nil,
        locationId: String? = nil,
        schedule: TaskSchedule? = nil,
        status: String = "pending"
    ) async throws -> [EngageTask] {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "status", value: status)
        ]
        if let p = projectId { queryItems.append(URLQueryItem(name: "project_id", value: p)) }
        if let a = areaId { queryItems.append(URLQueryItem(name: "area_id", value: a)) }
        if let s = sectionId { queryItems.append(URLQueryItem(name: "section_id", value: s)) }
        if let l = locationId { queryItems.append(URLQueryItem(name: "location_id", value: l)) }
        if let sc = schedule { queryItems.append(URLQueryItem(name: "schedule", value: String(sc.rawValue))) }
        AtaskLog.info("tasksList(projectId:\(projectId ?? "nil"), areaId:\(areaId ?? "nil"), schedule:\(schedule?.title ?? "nil"), status:\(status))")
        let data = try await get("/tasks", queryItems: queryItems)
        let tasks = try JSONDecoder.apiDecoder.decode([EngageTask].self, from: data)
        AtaskLog.info("tasksList → \(tasks.count) tasks")
        return tasks
    }

    func taskCreate(
        title: String,
        id: String? = nil,
        schedule: TaskSchedule? = nil,
        startDate: Date? = nil,
        deadline: Date? = nil,
        projectId: String? = nil,
        sectionId: String? = nil,
        areaId: String? = nil,
        locationId: String? = nil,
        repeatRule: RecurrenceRule? = nil,
        tags: [String] = [],
        linkedTaskIds: [String] = []
    ) async throws -> EngageTask {
        var body: [String: Any] = ["title": title]
        if let id = id { body["id"] = id }
        if let sc = schedule { body["schedule"] = sc.rawValue }
        if let sd = startDate { body["startDate"] = dateFormatter.string(from: sd) }
        if let dl = deadline { body["deadline"] = dateFormatter.string(from: dl) }
        if let p = projectId { body["projectId"] = p }
        if let s = sectionId { body["sectionId"] = s }
        if let a = areaId { body["areaId"] = a }
        if let l = locationId { body["locationId"] = l }
        if let rr = repeatRule {
            body["repeatRule"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rr))
        }
        if !tags.isEmpty { body["tags"] = tags }
        if !linkedTaskIds.isEmpty { body["linkedTaskIds"] = linkedTaskIds }
        AtaskLog.info("taskCreate(title: \"\(title)\", projectId:\(projectId ?? "nil"), areaId:\(areaId ?? "nil"), deadline:\(deadline?.description ?? "nil"))")
        let data = try await post("/tasks", body: body)
        let task = try JSONDecoder.apiDecoder.decode(EngageTask.self, from: data)
        AtaskLog.info("taskCreate → id=\(task.id)", file: #file, function: #function, line: #line)
        return task
    }

    func taskGet(id: String) async throws -> EngageTask {
        AtaskLog.info("taskGet(id: \(id))", file: #file, function: #function, line: #line)
        let data = try await get("/tasks/\(id)")
        let task = try JSONDecoder.apiDecoder.decode(EngageTask.self, from: data)
        AtaskLog.info("taskGet → title=\(task.title)", file: #file, function: #function, line: #line)
        return task
    }

    func taskDelete(id: String) async throws {
        AtaskLog.info("taskDelete(id: \(id))", file: #file, function: #function, line: #line)
        try await delete("/tasks/\(id)")
        AtaskLog.info("taskDelete → done", file: #file, function: #function, line: #line)
    }

    func taskComplete(id: String) async throws {
        AtaskLog.info("taskComplete(id: \(id))", file: #file, function: #function, line: #line)
        try await postVoid("/tasks/\(id)/complete", body: [:])
        AtaskLog.info("taskComplete → done", file: #file, function: #function, line: #line)
    }

    func taskCancel(id: String) async throws {
        AtaskLog.info("taskCancel(id: \(id))", file: #file, function: #function, line: #line)
        try await postVoid("/tasks/\(id)/cancel", body: [:])
        AtaskLog.info("taskCancel → done", file: #file, function: #function, line: #line)
    }

    func taskReopen(id: String) async throws {
        AtaskLog.info("taskReopen(id: \(id))", file: #file, function: #function, line: #line)
        try await postVoid("/tasks/\(id)/reopen", body: [:])
        AtaskLog.info("taskReopen → done", file: #file, function: #function, line: #line)
    }

    /// Partial update — only non-nil fields are applied server-side.
    func taskPatch(
        id: String,
        title: String? = nil,
        notes: String? = nil,
        schedule: TaskSchedule? = nil,
        startDate: Date? = nil,
        deadline: Date? = nil,
        projectId: String? = nil,
        sectionId: String? = nil,
        areaId: String? = nil
    ) async throws -> EngageTask {
        var body: [String: Any] = [:]
        if let t = title { body["title"] = t }
        if let n = notes { body["notes"] = n }
        if let sc = schedule { body["schedule"] = sc.rawValue }
        if let sd = startDate { body["startDate"] = dateFormatter.string(from: sd) }
        if let dl = deadline { body["deadline"] = dateFormatter.string(from: dl) }
        if let p = projectId { body["projectId"] = p }
        if let s = sectionId { body["sectionId"] = s }
        if let a = areaId { body["areaId"] = a }
        AtaskLog.info("taskPatch(id: \(id), title:\(title ?? "nil"), notes:\(notes != nil ? "<set>" : "nil"), deadline:\(deadline?.description ?? "nil"), projectId:\(projectId ?? "nil"), areaId:\(areaId ?? "nil"))")
        let data = try await patch("/tasks/\(id)", body: body)
        let task = try JSONDecoder.apiDecoder.decode(EngageTask.self, from: data)
        AtaskLog.info("taskPatch → title=\(task.title)", file: #file, function: #function, line: #line)
        return task
    }

    func taskUpdateTitle(id: String, title: String) async throws {
        AtaskLog.info("taskUpdateTitle(id: \(id), title: \"\(title)\")", file: #file, function: #function, line: #line)
        let body: [String: Any] = ["title": title]
        try await putVoid("/tasks/\(id)/title", body: body)
        AtaskLog.info("taskUpdateTitle → done", file: #file, function: #function, line: #line)
    }

    func taskUpdateNotes(id: String, notes: String) async throws {
        AtaskLog.info("taskUpdateNotes(id: \(id))", file: #file, function: #function, line: #line)
        let body: [String: Any] = ["notes": notes]
        try await putVoid("/tasks/\(id)/notes", body: body)
        AtaskLog.info("taskUpdateNotes → done", file: #file, function: #function, line: #line)
    }

    func taskMoveToProject(id: String, projectId: String?) async throws {
        AtaskLog.info("taskMoveToProject(id: \(id), projectId: \(projectId ?? "nil"))", file: #file, function: #function, line: #line)
        var body: [String: Any] = [:]
        if let p = projectId { body["projectId"] = p }
        try await putVoid("/tasks/\(id)/project", body: body)
        AtaskLog.info("taskMoveToProject → done", file: #file, function: #function, line: #line)
    }

    func taskMoveToArea(id: String, areaId: String?) async throws {
        AtaskLog.info("taskMoveToArea(id: \(id), areaId: \(areaId ?? "nil"))", file: #file, function: #function, line: #line)
        var body: [String: Any] = [:]
        if let a = areaId { body["areaId"] = a }
        try await putVoid("/tasks/\(id)/area", body: body)
        AtaskLog.info("taskMoveToArea → done", file: #file, function: #function, line: #line)
    }

    func taskSetRecurrence(id: String, rule: RecurrenceRule) async throws {
        AtaskLog.info("taskSetRecurrence(id: \(id), rule: \(rule))", file: #file, function: #function, line: #line)
        let body: [String: Any] = [
            "type": rule.type.rawValue,
            "interval": rule.interval,
            "unit": rule.unit.rawValue
        ]
        try await putVoid("/tasks/\(id)/recurrence", body: body)
        AtaskLog.info("taskSetRecurrence → done", file: #file, function: #function, line: #line)
    }

    // MARK: - Views (pre-computed task lists)

    func viewInbox() async throws -> [InlineTask] {
        let data = try await get("/views/inbox")
        return try JSONDecoder.apiDecoder.decode([InlineTask].self, from: data)
    }

    func viewToday() async throws -> [InlineTask] {
        let data = try await get("/views/today")
        return try JSONDecoder.apiDecoder.decode([InlineTask].self, from: data)
    }

    func viewUpcoming() async throws -> [InlineTask] {
        let data = try await get("/views/upcoming")
        return try JSONDecoder.apiDecoder.decode([InlineTask].self, from: data)
    }

    func viewSomeday() async throws -> [InlineTask] {
        let data = try await get("/views/someday")
        return try JSONDecoder.apiDecoder.decode([InlineTask].self, from: data)
    }

    func viewLogbook() async throws -> [InlineTask] {
        let data = try await get("/views/logbook")
        return try JSONDecoder.apiDecoder.decode([InlineTask].self, from: data)
    }

    // MARK: - Projects

    func projectsList(status: String = "pending") async throws -> [Project] {
        AtaskLog.info("projectsList(status: \(status))")
        let data = try await get("/projects", queryItems: [URLQueryItem(name: "status", value: status)])
        let projects = try JSONDecoder.apiDecoder.decode([Project].self, from: data)
        AtaskLog.info("projectsList → \(projects.count) projects")
        return projects
    }

    func projectCreate(title: String, id: String? = nil, areaId: String? = nil) async throws -> Project {
        AtaskLog.info("projectCreate(title: \(title), areaId: \(areaId ?? "nil"))")
        var body: [String: Any] = ["title": title]
        if let id = id { body["id"] = id }
        if let a = areaId { body["areaId"] = a }
        let data = try await post("/projects", body: body)
        let project = try JSONDecoder.apiDecoder.decode(Project.self, from: data)
        AtaskLog.info("projectCreate → id=\(project.id)")
        return project
    }

    func projectGet(id: String) async throws -> Project {
        let data = try await get("/projects/\(id)")
        return try JSONDecoder.apiDecoder.decode(Project.self, from: data)
    }

    func projectDelete(id: String) async throws {
        try await delete("/projects/\(id)")
    }

    func projectComplete(id: String) async throws {
        try await postVoid("/projects/\(id)/complete", body: [:])
    }

    func projectCancel(id: String) async throws {
        try await postVoid("/projects/\(id)/cancel", body: [:])
    }

    func projectPatch(id: String, title: String? = nil, notes: String? = nil, areaId: String? = nil, color: String? = nil) async throws -> Project {
        AtaskLog.info("projectPatch(id: \(id), title:\("\(title ?? "nil")"), areaId:\(areaId ?? "nil"))")
        var body: [String: Any] = [:]
        if let t = title { body["title"] = t }
        if let n = notes { body["notes"] = n }
        if let a = areaId { body["areaId"] = a }
        if let c = color { body["color"] = c }
        let data = try await patch("/projects/\(id)", body: body)
        let project = try JSONDecoder.apiDecoder.decode(Project.self, from: data)
        AtaskLog.info("projectPatch → title=\(project.title)")
        return project
    }

    func projectUpdateTitle(id: String, title: String) async throws {
        let body: [String: Any] = ["title": title]
        try await putVoid("/projects/\(id)/title", body: body)
    }

    // MARK: - Areas

    func areasList() async throws -> [Area] {
        AtaskLog.info("areasList()")
        let data = try await get("/areas")
        let areas = try JSONDecoder.apiDecoder.decode([Area].self, from: data)
        AtaskLog.info("areasList → \(areas.count) areas")
        return areas
    }

    func areaCreate(title: String, id: String? = nil) async throws -> Area {
        AtaskLog.info("areaCreate(title: \(title))")
        var body: [String: Any] = ["title": title]
        if let id = id { body["id"] = id }
        let data = try await post("/areas", body: body)
        let area = try JSONDecoder.apiDecoder.decode(Area.self, from: data)
        AtaskLog.info("areaCreate → id=\(area.id)")
        return area
    }

    func areaGet(id: String) async throws -> Area {
        let data = try await get("/areas/\(id)")
        return try JSONDecoder.apiDecoder.decode(Area.self, from: data)
    }

    func areaDelete(id: String) async throws {
        try await delete("/areas/\(id)")
    }

    func areaArchive(id: String) async throws {
        try await postVoid("/areas/\(id)/archive", body: [:])
    }

    func areaUnarchive(id: String) async throws {
        try await postVoid("/areas/\(id)/unarchive", body: [:])
    }

    func areaPatch(id: String, title: String) async throws -> Area {
        AtaskLog.info("areaPatch(id: \(id), title: \(title))")
        let body: [String: Any] = ["title": title]
        let data = try await patch("/areas/\(id)", body: body)
        let area = try JSONDecoder.apiDecoder.decode(Area.self, from: data)
        AtaskLog.info("areaPatch → title=\(area.title)")
        return area
    }

    // MARK: - Sections

    func sectionsList(projectId: String) async throws -> [Section] {
        let data = try await get("/sections", queryItems: [URLQueryItem(name: "project_id", value: projectId)])
        return try JSONDecoder.apiDecoder.decode([Section].self, from: data)
    }

    func sectionCreate(title: String, projectId: String) async throws -> Section {
        let body: [String: Any] = ["title": title, "projectId": projectId]
        let data = try await post("/sections", body: body)
        return try JSONDecoder.apiDecoder.decode(Section.self, from: data)
    }

    func sectionDelete(id: String) async throws {
        try await delete("/sections/\(id)")
    }

    // MARK: - Tags

    func tagsList() async throws -> [Tag] {
        let data = try await get("/tags")
        return try JSONDecoder.apiDecoder.decode([Tag].self, from: data)
    }

    func tagCreate(title: String) async throws -> Tag {
        let body: [String: Any] = ["title": title]
        let data = try await post("/tags", body: body)
        return try JSONDecoder.apiDecoder.decode(Tag.self, from: data)
    }

    func taskAddTag(taskId: String, tagId: String) async throws {
        try await postVoid("/tasks/\(taskId)/tags/\(tagId)", body: [:])
    }

    func taskRemoveTag(taskId: String, tagId: String) async throws {
        try await delete("/tasks/\(taskId)/tags/\(tagId)")
    }

    // MARK: - Locations

    func locationsList() async throws -> [Location] {
        let data = try await get("/locations")
        return try JSONDecoder.apiDecoder.decode([Location].self, from: data)
    }

    func locationCreate(name: String) async throws -> Location {
        let body: [String: Any] = ["name": name]
        let data = try await post("/locations", body: body)
        return try JSONDecoder.apiDecoder.decode(Location.self, from: data)
    }

    // MARK: - Checklist

    func checklistAdd(taskId: String, title: String) async throws -> ChecklistItem {
        AtaskLog.info("checklistAdd(taskId: \(taskId), title: \(title))")
        let body: [String: Any] = ["title": title]
        let data = try await post("/tasks/\(taskId)/checklist", body: body)
        let item = try JSONDecoder.apiDecoder.decode(ChecklistItem.self, from: data)
        AtaskLog.info("checklistAdd → item.id=\(item.id)")
        return item
    }

    func checklistComplete(taskId: String, itemId: String) async throws {
        AtaskLog.info("checklistComplete(taskId: \(taskId), itemId: \(itemId))")
        try await postVoid("/tasks/\(taskId)/checklist/\(itemId)/complete", body: [:])
        AtaskLog.info("checklistComplete → done")
    }

    func checklistUncomplete(taskId: String, itemId: String) async throws {
        AtaskLog.info("checklistUncomplete(taskId: \(taskId), itemId: \(itemId))")
        try await postVoid("/tasks/\(taskId)/checklist/\(itemId)/uncomplete", body: [:])
        AtaskLog.info("checklistUncomplete → done")
    }

    func checklistDelete(taskId: String, itemId: String) async throws {
        AtaskLog.info("checklistDelete(taskId: \(taskId), itemId: \(itemId))")
        try await delete("/tasks/\(taskId)/checklist/\(itemId)")
        AtaskLog.info("checklistDelete → done")
    }

    func checklistReorder(taskId: String, itemId: String, index: Int) async throws {
        let body: [String: Any] = ["index": index]
        try await putVoid("/tasks/\(taskId)/checklist/\(itemId)/reorder", body: body)
    }

    // MARK: - Task Links

    func taskAddLink(taskId: String, linkedTaskId: String) async throws {
        try await postVoid("/tasks/\(taskId)/links/\(linkedTaskId)", body: [:])
    }

    func taskRemoveLink(taskId: String, linkedTaskId: String) async throws {
        try await delete("/tasks/\(taskId)/links/\(linkedTaskId)")
    }

    // MARK: - Sync

    func syncDeltas(since: Int64 = 0) async throws -> [DeltaEvent] {
        let data = try await get("/sync/deltas", queryItems: [URLQueryItem(name: "since", value: String(since))])
        return try JSONDecoder.apiDecoder.decode([DeltaEvent].self, from: data)
    }


    // MARK: - Agents (Engage-specific — not yet in upstream atask)

    func agentsList() async throws -> [Agent] {
        AtaskLog.info("agentsList() — not yet implemented in upstream atask")
        throw AtaskError.serverError(501)
    }

    func agentMemory(agentId: String) async throws -> [AgentMemoryEntry] {
        AtaskLog.info("agentMemory(agentId: \(agentId)) — not yet implemented")
        throw AtaskError.serverError(501)
    }

    // MARK: - HTTP helpers

    private func get(_ path: String, queryItems: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: true)!
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        let url = components.url!
        let query = queryItems.isEmpty ? "" : "?\(components.percentEncodedQuery ?? "")"
        AtaskLog.request("GET", "\(path)\(query)")
        let start = Date()
        var req = URLRequest(url: url)
        req.addValue("ApiKey \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let duration = Date().timeIntervalSince(start)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let bodyStr = String(data: data, encoding: .utf8)
        AtaskLog.response("GET", path, status: status, duration: duration, body: bodyStr)
        guard status < 400 else {
            throw AtaskError.serverError(status)
        }
        return data
    }

    private func post(_ path: String, body: [String: Any]) async throws -> Data {
        AtaskLog.request("POST", path, body: body)
        let start = Date()
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue("ApiKey \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let duration = Date().timeIntervalSince(start)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let bodyStr = String(data: data, encoding: .utf8)
        AtaskLog.response("POST", path, status: status, duration: duration, body: bodyStr)
        guard status < 400 else {
            throw AtaskError.serverError(status)
        }
        return data
    }

    private func patch(_ path: String, body: [String: Any]) async throws -> Data {
        AtaskLog.request("PATCH", path, body: body)
        let start = Date()
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "PATCH"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue("ApiKey \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let duration = Date().timeIntervalSince(start)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let bodyStr = String(data: data, encoding: .utf8)
        AtaskLog.response("PATCH", path, status: status, duration: duration, body: bodyStr)
        guard status < 400 else {
            throw AtaskError.serverError(status)
        }
        return data
    }

    private func putVoid(_ path: String, body: [String: Any]) async throws {
        _ = try await put(path, body: body)
    }

    private func put(_ path: String, body: [String: Any]) async throws -> Data {
        AtaskLog.request("PUT", path, body: body)
        let start = Date()
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "PUT"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue("ApiKey \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let duration = Date().timeIntervalSince(start)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let bodyStr = String(data: data, encoding: .utf8)
        AtaskLog.response("PUT", path, status: status, duration: duration, body: bodyStr)
        guard status < 400 else {
            throw AtaskError.serverError(status)
        }
        return data
    }

    private func delete(_ path: String) async throws {
        AtaskLog.request("DELETE", path)
        let start = Date()
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "DELETE"
        req.addValue("ApiKey \(apiKey)", forHTTPHeaderField: "Authorization")
        let (_, resp) = try await URLSession.shared.data(for: req)
        let duration = Date().timeIntervalSince(start)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        AtaskLog.response("DELETE", path, status: status, duration: duration)
        guard status < 400 else {
            throw AtaskError.serverError(status)
        }
    }

    private func postVoid(_ path: String, body: [String: Any]) async throws {
        _ = try await post(path, body: body)
    }

    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }
}

// MARK: - Error

enum AtaskError: LocalizedError {
    case serverError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .serverError(let code): return "Server error: \(code)"
        case .invalidResponse: return "Invalid server response"
        }
    }
}

// MARK: - AnyCodable helper for mixed-type JSON decode

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { value = s }
        else if let i = try? container.decode(Int.self) { value = i }
        else if let d = try? container.decode(Double.self) { value = d }
        else if let b = try? container.decode(Bool.self) { value = b }
        else if let a = try? container.decode([String: AnyCodable].self) {
            value = a.mapValues { $0.value }
        } else if let a = try? container.decode([AnyCodable].self) {
            value = a.map { $0.value }
        } else { value = "" }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let s = value as? String { try container.encode(s) }
        else if let i = value as? Int { try container.encode(i) }
        else if let d = value as? Double { try container.encode(d) }
        else if let b = value as? Bool { try container.encode(b) }
        else { try container.encodeNil() }
    }
}

// MARK: - JSON Decoder extension

extension JSONDecoder {
    static var apiDecoder: JSONDecoder {
        let d = JSONDecoder()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        fmt.timeZone = TimeZone(identifier: "UTC")
        let dateStrat = JSONDecoder.DateDecodingStrategy.custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateStr = try container.decode(String.self)
            let formats = [
                "yyyy-MM-dd'T'HH:mm:ss.SSSSSSS'Z'",
                "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'",
                "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
                "yyyy-MM-dd'T'HH:mm:ss'Z'",
                "yyyy-MM-dd"
            ]
            for format in formats {
                let f = DateFormatter()
                f.dateFormat = format
                f.timeZone = TimeZone(identifier: "UTC")
                if let d = f.date(from: dateStr) { return d }
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date: \(dateStr)")
        }
        d.dateDecodingStrategy = dateStrat
        return d
    }
}

// MARK: - ClientProvider (shared singleton accessor)

final class ClientProvider: ObservableObject {
    static let shared = ClientProvider()
    @Published var client: AtaskClient = .shared
    private init() {}

    @MainActor
    func update(baseURL: URL, apiKey: String) {
        self.client = AtaskClient(baseURL: baseURL, apiKey: apiKey)
    }
}
