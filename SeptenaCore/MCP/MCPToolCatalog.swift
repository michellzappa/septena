import Foundation

// The tool manifest the local server advertises in `tools/list`. Mirrors the
// hosted gateway's GLOBAL_TOOLS + SECTION_TOOLS so the local connector and the
// cloud connector expose an identical surface.
//
// SCHEMA DRY POLICY (matches the gateway's own "for now, mirror" convention —
// see ../septena-mcp-gateway/src/tools/*.ts): no shared schema package exists
// across the app / gateway / CLI yet, so schemas are MIRRORED by hand and made
// auditable — each section cites its gateway counterpart, and `expectedNames`
// is the drift tripwire a test asserts against the gateway manifest.
//
// MIRROR: ../septena-mcp-gateway/src/mcp.ts (GLOBAL_TOOLS, SECTION_TOOLS)
//         ../septena-mcp-gateway/src/tools/*.ts (the *JsonSchema literals)

enum MCPToolCatalog {

  // MARK: - Shared schema fragments

  /// The date/from/to/limit shape every event-list tool shares.
  private static func eventListSchema(defaultLimit: Int) -> [String: Any] {
    ["type": "object", "properties": [
      "date": ["type": "string", "description": "YYYY-MM-DD filter. Omit to return the last 7 days."],
      "from": ["type": "string", "description": "YYYY-MM-DD range start (inclusive). Ignored if date is set."],
      "to": ["type": "string", "description": "YYYY-MM-DD range end (inclusive). Defaults to today."],
      "limit": ["type": "integer", "minimum": 1, "maximum": 500, "default": defaultLimit],
    ]]
  }

  private static func dateOnlySchema(_ desc: String = "YYYY-MM-DD. Defaults to today.") -> [String: Any] {
    ["type": "object", "properties": ["date": ["type": "string", "description": desc]]]
  }

  private static let emptySchema: [String: Any] = ["type": "object", "properties": [:] as [String: Any]]

  /// The 16 canonical muscle-group values (mirrors `Muscle.allCases`). Kept as
  /// a literal here so the catalog has no dependency direction issue; the
  /// dispatch-side validator (`validMuscles`) derives the same set from the enum.
  private static let muscleEnum = [
    "chest", "frontDelts", "sideDelts", "rearDelts", "triceps",
    "lats", "upperBack", "biceps", "forearms",
    "quads", "hamstrings", "glutes", "calves", "adductors",
    "abs", "lowerBack",
  ]

  /// The 4 routine categories (mirrors `SessionKind.allCases`). Drives the
  /// session-type create/update `kind` enum; the dispatch-side validator
  /// (`checkedSessionKind`) resolves the same raw values back to the enum.
  private static let sessionKindEnum = ["strength", "cardio", "mobility", "mixed"]

  /// All 36 canonical mood emotion words, derived from `MoodVocabulary` — the
  /// single source shared with the phone + watch pickers, so this can't drift.
  /// Used as the `mood_log` emotion enum (an invalid word is rejected at the
  /// schema; the dispatch handler resolves the word to its circumplex triple).
  private static let moodEmotionEnum = MoodVocabulary.quadrants.flatMap { MoodVocabulary.words(for: $0) }

  // MARK: - Global tools (always exposed)

  static var global: [MCPTool] {
    tasks + [
      MCPTool(name: "tasks_list_projects",
              description: "List Septena projects available for task assignment, optionally filtered by status.",
              inputSchema: ["type": "object", "properties": [
                "status": ["type": "string", "enum": ["active", "done", "cancelled", "all"], "default": "active"],
                "limit": ["type": "integer", "minimum": 1, "maximum": 500, "default": 200],
              ]]),
      MCPTool(name: "tasks_list_areas",
              description: "List Septena areas available for task assignment (top-level containers like 'home', 'envisioning').",
              inputSchema: ["type": "object", "properties": [
                "limit": ["type": "integer", "minimum": 1, "maximum": 500, "default": 100],
              ]]),
    ] + goals + settingsAndSections
  }

  // MARK: - Tasks (GLOBAL)

