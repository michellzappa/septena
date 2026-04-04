import Foundation

// ─── Convex Client (Pure HTTP, no SDK) ─────────────────────────────────────────

@MainActor
final class ConvexClient: ObservableObject {
  static let shared = ConvexClient()

  private let convexUrl: String
  private let convexKey: String

  private init() {
    self.convexUrl = ProcessInfo.processInfo.environment["ENGAGE_CONVEX_URL"]
      ?? "https://fiery-oriole-57.eu-west-1.convex.cloud"

    self.convexKey = ProcessInfo.processInfo.environment["ENGAGE_CONVEX_KEY"] ?? ""
  }

  var isConfigured: Bool { !convexKey.isEmpty }

  // ─── HTTP Helpers ─────────────────────────────────────────────────────────

  private func convexRequest(endpoint: String, args: [String: Any] = [:]) async throws -> [[String: Any]] {
    let url = URL(string: "\(convexUrl)/api/query")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if !convexKey.isEmpty {
      request.setValue("Bearer \(convexKey)", forHTTPHeaderField: "Authorization")
    }
    request.setValue("engage-swift/1.0", forHTTPHeaderField: "Convex-Client")

    let body: [String: Any] = ["path": endpoint, "args": args]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
      throw ConvexError.requestFailed
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ConvexError.invalidResponse
    }

    if let error = json["error"] as? String {
      throw ConvexError.serverError(error)
    }

    guard let value = json["value"] as? [[String: Any]] else {
      // Value might be null or not an array — return empty
      return []
    }

