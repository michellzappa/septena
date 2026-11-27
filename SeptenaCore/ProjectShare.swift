import Foundation
import SwiftData

// Shared projects (docs/PROJECT_SHARING_SPEC.md). The server writes who
// shares a project into the project row's `share` column; this reads it.

/// The `share` column of a shared project (backend `ShareInfo`).
struct ProjectShare: Codable, Hashable, Sendable {
  struct Member: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    /// `"owner"` or `"editor"`. Text, so a role this build does not know
    /// still decodes.
    let role: String

    var isOwner: Bool { role == "owner" }
    var initials: String { PersonInitials.of(name) }
  }

  /// "Members: Ann, Ben", for the marks that show no names.
  var membersLabel: String {
    "\(RegistrySharing.members): \(members.map(\.name).formatted(.list(type: .and)))"
  }

  let id: String
  let role: String
  /// This account's member id.
  let me: String
  let members: [Member]

  var isOwner: Bool { role == "owner" }

  func name(of memberID: String?) -> String? {
    guard let memberID else { return nil }
    return members.first { $0.id == memberID }?.name
  }

  static func decode(_ json: String?) -> ProjectShare? {
    guard let data = json?.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(ProjectShare.self, from: data)
  }
}

enum PersonInitials {
  static func of(_ name: String) -> String {
    let words = name.trimmingCharacters(in: .whitespaces).split(separator: " ")
    // A single short token is almost certainly typed-in initials ("MZ",
    // "abc") — show it verbatim. A longer single name → its first letter.
    // Multi-word → first letter of the first two words.
    if words.count <= 1 {
      let token = words.first.map(String.init) ?? ""
      return (token.count <= 3 ? token : String(token.prefix(1))).uppercased()
    }
    return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
  }
}

/// One person a task can be assigned to.
struct TaskAssignee: Identifiable, Hashable {
  /// nil = nobody.
  let memberID: String?
  let name: String
  var id: String { memberID ?? "nobody" }
}

/// Filter on a shared project's list: one member or unassigned ("Nobody").
enum TaskAssigneeFilter: Hashable, Sendable {
  case member(String)
  case unassigned

  func matches(_ task: SeptenaTask) -> Bool {
    switch self {
    case .member(let id): return task.assignedTo == id
    case .unassigned: return task.assignedTo == nil
    }
  }
}

enum SharedProjects {
  /// Localized "Assign To" title from `registry/actions.json`.
  static var assignTitle: String {
    RegistryActions.contextMenus[.taskRow]?.first { $0.id == "assign" }?.title ?? "Assign To"
  }

  static func share(ofProject id: String?, in context: ModelContext) -> ProjectShare? {
    guard let id else { return nil }
    var descriptor = FetchDescriptor<ProjectEntity>(predicate: #Predicate { $0.id == id })
    descriptor.fetchLimit = 1
    return (try? context.fetch(descriptor).first)?.share
  }

  /// True when a shared task is assigned to another member (`assignedTo != me`).
  static func isAssignedToOther(project: String?, assignedTo: String?, in context: ModelContext?) -> Bool {
    guard let assignedTo, !assignedTo.isEmpty,
          let context, let share = share(ofProject: project, in: context) else { return false }
    return assignedTo != share.me
  }

  /// Shared-project Waiting target (ADR 0053, #672): non-nil only when THIS
  /// user assigned the task to another member.
  static func sharedWaiting(
    share: ProjectShare?,
    assignedTo: String?,
    assignedBy: String?,
    assignedAt: String?
  ) -> (name: String, since: String?)? {
    guard let share,
          let assignedTo, !assignedTo.isEmpty,
          let assignedBy, !assignedBy.isEmpty,
          assignedTo != share.me,
          assignedBy == share.me else { return nil }
    return (share.name(of: assignedTo) ?? assignedTo, assignedAt)
  }

  /// The name on a row: who does this task. Inside a shared project
  /// (`includeSelf: true`), shows "You" for tasks assigned to you so Mine vs.
  /// Unassigned is scannable; outside the project, shows only others.
  static func assigneeName(of task: SeptenaTask, includeSelf: Bool = false, in context: ModelContext) -> String? {
    guard let assigned = task.assignedTo,
          let share = task.projectShare ?? share(ofProject: task.project, in: context) else { return nil }
    if assigned == share.me {
      return includeSelf ? RegistrySharing.you : nil
    }
    return share.name(of: assigned)
  }

  /// Assign To ▸ for tasks of one shared project; empty for any others.
  static func assignees(for tasks: [SeptenaTask], in context: ModelContext) -> [TaskAssignee] {
    let projects = Set(tasks.map(\.project))
    guard projects.count == 1, let project = projects.first,
          let share = share(ofProject: project, in: context) else { return [] }
    return [TaskAssignee(memberID: nil, name: RegistrySharing.nobody)] + share.members.map {
      TaskAssignee(memberID: $0.id, name: $0.id == share.me ? "\($0.name) (\(RegistrySharing.you))" : $0.name)
    }
  }

  /// The token of an invite link: `https://…/join/<token>`,
  /// `septask://join/<token>`, or the bare token.
  nonisolated static func inviteToken(in text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let last = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    let pattern = "^sp_[A-Za-z0-9_-]{32}\\.[A-Za-z0-9_-]{32}$"
    return last.range(of: pattern, options: .regularExpression) == nil ? nil : last
  }
}

// MARK: - Wire

struct BackendShareDetails: Decodable, Sendable {
  struct Invite: Decodable, Identifiable, Sendable {
    let id: String
    let createdAt: Double
    let expiresAt: Double
  }
  let share: ProjectShare
  let invites: [Invite]
}

struct BackendSharePreview: Decodable, Sendable {
  let title: String
  let from: String
  let members: Int
}

struct BackendShareCreated: Decodable, Sendable {
  let share: ProjectShare
}

struct BackendShareInvite: Decodable, Sendable {
  let url: String
}

struct BackendShareJoined: Decodable, Sendable {
  let shareId: String
  let title: String
}
