import Foundation

// A task's change history from the task backend (`GET /v1/changes`,
// ../septena-mcp-gateway/src/api/routes.ts), and the words the History
// section shows for it. UI-free: the Mac inspector (AppKit) and the shared
// SwiftUI composer both render `TaskHistoryRow`s.
//
// Who: the server logs app writes as `app:<X-Septena-Client>` and connector
// writes as `mcp:<agent name>` (`mcp:<agent>@<client>` for the agent loop).
// History names the agent (`agentName`), so the user sees which agent changed what.

// MARK: - Wire

/// One row of the change log. Decoding is strict, like the rest of the wire:
/// a missing field or an unknown entity fails the whole reply.
struct BackendChange: Decodable, Sendable {
  let rev: Int
  let entity: BackendEntity
  let id: String
  /// `upsert`, `delete`, `dropped`, `append`, `upload`, or a claim op. Kept as
  /// text: an op this build does not know shows as nothing, not as a failure.
  let op: String
  let fields: [String]?
  /// Per changed field: `[before, after]`. Long values arrive cut short.
  let diff: [String: [BackendJSON]]?
  let actor: String
  let at: String
  let reason: String?
}

struct BackendChangesResponse: Decodable, Sendable {
  let changes: [BackendChange]
  /// Changes older than the plan's window that the server did not send.
  /// Absent outside enforce mode; nil while more pages follow.
  let hiddenOlder: Int?
  /// The upsell moment for the end of the list (`history_edge`): set by the
  /// server only on the free plan when it hid older changes (spec §3.2).
  let upsell: String?
}

// MARK: - Rows

/// One line of the History section.
struct TaskHistoryRow: Identifiable, Hashable, Sendable {
  let id: Int
  let date: Date?
  let who: String
  let byClaude: Bool
  /// What changed, one short phrase per change. Never empty.
  let lines: [String]
}

enum TaskHistory {
  /// How many log rows one load asks for. Reorders and bookkeeping fields are
  /// dropped after the fetch, so the shown list can be shorter.
  static let pageSize = 50
  static let valueMax = 40

  /// The History section appears only where the backend owns tasks and this
  /// device holds a session: the log lives there and nowhere else.
  static var isAvailable: Bool {
    TaskStoreMode.current == .backend && TaskBackendClient.hasSession
  }

  /// The upsell line under the last row, when the server says the free
  /// plan's window hid older changes. The server judges; nil otherwise.
  static func edgeUpsell(_ page: BackendChangesResponse) -> RegistryPlanNote? {
    guard page.upsell == "history_edge" else { return nil }
    return RegistryPlans.upsell("history_edge")
  }

  /// Rows newest first. `listTitle` names an area or project id, nil when
  /// the id is unknown here.
  static func rows(_ changes: [BackendChange], listTitle: (String) -> String?) -> [TaskHistoryRow] {
    changes.compactMap { change in
      let lines = describe(change, listTitle: listTitle)
      guard !lines.isEmpty else { return nil }
      return TaskHistoryRow(id: change.rev, date: parseStamp(change.at), who: who(change.actor),
                            byClaude: change.actor.hasPrefix("mcp:"), lines: lines)
    }
  }

  static func who(_ actor: String) -> String {
    if actor.hasPrefix("mcp:") { return agentName(actor) }
    switch actor {
    case "app:septask-mac": return String(localized: "You on Mac", comment: "Task history: who")
    case "app:septask-ios": return String(localized: "You on iPhone", comment: "Task history: who")
    default: return String(localized: "You", comment: "Task history: who")
    }
  }

  /// The agent's name in an `mcp:` actor. The backend logs MCP writes as
  /// `mcp:<connection name>` and agent-loop writes as `mcp:<agent>@<client>`;
  /// the legacy `mcp:claude` reads as the registry fallback name.
  static func agentName(_ actor: String) -> String {
    let name = String(actor.dropFirst("mcp:".count)).split(separator: "@").first
      .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    return name.isEmpty || name == "claude" ? RegistrySurfaces.provenanceAgentFallbackName : name
  }

