import Foundation

// Maps the local SwiftData mirror to task-backend rows (phase 1 import,
// docs/SEPTASK_BACKEND.md §5 and §9). One function per entity. Every field the
// backend has a column for is sent on every run, so a re-run overwrites the
// whole row. Ids are unchanged.
//
// Validation copies the server's Zod limits (columns.ts / ops.ts). One bad
// field in a push would make the Worker refuse the whole 500-op batch, so a
// row that fails here is left out and reported instead.

/// A row the import could not send, or a difference it found.
struct TaskBackendIssue: Error, Hashable, Sendable {
  let entity: BackendEntity
  let id: String
  let reason: String
  /// Unique per issue, for `ForEach`.
  var key: String { "\(entity.rawValue):\(id):\(reason)" }
}

/// A row ready to push.
struct BackendRowPlan: Sendable {
  let entity: BackendEntity
  let id: String
  let fields: [String: BackendJSON]
  /// Soft-deleted locally (Recently Deleted): pushed as upsert then delete.
  let deleted: Bool
}

struct BackendAttachmentPlan: Sendable {
  let row: BackendRowPlan
  let fileURL: URL?
  let contentType: String
  let byteCount: Int64
}

struct BackendTurnsPlan: Sendable {
  let taskID: String
  /// Turns in local thread order, `inReplyTo` renumbered to 1-based position.
  let turns: [[String: BackendJSON]]
}

