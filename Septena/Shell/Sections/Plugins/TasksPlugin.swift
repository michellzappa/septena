import SwiftUI

@MainActor
enum TasksPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["tasks"]!
  }

  static func todayEvents(date: String, ctx: TodayContext) -> [TodayEvent] {
    let accent = ctx.theme.color(for: "tasks")
    return ctx.tasks
      .filter { $0.status == .done }
      .compactMap { task -> TodayEvent? in
        guard let ts = task.completedAt, ts.hasPrefix(date), ts.count >= 16 else { return nil }
        let hhmm = String(ts.dropFirst(11).prefix(5))
        return TodayEvent(
          id: "task-\(task.id)",
          time: hhmm,
          section: "tasks",
          color: accent,
          title: task.title,
          detail: nil,
          kind: .task(task)
        )
      }
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