    return value
  }

  private func convexMutation(endpoint: String, args: [String: Any] = [:]) async throws {
    let url = URL(string: "\(convexUrl)/api/mutation")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if !convexKey.isEmpty {
      request.setValue("Bearer \(convexKey)", forHTTPHeaderField: "Authorization")
    }
    request.setValue("engage-swift/1.0", forHTTPHeaderField: "Convex-Client")

    let body: [String: Any] = ["path": endpoint, "args": args, "continuation": NSNull()]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
      throw ConvexError.requestFailed
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ConvexError.invalidResponse
    }

    if let error = json["error"] as? String {
      throw ConvexError.serverError(error)
    }
  }

  // ─── Task Queries ─────────────────────────────────────────────────────────

  func tasksList(
    status: TaskStatus? = nil,
    owner: String? = nil,
    area: String? = nil,
    project: String? = nil,
    agentAssignedMe: Bool? = nil,
    staleDays: Int? = nil
  ) async throws -> [EngageTask] {
    var filter: [String: Any] = [:]
    if let status { filter["status"] = status.rawValue }
    if let owner { filter["owner"] = owner }
    if let area { filter["area"] = area }
    if let project { filter["project"] = project }
    if let agentAssignedMe { filter["agentAssignedMe"] = agentAssignedMe }
    if let staleDays { filter["staleDays"] = staleDays }

    let requestArgs: [String: Any] = filter.isEmpty ? [:] : ["filter": filter]
    let items = try await convexRequest(endpoint: "tasks:list", args: requestArgs)
    return items.compactMap { dictToTask($0) }
  }

  func taskComments(taskId: String) async throws -> [Comment] {
    let items = try await convexRequest(endpoint: "comments:list", args: ["taskId": taskId])
    return items.compactMap { dictToComment($0) }
  }

  // ─── Task Mutations ────────────────────────────────────────────────────────

  func taskCreate(
    title: String,
    notes: String? = nil,
    origin: TaskOrigin,
    owner: String,
    area: String? = nil,
    project: String? = nil,
    due: Date? = nil,
    start: Date? = nil,
    priority: Int = 0,
    repeatRule: String? = nil,
    conclusionRule: String? = nil,
    agentAssignedMe: Bool = false
  ) async throws {
    var args: [String: Any] = [
      "title": title,
      "origin": origin.rawValue,
      "owner": owner,
      "priority": priority,
      "agentAssignedMe": agentAssignedMe,
    ]
    if let notes { args["notes"] = notes }
    if let area { args["area"] = area }
    if let project { args["project"] = project }
    if let due { args["due"] = Int(due.timeIntervalSince1970 * 1000) }
    if let start { args["start"] = Int(start.timeIntervalSince1970 * 1000) }
    if let repeatRule { args["repeatRule"] = repeatRule }
    if let conclusionRule { args["conclusionRule"] = conclusionRule }

    try await convexMutation(endpoint: "tasks:create", args: args)
  }

  func taskUpdate(id: String, patch: [String: Any], actor: String) async throws {
    try await convexMutation(endpoint: "tasks:update", args: ["id": id, "patch": patch, "actor": actor])
  }

  func taskComplete(id: String, completedBy: String) async throws {
    try await convexMutation(endpoint: "tasks:complete", args: ["id": id, "completedBy": completedBy])
  }

  func taskCancel(id: String, actor: String) async throws {
    try await convexMutation(endpoint: "tasks:cancel", args: ["id": id, "actor": actor])
  }

  func taskAssign(id: String, owner: String, agentAcknowledged: Bool, actor: String) async throws {
    try await convexMutation(endpoint: "tasks:assign", args: [
      "id": id, "owner": owner, "agentAcknowledged": agentAcknowledged, "actor": actor
    ])
  }

  func taskAddComment(taskId: String, actor: String, body: String) async throws {
    try await convexMutation(endpoint: "comments:addComment", args: ["taskId": taskId, "actor": actor, "body": body])
  }

  func resolveComment(id: String, resolved: Bool) async throws {
    try await convexMutation(endpoint: "comments:resolve", args: ["id": id, "resolved": resolved])
  }

  // ─── Area / Project / Tag ───────────────────────────────────────────────

  func areasList() async throws -> [Area] {
    let items = try await convexRequest(endpoint: "areas:list", args: [:])
    return items.compactMap { dictToArea($0) }
  }

  func projectsList(areaId: String? = nil) async throws -> [Project] {
    let args: [String: Any] = areaId.map { ["areaId": $0] } ?? [:]
    let items = try await convexRequest(endpoint: "projects:list", args: args)
    return items.compactMap { dictToProject($0) }
  }

  func areaCreate(name: String, icon: String? = nil, color: String? = nil, sortOrder: Int = 0) async throws {
    var args: [String: Any] = ["name": name, "sortOrder": sortOrder]
    if let icon { args["icon"] = icon }
    if let color { args["color"] = color }
    try await convexMutation(endpoint: "areas:create", args: args)
  }

  func projectCreate(name: String, area: String? = nil, notes: String? = nil, sortOrder: Int = 0) async throws {
    var args: [String: Any] = ["name": name, "sortOrder": sortOrder]
    if let area { args["area"] = area }
    if let notes { args["notes"] = notes }
    try await convexMutation(endpoint: "projects:create", args: args)
  }

  func areaUpdate(id: String, patch: [String: Any]) async throws {
    try await convexMutation(endpoint: "areas:update", args: ["id": id, "patch": patch])
  }

  func projectUpdate(id: String, patch: [String: Any]) async throws {
    try await convexMutation(endpoint: "projects:update", args: ["id": id, "patch": patch])
  }

  func tagsList() async throws -> [Tag] {
    let items = try await convexRequest(endpoint: "tags:list", args: [:])
    return items.compactMap { dictToTag($0) }
  }

  // ─── Agent ───────────────────────────────────────────────────────────────

  func agentsList() async throws -> [Agent] {
    let items = try await convexRequest(endpoint: "agents:list", args: ["activeOnly": true])
    return items.compactMap { dictToAgent($0) }
  }

  func agentMemory(agentId: String) async throws -> [AgentMemoryEntry] {
    let items = try await convexRequest(endpoint: "agentMemory:list", args: ["agentId": agentId])
    return items.compactMap { dictToAgentMemory($0) }
  }

  func collaborationLog(taskId: String? = nil, limit: Int = 50) async throws -> [CollaborationLogEntry] {
    var args: [String: Any] = ["limit": limit]
    if let taskId { args["taskId"] = taskId }
    let items = try await convexRequest(endpoint: "collaborationLog:list", args: args)
    return items.compactMap { dictToLogEntry($0) }
  }
}

// ─── Errors ────────────────────────────────────────────────────────────────────

enum ConvexError: Error, LocalizedError {
  case requestFailed
  case invalidResponse
  case serverError(String)

  var errorDescription: String? {
    switch self {
    case .requestFailed: return "Request failed"
    case .invalidResponse: return "Invalid response"
    case .serverError(let msg): return msg
    }
  }
}

// ─── Dict Helpers ──────────────────────────────────────────────────────────────

