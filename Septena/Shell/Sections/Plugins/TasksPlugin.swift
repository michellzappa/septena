import SwiftUI
import SwiftData

@MainActor
enum TasksPlugin: SectionPlugin {
  static var producesTimedEvents: Bool { true }

  static var manifest: SectionManifest {
    SectionManifest.byKey["tasks"]!
  }

  // The homepage Tasks tile opens this light drawer — today's tasks +
  // inline capture, on the shared `SectionDrawer` chrome — exactly like
  // every other section. The deep areas / projects / scheduling surface
  // stays on the Tasks tab (`TaskListView`); the "Open in" setting lets a
  // user route the tile straight there instead.
  static func destinationView() -> AnyView? { AnyView(TasksDestinationView()) }

  static var logActions: [LogAction] {
    [LogAction(id: "new", title: "New task", systemImage: "plus")]
  }

  static func detailPaneContent() -> AnyView? { AnyView(TasksDetailContent()) }

  static var exportContribution: SectionExportContribution? {
    SectionExportContribution(
      tables: [
        SchemaTable(name: "task", purpose: "one row per task / to-do", fields: [
          .req("id", "string"), .req("title", "string"),
          .opt("status", "string", "open | done | cancelled | someday"),
          .opt("created", "date"), .opt("scheduled", "date"),
          .opt("due", "date"), .opt("today", "bool"),
          .opt("todaySetOn", "date"), .opt("completedAt", "timestamp"),
          .opt("area", "string", "area id"),
          .opt("project", "string", "project id"),
          .opt("notes", "string"),
          .opt("recurrenceUnit", "string", "day | week | month | year"),
          .opt("recurrenceInterval", "int"),
          .opt("recurrenceAfterCompletion", "bool"),
        ]),
        SchemaTable(name: "project", purpose: "a project grouping tasks", fields: [
          .req("id", "string"), .req("title", "string"),
          .opt("status", "string", "active | completed | cancelled"),
          .opt("area", "string", "area id"),
          .opt("created", "date"), .opt("completedAt", "timestamp"),
          .opt("notes", "string"), .opt("context", "string"),
        ]),
        SchemaTable(name: "area", purpose: "a top-level area of life", fields: [
          .req("id", "string"), .req("title", "string"),
          .opt("context", "string"),
        ]),
      ],
      collect: { ctx in
        let tasks    = try ctx.fetch(FetchDescriptor<TaskEntity>())
        let projects = try ctx.fetch(FetchDescriptor<ProjectEntity>())
        let areas    = try ctx.fetch(FetchDescriptor<AreaEntity>())
        return [
          "task":    tasks.map(taskExportDict),
          "project": projects.map(projectExportDict),
          "area":    areas.map(areaExportDict),
        ]
      }
    )
  }

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SectionExplainerView(
      sectionKey: "tasks",
      title: "Tasks",
      intro: "Tasks route by intent, not by tags. Three fields decide visibility — today, scheduled, and due.",
      bullets: [
        .init("Inbox", "No today / scheduled / due → lands in Inbox. The parking spot for anything not yet committed.", icon: "tray"),
        .init("Today", "Pin to Today to commit. Use it for what you'll actually do today.", icon: "sun.max"),
        .init("Scheduled / due", "Scheduled puts it in Upcoming. Due adds a deadline without scheduling — both surface in Anytime.", icon: "calendar"),
        .init("Areas & projects", "Tags for filtering only — not routing. A project task with no view pin still sits in Inbox.", icon: "folder"),
      ],
      primaryActionLabel: "Add your first task",
      complete: complete
    ))
  }

  static var mcpSkill: SectionSkill? {
    SectionSkill(
      key: "tasks",
      summary: "Manage tasks, projects, and areas. Always available.",
      tools: [
        SectionSkill.Tool("tasks_list",          "List by view. Inbox = unscheduled, untoday; today = pinned; upcoming = future-scheduled; anytime EXCLUDES inbox-only tasks",
              inputs: "optional: view (today|inbox|upcoming|anytime|someday|completed), limit"),
        SectionSkill.Tool("tasks_create",        "New task. Without today/scheduled/due it lands in INBOX ONLY — invisible in today/anytime/upcoming. Set a routing field if the user expects to see it",
              inputs: "required: title · optional: today (boolean — pins to Today), scheduled (YYYY-MM-DD — puts in upcoming), due (YYYY-MM-DD — deadline only, does NOT route into views), area (id, not a routing field), project (id, not a routing field)"),
        SectionSkill.Tool("tasks_update",        "Patch any subset. Pass null to clear scheduled/due/area/project",
              inputs: "required: id · optional: title, today, scheduled (YYYY-MM-DD or null), due (YYYY-MM-DD or null), area (id or null), project (id or null), status (open|cancelled)"),
        SectionSkill.Tool("tasks_complete",      "Mark done. ERRORS on recurring — those must be done in-app so the next occurrence spawns",
              inputs: "required: id"),
        SectionSkill.Tool("tasks_defer",         "Set scheduled date, clear today",
              inputs: "required: id, until (YYYY-MM-DD)"),
        SectionSkill.Tool("tasks_move_to_today", "Pin to Today (today=true, clear scheduled)",
              inputs: "required: id"),
        SectionSkill.Tool("tasks_list_projects", "Resolve project name → id",
              inputs: "optional: status (active|done|cancelled|all), limit"),
        SectionSkill.Tool("tasks_list_areas",    "Resolve area name → id",
              inputs: "optional: limit"),
        SectionSkill.Tool("tasks_pending_reasoning", "Your work queue: tasks marked for Claude or stuck on a low-confidence step. Start here",
              inputs: "optional: limit"),
        SectionSkill.Tool("tasks_thread_get",    "Read a task's conversation (TaskConvo: confirmedIntent, acceptance, thread, artifact, handoff, endState, assignee)",
              inputs: "required: id"),
        SectionSkill.Tool("tasks_thread_append", "Append one turn. Propose (provider turn: question+options) and choose (user turn: chosen+inReplyTo) are SEPARATE — never invent the user's choice. A confirm turn with chosen sets confirmedIntent (resolved intent in note)",
              inputs: "required: id, turn{role(user|provider), step(confirm|ground|scope|decide|work)} · optional in turn: provider, confidence, question, options, chosen, otherText, inReplyTo, note"),
        SectionSkill.Tool("tasks_set_acceptance", "The agent-done bar (your deliverable). Distinct from task completion = the human-done bar",
              inputs: "required: id, acceptance"),
        SectionSkill.Tool("tasks_set_artifact",  "Attach what you PRODUCED (comparison/draft/summary) — renders as a block (agent_assisted)",
              inputs: "required: id, artifact{title} · optional in artifact: kind, body, refs[]"),
        SectionSkill.Tool("tasks_set_handoff",   "The human's last-mile action, rendered as a tappable button (open_url|compose|call|none)",
              inputs: "required: id, handoff{instruction} · optional in handoff: actionType, payload"),
        SectionSkill.Tool("tasks_set_endstate",  "Record the conversation's terminal end-state (agent_done|human_done|agent_assisted_done|needs_verify|decomposed|reminder_set|promoted_to_today|wont_do|open)",
              inputs: "required: id, endState · optional: note"),
        SectionSkill.Tool("tasks_set_assignee",  "Route a task: me|local|claude, or null for router-decided. claude marks it for the reasoning queue",
              inputs: "required: id, assignee"),
      ],
      body: """
      ### View routing — important
      A task's visibility depends entirely on three fields: `today`, `scheduled`, `due`.

      | Set on create        | Appears in view(s)            |
      |----------------------|-------------------------------|
      | `today: true`        | `today`, `anytime`            |
      | `scheduled: <date>`  | `upcoming`, `anytime`         |
      | `due: <date>` only   | `anytime` (deadline; no route)|
      | None of the above    | **`inbox` only**              |

      Notes:
      - `anytime` does NOT mean "all tasks." It excludes inbox-only tasks.
      - `area` / `project` are NOT routing fields. They tag a task for filtering inside views, but a task pinned to no view stays in inbox even if it has an area.
      - `tasks_create` returns success for any schema-valid write — it does not tell you which view the task will land in. Reason about routing yourself.

      ### Footgun
      A bare `tasks_create(title: "X")` lands in `inbox` and stays invisible to anyone listing `today`/`anytime`/`upcoming`. Models have lost track of created tasks because of this — the write succeeded, but neither model nor user noticed it ended up in inbox.

      **Default behavior to adopt**: if the user doesn't specify a date or "today," either:
      1. Ask: "Do you want this on today's list, scheduled, or just in your inbox?"
      2. Or proceed with no flags AND explicitly tell them "I put it in your inbox" so they know where to look.

      Never claim a freshly created task is "added" without indicating where it lives.

      ### Examples
      **"Add 'pick up groceries' to today"**
      ```
      tasks_create(title: "pick up groceries", today: true)
      ```

      **"Add 'pick up groceries' for tomorrow"**
      ```
      tasks_create(title: "pick up groceries", scheduled: "<tomorrow YYYY-MM-DD>")
      ```

      **"Just add 'pick up groceries' to my list"**
      ```
      tasks_create(title: "pick up groceries")
      → reply: "Added to your inbox."
      ```

      **"Move my errands to Saturday"**
      ```
      tasks_list(view: "today")                  → find ids
      tasks_defer(id, until: "<next saturday>")  → for each
      ```

      **"Show me everything I haven't scheduled"**
      ```
      tasks_list(view: "inbox")
      ```

      ### Verification habit
      If you're about to tell the user "I added/moved/scheduled X," and routing matters, list the destination view first to confirm X is actually there. `tasks_create` and `tasks_update` return success on any schema-valid write — they don't validate that the result matches user intent.

      ### Don't
      - Don't try to `tasks_complete` a recurring task. Tell the user to do it in the app.
      - Don't reference area/project by name. Always resolve to id first via `tasks_list_areas` / `tasks_list_projects`.
      - Don't assume `anytime` shows all tasks. It excludes inbox-only items.
      - Don't claim a task is "added" without mentioning which view/list it landed in.
      """
    )
  }
}

