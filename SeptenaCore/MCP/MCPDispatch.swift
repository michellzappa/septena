import Foundation
import SwiftData

// Routes JSON-RPC methods and tool calls to the app's mutators (writes) and
// read APIs (LocalCache / ChecklistMirror / FetchDescriptor). The local
// analogue of the gateway's `callTool` switch — but instead of CloudKit Web
// Services, every write goes through the in-process mutators, so the write
// boundary, optimistic update, and CloudKit queueing are the app's own.
//
// Everything is @MainActor: the mutators and synchronous reads require it.

@MainActor
enum MCPDispatch {

  private static let defaultProtocolVersion = "2024-11-05"
  static let serverName = "septena-local"
  static let serverVersion = "0.2.0"

  /// Gateway key aliases (canonicalize before gating / section writes).
  private static let keyAliases = ["exercise": "training"]

  // MARK: - JSON-RPC

  static func handle(method: String, id: Any?, params: [String: Any]?) async -> [String: Any]? {
    if id == nil || method.hasPrefix("notifications/") { return nil }

    switch method {
    case "initialize":
      let requested = (params?["protocolVersion"] as? String) ?? defaultProtocolVersion
      return JSONRPC.result(id: id, [
        "protocolVersion": requested,
        "capabilities": ["tools": [:] as [String: Any]],
        "serverInfo": ["name": serverName, "version": serverVersion],
      ])

    case "ping":
      return JSONRPC.result(id: id, [:] as [String: Any])

    case "tools/list":
      // Reads section config from the local mirror — must NOT block on the
      // networked part of start() (a slow CloudKit sync would otherwise make
      // the whole connector look dead). start() is already kicked off at app
      // launch and by LocalMCPServer.start().
      let enabled = enabledSections()
      return JSONRPC.result(id: id, ["tools": MCPToolCatalog.manifest(enabledSections: enabled).map(\.listEntry)])

    case "tools/call":
      let name = (params?["name"] as? String) ?? ""
      let args = MCPArgs(params?["arguments"] as? [String: Any])
      do {
        return JSONRPC.result(id: id, JSONRPC.toolResult(try await callTool(name: name, args: args)))
      } catch let e as MCPError {
        return JSONRPC.result(id: id, JSONRPC.toolResult(["error": e.message], isError: true))
      } catch {
        return JSONRPC.result(id: id, JSONRPC.toolResult(["error": String(describing: error)], isError: true))
      }

    default:
      return JSONRPC.error(id: id, code: -32601, "Method not found: \(method)")
    }
  }

  // MARK: - Context + gating

  private static var ctx: ModelContext { LocalStore.shared.container.mainContext }

  /// Section keys whose tools should be advertised. Mirrors the gateway's
  /// rule exactly (src/mcp.ts tools/list): a section qualifies only when it's
  /// `isEnabled` AND — when `section_order` is non-empty — present in that
  /// order. A section enabled but absent from the order is NOT exposed, so a
  /// half-configured section can't leak its tools. No sections at all ⇒ empty
  /// (globals only), never "everything".
  ///
  /// Delegates to `SeptenaServices.enabledSectionKeys()` so the MCP tool list
  /// and the App Intents surface (`SectionLogIntent.requireSection`) share ONE
  /// gate and can't drift.
  private static func enabledSections() -> Set<String> {
    SeptenaServices.shared.enabledSectionKeys()
  }

  // MARK: - Startup gating
  //
  // Reads run off the local SwiftData mirror (`LocalStore`), which is available
  // the instant the process is up — they must NEVER await the networked part of
  // `start()`, or a slow/stalled CloudKit sync makes every read hang and the
  // connector looks dead. Writes need the mutators bound (TaskMutator etc.
  // `preconditionFailure` if you call them unbound), so they wait for start() —
  // but only up to a timeout, then fail cleanly with a retryable tool error
  // instead of hanging or crashing.

  /// Tools that only read the local mirror — no startup wait required.
  private static let readOnlyTools: Set<String> = [
    "tasks_list", "tasks_get", "tasks_list_projects", "tasks_list_areas",
    "goals_list", "settings_get", "sections_list",
    "habits_list", "supplements_list", "chores_list",
    "gut_events_list",
    "symptoms_list", "medications_list",
    "intake_kinds_list", "intake_items_list", "intake_events_list",
    "nutrition_entries_list", "nutrition_day_summary",
    "training_entries_list", "training_exercises_list",
    "hydration_today", "hydration_history", "grocery_items_list",
  ]