enum TaskBackendMapping {
  // Computed, not stored: `Regex` is not Sendable. Extended delimiters
  // because bare `/…/` literals need the Swift 6 language mode.
  static var idPattern: Regex<Substring> { #/[A-Za-z0-9._:-]{1,128}/# }
  static var dayPattern: Regex<Substring> { #/[0-9]{4}-[0-9]{2}-[0-9]{2}/# }
  static var stampPattern: Regex<Substring> { #/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}/# }
  static let notesMax = RegistryEntityLimits.notesMax
  static let maxAttachmentBytes: Int64 = RegistryEntityLimits.maxAttachmentBytes

  /// UTC ISO-8601 without fractions, e.g. `2026-11-19T10:00:00Z`. Passes both
  /// the stamp columns and the turn `ts` rule (`datetime({ offset: true })`).
  static func stamp(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: date)
  }

  // MARK: - Field checks

  /// Collects the first problem per field. JS `string.length` counts UTF-16
  /// units, so lengths are measured the same way.
  struct Checker {
    var problems: [String] = []

    mutating func text(_ name: String, _ v: String?, max: Int = RegistryEntityLimits.textMax) -> BackendJSON {
      guard let v else { return .null }
      if v.utf16.count > max { problems.append("\(name) longer than \(max)") }
      return .string(v)
    }
    mutating func id(_ name: String, _ v: String?) -> BackendJSON {
      guard let v else { return .null }
      if v.wholeMatch(of: TaskBackendMapping.idPattern) == nil { problems.append("\(name) is not a valid id") }
      return .string(v)
    }
    mutating func day(_ name: String, _ v: String?) -> BackendJSON {
      guard let v else { return .null }
      if v.wholeMatch(of: TaskBackendMapping.dayPattern) == nil { problems.append("\(name) \"\(v)\" is not YYYY-MM-DD") }
      return .string(v)
    }
    mutating func stamp(_ name: String, _ v: String?) -> BackendJSON {
      guard let v else { return .null }
      if v.prefixMatch(of: TaskBackendMapping.stampPattern) == nil || v.utf16.count > RegistryEntityLimits.stampMax {
        problems.append("\(name) \"\(v)\" is not an ISO time")
      }
      return .string(v)
    }
    mutating func real(_ name: String, _ v: Double) -> BackendJSON {
      if !v.isFinite { problems.append("\(name) is not a finite number") }
      return .double(v)
    }
    /// `AreaAttachment` JSON: must be an object, at most `attachmentPointerMax` characters.
    mutating func pointer(_ name: String, _ json: String?) -> BackendJSON {
      guard let json, !json.isEmpty else { return .null }
      guard let data = json.data(using: .utf8),
            let value = try? JSONDecoder().decode(BackendJSON.self, from: data),
            case .object = value else {
        problems.append("\(name) is not a JSON object")
        return .null
      }
      if json.utf16.count > RegistryEntityLimits.attachmentPointerMax {
        problems.append("\(name) longer than \(RegistryEntityLimits.attachmentPointerMax)")
      }
      return value
    }
    mutating func rowID(_ v: String) {
      if v.wholeMatch(of: TaskBackendMapping.idPattern) == nil { problems.append("id is not valid") }
    }
  }

  private static func finish(_ entity: BackendEntity, _ id: String, _ c: Checker,
                             _ fields: [String: BackendJSON], deleted: Bool) -> Result<BackendRowPlan, TaskBackendIssue> {
    if let first = c.problems.first {
      let more = c.problems.count > 1 ? " (+\(c.problems.count - 1) more)" : ""
      return .failure(TaskBackendIssue(entity: entity, id: id, reason: first + more))
    }
    return .success(BackendRowPlan(entity: entity, id: id, fields: fields, deleted: deleted))
  }

  // MARK: - Rows

  @MainActor
  static func area(_ a: AreaEntity) -> Result<BackendRowPlan, TaskBackendIssue> {
    var c = Checker()
    c.rowID(a.id)
    let fields: [String: BackendJSON] = [
      "title": c.text("title", a.title),
      "context": c.text("context", a.context, max: notesMax),
      "emoji": c.text("emoji", a.emoji, max: 16),
      "attachment": c.pointer("attachment", a.attachmentJSON),
      "position": .int(Int64(a.position)),
    ]
    return finish(.area, a.id, c, fields, deleted: false)
  }

  @MainActor
  static func project(_ p: ProjectEntity) -> Result<BackendRowPlan, TaskBackendIssue> {
    var c = Checker()
    c.rowID(p.id)
    let fields: [String: BackendJSON] = [
      "title": c.text("title", p.title),
      "status": c.text("status", p.statusRaw, max: 32),
      "area": c.id("area", p.area),
      "created": c.day("created", p.created),
      "completedAt": c.stamp("completedAt", p.completedAt),
      "notes": c.text("notes", p.notes, max: notesMax),
      "context": c.text("context", p.context, max: notesMax),
      "githubRepo": c.text("githubRepo", p.githubRepo, max: 200),
      "attachment": c.pointer("attachment", p.attachmentJSON),
      "position": .int(Int64(p.position)),
    ]
    return finish(.project, p.id, c, fields, deleted: p.deletedAt != nil)
  }

  @MainActor
  static func task(_ t: TaskEntity) -> Result<BackendRowPlan, TaskBackendIssue> {
    var c = Checker()
    c.rowID(t.id)
    let fields: [String: BackendJSON] = [
      "title": c.text("title", t.title),
      "status": c.text("status", t.statusRaw, max: 32),
      // "" means an ordinary task locally; the backend stores that as null.
      "kind": t.kind.isEmpty ? .null : c.text("kind", t.kind, max: 32),
      "heading": c.id("heading", t.heading),
      "area": c.id("area", t.area),
      "project": c.id("project", t.project),
      "created": c.day("created", t.created),
      "scheduled": c.day("scheduled", t.scheduled),
      "deadline": c.day("deadline", t.deadline),
      "today": .bool(t.today),
      "todaySetOn": c.day("todaySetOn", t.todaySetOn),
      "completedAt": c.stamp("completedAt", t.completedAt),
      "notes": c.text("notes", t.notes, max: notesMax),
      "position": c.real("position", t.position),
      // Today's own order (#66). Null until the row is first ordered on
      // Today; readers then fall back to `position` (docs/SEPTASK_BACKEND.md
      // §5.2). The app clears it when an open row leaves Today.
      "todayPosition": t.deletedAt == nil ? t.todayPosition.map { c.real("todayPosition", $0) } ?? .null : .null,
      "recurrenceUnit": c.text("recurrenceUnit", t.recurrenceUnit, max: 16),
      "recurrenceInterval": .int(Int64(t.recurrenceInterval)),
      "recurrenceAfterCompletion": .bool(t.recurrenceAfterCompletion),
      "recurrencePaused": .bool(t.recurrencePaused),
      "recurrenceSeriesID": c.text("recurrenceSeriesID", t.recurrenceSeriesID, max: 128),
      "recurrenceAnchorDate": c.day("recurrenceAnchorDate", t.recurrenceAnchorDate),
      "recurrenceWeekdays": {
        guard let w = t.recurrence?.weekdays, !w.isEmpty else { return .null }
        return .array(w.map { .int(Int64($0)) })
      }(),
      "recurrenceMonthDay": t.recurrenceMonthDay.map { .int(Int64($0)) } ?? .null,
      "recurrenceOrdinalWeekday": {
        guard let ow = t.recurrence?.ordinalWeekday else { return .null }
        return .object(["ordinal": .int(Int64(ow.ordinal)), "weekday": .int(Int64(ow.weekday))])
      }(),
      "source": c.text("source", t.source, max: 64),
      "sourceClient": c.text("sourceClient", t.sourceClient, max: 64),
      "acknowledgedAt": t.acknowledgedAt.map { .string(stamp($0)) } ?? .null,
      // `.distantPast` marks a row from before the field existed: unknown.
      "createdAt": t.createdAt == .distantPast ? .null : .string(stamp(t.createdAt)),
    ]
    return finish(.task, t.id, c, fields, deleted: t.deletedAt != nil)
  }

  @MainActor
  static func attachment(_ a: TaskAttachmentEntity) -> Result<BackendAttachmentPlan, TaskBackendIssue> {
    var c = Checker()
    c.rowID(a.id)
    if a.byteCount < 0 || a.byteCount > maxAttachmentBytes {
      c.problems.append("file is \(a.byteCount) bytes, the limit is \(maxAttachmentBytes)")
    }
    let fields: [String: BackendJSON] = [
      "taskId": c.id("taskId", a.taskID),
      "filename": c.text("filename", a.filename, max: 512),
      "contentType": c.text("contentType", a.contentType, max: 200),
      "byteCount": .int(a.byteCount),
      "position": c.real("position", a.position),
      "createdAt": .string(stamp(a.createdAt)),
    ]
    return finish(.attachment, a.id, c, fields, deleted: false).map {
      BackendAttachmentPlan(row: $0, fileURL: TaskAttachmentFiles.url(for: a),
                            contentType: a.contentType, byteCount: a.byteCount)
    }
  }

  /// The non-turn half of the conversation (`convos` table, keyed by task id).
  /// Nil when the task has no conversation.
  @MainActor
  static func convo(taskID: String, json: String?) -> Result<(BackendRowPlan, BackendTurnsPlan)?, TaskBackendIssue> {
    guard let json, !json.isEmpty else { return .success(nil) }
    guard let data = json.data(using: .utf8),
          let convo = try? JSONDecoder.taskConvo.decode(TaskConvo.self, from: data) else {
      return .failure(TaskBackendIssue(entity: .convo, id: taskID, reason: "conversation JSON does not decode"))
    }
    var c = Checker()
    if convo.subtasks.count > RegistryEntityLimits.maxSubtasks {
      c.problems.append("more than \(RegistryEntityLimits.maxSubtasks) subtasks")
    }
    var fields: [String: BackendJSON] = [
      "confirmedIntent": c.text("confirmedIntent", convo.confirmedIntent, max: notesMax),
      "acceptance": c.text("acceptance", convo.acceptance, max: notesMax),
      "subtasks": .array(convo.subtasks.map { c.id("subtask", $0) }),
      "endState": c.text("endState", convo.endState?.rawValue, max: 32),
      "endStateNote": c.text("endStateNote", convo.endStateNote, max: notesMax),
      "assignee": .from(convo.assignee?.rawValue),
      // `claimedBy` / `claimUntil` are server-owned and never pushed.
      "stoppedAt": convo.stoppedAt.map { .string(stamp($0)) } ?? .null,
      "artifact": .null,
      "handoff": .null,
    ]
    if let a = convo.artifact {
      var obj: [String: BackendJSON] = [
        "kind": c.text("artifact.kind", a.kind, max: 64),
        "title": c.text("artifact.title", a.title),
        "body": c.text("artifact.body", a.body, max: notesMax),
      ]
      if let refs = a.refs {
        if refs.count > RegistryEntityLimits.maxArtifactRefs {
          c.problems.append("artifact has more than \(RegistryEntityLimits.maxArtifactRefs) refs")
        }
        obj["refs"] = .array(refs.map { c.text("artifact.ref", $0) })
      }
      fields["artifact"] = .object(obj)
    }
    if let h = convo.handoff {
      var obj: [String: BackendJSON] = [
        "instruction": c.text("handoff.instruction", h.instruction),
        "actionType": .string(h.actionType.rawValue),
      ]
      if let payload = h.payload { obj["payload"] = c.text("handoff.payload", payload) }
      fields["handoff"] = .object(obj)
    }

    // Turns: local thread order by `seq`. The server numbers appended turns
    // 1, 2, 3…, so `inReplyTo` (a local seq) is renumbered to that position.
    let ordered = convo.thread.sorted { $0.seq < $1.seq }
    var position: [Int: Int] = [:]
    for (i, turn) in ordered.enumerated() where position[turn.seq] == nil { position[turn.seq] = i + 1 }
    var turns: [[String: BackendJSON]] = []
    for turn in ordered {
      var t: [String: BackendJSON] = [
        "role": .string(turn.role.rawValue),
        "step": .string(turn.step.rawValue),
        "ts": .string(stamp(turn.ts)),
      ]
      // Nil fields are left out: the server's pull drops null turn fields too.
      if let v = turn.provider { t["provider"] = c.text("turn.provider", v.rawValue, max: RegistryEntityLimits.turnProviderMax) }
      if let v = turn.confidence {
        if !(0...1).contains(v) { c.problems.append("turn \(turn.seq) confidence \(v) is outside 0...1") }
        t["confidence"] = .double(v)
      }
      if let v = turn.question { t["question"] = c.text("turn.question", v, max: RegistryEntityLimits.turnQuestionMax) }
      if let v = turn.options {
        if v.count > RegistryEntityLimits.turnMaxOptions {
          c.problems.append("turn \(turn.seq) has more than \(RegistryEntityLimits.turnMaxOptions) options")
        }
        t["options"] = .array(v.map { c.text("turn.option", $0, max: RegistryEntityLimits.turnOptionMax) })
      }
      if let v = turn.chosen { t["chosen"] = c.text("turn.chosen", v, max: RegistryEntityLimits.turnChosenMax) }
      if let v = turn.otherText { t["otherText"] = c.text("turn.otherText", v, max: RegistryEntityLimits.turnOtherTextMax) }
      if let v = turn.inReplyTo, let p = position[v] { t["inReplyTo"] = .int(Int64(p)) }
      if let v = turn.note { t["note"] = c.text("turn.note", v, max: RegistryEntityLimits.turnNoteMax) }
      turns.append(t)
    }
    return finish(.convo, taskID, c, fields, deleted: false).map {
      ($0, BackendTurnsPlan(taskID: taskID, turns: turns))
    }
  }
}
