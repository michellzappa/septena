import Foundation

// ─── Atask REST API Client ──────────────────────────────────────────────────────
// Bridges engage-app to the upstream atask Go backend (arthursoares/atask).
// Set ENGAGE_SERVER_URL and ENGAGE_API_KEY in Xcode scheme, or via Settings screen.
// Auth: Authorization: ApiKey <key>

@MainActor
final class AtaskClient: ObservableObject {
    private let baseURL: URL
    private let apiKey: String

    init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    static let shared: AtaskClient = {
        let url = URL(string: ProcessInfo.processInfo.environment["ENGAGE_SERVER_URL"] ?? "http://localhost:8080")!
        let key = ProcessInfo.processInfo.environment["ENGAGE_API_KEY"] ?? ""
        return AtaskClient(baseURL: url, apiKey: key)
    }()

    func updateConfig(baseURL: URL, apiKey: String) {
        // Re-create shared singleton with new config
        ObjectPublisher.shared.client = AtaskClient(baseURL: baseURL, apiKey: apiKey)
    }

    // MARK: - Connection test

    func ping() async throws -> String {
        let data = try await get("/tasks?limit=1")
        if let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return "OK — server reachable"
        }
        return "OK"
    }

    // MARK: - Auth

    func register(email: String, password: String, name: String) async throws -> User {
        let body: [String: Any] = ["email": email, "password": password, "name": name]
        let data = try await post("/auth/register", body: body)
        return try JSONDecoder().decode(User.self, from: data)
    }

    func login(email: String, password: String) async throws -> String {
        let body: [String: Any] = ["email": email, "password": password]
        let data = try await post("/auth/login", body: body)
        let resp = try JSONDecoder().decode([String: String].self, from: data)
        guard let token = resp["token"] else {
            throw AtaskError.invalidResponse
        }
        return token
    }

    func me() async throws -> User {
        let data = try await get("/auth/me")
        return try JSONDecoder().decode(User.self, from: data)
    }

    func createAPIKey(name: String) async throws -> String {
        let body: [String: Any] = ["name": name]
        let data = try await post("/auth/api-keys", body: body)
        let resp = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        guard let key = resp["key"]?.value as? String else {
            throw AtaskError.invalidResponse
        }
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

        let data = try await get("/tasks", queryItems: queryItems)
        return try JSONDecoder.apiDecoder.decode([EngageTask].self, from: data)
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

        let data = try await post("/tasks", body: body)
        return try JSONDecoder.apiDecoder.decode(EngageTask.self, from: data)
    }

    func taskGet(id: String) async throws -> EngageTask {
        let data = try await get("/tasks/\(id)")
        return try JSONDecoder.apiDecoder.decode(EngageTask.self, from: data)
    }

    func taskDelete(id: String) async throws {
        try await delete("/tasks/\(id)")
    }

    func taskComplete(id: String) async throws {
        try await postVoid("/tasks/\(id)/complete", body: [:])
    }

    func taskCancel(id: String) async throws {
        try await postVoid("/tasks/\(id)/cancel", body: [:])
    }

    func taskReopen(id: String) async throws {
        try await postVoid("/tasks/\(id)/reopen", body: [:])
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

        let data = try await patch("/tasks/\(id)", body: body)
        return try JSONDecoder.apiDecoder.decode(EngageTask.self, from: data)
    }

    func taskUpdateTitle(id: String, title: String) async throws {
        let body: [String: Any] = ["title": title]
        try await putVoid("/tasks/\(id)/title", body: body)
    }

    func taskUpdateNotes(id: String, notes: String) async throws {
        let body: [String: Any] = ["notes": notes]
        try await putVoid("/tasks/\(id)/notes", body: body)
    }

    func taskMoveToProject(id: String, projectId: String?) async throws {
        var body: [String: Any] = [:]
        if let p = projectId { body["projectId"] = p }
        try await putVoid("/tasks/\(id)/project", body: body)
    }

    func taskMoveToArea(id: String, areaId: String?) async throws {
        var body: [String: Any] = [:]
        if let a = areaId { body["areaId"] = a }
        try await putVoid("/tasks/\(id)/area", body: body)
    }

    func taskSetRecurrence(id: String, rule: RecurrenceRule) async throws {
        let body: [String: Any] = [
            "type": rule.type.rawValue,
            "interval": rule.interval,
            "unit": rule.unit.rawValue
        ]
        try await putVoid("/tasks/\(id)/recurrence", body: body)
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
        let data = try await get("/projects", queryItems: [URLQueryItem(name: "status", value: status)])
        return try JSONDecoder.apiDecoder.decode([Project].self, from: data)
    }

    func projectCreate(title: String, id: String? = nil, areaId: String? = nil) async throws -> Project {
        var body: [String: Any] = ["title": title]
        if let id = id { body["id"] = id }
        if let a = areaId { body["areaId"] = a }
        let data = try await post("/projects", body: body)
        return try JSONDecoder.apiDecoder.decode(Project.self, from: data)
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
        var body: [String: Any] = [:]
        if let t = title { body["title"] = t }
        if let n = notes { body["notes"] = n }
        if let a = areaId { body["areaId"] = a }
        if let c = color { body["color"] = c }
        let data = try await patch("/projects/\(id)", body: body)
        return try JSONDecoder.apiDecoder.decode(Project.self, from: data)
    }

    func projectUpdateTitle(id: String, title: String) async throws {
        let body: [String: Any] = ["title": title]
        try await putVoid("/projects/\(id)/title", body: body)
    }

    // MARK: - Areas

    func areasList() async throws -> [Area] {
        let data = try await get("/areas")
        return try JSONDecoder.apiDecoder.decode([Area].self, from: data)
    }

    func areaCreate(title: String, id: String? = nil) async throws -> Area {
        var body: [String: Any] = ["title": title]
        if let id = id { body["id"] = id }
        let data = try await post("/areas", body: body)
        return try JSONDecoder.apiDecoder.decode(Area.self, from: data)
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
        let body: [String: Any] = ["title": title]
        let data = try await patch("/areas/\(id)", body: body)
        return try JSONDecoder.apiDecoder.decode(Area.self, from: data)
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
        let body: [String: Any] = ["title": title]
        let data = try await post("/tasks/\(taskId)/checklist", body: body)
        return try JSONDecoder.apiDecoder.decode(ChecklistItem.self, from: data)
    }

    func checklistComplete(taskId: String, itemId: String) async throws {
        try await postVoid("/tasks/\(taskId)/checklist/\(itemId)/complete", body: [:])
    }

    func checklistUncomplete(taskId: String, itemId: String) async throws {
        try await postVoid("/tasks/\(taskId)/checklist/\(itemId)/uncomplete", body: [:])
    }

    func checklistDelete(taskId: String, itemId: String) async throws {
        try await delete("/tasks/\(taskId)/checklist/\(itemId)")
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

    // MARK: - HTTP helpers

    private func get(_ path: String, queryItems: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: true)!
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        var req = URLRequest(url: components.url!)
        req.addValue("ApiKey \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode < 400 else {
            throw AtaskError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    private func post(_ path: String, body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue("ApiKey \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode < 400 else {
            throw AtaskError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    private func patch(_ path: String, body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "PATCH"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue("ApiKey \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode < 400 else {
            throw AtaskError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    private func putVoid(_ path: String, body: [String: Any]) async throws {
        _ = try await put(path, body: body)
    }

    private func put(_ path: String, body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "PUT"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue("ApiKey \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode < 400 else {
            throw AtaskError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    private func delete(_ path: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "DELETE"
        req.addValue("ApiKey \(apiKey)", forHTTPHeaderField: "Authorization")
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode < 400 else {
            throw AtaskError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
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

    func update(baseURL: URL, apiKey: String) {
        self.client = AtaskClient(baseURL: baseURL, apiKey: apiKey)
    }
}