  static var tasks: [MCPTool] {
    [
      MCPTool(name: "tasks_list",
              description: "List Septena tasks for a given view (today, triage, inbox, upcoming, anytime, completed). 'anytime' is the single home for open, dateless tasks (it absorbed the former 'someday' bucket). 'triage' is the to-sort pile shown above Today — unratified rows the user hasn't placed yet (your unacknowledged proposals + the user's loose captures); 'today' excludes those. Returns {tasks, total, truncated}; truncated=true means more rows exist beyond limit.",
              inputSchema: ["type": "object", "properties": [
                "view": ["type": "string",
                         "enum": ["today", "triage", "inbox", "anytime", "upcoming", "completed"],
                         "default": "today",
                         "description": "Which task list to read. 'today' = ratified + due; 'triage' = the unratified to-sort pile above Today."],
                "limit": ["type": "integer", "minimum": 1, "maximum": 500, "default": 100],
              ]]),
      MCPTool(name: "tasks_get",
              description: "Inspect a single task by id: title, status, area, project, scheduled, deadline, today, completedAt, source, notes (free-text body), and a compact conversation summary. One call answers 'where is this task and what's its state?' regardless of view or status.",
              inputSchema: ["type": "object", "required": ["id"], "properties": [
                "id": ["type": "string"],
              ]]),
      MCPTool(name: "tasks_create",
              description: "Create a new Septena task. Returns the new id and its placement. Set `origin` to declare provenance: `user_request` when the user explicitly asked for this task (it lands committed, where you place it) or `agent_suggestion` when you surfaced it yourself, proactively (it lands as a PROPOSAL in the user's inbox to review). Omit and this connection's default applies.",
              inputSchema: ["type": "object", "required": ["title"], "properties": [
                "title": ["type": "string", "minLength": 1],
                "today": ["type": "boolean", "default": false],
                "scheduled": ["type": "string", "description": "YYYY-MM-DD"],
                "deadline": ["type": "string", "description": "YYYY-MM-DD (hard deadline)"],
                "area": ["type": "string", "description": "Area id (e.g. 'envisioning')"],
                "project": ["type": "string", "description": "Project id (e.g. 'septena')"],
                "notes": ["type": "string", "description": "Free-text note body for the task."],
                "origin": ["type": "string", "enum": ["user_request", "agent_suggestion"],
                           "description": "Provenance. user_request = the user asked (committed, placed where specified). agent_suggestion = you proposed it without being asked (lands unratified in the inbox for review). Omit to use the connection default."],
              ]]),
      MCPTool(name: "tasks_complete",
              description: "Mark a task done. Errors on recurring tasks (complete those in the app so the next occurrence spawns).",
              inputSchema: ["type": "object", "required": ["id"], "properties": ["id": ["type": "string"]]]),
      MCPTool(name: "tasks_update",
              description: "Update fields on an existing task. Any subset of title, today, scheduled, deadline, area, project, status (cancelled), notes.",
              inputSchema: ["type": "object", "required": ["id"], "properties": [
                "id": ["type": "string"],
                "title": ["type": "string"],
                "today": ["type": "boolean"],
                "scheduled": ["type": ["string", "null"], "description": "YYYY-MM-DD, or null to clear"],
                "deadline": ["type": ["string", "null"], "description": "YYYY-MM-DD, or null to clear"],
                "area": ["type": ["string", "null"]],
                "project": ["type": ["string", "null"]],
                "status": ["type": "string", "enum": ["open", "cancelled"]],
                "notes": ["type": ["string", "null"], "description": "Free-text note body, or null/\"\" to clear"],
              ]]),
      MCPTool(name: "tasks_thread_get",
              description: "Read a task's conversation (TaskConvo: confirmedIntent, acceptance, thread of turns, artifact, handoff, endState, assignee).",
              inputSchema: ["type": "object", "required": ["id"], "properties": [
                "id": ["type": "string"],
              ]]),
      MCPTool(name: "tasks_thread_append",
              description: "Append one turn to a task's conversation. Provider turns propose (question+options); user turns choose (chosen+inReplyTo). A confirm-step turn carrying a chosen also sets confirmedIntent — put the resolved intent sentence in note.",
              inputSchema: ["type": "object", "required": ["id", "turn"], "properties": [
                "id": ["type": "string"],
                "turn": ["type": "object", "required": ["role", "step"], "properties": [
                  "role": ["type": "string", "enum": ["user", "provider"]],
                  "step": ["type": "string", "enum": ["confirm", "ground", "scope", "decide", "work"]],
                  "provider": ["type": "string", "enum": ["onDevice", "claude", "applePCC"]],
                  "confidence": ["type": "number"],
                  "question": ["type": "string"],
                  "options": ["type": "array", "items": ["type": "string"]],
                  "chosen": ["type": "string"],
                  "otherText": ["type": "string"],
                  "inReplyTo": ["type": "integer"],
                  "note": ["type": "string"],
                ]],
              ]]),
      MCPTool(name: "tasks_set_acceptance",
              description: "Set the agent-done bar (what 'done' means for the agent's deliverable). Distinct from task completion, which is the human's bar.",
              inputSchema: ["type": "object", "required": ["id", "acceptance"], "properties": [
                "id": ["type": "string"],
                "acceptance": ["type": "string"],
              ]]),
      MCPTool(name: "tasks_set_endstate",
              description: "Record the conversation's terminal end-state.",
              inputSchema: ["type": "object", "required": ["id", "endState"], "properties": [
                "id": ["type": "string"],
                "endState": ["type": "string", "enum": ["agent_done", "human_done", "agent_assisted_done", "needs_verify", "decomposed", "reminder_set", "promoted_to_today", "wont_do", "open"]],
                "note": ["type": "string", "description": "e.g. needs_verify: what to verify"],
              ]]),
      MCPTool(name: "tasks_set_assignee",
              description: "Route a task: me | local | claude, or null to let the router decide. Setting claude marks it for the reasoning queue.",
              inputSchema: ["type": "object", "required": ["id", "assignee"], "properties": [
                "id": ["type": "string"],
                "assignee": ["type": ["string", "null"], "enum": ["me", "local", "claude"]],
              ]]),
      MCPTool(name: "tasks_set_artifact",
              description: "Attach the agent's deliverable to a task (agent_assisted): the research/table/draft you produced. Distinct from the handoff (the human's last-mile action).",
              inputSchema: ["type": "object", "required": ["id", "artifact"], "properties": [
                "id": ["type": "string"],
                "artifact": ["type": "object", "required": ["title"], "properties": [
                  "kind": ["type": "string", "description": "e.g. availability-table, draft-email, summary"],
                  "title": ["type": "string"],
                  "body": ["type": "string"],
                  "refs": ["type": "array", "items": ["type": "string"]],
                ]],
              ]]),
      MCPTool(name: "tasks_set_handoff",
              description: "Set the human last-mile, rendered as a tappable action button. The agent is done; the task stays open until the human does this.",
              inputSchema: ["type": "object", "required": ["id", "handoff"], "properties": [
                "id": ["type": "string"],
                "handoff": ["type": "object", "required": ["instruction"], "properties": [
                  "instruction": ["type": "string"],
                  "actionType": ["type": "string", "enum": ["open_url", "compose", "call", "none"]],
                  "payload": ["type": "string", "description": "URL / email / phone for the action"],
                ]],
              ]]),
      MCPTool(name: "tasks_pending_reasoning",
              description: "List tasks awaiting reasoning: marked for Claude, or whose last provider turn was low-confidence, and not yet terminal.",
              inputSchema: ["type": "object", "properties": [
                "limit": ["type": "integer"],
              ]]),
      MCPTool(name: "tasks_defer",
              description: "Defer a task to a future date (sets scheduled, clears today).",
              inputSchema: ["type": "object", "required": ["id", "until"], "properties": [
                "id": ["type": "string"],
                "until": ["type": "string", "description": "YYYY-MM-DD"],
              ]]),
      MCPTool(name: "tasks_move_to_today",
              description: "Pin a task to Today (sets today=true, clears scheduled).",
              inputSchema: ["type": "object", "required": ["id"], "properties": ["id": ["type": "string"]]]),
    ]
  }