  /// Wait for `start()` to finish binding the mutators, bounded by `timeout`.
  /// Returns without throwing once started; throws a retryable tool error if it
  /// doesn't complete in time (the real start() keeps running in the
  /// background, so a retry shortly after usually succeeds).
  private static func ensureStartedOrThrow(timeout: Double = 6) async throws {
    let started = await withTaskGroup(of: Bool.self) { group -> Bool in
      group.addTask { await SeptenaServices.shared.start(); return true }
      group.addTask {
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }
    if !started {
      throw MCPError.rejected("Septena is still starting up (CloudKit sync in progress) — retry in a moment.")
    }
  }

  // MARK: - Tool routing

  private static func callTool(name: String, args: MCPArgs) async throws -> Any {
    if !readOnlyTools.contains(name) {
      try await ensureStartedOrThrow()
    }

    switch name {
    // ---- Tasks ----
    case "tasks_list":          return tasksList(args)
    case "tasks_get":           return try tasksGet(args)
    case "tasks_create":        return try tasksCreate(args)
    case "tasks_complete":      return tasksComplete(args)
    case "tasks_update":        return try tasksUpdate(args)
    case "tasks_defer":         return try tasksDefer(args)
    case "tasks_move_to_today": return tasksMoveToToday(args)
    case "tasks_list_projects": return tasksListProjects(args)
    case "tasks_list_areas":    return tasksListAreas(args)
    case "tasks_thread_get":        return try tasksThreadGet(args)
    case "tasks_thread_append":     return try tasksThreadAppend(args)
    case "tasks_set_acceptance":    return try tasksSetAcceptance(args)
    case "tasks_set_endstate":      return try tasksSetEndState(args)
    case "tasks_set_assignee":      return try tasksSetAssignee(args)
    case "tasks_set_artifact":      return try tasksSetArtifact(args)
    case "tasks_set_handoff":       return try tasksSetHandoff(args)
    case "tasks_pending_reasoning": return tasksPendingReasoning(args)

    // ---- Goals ----
    case "goals_list":          return goalsList()
    case "goals_create":        return goalsCreate(args)
    case "goals_update":        return try goalsUpdate(args)

    // ---- Settings / Sections ----
    case "settings_get":        return settingsGet()
    case "settings_update":     return try settingsUpdate(args)
    case "sections_list":       return sectionsList()
    case "sections_update":     return try sectionsUpdate(args)

    // ---- Habits ----
    case "habits_list":         return habitsList(args)
    case "habits_create":       return habitsCreate(args)
    case "habits_toggle":       return try habitsToggle(args)

    // ---- Supplements ----
    case "supplements_list":    return supplementsList(args)
    case "supplements_create":  return supplementsCreate(args)
    case "supplements_toggle":  return try supplementsToggle(args)

    // ---- Chores ----
    case "chores_list":         return choresList()
    case "chores_create":       return choresCreate(args)
    case "chores_complete":     return try choresComplete(args)
    case "chores_uncomplete":   return try choresUncomplete(args)

    // ---- Intake (generic consumables) ----
    case "intake_kinds_list":   return intakeKindsList(args)
    case "intake_kind_create":  return try intakeKindCreate(args)
    case "intake_kind_update":  return try intakeKindUpdate(args)
    case "intake_items_list":   return try intakeItemsList(args)
    case "intake_item_create":  return try intakeItemCreate(args)
    case "intake_item_delete":  return try intakeItemDelete(args)
    case "intake_events_list":  return try intakeEventsList(args)
    case "intake_event_log":    return try intakeEventLog(args)
    case "intake_event_delete": return try intakeEventDelete(args)

    // ---- Gut ----
    case "gut_events_list":     return gutList(args)
    case "gut_event_log":       return try gutLog(args)

    // ---- Symptoms ----
    case "symptoms_list":       return symptomsList(args)
    case "symptoms_create":     return try symptomsCreate(args)
    case "symptoms_log":        return try symptomsLog(args)

    // ---- Medications ----
    case "medications_list":    return medicationsList(args)
    case "medications_create":  return try medicationsCreate(args)
    case "medications_log":     return try medicationsLog(args)

    // ---- Nutrition ----
    case "nutrition_entries_list": return nutritionList(args)
    case "nutrition_entry_log":    return try nutritionLog(args)
    case "nutrition_entry_update": return try nutritionUpdate(args)
    case "nutrition_day_summary":  return nutritionDaySummary(args)

    // ---- Training ----
    case "training_entries_list":  return trainingList(args)
    case "training_entry_log":     return try trainingLog(args)
    case "training_entry_update":  return try trainingUpdate(args)
    case "training_exercises_list": return trainingExercises(args)
    case "training_exercise_create": return try trainingExerciseCreate(args)
    case "training_exercise_update": return try trainingExerciseUpdate(args)

    // ---- Hydration ----
    case "hydration_log":       return try hydrationLog(args)
    case "hydration_today":     return hydrationToday()
    case "hydration_history":   return hydrationHistory(args)

    // ---- Groceries ----
    case "grocery_items_list":   return groceryList(args)
    case "grocery_item_create":  return try groceryCreate(args)
    case "grocery_item_set_low": return try grocerySetLow(args)

    default:
      throw MCPError.unknownTool(name)
    }
  }

  // MARK: - Date helpers

  private static var today: String { SeptenaDate.today }
  private static var nowHHMM: String { SeptenaDate.nowHHMM }
  private static var nowHHMMSS: String { SeptenaDate.nowHHMMSS }

  private static func ymd(daysBack: Int) -> String {
    let d = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
    return SeptenaDate.format(d) ?? today
  }

  /// Resolve date/from/to args into an inclusive YMD range. `date` pins a single
  /// day; otherwise from defaults to N days back and to defaults to today.
  private static func range(_ args: MCPArgs, daysBack: Int) -> (from: String, to: String) {
    if let d = args.string("date") { return (d, d) }
    return (args.string("from") ?? ymd(daysBack: daysBack), args.string("to") ?? today)
  }

  // MARK: - Tasks

  private static func tasksList(_ args: MCPArgs) -> Any {
    let view = args.string("view") ?? "today"
    let limit = args.int("limit") ?? 100
    let filter: TaskFilter
    switch view {
    case "triage": filter = .triage
    case "inbox": filter = .inbox
    case "upcoming": filter = .upcoming
    // "someday" is the retired bucket — accept it as an alias for "anytime"
    // so existing agent calls keep working.
    case "anytime", "someday": filter = .unscheduled
    case "completed": filter = .logbook
    default: filter = .today
    }
    // Truncation signal so a caller knows there's more beyond `limit` (the
    // classic "scanned completed to 400, missed #481, concluded deleted"
    // misread). `total` is the full count for the view; `truncated` whether
    // the returned page leaves rows behind.
    let all = LocalCache.tasks(in: ctx, filter: filter)
    return [
      "tasks": all.prefix(limit).map(taskJSON),
      "total": all.count,
      "truncated": all.count > limit,
    ]
  }

  /// One-call "where is this task, what's its state?" — every core field plus a
  /// compact conversation summary, regardless of which view (or none) the task
  /// lives in. Use `tasks_thread_get` for the full turn-by-turn conversation.
  private static func tasksGet(_ args: MCPArgs) throws -> Any {
    let id = try args.requireString("id")
    let desc = FetchDescriptor<TaskEntity>(predicate: #Predicate { $0.id == id })
    guard let e = try? ctx.fetch(desc).first else {
      throw MCPError.badArgument("unknown task id '\(id)'")
    }
    var out: [String: Any] = ["id": e.id, "title": e.title, "status": e.status.rawValue, "today": e.today]
    if let v = e.scheduled { out["scheduled"] = v }
    if let v = e.due { out["due"] = v }
    if let v = e.area { out["area"] = v }
    if let v = e.project { out["project"] = v }
    if let v = e.completedAt { out["completedAt"] = v }
    if let v = e.source { out["source"] = v }
    let c = e.conversation
    var convo: [String: Any] = [
      "turns": c.thread.count,
      "hasArtifact": c.artifact != nil,
      "hasHandoff": c.handoff != nil,
      "pendingReasoning": c.isPendingReasoning(),
    ]
    if let v = c.confirmedIntent { convo["confirmedIntent"] = v }
    if let v = c.acceptance { convo["acceptance"] = v }
    if let v = c.assignee { convo["assignee"] = v.rawValue }
    if let v = c.endState { convo["endState"] = v.rawValue }
    out["convo"] = convo
    return out
  }

  private static func tasksCreate(_ args: MCPArgs) throws -> Any {
    try validateContainer("area", args.string("area"))
    try validateContainer("project", args.string("project"))
    let t = SeptenaServices.shared.taskMutator.create(
      title: try args.requireString("title"),
      area: args.string("area"), project: args.string("project"),
      scheduled: try args.date("scheduled"), due: try args.date("due"),
      today: args.bool("today") ?? false)
    return ["id": t.id, "title": t.title]
  }

  /// Reject writes that point a task at an `area`/`project` id with no matching
  /// container — the mutator stores the string verbatim, so an unknown id becomes
  /// a dangling reference that never surfaces under any real area/project. `nil`
  /// or empty (clearing the field) is always allowed. Surfaced as `badArgument`
  /// so the calling model can self-correct against `tasks_list_areas/projects`.
  private static func validateContainer(_ kind: String, _ id: String?) throws {
    guard let id, !id.isEmpty else { return }
    let valid: [(String, String)] = kind == "area"
      ? LocalCache.areas(in: ctx).map { ($0.id, $0.title) }
      : LocalCache.projects(in: ctx).map { ($0.id, $0.title) }
    guard !valid.contains(where: { $0.0 == id }) else { return }
    let known = valid.map { "\($0.0) (\($0.1))" }.joined(separator: ", ")
    throw MCPError.badArgument(
      "unknown \(kind) id '\(id)'. Use tasks_list_\(kind)s for valid ids. Known: \(known)")
  }

  private static func tasksComplete(_ args: MCPArgs) -> Any {
    let id = (try? args.requireString("id")) ?? ""
    SeptenaServices.shared.taskMutator.complete(id: id)
    return ["id": id, "status": "done"]
  }

  private static func tasksUpdate(_ args: MCPArgs) throws -> Any {
    let id = try args.requireString("id")
    let m = SeptenaServices.shared.taskMutator
    var updated: [String] = []
    if let title = args.string("title") { m.update(id: id, title: title); updated.append("title") }
    if let today = args.bool("today") {
      today ? m.moveToToday(id: id) : m.removeFromToday(id: id); updated.append("today")
    }
    if args.present("scheduled") { m.schedule(id: id, date: try args.date("scheduled")); updated.append("scheduled") }
    if args.present("due") { m.setDue(id: id, date: try args.date("due")); updated.append("due") }
    if args.present("area") {
      try validateContainer("area", args.string("area"))
      m.moveToArea(id: id, area: args.string("area")); updated.append("area")
    }
    if args.present("project") {
      try validateContainer("project", args.string("project"))
      m.moveToProject(id: id, project: args.string("project")); updated.append("project")
    }
    if args.string("status") == "cancelled" { m.cancel(id: id); updated.append("status") }
    return ["id": id, "updated": updated]
  }

  // MARK: - Task Conversations (docs/TASK_CONVERSATIONS_PHASE0.md)

  private static func tasksThreadGet(_ args: MCPArgs) throws -> Any {
    let id = try args.requireString("id")
    guard let convo = SeptenaServices.shared.taskMutator.conversation(id: id) else {
      throw MCPError.badArgument("unknown task id '\(id)'")
    }
    let data = try JSONEncoder.taskConvo.encode(convo)
    let obj = (try? JSONSerialization.jsonObject(with: data)) ?? [:]
    return ["id": id, "conversation": obj]
  }

  private static func tasksThreadAppend(_ args: MCPArgs) throws -> Any {
    let id = try args.requireString("id")
    guard let raw = args.object("turn") else { throw MCPError.badArgument("missing 'turn' object") }
    let t = MCPArgs(raw)
    guard let role = t.string("role").flatMap(ConvoTurn.Role.init(rawValue:)) else {
      throw MCPError.badArgument("turn.role must be 'user' or 'provider'")
    }
    guard let step = t.string("step").flatMap(ConvoTurn.Step.init(rawValue:)) else {
      throw MCPError.badArgument("turn.step must be confirm|ground|scope|decide|work")
    }
    let turn = ConvoTurn(
      seq: 0,                                          // assigned by the mutator
      role: role,
      step: step,
      provider: t.string("provider").flatMap(ConvoTurn.Provider.init(rawValue:)),
      confidence: t.double("confidence"),
      question: t.string("question"),
      options: t.stringArray("options"),
      chosen: t.string("chosen"),
      otherText: t.string("otherText"),
      inReplyTo: t.int("inReplyTo"),
      note: t.string("note"),
      ts: Date()
    )
    let seq = SeptenaServices.shared.taskMutator.appendConvoTurn(id: id, turn)
    return ["id": id, "seq": seq]
  }

  private static func tasksSetAcceptance(_ args: MCPArgs) throws -> Any {
    let id = try args.requireString("id")
    let line = try args.requireString("acceptance")
    SeptenaServices.shared.taskMutator.setConvoAcceptance(id: id, line)
    return ["id": id, "acceptance": line]
  }

  private static func tasksSetEndState(_ args: MCPArgs) throws -> Any {
    let id = try args.requireString("id")
    let raw = try args.requireString("endState")
    guard let state = ConvoEndState(rawValue: raw) else {
      throw MCPError.badArgument("unknown endState '\(raw)'")
    }
    SeptenaServices.shared.taskMutator.setConvoEndState(id: id, state, note: args.string("note"))
    return ["id": id, "endState": raw]
  }

  private static func tasksSetAssignee(_ args: MCPArgs) throws -> Any {
    let id = try args.requireString("id")
    guard args.present("assignee") else { throw MCPError.badArgument("missing 'assignee'") }
    let assignee: ConvoAssignee?
    if let s = args.string("assignee") {
      guard let a = ConvoAssignee(rawValue: s) else {
        throw MCPError.badArgument("assignee must be me|local|claude, or null")
      }
      assignee = a
    } else {
      assignee = nil                                   // explicit null → router-decided
    }
    SeptenaServices.shared.taskMutator.setConvoAssignee(id: id, assignee)
    return ["id": id, "assignee": assignee?.rawValue ?? "auto"]
  }

  private static func tasksSetArtifact(_ args: MCPArgs) throws -> Any {
    let id = try args.requireString("id")
    guard let raw = args.object("artifact") else { throw MCPError.badArgument("missing 'artifact' object") }
    let a = MCPArgs(raw)
    let artifact = ConvoArtifact(
      kind: a.string("kind") ?? "note",
      title: try a.requireString("title"),
      body: a.string("body") ?? "",
      refs: a.stringArray("refs")
    )
    SeptenaServices.shared.taskMutator.setConvoArtifact(id: id, artifact)
    return ["id": id, "artifact": artifact.title]
  }

  private static func tasksSetHandoff(_ args: MCPArgs) throws -> Any {
    let id = try args.requireString("id")
    guard let raw = args.object("handoff") else { throw MCPError.badArgument("missing 'handoff' object") }
    let h = MCPArgs(raw)
    let actionRaw = h.string("actionType") ?? "none"
    guard let action = ConvoHandoff.ActionType(rawValue: actionRaw) else {
      throw MCPError.badArgument("handoff.actionType must be open_url|compose|call|none")
    }
    let handoff = ConvoHandoff(instruction: try h.requireString("instruction"), actionType: action, payload: h.string("payload"))
    SeptenaServices.shared.taskMutator.setConvoHandoff(id: id, handoff)
    return ["id": id, "handoff": handoff.instruction]
  }

  private static func tasksPendingReasoning(_ args: MCPArgs) -> Any {
    let limit = args.int("limit") ?? 50
    let rows = SeptenaServices.shared.taskMutator.pendingReasoning(limit: limit).map { e -> [String: Any] in
      var row: [String: Any] = ["id": e.id, "title": e.title]
      let c = e.conversation
      if let ci = c.confirmedIntent { row["confirmedIntent"] = ci }
      if let a = c.assignee { row["assignee"] = a.rawValue }
      return row
    }
    return ["tasks": rows]
  }

  private static func tasksDefer(_ args: MCPArgs) throws -> Any {
    let id = try args.requireString("id")
    guard let until = try args.date("until") else { throw MCPError.badArgument("missing 'until'") }
    let m = SeptenaServices.shared.taskMutator
    m.schedule(id: id, date: until); m.removeFromToday(id: id)
    return ["id": id, "scheduled": SeptenaDate.format(until) ?? ""]
  }

  private static func tasksMoveToToday(_ args: MCPArgs) -> Any {
    let id = (try? args.requireString("id")) ?? ""
    let m = SeptenaServices.shared.taskMutator
    m.moveToToday(id: id); m.schedule(id: id, date: nil)
    return ["id": id, "today": true]
  }

  private static func tasksListProjects(_ args: MCPArgs) -> Any {
    let status = args.string("status") ?? "active"
    let limit = args.int("limit") ?? 200
    let projects = LocalCache.projects(in: ctx)
      .filter { status == "all" || $0.status.rawValue == status }
      .prefix(limit)
      .map { ["id": $0.id, "title": $0.title, "status": $0.status.rawValue, "area": $0.area ?? ""] }
    return ["projects": Array(projects)]
  }

  private static func tasksListAreas(_ args: MCPArgs) -> Any {
    let limit = args.int("limit") ?? 100
    return ["areas": LocalCache.areas(in: ctx).prefix(limit).map { ["id": $0.id, "title": $0.title] }]
  }

  private static func taskJSON(_ t: SeptenaTask) -> [String: Any] {
    var out: [String: Any] = ["id": t.id, "title": t.title, "status": t.status.rawValue, "today": t.today]
    if let s = t.scheduled { out["scheduled"] = s }
    if let d = t.deadline { out["deadline"] = d }
    if let a = t.area { out["area"] = a }
    if let p = t.project { out["project"] = p }
    if let c = t.completedAt { out["completedAt"] = c }
    return out
  }

  // MARK: - Goals

  private static func goalsList() -> Any {
    ["goals": LocalCache.goals(in: ctx).map { g -> [String: Any] in
      var d: [String: Any] = ["id": g.id, "text": g.text, "sections": g.sections, "created": g.created]
      // Measurement attachment (quant goals) so an agent sees targets, ranges
      // and progress — not just the title. Omitted on free-text goals.
      // metricTargetUpper present ⇒ a "between" range band [target, upper].
      if let v = g.metricKey { d["metricKey"] = v }
      if let v = g.metricWindow { d["metricWindow"] = v }
      if let v = g.metricComparator { d["metricComparator"] = v }
      if let v = g.metricTarget { d["metricTarget"] = v }
      if let v = g.metricTargetUpper { d["metricTargetUpper"] = v }
      if let v = g.metricBaseline { d["metricBaseline"] = v }
      return d
    }]
  }

  private static func goalsCreate(_ args: MCPArgs) -> Any {
    let m = SeptenaServices.shared.goalMutator
    let g = m.createGoal(text: args.string("text") ?? "")
    if let sections = args.stringArray("sections"), !sections.isEmpty {
      m.updateGoal(id: g.id, text: g.text, sections: sections)
    }
    return ["id": g.id, "text": g.text]
  }

  private static func goalsUpdate(_ args: MCPArgs) throws -> Any {
    let id = try args.requireString("id")
    guard let current = LocalCache.goals(in: ctx).first(where: { $0.id == id }) else {
      throw MCPError.rejected("Goal not found: \(id)")
    }
    let text = args.string("text") ?? current.text
    let sections = args.stringArray("sections") ?? current.sections
    SeptenaServices.shared.goalMutator.updateGoal(id: id, text: text, sections: sections)
    return ["id": id, "text": text, "sections": sections]
  }

  // MARK: - Settings / Sections

  private static func settingsGet() -> Any {
    guard let s = SettingsMirror.loadSettings(context: ctx),
          let data = try? JSONEncoder().encode(s),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      return [:] as [String: Any]
    }
    return obj
  }

  private static func settingsUpdate(_ args: MCPArgs) throws -> Any {
    guard let patch = args.object("patch") else { throw MCPError.badArgument("missing 'patch'") }
    var base = (settingsGet() as? [String: Any]) ?? [:]
    base = deepMerge(base, patch)
    do {
      let data = try JSONSerialization.data(withJSONObject: base)
      let merged = try JSONDecoder().decode(AppSettings.self, from: data)
      SettingsMirror.upsert(settings: merged, context: ctx, engine: SeptenaServices.shared.ckEngine)
      return ["ok": true, "updated": Array(patch.keys)]
    } catch {
      throw MCPError.rejected("settings patch did not apply cleanly: \(error)")
    }
  }

  private static func deepMerge(_ base: [String: Any], _ patch: [String: Any]) -> [String: Any] {
    var out = base
    for (k, v) in patch {
      if let bv = out[k] as? [String: Any], let pv = v as? [String: Any] {
        out[k] = deepMerge(bv, pv)
      } else {
        out[k] = v
      }
    }
    return out
  }

  private static func sectionsList() -> Any {
    let order = SettingsMirror.loadSettings(context: ctx)?.sectionOrder ?? []
    let idx = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
    let sections = SettingsMirror.loadSections(context: ctx).sorted {
      (idx[$0.key] ?? Int.max, $0.label) < (idx[$1.key] ?? Int.max, $1.label)
    }
    return ["sections": sections.map {
      ["key": $0.key, "label": $0.label, "color": $0.color,
       "isEnabled": $0.isEnabled, "showInToday": $0.showInToday]
    }]
  }

  private static func sectionsUpdate(_ args: MCPArgs) throws -> Any {
    let rawKey = try args.requireString("key")
    let key = keyAliases[rawKey] ?? rawKey
    let engine = SeptenaServices.shared.ckEngine
    let existing = SettingsMirror.loadSections(context: ctx).first { $0.key == key }

    let config = SectionConfig(
      key: key,
      label: args.string("label") ?? existing?.label ?? key,
      color: args.string("color") ?? existing?.color ?? "#888888",
      isEnabled: args.bool("enabled") ?? existing?.isEnabled ?? true,
      showInToday: existing?.showInToday ?? true,
      // Preserve the Spotlight opt-out — MCP doesn't manage it, but
      // replaceSections writes it, so carry the existing value through.
      showInSpotlight: existing?.showInSpotlight ?? true,
      hasOnboarded: existing?.hasOnboarded ?? false)
    SettingsMirror.replaceSections([config], context: ctx, engine: engine)

    if let order = args.int("order") {
      var settings = SettingsMirror.loadSettings(context: ctx) ?? AppSettings()
      var ord = settings.sectionOrder ?? []
      ord.removeAll { $0 == key }
      ord.insert(key, at: min(max(order, 0), ord.count))
      settings.sectionOrder = ord
      SettingsMirror.upsert(settings: settings, context: ctx, engine: engine)
    }
    return ["key": key, "label": config.label, "color": config.color, "isEnabled": config.isEnabled]
  }

  // MARK: - Habits

  private static func habitsList(_ args: MCPArgs) -> Any {
    let date = args.string("date") ?? today
    guard let resp = ChecklistMirror.loadHabitsDay(context: ctx, date: date) else {
      return ["date": date, "habits": []]
    }
    let habits = resp.grouped.values.flatMap { $0 }.map {
      ["id": $0.id, "name": $0.name, "emoji": $0.emoji ?? "", "bucket": $0.bucket,
       "done": $0.done, "skipped": $0.skipped]
    }
    return ["date": date, "habits": habits]
  }

  private static func habitsCreate(_ args: MCPArgs) -> Any {
    let h = SeptenaServices.shared.checklistMutator.createHabit(
      name: args.string("title") ?? "", bucket: args.string("bucket") ?? "anytime",
      emoji: args.string("emoji"))
    return ["id": h.id, "name": h.name, "bucket": h.bucket]
  }

  private static func habitsToggle(_ args: MCPArgs) throws -> Any {
    let id = try args.requireString("id")
    let date = args.string("date") ?? today
    let done = args.bool("done") ?? false
    let skipped = args.bool("skipped") ?? false
    let m = SeptenaServices.shared.checklistMutator
    if skipped {
      m.skipHabit(id: id, date: date, skipped: true)
    } else if done {
      m.toggleHabit(id: id, date: date, done: true)
    } else {
      m.toggleHabit(id: id, date: date, done: false)
      m.skipHabit(id: id, date: date, skipped: false)
    }
    return ["id": id, "date": date, "done": done, "skipped": skipped]
  }

  // MARK: - Supplements

  private static func supplementsList(_ args: MCPArgs) -> Any {
    let date = args.string("date") ?? today
    guard let resp = ChecklistMirror.loadSupplementsDay(context: ctx, date: date) else {
      return ["date": date, "supplements": []]
    }
    return ["date": date, "supplements": resp.items.map {
      ["id": $0.id, "name": $0.name, "emoji": $0.emoji ?? "", "done": $0.done]
    }]
  }

  private static func supplementsCreate(_ args: MCPArgs) -> Any {
    let sup = SeptenaServices.shared.checklistMutator.createSupplement(
      name: args.string("title") ?? "", emoji: args.string("emoji"))
    return ["id": sup.id, "name": sup.name]
  }

  private static func supplementsToggle(_ args: MCPArgs) throws -> Any {
    let id = try args.requireString("id")
    let date = args.string("date") ?? today
    let done = args.bool("done") ?? false
    SeptenaServices.shared.checklistMutator.toggleSupplement(id: id, date: date, done: done)
    return ["id": id, "date": date, "done": done]
  }

  // MARK: - Chores

  private static func choresList() -> Any {
    ["chores": ChecklistMirror.loadChores(context: ctx).map {
      ["id": $0.id, "name": $0.name, "emoji": $0.emoji ?? "",
       "dueDate": $0.dueDate ?? "", "lastCompleted": $0.lastCompleted ?? "",
       "daysOverdue": $0.daysOverdue, "cadenceDays": $0.cadenceDays ?? 0]
    }]
  }

  private static func choresCreate(_ args: MCPArgs) -> Any {
    let c = SeptenaServices.shared.checklistMutator.createChore(
      name: args.string("title") ?? "", cadenceDays: args.int("cadenceDays") ?? 7,
      emoji: args.string("emoji"))
    return ["id": c.id, "name": c.name, "cadenceDays": c.cadenceDays ?? 0]
  }

  private static func choresComplete(_ args: MCPArgs) throws -> Any {
    let id = try args.requireString("id")
    let date = args.string("date") ?? today
    SeptenaServices.shared.checklistMutator.completeChore(id: id, date: date)
    return ["id": id, "date": date]
  }

  private static func choresUncomplete(_ args: MCPArgs) throws -> Any {
    let id = try args.requireString("id")
    let date = args.string("date") ?? today
    SeptenaServices.shared.checklistMutator.uncompleteChore(id: id, date: date)
    return ["id": id, "date": date]
  }

  // MARK: - Intake (generic consumables)
  //
  // The tracker ("kind") is resolved from an id OR unique case-insensitive
  // name, and every resolution failure returns the candidate list inline so a
  // wrong guess self-corrects in one round trip (study §6.1).

  private static func resolveIntakeKind(_ args: MCPArgs) throws -> IntakeKindEntity {
    let key = try args.requireString("kind")
    let kinds = (try? ctx.fetch(FetchDescriptor<IntakeKindEntity>())) ?? []
    if let exact = kinds.first(where: { $0.id == key }) { return exact }
    let lower = key.lowercased()
    let named = kinds.filter { $0.name.lowercased() == lower }
    if named.count == 1 { return named[0] }
    let candidates = kinds.filter { $0.archivedAt == nil }
      .map { "\($0.name) (\($0.id))" }.joined(separator: ", ")
    throw MCPError.badArgument(named.isEmpty
      ? "unknown kind '\(key)' — kinds: \(candidates)"
      : "ambiguous kind '\(key)' — use an id. kinds: \(candidates)")
  }

  /// Parse a `methods` array argument into rows. Token defaults to a slug of
  /// the label so agents can pass labels only.
  private static func intakeMethodRows(_ args: MCPArgs) -> [IntakeMethodRow]? {
    guard let arr = args.raw["methods"] as? [[String: Any]] else { return nil }
    let rows = arr.compactMap { m -> IntakeMethodRow? in
      guard let label = (m["label"] as? String) ?? (m["token"] as? String) else { return nil }
      let token = (m["token"] as? String).flatMap { $0.isEmpty ? nil : $0.lowercased() }
        ?? IntakeTemplates.slug(label)
      return IntakeMethodRow(token: token, label: label,
                             symbol: m["symbol"] as? String,
                             defaultAmount: (m["defaultAmount"] as? NSNumber)?.doubleValue,
                             usesContainer: (m["usesContainer"] as? Bool) ?? false)
    }
    return rows.isEmpty ? nil : rows
  }

  private static func intakeKindsList(_ args: MCPArgs) -> Any {
    let includeArchived = args.bool("includeArchived") ?? false
    let kinds = ((try? ctx.fetch(FetchDescriptor<IntakeKindEntity>(
      sortBy: [SortDescriptor(\.sortIndex)]))) ?? [])
      .filter { includeArchived || $0.archivedAt == nil }
    let events = (try? ctx.fetch(FetchDescriptor<IntakeEventEntity>())) ?? []
    let items = (try? ctx.fetch(FetchDescriptor<IntakeItemEntity>())) ?? []
    let todayStr = today
    return ["kinds": kinds.map { (k: IntakeKindEntity) -> [String: Any] in
      var lastContainer = 0
      if let token = k.methods.first(where: { $0.usesContainer })?.token {
        lastContainer = events
          .filter { $0.kindID == k.id && $0.date == todayStr && $0.method == token }
          .max(by: { $0.occurredAt < $1.occurredAt })?.count ?? 0
      }
      return ["id": k.id, "name": k.name, "symbol": k.symbol, "color": k.color,
              "unit": k.unit ?? "", "doseStyle": k.doseStyle,
              "countNoun": k.countNoun ?? "", "containerNoun": k.containerNoun ?? "",
              "containerCap": k.containerCap ?? 0, "catalogNoun": k.catalogNoun ?? "",
              "objective": k.objective, "archived": k.archivedAt != nil,
              "methods": k.methods.map { ["token": $0.token, "label": $0.label,
                                          "usesContainer": $0.usesContainer,
                                          "defaultAmount": $0.defaultAmount ?? 0] },
              "itemCount": items.filter { $0.kindID == k.id }.count,
              "todayCount": events.filter { $0.kindID == k.id && $0.date == todayStr }.count,
              "lastContainerCountToday": lastContainer]
    }]
  }

  private static func intakeKindCreate(_ args: MCPArgs) throws -> Any {
    let kind = SeptenaServices.shared.intakeMutator.addKind(
      name: try args.requireString("name"),
      symbol: args.string("symbol") ?? "circle",
      color: args.string("color") ?? "",
      unit: args.string("unit"),
      doseStyle: args.string("doseStyle") ?? "none",
      countNoun: args.string("countNoun"),
      containerNoun: args.string("containerNoun"),
      containerCap: args.int("containerCap"),
      catalogNoun: args.string("catalogNoun"),
      objective: args.string("objective") ?? "log",
      methods: intakeMethodRows(args) ?? [])
    if kind.objective != "log" {
      SeptenaServices.shared.goalMutator.syncIntakeObjectiveGoal(
        kindID: kind.id, kindName: kind.name, objective: kind.objective,
        target: args.double("target"), weekly: args.bool("weekly"))
    }
    return ["id": kind.id, "name": kind.name]
  }

  private static func intakeKindUpdate(_ args: MCPArgs) throws -> Any {
    let kind = try resolveIntakeKind(args)
    let mutator = SeptenaServices.shared.intakeMutator
    mutator.updateKind(
      id: kind.id,
      name: args.string("name"),
      symbol: args.string("symbol"),
      color: args.string("color"),
      unit: args.string("unit").map { Optional($0) },
      doseStyle: args.string("doseStyle"),
      countNoun: args.string("countNoun").map { Optional($0) },
      containerNoun: args.string("containerNoun").map { Optional($0) },
      containerCap: args.int("containerCap").map { Optional($0) },
      catalogNoun: args.string("catalogNoun").map { Optional($0) },
      objective: args.string("objective"),
      methods: intakeMethodRows(args))
    if let archived = args.bool("archived") {
      mutator.setKindArchived(id: kind.id, archived: archived)
    }
    if let objective = args.string("objective") {
      SeptenaServices.shared.goalMutator.syncIntakeObjectiveGoal(
        kindID: kind.id, kindName: args.string("name") ?? kind.name,
        objective: objective, target: args.double("target"), weekly: args.bool("weekly"))
    }
    return ["id": kind.id, "name": args.string("name") ?? kind.name]
  }

  private static func intakeItemsList(_ args: MCPArgs) throws -> Any {
    let kind = try resolveIntakeKind(args)
    let rows = ((try? ctx.fetch(FetchDescriptor<IntakeItemEntity>(
      sortBy: [SortDescriptor(\.sortIndex)]))) ?? [])
      .filter { $0.kindID == kind.id && $0.archivedAt == nil }
    return ["kind": kind.name, "items": rows.map { (i: IntakeItemEntity) -> [String: Any] in
      ["id": i.id, "name": i.name]
    }]
  }

  private static func intakeItemCreate(_ args: MCPArgs) throws -> Any {
    let kind = try resolveIntakeKind(args)
    let item = SeptenaServices.shared.intakeMutator.addItem(
      kindID: kind.id, name: try args.requireString("name"))
    return ["id": item.id, "name": item.name]
  }

  private static func intakeItemDelete(_ args: MCPArgs) throws -> Any {
    SeptenaServices.shared.intakeMutator.deleteItem(id: try args.requireString("id"))
    return ["ok": true]
  }

  private static func intakeEventsList(_ args: MCPArgs) throws -> Any {
    let kind = try resolveIntakeKind(args)
    let (from, to) = range(args, daysBack: 6)
    let limit = args.int("limit") ?? 100
    let itemNames = Dictionary(
      ((try? ctx.fetch(FetchDescriptor<IntakeItemEntity>())) ?? []).map { ($0.id, $0.name) },
      uniquingKeysWith: { a, _ in a })
    let rows = ((try? ctx.fetch(FetchDescriptor<IntakeEventEntity>())) ?? [])
      .filter { $0.kindID == kind.id && $0.date >= from && $0.date <= to }
      .sorted { $0.occurredAt > $1.occurredAt }
      .prefix(limit)
    return ["kind": kind.name, "kindID": kind.id,
            "events": rows.map { (e: IntakeEventEntity) -> [String: Any] in
      ["id": e.id, "date": e.date, "time": EventTimestamp.hhmm(from: e.occurredAt),
       "method": e.method, "item": e.itemID.flatMap { itemNames[$0] } ?? "",
       "amount": e.amount ?? 0, "count": e.count ?? 0, "note": e.note ?? ""]
    }]
  }

  private static func intakeEventLog(_ args: MCPArgs) throws -> Any {
    let kind = try resolveIntakeKind(args)
    let rawMethod = try args.requireString("method")
    let lower = rawMethod.lowercased()
    // Tokens are canonical; labels resolve too so agents can speak in the
    // user's vocabulary. An unknown method errors with the candidate list.
    guard let token = kind.methods.first(where: {
      $0.token == lower || $0.label.lowercased() == lower
    })?.token ?? (kind.methods.isEmpty ? IntakeTemplates.slug(rawMethod) : nil) else {
      throw MCPError.badArgument(
        "unknown method '\(rawMethod)' for \(kind.name) — methods: "
        + kind.methods.map(\.token).joined(separator: ", "))
    }
    var itemID: String? = nil
    if let itemArg = args.string("item") {
      let items = ((try? ctx.fetch(FetchDescriptor<IntakeItemEntity>())) ?? [])
        .filter { $0.kindID == kind.id }
      itemID = items.first { $0.id == itemArg }?.id
        ?? items.first { $0.name.lowercased() == itemArg.lowercased() }?.id
      if itemID == nil {
        throw MCPError.badArgument(
          "unknown item '\(itemArg)' — items: " + items.map(\.name).joined(separator: ", "))
      }
    }
    let e = SeptenaServices.shared.intakeMutator.addEntry(
      kindID: kind.id,
      date: args.string("date") ?? today,
      time: args.string("time") ?? nowHHMMSS,
      method: token,
      itemID: itemID,
      amount: args.double("amount"),
      count: args.int("count"),
      note: args.string("note") ?? "")
    return ["id": e.id, "date": e.date, "method": e.method, "kind": kind.name]
  }

  private static func intakeEventDelete(_ args: MCPArgs) throws -> Any {
    SeptenaServices.shared.intakeMutator.deleteEntry(id: try args.requireString("id"))
    return ["ok": true]
  }

  // MARK: - Gut

  private static func gutList(_ args: MCPArgs) -> Any {
    let (from, to) = range(args, daysBack: 6)
    let limit = args.int("limit") ?? 100
    let rows = (try? ctx.fetch(FetchDescriptor<GutEventEntity>()))?
      .filter { $0.date >= from && $0.date <= to }
      .sorted { $0.occurredAt > $1.occurredAt }
      .prefix(limit) ?? []
    // Explicit element type so `e.id` resolves to the stored `var id: String`
    // rather than @Model's synthesized `persistentModelID`.
    return ["events": rows.map { (e: GutEventEntity) -> [String: Any] in
      ["id": e.id, "date": e.date, "bristol": e.bristol,
       "volume": e.volume ?? "", "note": e.note ?? ""]
    }]
  }

  private static func gutLog(_ args: MCPArgs) throws -> Any {
    guard let bristol = args.int("bristol") else { throw MCPError.badArgument("missing 'bristol'") }
    let e = SeptenaServices.shared.gutMutator.addEntry(
      date: args.string("date") ?? today, time: args.string("time") ?? nowHHMMSS,
      bristol: bristol,
      volume: args.string("volume"), note: args.string("note") ?? "")
    return ["id": e.id, "date": e.date, "bristol": e.bristol]
  }

  // MARK: - Symptoms

  private static func symptomDefinitions() -> [SymptomDefinitionEntity] {
    ((try? ctx.fetch(FetchDescriptor<SymptomDefinitionEntity>(
      sortBy: [SortDescriptor(\.sortIndex)]))) ?? [])
  }

  private static func symptomsList(_ args: MCPArgs) -> Any {
    let (from, to) = range(args, daysBack: 6)
    let limit = args.int("limit") ?? 100
    let definitions = symptomDefinitions()
    let titleByID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0.title) })
    let events = ((try? ctx.fetch(FetchDescriptor<SymptomEventEntity>())) ?? [])
      .filter { $0.date >= from && $0.date <= to }
      .sorted { $0.occurredAt > $1.occurredAt }
      .prefix(limit)
    return [
      "definitions": definitions.map { (d: SymptomDefinitionEntity) -> [String: Any] in
        [
          "id": d.id,
          "title": d.title,
          "emoji": d.emoji ?? "",
          "bodySystem": d.bodySystem ?? "",
          "defaultBodyRegion": d.defaultBodyRegion ?? "",
          "archived": d.archived,
        ]
      },
      "events": events.map { (e: SymptomEventEntity) -> [String: Any] in
        var out: [String: Any] = [
          "id": e.id,
          "date": e.date,
          "time": EventTimestamp.hhmm(from: e.occurredAt),
          "symptomID": e.symptomID,
          "symptom": titleByID[e.symptomID] ?? "",
          "severity": e.severity,
        ]
        if let v = e.durationMinutes { out["durationMinutes"] = v }
        if let v = e.bodyRegion { out["bodyRegion"] = v }
        if let v = e.side { out["side"] = v }
        if let v = e.quality { out["quality"] = v }
        if let v = e.triggerNote { out["triggerNote"] = v }
        if let v = e.reliefNote { out["reliefNote"] = v }
        if let v = e.note { out["note"] = v }
        return out
      },
    ]
  }

  private static func symptomsCreate(_ args: MCPArgs) throws -> Any {
    let d = SeptenaServices.shared.symptomsMutator.addDefinition(
      title: try args.requireString("title"),
      emoji: args.string("emoji"),
      bodySystem: args.string("bodySystem"),
      defaultBodyRegion: args.string("defaultBodyRegion"))
    return ["id": d.id, "title": d.title]
  }

  private static func symptomsLog(_ args: MCPArgs) throws -> Any {
    let symptomID = try args.requireString("symptomID")
    guard symptomDefinitions().contains(where: { $0.id == symptomID && !$0.archived }) else {
      throw MCPError.badArgument("unknown active symptomID '\(symptomID)' — call symptoms_list")
    }
    guard let severity = args.int("severity") else {
      throw MCPError.badArgument("missing 'severity'")
    }
    let e = SeptenaServices.shared.symptomsMutator.addEvent(
      symptomID: symptomID,
      date: args.string("date") ?? today,
      time: args.string("time") ?? nowHHMMSS,
      severity: severity,
      durationMinutes: args.int("durationMinutes"),
      bodyRegion: args.string("bodyRegion"),
      side: args.string("side"),
      quality: args.string("quality"),
      triggerNote: args.string("triggerNote") ?? "",
      reliefNote: args.string("reliefNote") ?? "",
      note: args.string("note") ?? "",
      source: "mcp")
    return ["id": e.id, "date": e.date, "symptomID": e.symptomID, "severity": e.severity]
  }

  // MARK: - Medications

  private static func medicationDefinitions() -> [MedicationDefinitionEntity] {
    ((try? ctx.fetch(FetchDescriptor<MedicationDefinitionEntity>(
      sortBy: [SortDescriptor(\.sortIndex)]))) ?? [])
  }

  private static func medicationsList(_ args: MCPArgs) -> Any {
    let (from, to) = range(args, daysBack: 6)
    let limit = args.int("limit") ?? 100
    let definitions = medicationDefinitions()
    let titleByID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0.title) })
    let doses = ((try? ctx.fetch(FetchDescriptor<MedicationDoseEventEntity>())) ?? [])
      .filter { $0.date >= from && $0.date <= to }
      .sorted { $0.occurredAt > $1.occurredAt }
      .prefix(limit)
    return [
      "definitions": definitions.map { (d: MedicationDefinitionEntity) -> [String: Any] in
        var out: [String: Any] = [
          "id": d.id,
          "title": d.title,
          "bucket": d.bucket ?? "",
          "scheduleKind": d.scheduleKind ?? "daily",
          "targetDosesPerDay": d.targetDosesPerDay ?? 1,
          "archived": d.archived,
        ]
        if let v = d.genericName { out["genericName"] = v }
        if let v = d.form { out["form"] = v }
        if let v = d.route { out["route"] = v }
        if let v = d.strengthValue { out["strengthValue"] = v }
        if let v = d.strengthUnit { out["strengthUnit"] = v }
        if let v = d.defaultDoseValue { out["defaultDoseValue"] = v }
        if let v = d.defaultDoseUnit { out["defaultDoseUnit"] = v }
        if let v = d.instructions { out["instructions"] = v }
        return out
      },
      "doses": doses.map { (e: MedicationDoseEventEntity) -> [String: Any] in
        var out: [String: Any] = [
          "id": e.id,
          "date": e.date,
          "time": EventTimestamp.hhmm(from: e.occurredAt),
          "medicationID": e.medicationID,
          "medication": titleByID[e.medicationID] ?? "",
          "status": e.status,
        ]
        if let v = e.doseValue { out["doseValue"] = v }
        if let v = e.doseUnit { out["doseUnit"] = v }
        if let v = e.reason { out["reason"] = v }
        if let v = e.effectNote { out["effectNote"] = v }
        if let v = e.sideEffectNote { out["sideEffectNote"] = v }
        return out
      },
    ]
  }

  private static func medicationsCreate(_ args: MCPArgs) throws -> Any {
    let d = SeptenaServices.shared.medicationsMutator.addDefinition(
      title: try args.requireString("title"),
      genericName: args.string("genericName"),
      form: args.string("form"),
      route: args.string("route"),
      strengthValue: args.double("strengthValue"),
      strengthUnit: args.string("strengthUnit"),
      defaultDoseValue: args.double("defaultDoseValue"),
      defaultDoseUnit: args.string("defaultDoseUnit"),
      bucket: args.string("bucket"),
      scheduleKind: args.string("scheduleKind") ?? "daily",
      targetDosesPerDay: args.int("targetDosesPerDay") ?? 1,
      instructions: args.string("instructions"))
    return ["id": d.id, "title": d.title]
  }

  private static let validMedicationStatuses = ["taken", "skipped", "missed"]

  private static func medicationsLog(_ args: MCPArgs) throws -> Any {
    let medicationID = try args.requireString("medicationID")
    guard medicationDefinitions().contains(where: { $0.id == medicationID && !$0.archived }) else {
      throw MCPError.badArgument("unknown active medicationID '\(medicationID)' — call medications_list")
    }
    let status = try args.requireString("status")
    guard validMedicationStatuses.contains(status) else {
      throw MCPError.badArgument("status must be taken|skipped|missed")
    }
    let e = SeptenaServices.shared.medicationsMutator.addDose(
      medicationID: medicationID,
      date: args.string("date") ?? today,
      time: args.string("time") ?? nowHHMMSS,
      status: status,
      doseValue: args.double("doseValue"),
      doseUnit: args.string("doseUnit"),
      reason: args.string("reason") ?? "",
      effectNote: args.string("effectNote") ?? "",
      sideEffectNote: args.string("sideEffectNote") ?? "",
      source: "mcp")
    return ["id": e.id, "date": e.date, "medicationID": e.medicationID, "status": e.status]
  }

  // MARK: - Nutrition

  private static func nutritionEntities(_ from: String, _ to: String) -> [NutritionEntryEntity] {
    let cal = Calendar.current
    guard let f = SeptenaDate.parse(from), let t = SeptenaDate.parse(to) else { return [] }
    let start = cal.startOfDay(for: f)
    let end = cal.startOfDay(for: t).addingTimeInterval(86_400)   // exclusive next midnight
    return (try? ctx.fetch(FetchDescriptor<NutritionEntryEntity>()))?
      .filter { $0.loggedAt >= start && $0.loggedAt < end }
      .sorted { $0.loggedAt > $1.loggedAt } ?? []
  }

  private static func nutritionList(_ args: MCPArgs) -> Any {
    let (from, to) = range(args, daysBack: 6)
    let limit = args.int("limit") ?? 200
    let iso = ISO8601DateFormatter()
    let rows = nutritionEntities(from, to).prefix(limit).map { e -> [String: Any] in
      var out: [String: Any] = [
        "id": e.id, "loggedAt": iso.string(from: e.loggedAt), "foods": e.foods,
        "proteinG": e.proteinG, "fatG": e.fatG, "carbsG": e.carbsG,
      ]
      if let m = e.mealType { out["mealType"] = m }
      if let n = e.note { out["note"] = n }
      if let k = e.kcal { out["kcal"] = k }
      if let w = e.waterMl { out["waterMl"] = w }
      return out
    }
    return ["entries": Array(rows)]
  }

  private static func nutritionLog(_ args: MCPArgs) throws -> Any {
    let foods = try args.requireString("foods").components(separatedBy: "\n").filter { !$0.isEmpty }
    let loggedAt = args.string("loggedAt").flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
    let e = SeptenaServices.shared.nutritionMutator.addEntry(
      loggedAt: loggedAt, emoji: args.string("emoji") ?? "", foods: foods,
      note: args.string("note") ?? "", mealType: args.string("mealType"), source: "mcp",
      proteinG: args.double("proteinG") ?? 0, fatG: args.double("fatG") ?? 0, carbsG: args.double("carbsG") ?? 0,
      fiberG: args.double("fiberG"), sugarG: args.double("sugarG"),
      saturatedFatG: args.double("saturatedFatG"), alcoholG: args.double("alcoholG"),
      kcal: args.double("kcal"), sodiumMg: args.double("sodiumMg"),
      cholesterolMg: args.double("cholesterolMg"), potassiumMg: args.double("potassiumMg"),
      waterMl: args.double("waterMl"))
    return ["id": e.id]
  }

  private static func nutritionUpdate(_ args: MCPArgs) throws -> Any {
    let id = try args.requireString("id")
    let foods = args.string("foods")?.components(separatedBy: "\n").filter { !$0.isEmpty }
    SeptenaServices.shared.nutritionMutator.updateEntry(
      id: id,
      pickedAt: args.string("loggedAt").flatMap { ISO8601DateFormatter().date(from: $0) },
      emoji: args.string("emoji"), foods: foods, note: args.string("note"),
      mealType: args.string("mealType"),
      proteinG: args.double("proteinG"), fatG: args.double("fatG"), carbsG: args.double("carbsG"),
      fiberG: args.double("fiberG"), sugarG: args.double("sugarG"),
      saturatedFatG: args.double("saturatedFatG"), alcoholG: args.double("alcoholG"),
      kcal: args.double("kcal"), sodiumMg: args.double("sodiumMg"),
      cholesterolMg: args.double("cholesterolMg"), potassiumMg: args.double("potassiumMg"),
      waterMl: args.double("waterMl"))
    return ["id": id]
  }

  private static func nutritionDaySummary(_ args: MCPArgs) -> Any {
    let date = args.string("date") ?? today
    guard let sum = (try? ctx.fetch(FetchDescriptor<NutritionDailySummaryEntity>()))?
      .first(where: { $0.date == date }) else {
      return ["date": date, "summary": NSNull()]
    }
    var out: [String: Any] = ["date": date, "entryCount": sum.entryCount]
    if let v = sum.kcal { out["kcal"] = v }
    if let v = sum.proteinG { out["proteinG"] = v }
    if let v = sum.fatG { out["fatG"] = v }
    if let v = sum.carbsG { out["carbsG"] = v }
    if let v = sum.waterMl { out["waterMl"] = v }
    return out
  }

  // MARK: - Training

  private static func trainingList(_ args: MCPArgs) -> Any {
    let (from, to) = range(args, daysBack: 13)
    let limit = args.int("limit") ?? 200
    let exercise = args.string("exercise")?.lowercased()
    let rows = (try? ctx.fetch(FetchDescriptor<ExerciseEntryEntity>()))?
      .filter { $0.date >= from && $0.date <= to }
      .filter { exercise == nil || $0.exercise.lowercased() == exercise }
      .sorted { $0.occurredAt > $1.occurredAt }
      .prefix(limit) ?? []
    return ["entries": rows.map { e -> [String: Any] in
      var out: [String: Any] = ["id": e.id, "date": e.date, "sessionType": e.sessionType, "exercise": e.exercise]
      if let w = e.weight { out["weight"] = w }
      if let s = e.sets { out["sets"] = s }
      if let r = e.reps { out["reps"] = r }
      if let d = e.durationMin { out["durationMin"] = d }
      if let dm = e.distanceM { out["distanceM"] = dm }
      return out
    }]
  }

  private static func trainingLog(_ args: MCPArgs) throws -> Any {
    let e = SeptenaServices.shared.trainingMutator.addEntry(
      date: args.string("date") ?? today, time: args.string("time") ?? nowHHMM,
      sessionType: try args.requireString("sessionType"), exercise: try args.requireString("exercise"),
      weight: args.double("weight"), sets: args.string("sets"), reps: args.string("reps"),
      difficulty: args.string("difficulty"), durationMin: args.double("durationMin"),
      distanceM: args.double("distanceM"), level: args.double("level"),
      note: args.string("note"), concludedAt: args.string("concludedAt"))
    return ["id": e.id, "exercise": e.exercise]
  }

  private static func trainingUpdate(_ args: MCPArgs) throws -> Any {
    // Full field parity with the hosted gateway's training_entry_update: identity
    // fields (date/time/sessionType/exercise) and every per-set metric are
    // patchable. The *Field accessors preserve present-vs-absent, so a call that
    // only canonicalizes the exercise name can't blank out the set's metrics.
    let id = try args.requireString("id")
    let updated = SeptenaServices.shared.trainingMutator.updateEntry(
      id: id,
      date: args.string("date"), time: args.string("time"),
      sessionType: args.string("sessionType"), exercise: args.string("exercise"),
      weight: args.doubleField("weight"), sets: args.stringField("sets"),
      reps: args.stringField("reps"), difficulty: args.stringField("difficulty"),
      durationMin: args.doubleField("durationMin"), distanceM: args.doubleField("distanceM"),
      level: args.doubleField("level"), note: args.stringField("note"),
      concludedAt: args.stringField("concludedAt"))
    return ["id": id, "updated": updated]
  }

  private static func trainingExercises(_ args: MCPArgs) -> Any {
    let type = args.string("type")
    let includeArchived = args.bool("archived") ?? false
    let limit = args.int("limit") ?? 200
    let rows = (try? ctx.fetch(FetchDescriptor<ExerciseDefinitionEntity>()))?
      .filter { type == nil || $0.type == type }
      .filter { includeArchived || !$0.archived }
      .sorted { $0.sortIndex < $1.sortIndex }
      .prefix(limit) ?? []
    return ["exercises": rows.map { (e: ExerciseDefinitionEntity) -> [String: Any] in
      var out: [String: Any] = [
        "id": e.id, "name": e.name, "type": e.type, "subgroup": e.subgroup ?? "",
        "archived": e.archived, "secondaryMuscles": e.secondaryMuscles,
        "aliases": e.aliases, "sortIndex": e.sortIndex,
      ]
      // Omit primaryMuscle when unassigned so the agent can tell "no muscle
      // set" (backfill candidate) from a real assignment.
      if let pm = e.primaryMuscle { out["primaryMuscle"] = pm }
      return out
    }]
  }

  /// The 10 canonical muscle-group raw values (see `Muscle`). Shared by the
  /// create/update validators so a typo ("quadriceps") can't dirty the data.
  private static let validMuscles: Set<String> = Set(Muscle.allCases.map(\.rawValue))

  private static func checkedMuscle(_ value: String) throws -> String {
    guard validMuscles.contains(value) else {
      throw MCPError.badArgument(
        "invalid muscle '\(value)'. Valid: \(validMuscles.sorted().joined(separator: ", "))")
    }
    return value
  }

  private static let validExerciseTypes = ["strength", "cardio", "mobility", "core"]

  private static func checkedExerciseType(_ value: String) throws -> String {
    guard validExerciseTypes.contains(value) else {
      throw MCPError.badArgument(
        "invalid type '\(value)'. Valid: \(validExerciseTypes.joined(separator: ", "))")
    }
    return value
  }

  private static func exerciseDefinitionJSON(_ id: String) -> [String: Any] {
    guard let e = (try? ctx.fetch(FetchDescriptor<ExerciseDefinitionEntity>(
      predicate: #Predicate { $0.id == id })))?.first else { return ["id": id] }
    var out: [String: Any] = [
      "id": e.id, "name": e.name, "type": e.type, "subgroup": e.subgroup ?? "",
      "archived": e.archived, "secondaryMuscles": e.secondaryMuscles, "aliases": e.aliases,
    ]
    out["primaryMuscle"] = e.primaryMuscle ?? NSNull()
    return out
  }

  private static func trainingExerciseCreate(_ args: MCPArgs) throws -> Any {
    let name = try args.requireString("name")
    let type = try checkedExerciseType(try args.requireString("type"))
    let primary: String? = try args.string("primaryMuscle").flatMap {
      $0.isEmpty ? nil : try checkedMuscle($0)
    }
    let secondary = try args.stringArray("secondaryMuscles")?.map { try checkedMuscle($0) }
    let entity = SeptenaServices.shared.trainingMutator.addExerciseDefinition(
      name: name, type: type, subgroup: args.string("subgroup"))
    let aliases = args.stringArray("aliases")
    if primary != nil || secondary != nil || aliases != nil {
      SeptenaServices.shared.trainingMutator.updateExerciseDefinition(
        id: entity.id, aliases: aliases,
        primaryMuscle: primary.map { Optional($0) },
        secondaryMuscles: secondary)
    }
    return exerciseDefinitionJSON(entity.id)
  }

  private static func trainingExerciseUpdate(_ args: MCPArgs) throws -> Any {
    let id = try args.requireString("id")
    guard ((try? ctx.fetch(FetchDescriptor<ExerciseDefinitionEntity>(
      predicate: #Predicate { $0.id == id })))?.first) != nil else {
      throw MCPError.badArgument(
        "no exercise with id '\(id)' — call training_exercises_list to find the id")
    }
    // primaryMuscle: absent = leave; "" = clear; value = validate + set. Read
    // from raw args, not args.string(), because the latter collapses "" → nil
    // and we'd lose the explicit clear signal the tool documents.
    var primary: String?? = nil
    if let pm = args.raw["primaryMuscle"] as? String {
      primary = pm.isEmpty ? .some(nil) : .some(try checkedMuscle(pm))
    }
    let secondary = try args.stringArray("secondaryMuscles")?.map { try checkedMuscle($0) }
    var subgroup: String?? = nil
    if let sg = args.raw["subgroup"] as? String { subgroup = .some(sg.isEmpty ? nil : sg) }
    let type = try args.string("type").map { try checkedExerciseType($0) }
    SeptenaServices.shared.trainingMutator.updateExerciseDefinition(
      id: id, name: args.string("name"), type: type, subgroup: subgroup,
      aliases: args.stringArray("aliases"), primaryMuscle: primary,
      secondaryMuscles: secondary, archived: args.bool("archived"))
    return exerciseDefinitionJSON(id)
  }

  // MARK: - Hydration (backed by Nutrition)

  private static func hydrationLog(_ args: MCPArgs) throws -> Any {
    guard let ml = args.int("ml") else { throw MCPError.badArgument("missing 'ml'") }
    let loggedAt = args.string("loggedAt").flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
    let e = SeptenaServices.shared.nutritionMutator.addEntry(
      loggedAt: loggedAt, emoji: "💧", foods: ["Water"], note: args.string("note") ?? "",
      source: "mcp", waterMl: Double(ml))
    return ["id": e.id, "ml": ml]
  }

  private static func hydrationToday() -> Any {
    let entries = nutritionEntities(today, today)
    let total = entries.compactMap(\.waterMl).reduce(0, +)
    let waterOnly = entries.filter { $0.foods == "Water" }
      .map { (e: NutritionEntryEntity) -> [String: Any] in ["id": e.id, "ml": e.waterMl ?? 0] }
    return ["date": today, "totalMl": total, "entries": waterOnly]
  }

  private static func hydrationHistory(_ args: MCPArgs) -> Any {
    let days = args.int("days") ?? 7
    let to = args.string("to") ?? today
    let from = args.string("from") ?? ymd(daysBack: days - 1)
    var byDate: [String: Double] = [:]
    for e in nutritionEntities(from, to) {
      guard let ml = e.waterMl, ml > 0, let d = SeptenaDate.format(e.loggedAt) else { continue }
      byDate[d, default: 0] += ml
    }
    return ["from": from, "to": to, "byDate": byDate]
  }

  // MARK: - Groceries

  private static func groceryList(_ args: MCPArgs) -> Any {
    let lowFilter = args.bool("low")
    let category = args.string("category")
    let limit = args.int("limit") ?? 300
    let rows = (try? ctx.fetch(FetchDescriptor<GroceryItemEntity>()))?
      .filter { lowFilter == nil || $0.low == lowFilter }
      .filter { category == nil || $0.category == category }
      .sorted { $0.sortIndex < $1.sortIndex }
      .prefix(limit) ?? []
    return ["items": rows.map { (e: GroceryItemEntity) -> [String: Any] in
      ["id": e.id, "name": e.name, "category": e.category, "emoji": e.emoji,
       "low": e.low, "lastBought": e.lastBought ?? ""]
    }]
  }

  private static func groceryCreate(_ args: MCPArgs) throws -> Any {
    let item = SeptenaServices.shared.groceryMutator.addItem(
      name: try args.requireString("name"), category: try args.requireString("category"),
      emoji: args.string("emoji") ?? "")
    return ["id": item.id, "name": item.name]
  }

  private static func grocerySetLow(_ args: MCPArgs) throws -> Any {
    let id = try args.requireString("id")
    guard let low = args.bool("low") else { throw MCPError.badArgument("missing 'low'") }
    SeptenaServices.shared.groceryMutator.setLow(id: id, low: low)
    return ["id": id, "low": low]
  }
}
