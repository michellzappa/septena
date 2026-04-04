import Foundation
import Convex

// ─── Convex Client ─────────────────────────────────────────────────────────────

@MainActor
final class ConvexClient: ObservableObject {
  static let shared = ConvexClient()

  private(set) var convex: Convex?
  private let convexUrl: String
  private let convexKey: String

  private init() {
    // Load from app config — replace with your project values
    self.convexUrl = Bundle.main.object(forInfoDictionaryKey: "ENGAGE_CONVEX_URL") as? String
      ?? ProcessInfo.processInfo.environment["ENGAGE_CONVEX_URL"]
      ?? "https://fiery-oriole-57.eu-west-1.convex.cloud"

    self.convexKey = Bundle.main.object(forInfoDictionaryKey: "ENGAGE_CONVEX_KEY") as? String
      ?? ProcessInfo.processInfo.environment["ENGAGE_CONVEX_KEY"]
      ?? ""

    if !convexKey.isEmpty {
      self.convex = Convex(
        deploymentUrl: convexUrl,
        adminKey: convexKey
      )
    }
  }

  var isConfigured: Bool { !convexKey.isEmpty }

  // ─── Task Queries ─────────────────────────────────────────────────────────

  func tasksList(
    status: TaskStatus? = nil,
    owner: String? = nil,
    area: String? = nil,
    project: String? = nil,
    agentAssignedMe: Bool? = nil,
    staleDays: Int? = nil
  ) async throws -> [EngageTask] {
    guard let convex else { return [] }

    var filter: [String: Any] = [:]
    if let status { filter["status"] = status.rawValue }
    if let owner { filter["owner"] = owner }
    if let area { filter["area"] = area }
    if let project { filter["project"] = project }
    if let agentAssignedMe { filter["agentAssignedMe"] = agentAssignedMe }
    if let staleDays { filter["staleDays"] = staleDays }

    let args: [String: Any] = filter.isEmpty ? [:] : ["filter": filter]
    let result: [[String: Any]] = try await convex.query(
      ConvexFunction(name: "tasks:list", args: Args(args))
    )

    return result.compactMap { dictToTask($0) }
  }

  func taskComments(taskId: String) async throws -> [Comment] {
    guard let convex else { return [] }
    let result: [[String: Any]] = try await convex.query(
      ConvexFunction(name: "tasks:comments", args: Args(["taskId": taskId]))
    )
    return result.compactMap { dictToComment($0) }
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
  ) async throws -> String {
    guard let convex else { throw ConvexError.notConfigured }

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
    if let due { args["due"] = due.timeIntervalSince1970 * 1000 }
    if let start { args["start"] = start.timeIntervalSince1970 * 1000 }
    if let repeatRule { args["repeatRule"] = repeatRule }
    if let conclusionRule { args["conclusionRule"] = conclusionRule }

    return try await convex.mutation(
      ConvexFunction(name: "tasks:create", args: Args(args))
    )
  }

  func taskUpdate(
    id: String,
    patch: [String: Any],
    actor: String
  ) async throws {
    guard let convex else { throw ConvexError.notConfigured }
    var args: [String: Any] = ["id": id, "patch": patch, "actor": actor]
    try await convex.mutation(ConvexFunction(name: "tasks:update", args: Args(args)))
  }

  func taskComplete(id: String, completedBy: String) async throws {
    guard let convex else { throw ConvexError.notConfigured }
    try await convex.mutation(
      ConvexFunction(
        name: "tasks:complete",
        args: Args(["id": id, "completedBy": completedBy])
      )
    )
  }

  func taskCancel(id: String, actor: String) async throws {
    guard let convex else { throw ConvexError.notConfigured }
    try await convex.mutation(
      ConvexFunction(name: "tasks:cancel", args: Args(["id": id, "actor": actor]))
    )
  }

  func taskAssign(
    id: String,
    owner: String,
    agentAcknowledged: Bool,
    actor: String
  ) async throws {
    guard let convex else { throw ConvexError.notConfigured }
    try await convex.mutation(
      ConvexFunction(
        name: "tasks:assign",
        args: Args([
          "id": id,
          "owner": owner,
          "agentAcknowledged": agentAcknowledged,
          "actor": actor,
        ])
      )
    )
  }

  func taskAddComment(taskId: String, actor: String, body: String) async throws {
    guard let convex else { throw ConvexError.notConfigured }
    try await convex.mutation(
      ConvexFunction(
        name: "tasks:addComment",
        args: Args(["taskId": taskId, "actor": actor, "body": body])
      )
    )
  }

  // ─── Area / Project / Tag ───────────────────────────────────────────────

  func areasList() async throws -> [Area] {
    guard let convex else { return [] }
    let result: [[String: Any]] = try await convex.query(
      ConvexFunction(name: "areas:list", args: Args([:]))
    )
    return result.compactMap { dictToArea($0) }
  }

  func projectsList(areaId: String? = nil) async throws -> [Project] {
    guard let convex else { return [] }
    var args: [String: Any] = [:]
    if let areaId { args["areaId"] = areaId }
    let result: [[String: Any]] = try await convex.query(
      ConvexFunction(name: "projects:list", args: Args(args))
    )
    return result.compactMap { dictToProject($0) }
  }

  func tagsList() async throws -> [Tag] {
    guard let convex else { return [] }
    let result: [[String: Any]] = try await convex.query(
      ConvexFunction(name: "tags:list", args: Args([:]))
    )
    return result.compactMap { dictToTag($0) }
  }