  // MARK: - Goals (GLOBAL)

  static var goals: [MCPTool] {
    [
      MCPTool(name: "goals_list",
              description: "List Septena goals (free-text intentions tagged with section keys).",
              inputSchema: emptySchema),
      MCPTool(name: "goals_create",
              description: "Create a new Septena goal. Optionally tag with section keys.",
              inputSchema: ["type": "object", "required": ["text"], "properties": [
                "text": ["type": "string", "minLength": 1, "description": "The goal text / intention"],
                "sections": ["type": "array", "items": ["type": "string"],
                             "description": "Section keys to tag this goal with (e.g. ['health', 'envisioning'])"],
              ]]),
      MCPTool(name: "goals_update",
              description: "Update a goal's text and/or section tags. sections replaces the existing tags entirely.",
              inputSchema: ["type": "object", "required": ["id"], "properties": [
                "id": ["type": "string"],
                "text": ["type": "string", "minLength": 1],
                "sections": ["type": "array", "items": ["type": "string"],
                             "description": "Replaces the current section tags entirely"],
              ]]),
    ]
  }

  // MARK: - Settings & Sections (GLOBAL)

  static var settingsAndSections: [MCPTool] {
    [
      MCPTool(name: "settings_get",
              description: "Read Septena app settings.",
              inputSchema: emptySchema),
      MCPTool(name: "sections_list",
              description: "List Septena section config, ordered by settings.section_order when present.",
              inputSchema: ["type": "object", "properties": [
                "limit": ["type": "integer", "minimum": 1, "maximum": 500, "default": 100],
              ]]),
      MCPTool(name: "settings_update",
              description: "Patch Septena app settings. section_order is canonicalized; sections metadata must be updated with sections_update.",
              inputSchema: ["type": "object", "required": ["patch"], "properties": [
                "patch": ["type": "object", "description": "Partial settings object to merge into the settings singleton."],
              ]]),
      MCPTool(name: "sections_update",
              description: "Create or update one Septena section record. Supports label, color, enabled, and optional order index.",
              inputSchema: ["type": "object", "required": ["key"], "properties": [
                "key": ["type": "string", "description": "Section key, e.g. tasks or training."],
                "label": ["type": "string"],
                "color": ["type": "string", "description": "Hex or hsl/rgb string."],
                "enabled": ["type": "boolean"],
                "order": ["type": "integer", "minimum": 0, "description": "Move this section to the given index in settings.section_order."],
              ]]),
    ]
  }

  // MARK: - Section tools (gated by enabled sections, like gateway SECTION_TOOLS)