private struct TasksDetailContent: View {
  @AppStorage(SettingsKey.badgeShowOverdue)   private var taskBadge: Bool = false
  @AppStorage(SettingsKey.todayShowCompleted) private var todayShowCompleted: Bool = true
  @AppStorage(SettingsKey.tasksOpenIn)        private var tasksOpenInRaw: String = TasksOpenMode.drawer.rawValue

  var body: some View {
    Section("Open in") {
      Picker("Tasks open in", selection: $tasksOpenInRaw) {
        ForEach(TasksOpenMode.allCases) { mode in
          Text(mode.label).tag(mode.rawValue)
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()
    }
    Section("Badge") {
      Toggle("Show overdue indicator on app icon", isOn: $taskBadge)
    }
    Section("Today") {
      Toggle("Show completed tasks in Today", isOn: $todayShowCompleted)
    }
    Section {
      Text("Areas and projects are managed in the Tasks tab.")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }
}

@MainActor func taskExportDict(_ e: TaskEntity) -> [String: Any] {
  compact([
    "id": e.id, "title": e.title, "status": e.statusRaw,
    "created": e.created, "scheduled": e.scheduled, "due": e.due,
    "today": e.today, "todaySetOn": e.todaySetOn, "completedAt": e.completedAt,
    "area": e.area, "project": e.project, "notes": e.notes,
    "recurrenceUnit": e.recurrenceUnit,
    "recurrenceInterval": e.recurrenceInterval,
    "recurrenceAfterCompletion": e.recurrenceAfterCompletion,
    "sortIndex": e.sortIndex,
    "updatedAt": e.updatedAt, "deletedAt": e.deletedAt,
  ])
}

@MainActor func projectExportDict(_ e: ProjectEntity) -> [String: Any] {
  compact([
    "id": e.id, "title": e.title, "status": e.statusRaw, "area": e.area,
    "created": e.created, "completedAt": e.completedAt,
    "notes": e.notes, "context": e.context, "githubRepo": e.githubRepo,
    "updatedAt": e.updatedAt, "deletedAt": e.deletedAt,
  ])
}

@MainActor func areaExportDict(_ e: AreaEntity) -> [String: Any] {
  compact([
    "id": e.id, "title": e.title, "context": e.context,
    "updatedAt": e.updatedAt,
  ])
}
