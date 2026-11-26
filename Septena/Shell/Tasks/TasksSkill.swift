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
        SectionSkill.Tool("tasks_orientation",   "Start here once: the server's guide, every tool by family, and which areas have a brief",
              inputs: nil),
        SectionSkill.Tool("tasks_search",        "Find tasks by words in title or notes, with near matches. Call it before tasks_create",
              inputs: "required: query · optional: area, project, status (open|completed|all), limit"),
        SectionSkill.Tool("tasks_get",           "One task by id, in any view or status: fields, checklist, refs, backlinks, attachments, convo summary",
              inputs: "required: id · optional: include_notes (adds the project and area notes)"),
        SectionSkill.Tool("tasks_list",          "List by view. Inbox = unfiled/unratified; today = Today page; review = open tasks awaiting human verification (needs_verify); waiting = tasks waiting on a person, oldest first; upcoming = future-scheduled; anytime EXCLUDES inbox-only tasks",
              inputs: "optional: view (today|inbox|review|waiting|upcoming|anytime|completed), limit"),
        SectionSkill.Tool("tasks_create",        "New task. Without today/scheduled/deadline it lands in INBOX ONLY — invisible in today/anytime/upcoming. Set a routing field if the user expects to see it",
              inputs: "required: title · optional: today (boolean — pins to Today), scheduled (YYYY-MM-DD — puts in upcoming), deadline (YYYY-MM-DD — hard date only, does NOT route into views), area (id, not a routing field), project (id, not a routing field), notes (free-text body), recurrence{unit(day|week|month), interval, after_completion}, refs[{key, role, snapshot}] (the email, issue, event or page it is about or comes from; with a role-from key that an active task has, nothing is created and that task returns as placement existing; a suggestion from an item the user turned down returns placement dismissed), allow_duplicate (create it anyway), heading (heading id: files it under that heading, in the heading's project), tags[] (names), checklist[], idempotency_key (same key on a retry: no second task)"),
        SectionSkill.Tool("tasks_update",        "Patch any subset. Pass null to clear scheduled/deadline/area/project/notes",
              inputs: "required: id · optional: title, today, scheduled (YYYY-MM-DD or null), deadline (YYYY-MM-DD or null), area (id or null), project (id or null), heading (heading id, or null to take it out), status (open|cancelled), tags[] (names) or null, notes (free-text body, or null/\"\" to clear), recurrence{unit, interval, after_completion} or null to clear, refs (add or update by key), refs_remove[]"),
        SectionSkill.Tool("tasks_find_by_ref",   "Which tasks point at this email, thread, event, GitHub issue, page or task. Call it before you create a task from an item",
              inputs: "required: key (a reference key, a web URL or a message:// link) · optional: limit"),
        SectionSkill.Tool("tasks_complete",      "Mark a plain task done (recurring tasks get their next occurrence). Refused with human_accepts on agent-assigned, claimed, or needs_verify tasks — call tasks_set_endstate(needs_verify) instead",
              inputs: "required: id"),
        SectionSkill.Tool("tasks_defer",         "Set scheduled date, clear today",
              inputs: "required: id, until (YYYY-MM-DD)"),
        SectionSkill.Tool("tasks_set_waiting",   "Mark a task as waiting on a person (Review ▸ Waiting). scheduled = the day to chase. Only the user ends a wait: clearing or completing a waiting task is refused (in_review). On a reply, ask with a provider turn: Got It Back / Still Waiting",
              inputs: "required: id, waiting_on (name, or null — refused for agents) · optional: scheduled (YYYY-MM-DD or null)"),
        SectionSkill.Tool("tasks_move_to_today", "Pin to Today (today=true, clear scheduled)",
              inputs: "required: id"),
        SectionSkill.Tool("tasks_list_projects", "Resolve project name → id",
              inputs: "optional: status (active|done|cancelled|all), limit"),
        SectionSkill.Tool("tasks_list_areas",    "Resolve area name → id",
              inputs: "optional: limit"),
        SectionSkill.Tool("tasks_list_tags",     "The user's tags with open-task counts. Reuse their names; only the user renames or recolors a tag",
              inputs: nil),
        SectionSkill.Tool("tasks_history",       "One task's changes, newest first, with before and after values",
              inputs: "required: id · optional: limit"),
        SectionSkill.Tool("tasks_checklist_add", "Append checklist steps to a task",
              inputs: "required: task_id, items[]"),
        SectionSkill.Tool("tasks_checklist_update", "Rename, check or uncheck, or reorder a checklist item. Checking every item does not complete the task",
              inputs: "required: id · optional: title, checked, position"),
        SectionSkill.Tool("tasks_checklist_delete", "Remove a checklist item",
              inputs: "required: id"),
        SectionSkill.Tool("tasks_area_create",   "New area, with optional notes. Ask the user first; list areas first",
              inputs: "required: title · optional: notes, emoji"),
        SectionSkill.Tool("tasks_area_update",   "Rename an area or set its emoji (null clears). Only the user deletes an area",
              inputs: "required: id · optional: title, emoji"),
        SectionSkill.Tool("tasks_project_create", "New project, optionally in an area, with optional notes. Ask the user first; list projects first",
              inputs: "required: title · optional: area, notes, githubRepo"),
        SectionSkill.Tool("tasks_project_update", "Rename a project, move it to an area (null for none), set githubRepo, or set status. Done or cancelled leaves its open tasks open. Change the status only when the user asked",
              inputs: "required: id · optional: title, area, githubRepo, status (active|done|cancelled)"),
        SectionSkill.Tool("tasks_project_get",   "One project: notes and noteRev, area notes, headings, open tasks (with heading), last changes. Read it before you decide about a task in it",
              inputs: "required: id"),
        SectionSkill.Tool("tasks_heading_create", "Add a heading (section) at the end of a project. Rename it with tasks_update on its id",
              inputs: "required: project, title"),
        SectionSkill.Tool("tasks_notes_log",     "Add one dated entry under ## Log of a project's or area's notes: a decision or a learning",
              inputs: "required: container (project|area), id, baseNoteRev, text"),
        SectionSkill.Tool("tasks_notes_write",   "Replace whole notes. Only while the brief (text above ## Log) is empty; else refused as brief_is_users",
              inputs: "required: container, id, baseNoteRev, body, why"),
        SectionSkill.Tool("tasks_notes_propose", "Suggest a new brief. The user accepts or rejects it in the app",
              inputs: "required: container, id, brief, why"),
        SectionSkill.Tool("tasks_notes_history", "Every saved version of a note, with who and why",
              inputs: "required: container, id · optional: limit, before, include_body"),
        SectionSkill.Tool("tasks_claim",         "Claim a task before you work on it. A lease (default 30 min): call again to renew. A refusal names its rule (paused, stopped, your_turn, held, doing, budget): respect it. Only held is retryable (after claimUntil). Returns the project and area notes",
              inputs: "required: id, agent · optional: ttlMinutes, why"),
        SectionSkill.Tool("tasks_release",       "End your claim, with one line on what you did",
              inputs: "required: id, agent · optional: why"),
        SectionSkill.Tool("tasks_agent_events",  "What changed for agents since your cursor: assignments, user answers, stops, pauses. Pass nextSince next time",
              inputs: "optional: since (omit for events from now on), limit"),
        SectionSkill.Tool("tasks_activity",      "Who changed what and why, for one task or all of them",
              inputs: "optional: id, limit"),
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
        SectionSkill.Tool("tasks_attachment_add", "Attach a file of up to 10 MB to a task. For a file on disk, pass neither text nor base64 and run the returned upload command. You cannot read or remove files",
              inputs: "required: task_id, filename, content_type · optional: text or base64"),
        SectionSkill.Tool("tasks_set_handoff",   "The human's last-mile action, rendered as a tappable button (open_url|compose|call|none)",
              inputs: "required: id, handoff{instruction} · optional in handoff: actionType, payload"),
        SectionSkill.Tool("tasks_set_endstate",  "Your one way to finish: needs_verify with a note that says what to check releases your claim and puts the task in the user's Review list. decomposed when the work goes on elsewhere. Other end states are the user's (refused as human_ends)",
              inputs: "required: id, endState (needs_verify|decomposed), note"),
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

      **"Remind me to write the newsletter every Monday"**
      ```
      tasks_create(title: "Write newsletter",
                   scheduled: "<the next Monday, YYYY-MM-DD>",
                   recurrence: {unit: "week", interval: 1, after_completion: false})
      ```
      A named weekday means a FIXED schedule: `after_completion: false` anchors
      the rule to the scheduled date, so it stays on Monday however late you tick
      it off. It requires `scheduled` in the same call and errors without one.
      Use the default `after_completion: true` only for "every N days/weeks"
      phrasing with no anchor day ("water the plants every 3 days"), where the
      clock should restart from the completion.

      **"Move my errands to Saturday"**
      ```
      tasks_list(view: "today")                  → find ids
      tasks_defer(id, until: "<next saturday>")  → for each
      ```

      **"Show me everything I haven't scheduled"**
      ```
      tasks_list(view: "anytime")
      ```

      ### Refusals and retries
      A refused call returns `isError` with `{ error: { code, message, hint, retryable } }` (also in `structuredContent`). `code` names the rule (`paused`, `held`, `human_accepts`, `stale`, `idempotency_conflict`, …). Follow the `hint`. Send the same call again only when `retryable` is true (`held`, `rate_limited`, `unavailable`).

      Every write tool takes an optional `idempotency_key` (a UUID you make per write). Send the same key when you retry: Septena returns the first result and does not write again, so a retried create never makes a second task. Keys live 24 hours; the same key with a different body is refused as `idempotency_conflict`.

      ### Skills
      Each skill is one procedure from this brief, as a file an agent can load: `https://septena.app/skills/connect-septena/SKILL.md` (connect and check the connection), `https://septena.app/skills/add-a-task-once/SKILL.md` (search, a `from` reference, `existing` and `dismissed`, one `idempotency_key` per create), `https://septena.app/skills/work-a-task/SKILL.md` (claim, notes, turns, hand over to Review) and `https://septena.app/skills/ask-the-person/SKILL.md` (a provider turn with options, then wait for `user_turn`). This brief stays the full set of rules.

      ### How the app works (help)
      - When the user asks how to do something in Septena, what a word means, or why something does not work, read `https://septena.app/help.md`. It lists every help page as Markdown, and `https://septena.app/llms-full.txt` has them all in one file. Answer from those pages with the app's own menu names.
      - When the pages do not answer it, say so and point to `https://septena.app/support`. Never guess a menu, a shortcut or a feature.
      - You cannot press buttons in the app. Tell the user where to tap, or make the change with a tool when one exists.

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