  static func describe(_ change: BackendChange, listTitle: (String) -> String?) -> [String] {
    switch change.op {
    case "delete": return [String(localized: "Deleted", comment: "Task history")]
    case "upsert": break
    default: return []
    }
    let diff = change.diff ?? [:]
    func before(_ key: String) -> BackendJSON { diff[key]?.first ?? .null }
    func after(_ key: String) -> BackendJSON { diff[key].flatMap { $0.count > 1 ? $0[1] : nil } ?? .null }

    // A row with no earlier title or status is the insert.
    if diff["title"] != nil, before("title").isNull, before("status").isNull {
      return [String(localized: "Created", comment: "Task history")]
    }

    var lines: [String] = []
    if diff["title"] != nil {
      let old = clip(before("title").stringValue ?? "")
      let new = clip(after("title").stringValue ?? "")
      lines.append(String(localized: "Title: \(old) → \(new)", comment: "Task history: title change"))
    }
    if diff["status"] != nil {
      switch after("status").stringValue {
      case TaskStatus.done.rawValue: lines.append(String(localized: "Completed", comment: "Task history"))
      case TaskStatus.cancelled.rawValue: lines.append(String(localized: "Cancelled", comment: "Task history"))
      default: lines.append(String(localized: "Reopened", comment: "Task history"))
      }
    }
    if diff["today"] != nil {
      lines.append(after("today") == .bool(true)
        ? String(localized: "Moved to Today", comment: "Task history")
        : String(localized: "Removed from Today", comment: "Task history"))
    }
    if let line = listLine(diff: diff, before: before, after: after, listTitle: listTitle) {
      lines.append(line)
    }
    if diff["scheduled"] != nil {
      if let day = after("scheduled").stringValue {
        lines.append(String(localized: "When: \(dayLabel(day))", comment: "Task history: scheduled day"))
      } else {
        lines.append(String(localized: "When cleared", comment: "Task history"))
      }
    }
    if diff["deadline"] != nil {
      if let day = after("deadline").stringValue {
        lines.append(String(localized: "Deadline: \(dayLabel(day))", comment: "Task history: deadline"))
      } else {
        lines.append(String(localized: "Deadline cleared", comment: "Task history"))
      }
    }
    if diff["notes"] != nil {
      let had = !(before("notes").stringValue ?? "").isEmpty
      let has = !(after("notes").stringValue ?? "").isEmpty
      lines.append(!had ? String(localized: "Notes added", comment: "Task history")
                   : has ? String(localized: "Notes edited", comment: "Task history")
                   : String(localized: "Notes cleared", comment: "Task history"))
    }
    if diff["recurrenceUnit"] != nil || diff["recurrenceInterval"] != nil ||
       diff["recurrenceWeekdays"] != nil || diff["recurrenceMonthDay"] != nil ||
       diff["recurrenceOrdinalWeekday"] != nil {
      lines.append(diff["recurrenceUnit"] != nil && after("recurrenceUnit").isNull
        ? String(localized: "Repeat removed", comment: "Task history")
        : String(localized: "Repeat changed", comment: "Task history"))
    }
    if diff["recurrencePaused"] != nil {
      lines.append(after("recurrencePaused") == .bool(true)
        ? String(localized: "Repeat paused", comment: "Task history")
        : String(localized: "Repeat resumed", comment: "Task history"))
    }
    if diff["reminderAt"] != nil {
      lines.append(after("reminderAt").isNull
        ? String(localized: "Reminder removed", comment: "Task history")
        : String(localized: "Reminder set", comment: "Task history"))
    }
    if diff["starred"] != nil {
      lines.append(after("starred") == .bool(true)
        ? String(localized: "Favorited", comment: "Task history")
        : String(localized: "Unfavorited", comment: "Task history"))
    }
    // Order, Today bookkeeping, acknowledgement and provenance fields are
    // left out: they change on every reorder and mean nothing to read.
    return lines
  }

  /// Project wins over area: a task in a project shows under that project.
  private static func listLine(diff: [String: [BackendJSON]],
                               before: (String) -> BackendJSON, after: (String) -> BackendJSON,
                               listTitle: (String) -> String?) -> String? {
    let hasProject = diff["project"] != nil
    let hasArea = diff["area"] != nil
    guard hasProject || hasArea else { return nil }
    if let newID = after("project").stringValue ?? after("area").stringValue {
      let name = listTitle(newID).map(clip)
        ?? String(localized: "another list", comment: "Task history: unknown list")
      return String(localized: "Moved to \(name)", comment: "Task history: list change")
    }
    // The changed list was cleared. When only one of the two changed, the
    // other may still hold the task, so name what it left.
    if hasProject != hasArea,
       let oldID = before(hasProject ? "project" : "area").stringValue,
       let name = listTitle(oldID) {
      return String(localized: "Removed from \(clip(name))", comment: "Task history: list change")
    }
    return String(localized: "Moved to Inbox", comment: "Task history: list change")
  }

  static func clip(_ text: String) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ")
    return flat.count > valueMax ? String(flat.prefix(valueMax - 1)) + "…" : flat
  }

  private static func dayLabel(_ wire: String) -> String {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    guard let date = f.date(from: wire) else { return wire }
    return date.formatted(.dateTime.month(.abbreviated).day())
  }

  static func parseStamp(_ text: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = f.date(from: text) { return date }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: text)
  }

  /// "5 min ago", "yesterday". Empty when the stamp did not parse.
  static func relative(_ date: Date?, now: Date) -> String {
    guard let date else { return "" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: date, relativeTo: now)
  }
}

extension BackendNoteRevision {
  var date: Date? { TaskHistory.parseStamp(at) }
  var who: String { TaskHistory.who(actor) }
}