  // ─── Agent ───────────────────────────────────────────────────────────────

  func agentsList() async throws -> [Agent] {
    guard let convex else { return [] }
    let result: [[String: Any]] = try await convex.query(
      ConvexFunction(name: "agents:list", args: Args(["activeOnly": true]))
    )
    return result.compactMap { dictToAgent($0) }
  }

  func agentMemory(agentId: String) async throws -> [AgentMemoryEntry] {
    guard let convex else { return [] }
    let result: [[String: Any]] = try await convex.query(
      ConvexFunction(name: "agentMemory:list", args: Args(["agentId": agentId]))
    )
    return result.compactMap { dictToAgentMemory($0) }
  }

  func collaborationLog(taskId: String? = nil, limit: Int = 50) async throws -> [CollaborationLogEntry] {
    guard let convex else { return [] }
    var args: [String: Any] = ["limit": limit]
    if let taskId { args["taskId"] = taskId }
    let result: [[String: Any]] = try await convex.query(
      ConvexFunction(name: "collaborationLog:list", args: Args(args))
    )
    return result.compactMap { dictToLogEntry($0) }
  }
}

// ─── Errors ────────────────────────────────────────────────────────────────────

enum ConvexError: Error {
  case notConfigured
}

// ─── Dict Helpers ─────────────────────────────────────────────────────────────

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
    id: id,
    title: title,
    notes: d["notes"] as? String,
    origin: origin,
    status: status,
    priority: (d["priority"] as? Int) ?? 0,
    area: d["area"] as? String,
    project: d["project"] as? String,
    tags: (d["tags"] as? [String]) ?? [],
    due: msToDate(d["due"] as? Int),
    dueDateSetBy: d["dueDateSetBy"] as? String,
    start: msToDate(d["start"] as? Int),
    end: msToDate(d["end"] as? Int),
    createdBy: createdBy,
    owner: owner,
    completedAt: msToDate(d["completedAt"] as? Int),
    completedBy: d["completedBy"] as? String,
    repeatRule: d["repeatRule"] as? String,
    conclusionRule: d["conclusionRule"] as? String,
    nextDue: msToDate(d["nextDue"] as? Int),
    nextDueSetBy: d["nextDueSetBy"] as? String,
    agentStatus: (d["agentStatus"] as? String).flatMap { TaskAgentStatus(rawValue: $0) },
    agentAssignedMe: (d["agentAssignedMe"] as? Bool) ?? false,
    agentContext: d["agentContext"] as? String,
    checklist: (d["checklist"] as? [[String: Any]])?.compactMap { item in
      guard let id = item["id"] as? String, let title = item["title"] as? String else { return nil }
      return ChecklistItem(id: id, title: title, done: (item["done"] as? Bool) ?? false)
    } ?? []
  )
}

private func dictToArea(_ d: [String: Any]) -> Area? {
  guard let id = d["_id"] as? String, let name = d["name"] as? String else { return nil }
  return Area(
    id: id,
    name: name,
    icon: d["icon"] as? String,
    sortOrder: (d["sortOrder"] as? Int) ?? 0,
    color: d["color"] as? String
  )
}

private func dictToProject(_ d: [String: Any]) -> Project? {
  guard let id = d["_id"] as? String, let name = d["name"] as? String else { return nil }
  return Project(
    id: id,
    name: name,
    area: d["area"] as? String,
    status: ProjectStatus(rawValue: (d["status"] as? String) ?? "active") ?? .active,
    notes: d["notes"] as? String,
    sortOrder: (d["sortOrder"] as? Int) ?? 0
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
  return Agent(
    id: id,
    name: name,
    avatar: d["avatar"] as? String,
    email: email,
    type: type,
    active: (d["active"] as? Bool) ?? true
  )
}

private func dictToAgentMemory(_ d: [String: Any]) -> AgentMemoryEntry? {
  guard let id = d["_id"] as? String, let agentId = d["agentId"] as? String,
        let content = d["content"] as? String else { return nil }
  return AgentMemoryEntry(
    id: id,
    agentId: agentId,
    taskId: d["taskId"] as? String,
    content: content,
    pinned: (d["pinned"] as? Bool) ?? false,
    updatedAt: msToDate(d["updatedAt"] as? Int) ?? Date()
  )
}

private func dictToComment(_ d: [String: Any]) -> Comment? {
  guard let id = d["_id"] as? String, let taskId = d["taskId"] as? String,
        let actor = d["actor"] as? String, let body = d["body"] as? String else { return nil }
  return Comment(
    id: id,
    taskId: taskId,
    actor: actor,
    body: body,
    createdAt: msToDate(d["createdAt"] as? Int) ?? Date()
  )
}

private func dictToLogEntry(_ d: [String: Any]) -> CollaborationLogEntry? {
  guard let id = d["_id"] as? String, let actor = d["actor"] as? String,
        let actionStr = d["action"] as? String,
        let action = LogAction(rawValue: actionStr) else { return nil }
  return CollaborationLogEntry(
    id: id,
    taskId: d["taskId"] as? String,
    actor: actor,
    action: action,
    content: d["content"] as? String,
    createdAt: msToDate(d["createdAt"] as? Int) ?? Date()
  )
}

private func msToDate(_ ms: Int?) -> Date? {
  guard let ms else { return nil }
  return Date(timeIntervalSince1970: Double(ms) / 1000)
}

// Stub for Convex generated types — filled in after `npx convex codegen`
typealias Args = [String: Any]
typealias ConvexFunction = (name: String, args: Args)