  static let section: [String: [MCPTool]] = [
    "habits": [
      MCPTool(name: "habits_list",
              description: "List habit definitions with done/skipped state for a given date (defaults to today).",
              inputSchema: dateOnlySchema()),
      MCPTool(name: "habits_create",
              description: "Create a new habit definition.",
              inputSchema: ["type": "object", "required": ["title", "bucket"], "properties": [
                "title": ["type": "string", "minLength": 1],
                "bucket": ["type": "string", "enum": ["morning", "afternoon", "evening", "anytime"]],
                "emoji": ["type": "string"],
              ]]),
      MCPTool(name: "habits_toggle",
              description: "Mark a habit done or skipped for a date. Pass done=false and skipped=false to unmark.",
              inputSchema: ["type": "object", "required": ["id", "done"], "properties": [
                "id": ["type": "string"],
                "date": ["type": "string", "description": "YYYY-MM-DD. Defaults to today."],
                "done": ["type": "boolean"],
                "skipped": ["type": "boolean", "default": false],
              ]]),
    ],
    "supplements": [
      MCPTool(name: "supplements_list",
              description: "List supplement definitions with done state for a given date (defaults to today).",
              inputSchema: dateOnlySchema()),
      MCPTool(name: "supplements_create",
              description: "Create a new supplement definition.",
              inputSchema: ["type": "object", "required": ["title"], "properties": [
                "title": ["type": "string", "minLength": 1],
                "emoji": ["type": "string"],
              ]]),
      MCPTool(name: "supplements_toggle",
              description: "Mark a supplement taken (done=true) or untaken (done=false) for a date.",
              inputSchema: ["type": "object", "required": ["id", "done"], "properties": [
                "id": ["type": "string"],
                "date": ["type": "string", "description": "YYYY-MM-DD. Defaults to today."],
                "done": ["type": "boolean"],
              ]]),
    ],
    "chores": [
      MCPTool(name: "chores_list",
              description: "List chore definitions with computed due dates and last-completed dates.",
              inputSchema: emptySchema),
      MCPTool(name: "chores_create",
              description: "Create a new chore definition.",
              inputSchema: ["type": "object", "required": ["title", "cadenceDays"], "properties": [
                "title": ["type": "string", "minLength": 1],
                "cadenceDays": ["type": "integer", "minimum": 1, "description": "How often this chore recurs (days)"],
                "emoji": ["type": "string"],
              ]]),
      MCPTool(name: "chores_complete",
              description: "Mark a chore as completed for today (or a given date).",
              inputSchema: ["type": "object", "required": ["id"], "properties": [
                "id": ["type": "string"],
                "date": ["type": "string", "description": "YYYY-MM-DD. Defaults to today."],
              ]]),
      MCPTool(name: "chores_uncomplete",
              description: "Remove the most recent completion event for a chore on a given date.",
              inputSchema: ["type": "object", "required": ["id"], "properties": [
                "id": ["type": "string"],
                "date": ["type": "string", "description": "YYYY-MM-DD. Defaults to today."],
              ]]),
    ],
    "intake": [
      // Generic consumable tools — the tracker ("kind") is an ARGUMENT, never
      // part of a tool name. Nine tools cover unlimited user-defined trackers;
      // substance nouns live only in the user's kind names (user data).
      MCPTool(name: "intake_kinds_list",
              description: "List the user's intake trackers (kinds) with full config: methods + tokens, dose style, unit, container cap + today's container state, catalog noun, item/event counts. Call this FIRST, then log against a kind by id or name.",
              inputSchema: ["type": "object", "properties": [
                "includeArchived": ["type": "boolean", "description": "Include archived trackers. Default false."],
              ]]),
      MCPTool(name: "intake_kind_create",
              description: "Create a new intake tracker. Only name is required; every axis is editable later.",
              inputSchema: ["type": "object", "required": ["name"], "properties": [
                "name": ["type": "string"],
                "symbol": ["type": "string", "description": "SF Symbol name."],
                "color": ["type": "string", "description": "Hex accent, e.g. #0d9488."],
                "unit": ["type": "string", "description": "Amount unit: g | mg | ml."],
                "doseStyle": ["type": "string", "enum": ["none", "amount", "count", "both"]],
                "countNoun": ["type": "string", "description": "Count unit name: hit | cup | puff."],
                "containerNoun": ["type": "string", "description": "capsule | pack — enables the container quick-add."],
                "containerCap": ["type": "integer", "description": "Uses per container."],
                "catalogNoun": ["type": "string", "description": "Variety catalog name: Beans | Strains."],
                "objective": ["type": "string", "enum": ["log", "limit", "reduce", "quit"]],
                "target": ["type": "number", "description": "Goal target for limit/reduce/quit."],
                "weekly": ["type": "boolean", "description": "Window the limit/reduce goal per week instead of per day."],
                "methods": ["type": "array", "description": "Method rows.", "items": ["type": "object", "properties": [
                  "token": ["type": "string"], "label": ["type": "string"],
                  "emoji": ["type": "string", "description": "Optional user glyph for this method."],
                  "defaultAmount": ["type": "number"], "usesContainer": ["type": "boolean"],
                ]]],
              ]]),
      MCPTool(name: "intake_kind_update",
              description: "Update an intake tracker's config (any field), archive/unarchive it, or change its objective goal.",
              inputSchema: ["type": "object", "required": ["kind"], "properties": [
                "kind": ["type": "string", "description": "Tracker id or unique name (case-insensitive)."],
                "name": ["type": "string"], "symbol": ["type": "string"], "color": ["type": "string"],
                "unit": ["type": "string"], "doseStyle": ["type": "string", "enum": ["none", "amount", "count", "both"]],
                "countNoun": ["type": "string"], "containerNoun": ["type": "string"],
                "containerCap": ["type": "integer"], "catalogNoun": ["type": "string"],
                "objective": ["type": "string", "enum": ["log", "limit", "reduce", "quit"]],
                "target": ["type": "number"], "weekly": ["type": "boolean"],
                "archived": ["type": "boolean"],
                "methods": ["type": "array", "items": ["type": "object", "properties": [
                  "token": ["type": "string"], "label": ["type": "string"],
                  "emoji": ["type": "string", "description": "Optional user glyph for this method."],
                  "defaultAmount": ["type": "number"], "usesContainer": ["type": "boolean"],
                ]]],
              ]]),
      MCPTool(name: "intake_items_list",
              description: "List a tracker's variety catalog (beans, strains, …).",
              inputSchema: ["type": "object", "required": ["kind"], "properties": [
                "kind": ["type": "string", "description": "Tracker id or unique name."],
              ]]),
      MCPTool(name: "intake_item_create",
              description: "Add a variety to a tracker's catalog.",
              inputSchema: ["type": "object", "required": ["kind", "name"], "properties": [
                "kind": ["type": "string"], "name": ["type": "string"],
                "emoji": ["type": "string", "description": "Optional user glyph for this variety."],
              ]]),
      MCPTool(name: "intake_item_delete",
              description: "Remove a catalog variety (events keep displaying its name).",
              inputSchema: ["type": "object", "required": ["id"], "properties": [
                "id": ["type": "string"],
              ]]),
      MCPTool(name: "intake_events_list",
              description: "List one tracker's logged events. Defaults to last 7 days; pass date for a single day or from/to for a range.",
              inputSchema: ["type": "object", "required": ["kind"], "properties": [
                "kind": ["type": "string", "description": "Tracker id or unique name."],
                "date": ["type": "string", "description": "YYYY-MM-DD filter. Omit for last 7 days."],
                "from": ["type": "string", "description": "YYYY-MM-DD range start (inclusive)."],
                "to": ["type": "string", "description": "YYYY-MM-DD range end (inclusive). Defaults to today."],
                "limit": ["type": "integer", "default": 100],
              ]]),
      MCPTool(name: "intake_event_log",
              description: "Log an intake event against a tracker. Method accepts a token or label from the kind's methods.",
              inputSchema: ["type": "object", "required": ["kind", "method"], "properties": [
                "kind": ["type": "string", "description": "Tracker id or unique name."],
                "method": ["type": "string", "description": "Method token or label (see intake_kinds_list)."],
                "date": ["type": "string", "description": "YYYY-MM-DD. Defaults to today."],
                "time": ["type": "string", "description": "HH:MM or HH:MM:SS. Defaults to now."],
                "amount": ["type": "number", "description": "Dose in the kind's unit."],
                "count": ["type": "integer", "description": "Hits/uses — container math reads this."],
                "item": ["type": "string", "description": "Catalog variety id or name."],
                "note": ["type": "string"],
              ]]),
      MCPTool(name: "intake_event_delete",
              description: "Remove one intake event (correction).",
              inputSchema: ["type": "object", "required": ["id"], "properties": [
                "id": ["type": "string"],
              ]]),
    ],
    "gut": [
      MCPTool(name: "gut_events_list",
              description: "List gut/digestive events. Defaults to last 7 days; pass date for a single day or from/to for a range.",
              inputSchema: eventListSchema(defaultLimit: 100)),
      MCPTool(name: "gut_event_log",
              description: "Log a new gut event with Bristol Stool Scale type. Cramping, discomfort or blood are symptoms — log them with symptoms_log instead.",
              inputSchema: ["type": "object", "required": ["bristol"], "properties": [
                "date": ["type": "string", "description": "YYYY-MM-DD. Defaults to today."],
                "time": ["type": "string", "description": "HH:MM or HH:MM:SS. Defaults to now."],
                "bristol": ["type": "integer", "minimum": 1, "maximum": 7, "description": "Bristol Stool Scale type (1–7)."],
                "volume": ["type": "string", "enum": ["small", "medium", "large"]],
                "note": ["type": "string"],
              ]]),
    ],
    "mood": [
      MCPTool(name: "mood_list",
              description: "List mood check-ins (Russell circumplex: quadrant, arousal 1–3, valence 1–3, emotion word). Defaults to last 7 days; pass date for a single day or from/to for a range.",
              inputSchema: eventListSchema(defaultLimit: 100)),
      MCPTool(name: "mood_log",
              description: "Log a mood. Provide emotion — a word from the canonical grid (e.g. 'Anxious', 'Content', 'Calm', 'Excited'); its quadrant / arousal / valence are derived automatically.",
              inputSchema: ["type": "object", "required": ["emotion"], "properties": [
                "date": ["type": "string", "description": "YYYY-MM-DD. Defaults to today."],
                "time": ["type": "string", "description": "HH:MM. Defaults to now (sets the morning/afternoon/evening bucket)."],
                "emotion": ["type": "string", "enum": moodEmotionEnum, "description": "Canonical emotion word (see enum). Matched case-insensitively."],
                "note": ["type": "string"],
              ]]),
    ],
    "symptoms": [
      MCPTool(name: "symptoms_list",
              description: "List symptom definitions and logged symptom events. Defaults to last 7 days; pass date for a single day or from/to for a range.",
              inputSchema: eventListSchema(defaultLimit: 100)),
      MCPTool(name: "symptoms_create",
              description: "Create a symptom definition for reuse when logging symptom events.",
              inputSchema: ["type": "object", "required": ["title"], "properties": [
                "title": ["type": "string", "minLength": 1],
                "emoji": ["type": "string"],
                "bodySystem": ["type": "string", "description": "Optional grouping, e.g. head, digestive, respiratory."],
                "defaultBodyRegion": ["type": "string", "description": "Default location used when logging this symptom."],
              ]]),
      MCPTool(name: "symptoms_log",
              description: "Log a symptom event against an existing symptom definition.",
              inputSchema: ["type": "object", "required": ["symptomID", "severity"], "properties": [
                "symptomID": ["type": "string", "description": "SymptomDefinition id from symptoms_list or symptoms_create."],
                "date": ["type": "string", "description": "YYYY-MM-DD. Defaults to today."],
                "time": ["type": "string", "description": "HH:MM or HH:MM:SS. Defaults to now."],
                "severity": ["type": "integer", "minimum": 0, "maximum": 10],
                "durationMinutes": ["type": "integer", "minimum": 0],
                "bodyRegion": ["type": "string"],
                "side": ["type": "string", "enum": ["left", "right", "both"]],
                "quality": ["type": "string", "description": "Ache, sharp, dull, burning, etc."],
                "triggerNote": ["type": "string"],
                "reliefNote": ["type": "string"],
                "note": ["type": "string"],
              ]]),
    ],
    "medications": [
      MCPTool(name: "medications_list",
              description: "List medication definitions and dose events. Defaults to last 7 days; pass date for a single day or from/to for a range.",
              inputSchema: eventListSchema(defaultLimit: 100)),
      MCPTool(name: "medications_create",
              description: "Create a medication definition for reuse when logging doses.",
              inputSchema: ["type": "object", "required": ["title"], "properties": [
                "title": ["type": "string", "minLength": 1],
                "genericName": ["type": "string"],
                "form": ["type": "string", "description": "Tablet, capsule, liquid, injection, topical, etc."],
                "route": ["type": "string", "description": "Oral, sublingual, nasal, topical, etc."],
                "strengthValue": ["type": "number"],
                "strengthUnit": ["type": "string"],
                "defaultDoseValue": ["type": "number"],
                "defaultDoseUnit": ["type": "string"],
                "bucket": ["type": "string", "enum": ["morning", "afternoon", "evening", "anytime"]],
                "scheduleKind": ["type": "string", "enum": ["daily", "asNeeded"], "default": "daily"],
                "targetDosesPerDay": ["type": "integer", "minimum": 1],
                "instructions": ["type": "string"],
              ]]),
      MCPTool(name: "medications_log",
              description: "Log a medication dose against an existing medication definition.",
              inputSchema: ["type": "object", "required": ["medicationID", "status"], "properties": [
                "medicationID": ["type": "string", "description": "MedicationDefinition id from medications_list or medications_create."],
                "date": ["type": "string", "description": "YYYY-MM-DD. Defaults to today."],
                "time": ["type": "string", "description": "HH:MM or HH:MM:SS. Defaults to now."],
                "status": ["type": "string", "enum": ["taken", "skipped", "missed"]],
                "doseValue": ["type": "number"],
                "doseUnit": ["type": "string"],
                "reason": ["type": "string"],
                "effectNote": ["type": "string"],
                "sideEffectNote": ["type": "string"],
              ]]),
    ],
    "nutrition": [
      MCPTool(name: "nutrition_entries_list",
              description: "List nutrition (meal/food) entries. Defaults to last 7 days; pass date for a single day or from/to for a range. Each entry includes loggedAt, foods (newline-separated), macros (proteinG/fatG/carbsG), and optional micros.",
              inputSchema: eventListSchema(defaultLimit: 200)),
      MCPTool(name: "nutrition_entry_log",
              description: "Log a new meal / food entry. Required: foods (newline-separated list). Macros default to 0 if omitted; kcal is computed from 4P+9F+4C+7A unless overridden.",
              inputSchema: ["type": "object", "required": ["foods"], "properties": nutritionWriteProps(includeLoggedAt: true)]),
      MCPTool(name: "nutrition_entry_update",
              description: "Update fields on an existing nutrition entry. Any subset of foods, loggedAt, mealType, macros, or micros.",
              inputSchema: ["type": "object", "required": ["id"],
                            "properties": (["id": ["type": "string"]] as [String: Any])
                              .merging(nutritionWriteProps(includeLoggedAt: true)) { a, _ in a }]),
      MCPTool(name: "nutrition_day_summary",
              description: "Read the computed daily nutrition summary (totals across all meals) for a date. Read-only.",
              inputSchema: dateOnlySchema()),
    ],
    "training": [
      MCPTool(name: "training_entries_list",
              description: "List exercise entries. Defaults to last 14 days; pass date for a single day, from/to for a range, or exercise to filter.",
              inputSchema: ["type": "object", "properties": [
                "date": ["type": "string", "description": "YYYY-MM-DD single-day filter."],
                "from": ["type": "string", "description": "YYYY-MM-DD range start (inclusive). Ignored if date is set."],
                "to": ["type": "string", "description": "YYYY-MM-DD range end (inclusive). Defaults to today."],
                "exercise": ["type": "string", "description": "Filter to a specific canonical exercise name."],
                "limit": ["type": "integer", "minimum": 1, "maximum": 500, "default": 200],
              ]]),
      MCPTool(name: "training_entry_log",
              description: "Log a new exercise set / entry. Required: sessionType, exercise (canonical name). Provide weight/sets/reps for strength; durationMin/distanceM for cardio.",
              inputSchema: ["type": "object", "required": ["sessionType", "exercise"], "properties": trainingWriteProps(includeKeys: true)]),
      MCPTool(name: "training_entry_update",
              description: "Update any subset of fields on an existing exercise entry — only fields you pass change (pass null to clear an optional one). Supports rename/retag (exercise, sessionType, date, time) as well as per-set metrics; returns the list of fields actually written.",
              inputSchema: ["type": "object", "required": ["id"],
                            "properties": (["id": ["type": "string"]] as [String: Any])
                              .merging(trainingWriteProps(includeKeys: true)) { a, _ in a }]),
      MCPTool(name: "training_exercises_list",
              description: "List exercise catalog (definitions), including muscle tags (primaryMuscle / secondaryMuscles). Filter by type (strength|cardio|mobility|core) or archived state.",
              inputSchema: ["type": "object", "properties": [
                "type": ["type": "string", "enum": ["strength", "cardio", "mobility", "core"], "description": "Filter by exercise type."],
                "archived": ["type": "boolean", "description": "Include archived. Defaults to false."],
                "limit": ["type": "integer", "default": 200],
              ]]),
      MCPTool(name: "training_exercise_create",
              description: "Add an exercise definition to the catalog. id defaults to a slug of the name.",
              inputSchema: ["type": "object", "required": ["name", "type"], "properties": [
                "name": ["type": "string", "description": "Canonical display name, e.g. 'Chest press'."],
                "type": ["type": "string", "enum": ["strength", "cardio", "mobility", "core"]],
                "subgroup": ["type": "string", "description": "Free-form grouping, e.g. 'push'/'pull'/'upper'."],
                "aliases": ["type": "array", "items": ["type": "string"]],
                "primaryMuscle": ["type": "string", "enum": muscleEnum, "description": "Primary muscle group."],
                "secondaryMuscles": ["type": "array", "items": ["type": "string", "enum": muscleEnum]],
              ]]),
      MCPTool(name: "training_exercise_update",
              description: "Edit an exercise definition — set muscle tags, rename, retype, archive. Use to clean up / backfill muscle groups one exercise at a time. Pass primaryMuscle: \"\" to clear it.",
              inputSchema: ["type": "object", "required": ["id"], "properties": [
                "id": ["type": "string", "description": "Exercise slug id (from training_exercises_list)."],
                "name": ["type": "string"],
                "type": ["type": "string", "enum": ["strength", "cardio", "mobility", "core"]],
                "subgroup": ["type": "string"],
                "aliases": ["type": "array", "items": ["type": "string"]],
                "primaryMuscle": ["type": "string", "description": "One of: \(muscleEnum.joined(separator: ", ")). Empty string clears it."],
                "secondaryMuscles": ["type": "array", "items": ["type": "string", "enum": muscleEnum]],
                "archived": ["type": "boolean"],
              ]]),
      MCPTool(name: "training_sessions_list",
              description: "List session-type templates (routines, e.g. 'upper'/'lower'/'cardio') — id, label, emoji, exercises, kind. Filter by archived state.",
              inputSchema: ["type": "object", "properties": [
                "archived": ["type": "boolean", "description": "Include archived. Defaults to false."],
                "limit": ["type": "integer", "default": 200],
              ]]),
      MCPTool(name: "training_session_create",
              description: "Create a session-type template (routine). id is the canonical key (e.g. 'upper'). exercises are canonical exercise NAMES.",
              inputSchema: ["type": "object", "required": ["id", "label"], "properties": [
                "id": ["type": "string", "description": "Canonical key, e.g. 'upper'/'lower'/'cardio'."],
                "label": ["type": "string", "description": "Display name."],
                "emoji": ["type": "string"],
                "exercises": ["type": "array", "items": ["type": "string"], "description": "Canonical exercise NAMES in this session (not slugs)."],
                "kind": ["type": "string", "enum": sessionKindEnum, "description": "Routine category."],
              ]]),
      MCPTool(name: "training_session_update",
              description: "Update a session-type template — rename, set emoji/exercises/kind, or archive. Pass archived: true to remove it from pickers without deleting (non-destructive). Pass emoji: \"\" to clear it.",
              inputSchema: ["type": "object", "required": ["id"], "properties": [
                "id": ["type": "string", "description": "Session-type id (from training_sessions_list)."],
                "label": ["type": "string"],
                "emoji": ["type": "string"],
                "exercises": ["type": "array", "items": ["type": "string"]],
                "kind": ["type": "string", "enum": sessionKindEnum],
                "archived": ["type": "boolean"],
              ]]),
    ],
    "hydration": [
      MCPTool(name: "hydration_log",
              description: "Log water intake in ml. Backed by Nutrition — writes a water-only entry so the day's nutrition summary sees it.",
              inputSchema: ["type": "object", "required": ["ml"], "properties": [
                "ml": ["type": "integer", "minimum": 1, "description": "Water amount in milliliters."],
                "loggedAt": ["type": "string", "description": "ISO8601 timestamp. Defaults to now."],
                "note": ["type": "string"],
              ]]),
      MCPTool(name: "hydration_today",
              description: "Today's total water ml + the list of water-only entries. Total INCLUDES water recorded on real meal entries.",
              inputSchema: emptySchema),
      MCPTool(name: "hydration_history",
              description: "Per-day water totals over a range. Defaults to last 7 days.",
              inputSchema: ["type": "object", "properties": [
                "from": ["type": "string", "description": "YYYY-MM-DD range start. Inclusive."],
                "to": ["type": "string", "description": "YYYY-MM-DD range end. Defaults to today."],
                "days": ["type": "integer", "minimum": 1, "maximum": 90, "default": 7, "description": "Used only if from/to omitted."],
              ]]),
    ],
    "groceries": [
      MCPTool(name: "grocery_items_list",
              description: "List grocery items. Filter by low (running-low flag) or category (id).",
              inputSchema: ["type": "object", "properties": [
                "low": ["type": "boolean", "description": "Filter to items marked low. Omit for all."],
                "category": ["type": "string", "description": "Filter by GroceryCategory id."],
                "limit": ["type": "integer", "default": 300],
              ]]),
      MCPTool(name: "grocery_item_create",
              description: "Add a new grocery item. category is an optional GroceryCategory id.",
              inputSchema: ["type": "object", "required": ["name", "category"], "properties": [
                "name": ["type": "string"],
                "category": ["type": "string", "description": "GroceryCategory id."],
                "emoji": ["type": "string"],
              ]]),
      MCPTool(name: "grocery_item_set_low",
              description: "Mark a grocery item as low/restocked. low=true means out/running low; low=false clears the flag and stamps lastBought=today.",
              inputSchema: ["type": "object", "required": ["id", "low"], "properties": [
                "id": ["type": "string", "description": "GroceryItem id."],
                "low": ["type": "boolean", "description": "true = mark out/low; false = restock."],
              ]]),
    ],
  ]

