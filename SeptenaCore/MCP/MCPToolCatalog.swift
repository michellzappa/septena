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
              description: "List Septena tasks for a given view (today, inbox, upcoming, anytime, someday, completed).",
              inputSchema: ["type": "object", "properties": [
                "view": ["type": "string",
                         "enum": ["today", "inbox", "anytime", "someday", "upcoming", "completed"],
                         "default": "today",
                         "description": "Which task list to read, matching the iOS app's sidebar."],
                "limit": ["type": "integer", "minimum": 1, "maximum": 500, "default": 100],
              ]]),
      MCPTool(name: "tasks_create",
              description: "Create a new Septena task. Returns the new id.",
              inputSchema: ["type": "object", "required": ["title"], "properties": [
                "title": ["type": "string", "minLength": 1],
                "today": ["type": "boolean", "default": false],
                "scheduled": ["type": "string", "description": "YYYY-MM-DD"],
                "due": ["type": "string", "description": "YYYY-MM-DD"],
                "area": ["type": "string", "description": "Area id (e.g. 'envisioning')"],
                "project": ["type": "string", "description": "Project id (e.g. 'septena')"],
              ]]),
      MCPTool(name: "tasks_complete",
              description: "Mark a task done. Errors on recurring tasks (complete those in the app so the next occurrence spawns).",
              inputSchema: ["type": "object", "required": ["id"], "properties": ["id": ["type": "string"]]]),
      MCPTool(name: "tasks_update",
              description: "Update fields on an existing task. Any subset of title, today, scheduled, due, area, project, status (cancelled).",
              inputSchema: ["type": "object", "required": ["id"], "properties": [
                "id": ["type": "string"],
                "title": ["type": "string"],
                "today": ["type": "boolean"],
                "scheduled": ["type": ["string", "null"], "description": "YYYY-MM-DD, or null to clear"],
                "due": ["type": ["string", "null"], "description": "YYYY-MM-DD, or null to clear"],
                "area": ["type": ["string", "null"]],
                "project": ["type": ["string", "null"]],
                "status": ["type": "string", "enum": ["open", "cancelled"]],
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
                  "provider": ["type": "string", "enum": ["onDevice", "claude"]],
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
                "bucket": ["type": "string", "enum": ["morning", "evening", "anytime"]],
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
    "caffeine": [
      MCPTool(name: "caffeine_events_list",
              description: "List caffeine intake events. Defaults to last 7 days; pass date for a single day or from/to for a range.",
              inputSchema: eventListSchema(defaultLimit: 100)),
      MCPTool(name: "caffeine_event_log",
              description: "Log a new caffeine intake event (v60, matcha, or other).",
              inputSchema: ["type": "object", "required": ["method"], "properties": [
                "date": ["type": "string", "description": "YYYY-MM-DD. Defaults to today."],
                "time": ["type": "string", "description": "HH:MM or HH:MM:SS. Defaults to now."],
                "method": ["type": "string", "enum": ["v60", "matcha", "other"], "description": "Brew / intake method."],
                "beans": ["type": "string", "description": "CaffeineBean id."],
                "grams": ["type": "number", "description": "Dose in grams."],
                "note": ["type": "string"],
              ]]),
    ],
    "cannabis": [
      MCPTool(name: "cannabis_events_list",
              description: "List cannabis intake events. Defaults to last 7 days; pass date for a single day or from/to for a range.",
              inputSchema: eventListSchema(defaultLimit: 100)),
      MCPTool(name: "cannabis_event_log",
              description: "Log a new cannabis intake event (vape or edible).",
              inputSchema: ["type": "object", "required": ["method"], "properties": [
                "date": ["type": "string", "description": "YYYY-MM-DD. Defaults to today."],
                "time": ["type": "string", "description": "HH:MM or HH:MM:SS. Defaults to now."],
                "method": ["type": "string", "enum": ["vape", "edible"], "description": "Intake method."],
                "hit": ["type": "integer", "description": "Number of hits / dose count."],
                "grams": ["type": "number", "description": "Dose in grams (for edibles)."],
                "note": ["type": "string"],
              ]]),
    ],
    "gut": [
      MCPTool(name: "gut_events_list",
              description: "List gut/digestive events. Defaults to last 7 days; pass date for a single day or from/to for a range.",
              inputSchema: eventListSchema(defaultLimit: 100)),
      MCPTool(name: "gut_event_log",
              description: "Log a new gut event with Bristol Stool Scale type and optional discomfort details.",
              inputSchema: ["type": "object", "required": ["bristol"], "properties": [
                "date": ["type": "string", "description": "YYYY-MM-DD. Defaults to today."],
                "time": ["type": "string", "description": "HH:MM or HH:MM:SS. Defaults to now."],
                "bristol": ["type": "integer", "minimum": 1, "maximum": 7, "description": "Bristol Stool Scale type (1–7)."],
                "blood": ["type": "boolean", "description": "Blood present."],
                "volume": ["type": "string", "enum": ["small", "medium", "large"]],
                "discomfortLevel": ["type": "string", "description": "Subjective discomfort descriptor."],
                "discomfortStart": ["type": "string", "description": "HH:MM when discomfort began."],
                "discomfortEnd": ["type": "string", "description": "HH:MM when discomfort ended."],
                "note": ["type": "string"],
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
              description: "Update fields on an existing exercise entry.",
              inputSchema: ["type": "object", "required": ["id"],
                            "properties": (["id": ["type": "string"]] as [String: Any])
                              .merging(trainingWriteProps(includeKeys: true)) { a, _ in a }]),
      MCPTool(name: "training_exercises_list",
              description: "List exercise catalog (definitions). Filter by type (strength|cardio|mobility|core) or archived state.",
              inputSchema: ["type": "object", "properties": [
                "type": ["type": "string", "enum": ["strength", "cardio", "mobility", "core"], "description": "Filter by exercise type."],
                "archived": ["type": "boolean", "description": "Include archived. Defaults to false."],
                "limit": ["type": "integer", "default": 200],
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
