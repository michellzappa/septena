import Foundation

// ─── Atask REST API Client ──────────────────────────────────────────────────────
// Bridges engage-app to the engage-server Go backend.
// Set ENGAGE_SERVER_URL and ENGAGE_API_KEY in Xcode scheme, or via Settings screen.
// No Convex SDK — pure URLSession HTTP.

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

    // MARK: - Config

    func updateConfig(baseURL: URL, apiKey: String) {
        // Replace shared with new config — Swift actors can't mutate state
        // Caller should replace the actor reference
    }

    // MARK: - Tasks

    func tasksList(schedule: String? = nil, project: String? = nil) async throws -> [EngageTask] {
        var components = URLComponents(url: baseURL.appendingPathComponent("tasks"), resolvingAgainstBaseURL: true)!
        if let schedule { components.queryItems = [URLQueryItem(name: "schedule", value: schedule)] }
        if let project { components.queryItems?.append(URLQueryItem(name: "project", value: project)) }
        let data = try await get(components.url!)
        return (try? JSONDecoder().decode([EngageTask].self, from: data)) ?? []
    }

    func taskCreate(title: String, notes: String? = nil, origin: TaskOrigin, owner: String, project: String? = nil, due: Date? = nil, priority: Int = 0, repeatRule: String? = nil) async throws -> EngageTask {
        let body: [String: Any] = [
            "title": title,
            "schedule": due == nil ? "inbox" : "upcoming",
            "priority": priority,
            "origin_actor": origin.rawValue,
            "owner": owner
        ]
        let data = try await post("/tasks", body: body)
        return try JSONDecoder().decode(EngageTask.self, from: data)
    }

    func taskComplete(id: String, completedBy: String) async throws {
        try await postVoid("/tasks/\(id)/complete", body: [:])
    }

    func taskCancel(id: String, actor: String) async throws {
        try await postVoid("/tasks/\(id)/cancel", body: ["actor": actor])
    }

    func taskUpdate(id: String, patch: [String: Any], actor: String) async throws {
        try await putVoid("/tasks/\(id)", body: patch)
    }

    // MARK: - Engage: Agent-native operations

    func taskSetAgentNote(id: String, note: String) async throws {
        try await putVoid("/tasks/\(id)/agent-note", body: ["agent_note": note])
    }

    func taskSetConfidence(id: String, confidence: Int) async throws {
        try await putVoid("/tasks/\(id)/confidence", body: ["confidence": confidence])
    }

    func taskRequestReview(id: String) async throws {
        try await postVoid("/tasks/\(id)/request-review", body: [:])
    }

    func taskApproveReview(id: String) async throws {
        try await postVoid("/tasks/\(id)/approve-review", body: [:])
    }

    func taskDismissReview(id: String) async throws {
        try await postVoid("/tasks/\(id)/dismiss-review", body: [:])
    }

    func taskAgentClaim(id: String) async throws {
        try await postVoid("/tasks/\(id)/agent-claim", body: [:])
    }

    func taskAgentRelease(id: String) async throws {
        try await postVoid("/tasks/\(id)/agent-release", body: [:])
    }

    func taskAgentComplete(id: String) async throws {
        try await postVoid("/tasks/\(id)/agent-complete", body: [:])
    }

    func taskAssign(id: String, owner: String, agentAcknowledged: Bool, actor: String) async throws {
        try await postVoid("/tasks/\(id)/assign", body: ["owner": owner])
    }

    // MARK: - Comments

    func taskComments(taskId: String) async throws -> [Comment] {
        let data = try await get(baseURL.appendingPathComponent("tasks/\(taskId)/comments"))
        return (try? JSONDecoder().decode([Comment].self, from: data)) ?? []
    }

    func taskAddComment(taskId: String, actor: String, body: String) async throws {
        try await postVoid("/tasks/\(taskId)/comments", body: ["body": body, "actor": actor])
    }

    func resolveComment(id: String, resolved: Bool) async throws {
        try await postVoid("/comments/\(id)/resolve", body: ["resolved": resolved])
    }

    // MARK: - Projects / Areas / Tags

    func projectsList() async throws -> [Project] {
        let data = try await get("/projects")
        return (try? JSONDecoder().decode([Project].self, from: data)) ?? []
    }

    func areasList() async throws -> [Area] {
        let data = try await get("/areas")
        return (try? JSONDecoder().decode([Area].self, from: data)) ?? []
    }

    func areaCreate(name: String) async throws -> Area {
        let body: [String: Any] = ["name": name]
        let data = try await post("/areas", body: body)
        return (try? JSONDecoder().decode(Area.self, from: data)) ?? Area(id: "", name: name)
    }

    func areaUpdate(id: String, patch: [String: Any]) async throws {
        try await putVoid("/areas/\(id)", body: patch)
    }

    func projectCreate(title: String) async throws -> Project {
        let body: [String: Any] = ["title": title]
        let data = try await post("/projects", body: body)
        return (try? JSONDecoder().decode(Project.self, from: data)) ?? Project(id: "", title: title, status: "active")
    }

    func projectUpdate(id: String, patch: [String: Any]) async throws {
        try await putVoid("/projects/\(id)", body: patch)
    }

    func tagsList() async throws -> [Tag] {
        let data = try await get("/tags")
        return (try? JSONDecoder().decode([Tag].self, from: data)) ?? []
    }

    // MARK: - Agents

    func agentsList() async throws -> [Agent] {
        let data = try await get("/agents")
        return (try? JSONDecoder().decode([Agent].self, from: data)) ?? []
    }

    func agentMemory(agentId: String) async throws -> [AgentMemoryEntry] {
        let data = try await get("/agents/\(agentId)/memory")
        return (try? JSONDecoder().decode([AgentMemoryEntry].self, from: data)) ?? []
    }

    // MARK: - Debug / Connection check

    func ping() async throws -> String {
        let data = try await get("/tasks?limit=1")
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return "OK — server reachable"
        }
        return "OK"
    }

    // MARK: - Private HTTP helpers

    private func get(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.addValue(apiKey, forHTTPHeaderField: "X-API-Key")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode < 400 else {
            throw AtaskError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    private func get(_ path: String) async throws -> Data {
        try await get(baseURL.appendingPathComponent(path))
    }

    private func postVoid(_ path: String, body: [String: Any]) async throws {
        let data = try await post(path, body: body)
        _ = data
    }

    private func putVoid(_ path: String, body: [String: Any]) async throws {
        let data = try await put(path, body: body)
        _ = data
    }

    private func post(_ path: String, body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode < 400 else {
            throw AtaskError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    private func put(_ path: String, body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "PUT"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode < 400 else {
            throw AtaskError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }
}

enum AtaskError: LocalizedError {
    case serverError(Int)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .serverError(let code): return "Server error: \(code)"
        case .networkError(let e): return e.localizedDescription
        }
    }
}