  // MARK: - Write-prop builders (shared between log + update)

  private static func nutritionWriteProps(includeLoggedAt: Bool) -> [String: Any] {
    var p: [String: Any] = [
      "foods": ["type": "string", "description": "Newline-separated list of foods/items consumed."],
      "ingredients": ["type": "string", "description": "Newline-separated ingredient breakdown (optional detail under foods)."],
      "emoji": ["type": "string"], "note": ["type": "string"],
      "mealType": ["type": "string", "enum": ["breakfast", "lunch", "dinner", "snack"]],
      "proteinG": ["type": "number"], "fatG": ["type": "number"], "carbsG": ["type": "number"],
      "fiberG": ["type": "number"], "sugarG": ["type": "number"], "saturatedFatG": ["type": "number"],
      "alcoholG": ["type": "number"], "kcal": ["type": "number", "description": "Optional override; else computed from 4P+9F+4C+7A."],
      "sodiumMg": ["type": "number"], "cholesterolMg": ["type": "number"],
      "potassiumMg": ["type": "number"], "waterMl": ["type": "number"],
    ]
    if includeLoggedAt {
      p["loggedAt"] = ["type": "string", "description": "ISO8601 timestamp of the meal. Defaults to now."]
    }
    return p
  }

  private static func trainingWriteProps(includeKeys: Bool) -> [String: Any] {
    [
      "date": ["type": "string", "description": "YYYY-MM-DD. Defaults to today."],
      "time": ["type": "string", "description": "HH:MM session start. Defaults to now."],
      "sessionType": ["type": "string", "description": "SessionType id (e.g. 'upper', 'lower', 'cardio')."],
      "exercise": ["type": "string", "description": "Canonical exercise NAME (e.g. 'Chest press')."],
      "weight": ["type": "number", "description": "Weight in kg."],
      "sets": ["type": "string", "description": "Integer or 'AMRAP'."],
      "reps": ["type": "string", "description": "Integer or free-form (e.g. '8,8,6')."],
      "difficulty": ["type": "string", "description": "Subjective difficulty."],
      "durationMin": ["type": "number", "description": "Duration in minutes."],
      "distanceM": ["type": "number", "description": "Distance in meters."],
      "level": ["type": "number", "description": "Machine resistance / incline level."],
      "note": ["type": "string"],
      "concludedAt": ["type": "string", "description": "ISO8601 timestamp when the set/session finished."],
    ]
  }

  // MARK: - Assembly + drift tripwire

  /// The advertised manifest for a given set of enabled section keys:
  /// globals always, plus the tools of each enabled section (gateway parity).
  static func manifest(enabledSections: Set<String>) -> [MCPTool] {
    var tools = global
    for (key, sectionTools) in section where enabledSections.contains(key) {
      tools += sectionTools
    }
    return tools
  }

  /// Every tool name the local server can serve, regardless of gating — the
  /// drift tripwire a test compares against the gateway's full manifest.
  static var expectedNames: [String] {
    global.map(\.name) + section.values.flatMap { $0 }.map(\.name)
  }
}
