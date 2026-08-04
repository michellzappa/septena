// The tasks MCP skill brief — relocated from TasksPlugin so both shells can
// surface it (Septena's Skills pane via the plugin; Septask's task-only
// skills pane directly — docs/SEPTASK.md). Keep in sync with the gateway's
// skill.md, which is generated from SectionRegistry.fullSkillMarkdown().

enum TasksSkill {
  static var skill: SectionSkill {
    SectionSkill(
      key: "tasks",
      summary: "Manage tasks, projects, and areas. Always available.",
      tools: [
        SectionSkill.Tool("tasks_list",          "List by view. Inbox = unscheduled, untoday; today = pinned; upcoming = future-scheduled; anytime EXCLUDES inbox-only tasks",
              inputs: "optional: view (today|inbox|upcoming|anytime|completed), limit"),
        SectionSkill.Tool("tasks_create",        "New task. Without today/scheduled/deadline it lands in INBOX ONLY — invisible in today/anytime/upcoming. Set a routing field if the user expects to see it",
              inputs: "required: title · optional: today (boolean — pins to Today), scheduled (YYYY-MM-DD — puts in upcoming), deadline (YYYY-MM-DD — hard date only, does NOT route into views), area (id, not a routing field), project (id, not a routing field), notes (free-text body)"),
        SectionSkill.Tool("tasks_update",        "Patch any subset. Pass null to clear scheduled/deadline/area/project/notes",
              inputs: "required: id · optional: title, today, scheduled (YYYY-MM-DD or null), deadline (YYYY-MM-DD or null), area (id or null), project (id or null), status (open|cancelled), notes (free-text body, or null/\"\" to clear)"),
        SectionSkill.Tool("tasks_complete",      "Mark done. Recurring tasks automatically get their next occurrence",
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
      A task's visibility depends entirely on three fields: `today`, `scheduled`, `deadline`.

      | Set on create        | Appears in view(s)            |
      |----------------------|-------------------------------|
      | `today: true`        | `today`, `anytime`            |
      | `scheduled: <date>`  | `upcoming`, `anytime`         |
      | `deadline: <date>`   | `anytime` (no route)          |
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
      tasks_list(view: "anytime")
      ```

      ### Verification habit
      If you're about to tell the user "I added/moved/scheduled X," and routing matters, list the destination view first to confirm X is actually there. `tasks_create` and `tasks_update` return success on any schema-valid write — they don't validate that the result matches user intent.

      ### Don't
      - Don't reference area/project by name. Always resolve to id first via `tasks_list_areas` / `tasks_list_projects`.
      - Don't assume `anytime` shows all tasks. It's only open, dateless, unfiled tasks.
      - Don't claim a task is "added" without mentioning which view/list it landed in.
      """
    )
  }
}