private func dictToTask(_ d: [String: Any]) -> EngageTask? {
  guard let id = d["_id"] as? String,
        let title = d["title"] as? String,
        let originStr = d["origin"] as? String,
        let origin = TaskOrigin(rawValue: originStr),
        let statusStr = d["status"] as? String,
        let status = TaskStatus(rawValue: statusStr),
        let createdBy = d["createdBy"] as? String,
        let owner = d["owner"] as? String
  else { return nil }

  return EngageTask(
    id: id, title: title, notes: d["notes"] as? String,
    origin: origin, status: status, priority: (d["priority"] as? Int) ?? 0,
    area: d["area"] as? String, project: d["project"] as? String,
    tags: (d["tags"] as? [String]) ?? [],
    due: msToDate(d["due"] as? Int), dueDateSetBy: d["dueDateSetBy"] as? String,
    start: msToDate(d["start"] as? Int), end: msToDate(d["end"] as? Int),
    createdBy: createdBy, owner: owner,
    completedAt: msToDate(d["completedAt"] as? Int), completedBy: d["completedBy"] as? String,
    repeatRule: d["repeatRule"] as? String, conclusionRule: d["conclusionRule"] as? String,
    nextDue: msToDate(d["nextDue"] as? Int), nextDueSetBy: d["nextDueSetBy"] as? String,
    agentStatus: (d["agentStatus"] as? String).flatMap { TaskAgentStatus(rawValue: $0) },
    agentAssignedMe: (d["agentAssignedMe"] as? Bool) ?? false,
    agentContext: d["agentContext"] as? String,
    agentNote: d["agentNote"] as? String,
    confidence: (d["confidence"] as? Int) ?? 0,
    needsHumanReview: (d["needsHumanReview"] as? Bool) ?? false,
    checklist: (d["checklist"] as? [[String: Any]])?.compactMap { item in
      guard let id = item["id"] as? String, let title = item["title"] as? String else { return nil }
      return ChecklistItem(id: id, title: title, done: (item["done"] as? Bool) ?? false)
    } ?? []
  )
}

private func dictToArea(_ d: [String: Any]) -> Area? {
  guard let id = d["_id"] as? String, let name = d["name"] as? String else { return nil }
  return Area(id: id, name: name, icon: d["icon"] as? String, sortOrder: (d["sortOrder"] as? Int) ?? 0, color: d["color"] as? String)
}

private func dictToProject(_ d: [String: Any]) -> Project? {
  guard let id = d["_id"] as? String, let name = d["name"] as? String else { return nil }
  return Project(
    id: id, name: name, area: d["area"] as? String,
    status: ProjectStatus(rawValue: (d["status"] as? String) ?? "active") ?? .active,
    notes: d["notes"] as? String, sortOrder: (d["sortOrder"] as? Int) ?? 0
  )
}

private func dictToTag(_ d: [String: Any]) -> Tag? {
  guard let id = d["_id"] as? String, let name = d["name"] as? String, let color = d["color"] as? String else { return nil }
  return Tag(id: id, name: name, color: color)
}

private func dictToAgent(_ d: [String: Any]) -> Agent? {
  guard let id = d["_id"] as? String, let name = d["name"] as? String,
        let email = d["email"] as? String, let typeStr = d["type"] as? String,
        let type = AgentType(rawValue: typeStr) else { return nil }
  return Agent(id: id, name: name, avatar: d["avatar"] as? String, email: email, type: type, active: (d["active"] as? Bool) ?? true)
}

private func dictToAgentMemory(_ d: [String: Any]) -> AgentMemoryEntry? {
  guard let id = d["_id"] as? String, let agentId = d["agentId"] as? String, let content = d["content"] as? String else { return nil }
  return AgentMemoryEntry(id: id, agentId: agentId, taskId: d["taskId"] as? String, content: content, pinned: (d["pinned"] as? Bool) ?? false, updatedAt: msToDate(d["updatedAt"] as? Int) ?? Date())
}

private func dictToComment(_ d: [String: Any]) -> Comment? {
  guard let id = d["_id"] as? String, let taskId = d["taskId"] as? String,
        let actor = d["actor"] as? String, let body = d["body"] as? String else { return nil }
  return Comment(id: id, taskId: taskId, actor: actor, body: body, resolved: (d["resolved"] as? Bool) ?? false, createdAt: msToDate(d["createdAt"] as? Int) ?? Date())
}

private func dictToLogEntry(_ d: [String: Any]) -> CollaborationLogEntry? {
  guard let id = d["_id"] as? String, let actor = d["actor"] as? String,
        let actionStr = d["action"] as? String, let action = LogAction(rawValue: actionStr) else { return nil }
  return CollaborationLogEntry(id: id, taskId: d["taskId"] as? String, actor: actor, action: action, content: d["content"] as? String, createdAt: msToDate(d["createdAt"] as? Int) ?? Date())
}

private func msToDate(_ ms: Int?) -> Date? {
  guard let ms else { return nil }
  return Date(timeIntervalSince1970: Double(ms) / 1000)
}
