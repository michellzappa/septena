---
name: septena
description: Use the Septena MCP at mcp.septena.app to read and write the user's personal life data — tasks, projects, areas, goals, habits, supplements, chores, caffeine, cannabis, gut events, and nutrition (meals/macros). Triggers when the user asks about their tasks, today's plan, what they ate, habits done today, supplements logged, chore status, coffee/matcha consumption, gut/digestive logs, or any "septena" data.
---

# Septena MCP

The Septena MCP at `https://mcp.septena.app/mcp` exposes the user's personal-data CloudKit store as tools. All data is in the user's private iCloud database — there is no shared backend. Every tool call is read or write against `iCloud.com.septena.cloud`, zone `septena-v1`.

## Architecture in one paragraph

The tool list is **dynamic**: on `tools/list` the gateway reads the user's `Settings.section_order` and returns global tools + tools for the sections the user has enabled. If you don't see a section's tools, that section isn't active for this user — don't ask them to enable it unless they specifically want that feature; just work with what's there.

## Tool groups

### Always available (global)

| Group | Tools |
|---|---|
| Tasks | `tasks_list`, `tasks_get`, `tasks_create`, `tasks_update`, `tasks_complete`, `tasks_defer`, `tasks_move_to_today`, `tasks_list_projects`, `tasks_list_areas` |
| Task Conversations | `tasks_thread_get`, `tasks_thread_append`, `tasks_set_acceptance`, `tasks_set_artifact`, `tasks_set_handoff`, `tasks_set_endstate`, `tasks_set_assignee`, `tasks_pending_reasoning` |
| Goals | `goals_list`, `goals_create`, `goals_update`, `goals_delete` |
| Settings/Sections | `settings_get`, `settings_update`, `sections_list`, `sections_update` |

### Section-gated (only visible if section is active)

| Section key | Tools |
|---|---|
| `habits` | `habits_list`, `habits_create`, `habits_update`, `habits_delete`, `habits_toggle` |
| `supplements` | `supplements_list`, `supplements_create`, `supplements_update`, `supplements_delete`, `supplements_toggle` |
| `chores` | `chores_list`, `chores_create`, `chores_update`, `chores_delete`, `chores_complete`, `chores_defer`, `chores_uncomplete` |
| `caffeine` | `caffeine_events_list`, `caffeine_event_log`, `caffeine_event_delete`, `caffeine_beans_list`, `caffeine_bean_create`, `caffeine_bean_delete` |
| `cannabis` | `cannabis_events_list`, `cannabis_event_log`, `cannabis_event_delete`, `cannabis_strains_list`, `cannabis_strain_create`, `cannabis_strain_delete` |
| `gut` | `gut_events_list`, `gut_event_log`, `gut_event_delete` |
| `nutrition` | `nutrition_entries_list`, `nutrition_entry_log`, `nutrition_entry_update`, `nutrition_entry_delete`, `nutrition_day_summary` |
| `training` | `training_entries_list`, `training_entry_log`, `training_entry_update`, `training_entry_delete`, `training_session_retag`, `training_exercises_list`, `training_exercise_create`, `training_exercise_update`, `training_exercise_delete`, `training_sessions_list`, `training_session_create`, `training_session_update`, `training_session_delete` |
| `hydration` | `hydration_log`, `hydration_today`, `hydration_history` |
| `groceries` | `grocery_items_list`, `grocery_item_create`, `grocery_item_update`, `grocery_item_set_low`, `grocery_item_delete`, `grocery_categories_list`, `grocery_category_create`, `grocery_category_delete` |

## Conventions across all tools

- **Dates** are `YYYY-MM-DD` strings (local time). When a tool accepts `date`, omitting it means **today**.
- **Date ranges**: event-list tools (`*_events_list`, `nutrition_entries_list`) accept either `date` (single day) or `from`/`to` (inclusive range). Omitting both returns the **last 7 days**.
- **Times** are `HH:MM:SS` (24-hour) for health events, `HH:MM` for habits/supplements. Default to "now" when not given.
- **IDs** are short, opaque strings. Always echo back the `id` from a create call before referencing in update/delete.
- **Catalog vs. event pattern**: caffeine/cannabis have a *catalog* (beans, strains) and *events* that reference catalog ids. Always call `*_beans_list` or `*_strains_list` first to resolve a name → id before logging an event with that bean/strain.
- **Definition vs. day-state pattern**: habits, supplements, and chores have *definitions* (the thing) and per-date *state*. `*_list` returns definitions with today's state merged in. `*_toggle` writes the state. Don't try to create a new definition just to mark something done.

## Specific guidance

### Tasks
- Views: `today`, `inbox`, `upcoming`, `anytime`, `someday`, `completed`. **`anytime` is NOT "all tasks"** — it excludes inbox-only items.
- `tasks_list` returns `{tasks, total, truncated}` — **`truncated: true` means more rows exist beyond `limit`**, so don't conclude a task is missing/deleted from a capped page; raise `limit` or use `tasks_get`.
- **`tasks_get(id)`** — one call for "where is this task, what's its state?": title, status, area, project, scheduled, due, today, completedAt, source, plus a compact convo summary. Works regardless of view or status; use this instead of scanning lists to locate a known id.
- `tasks_complete` will **error on recurring tasks** — tell the user to complete those in the app so the next occurrence spawns correctly.
- Resolve `area`/`project` names → ids via `tasks_list_areas` / `tasks_list_projects` before creating/updating.

#### Task Conversations (agent-driven resolution)

A task can hold a persisted **conversation** that drives it toward a solution. You are the
async reasoning provider: pull the queue, ground the task, and hand the user the smallest
possible choice. The loop is `confirm → ground → (scope if epic) → decide → work → end`.

- **`tasks_pending_reasoning`** — your work queue: tasks marked for you or stuck on a
  low-confidence step. Start here.
- **`tasks_thread_get(id)`** — read the full `TaskConvo` (confirmedIntent, acceptance,
  thread, artifact, handoff, endState, assignee) before acting.
- **`tasks_thread_append(id, turn)`** — append one turn. **Propose and choose are separate
  turns**: a `provider` turn carries `question` + `options` (offer 2–4 + let the user pick);
  a later `user` turn carries `chosen` + `inReplyTo`. **Never invent the user's choice** —
  append the provider turn and stop. A `confirm`-step turn with a `chosen` also sets
  `confirmedIntent` (put the resolved intent sentence in `note`).
- **Confirm first, always.** Don't ground or work until the user has confirmed what the task
  means — append a `confirm` provider turn with readings as options. Don't assume meaning.
- **Don't assume size.** If grounding reveals an epic (e.g. "build a section"), use a `scope`
  step (decompose / MVP / defer) — don't march to `work`.
- **`tasks_set_artifact(id, {title, body, kind?, refs?})`** — attach what you PRODUCED
  (a comparison, a draft, a summary). Renders as a block in the task.
- **`tasks_set_handoff(id, {instruction, actionType, payload?})`** — the human's last-mile
  action, rendered as a tappable button (`open_url`/`compose`/`call`/`none`). Use for
  `agent_assisted`: you did the work, the user does the final step.
- **`tasks_set_acceptance(id, line)`** — the **agent-done** bar (your deliverable). Distinct
  from task completion, which is the **human-done** bar. Set `tasks_set_endstate` (e.g.
  `agent_done`, `needs_verify`, `decomposed`, `reminder_set`) when the conversation is
  terminal; the task itself stays open until the human acts.
- **`tasks_set_assignee(id, "claude"|"local"|"me"|null)`** — routing. `claude` marks a task
  for your queue; `null` lets the router decide.
- This mirrors the in-app on-device provider exactly (same shape, same verbs). Keep behavior
  identical so the two surfaces never disagree.

#### View routing (critical)
A task's visibility depends on these three fields:

| Set on create        | Appears in view(s)            |
|----------------------|-------------------------------|
| `today: true`        | `today`, `anytime`            |
| `scheduled: <date>`  | `upcoming`, `anytime`         |
| `due: <date>` only   | `anytime` (deadline only)     |
| None of the above    | **`inbox` only**              |

`area` and `project` are NOT routing fields. They tag a task for filtering inside views but don't make it appear anywhere on their own.

**Footgun**: a bare `tasks_create(title: "X")` lands in inbox and is invisible from `today`/`anytime`/`upcoming`. `tasks_create` returns success — it doesn't tell you which view the task ended up in. Models have lost track of created tasks because of this.

**Default behavior**: when the user doesn't specify "today" or a date, either ask which list they want it on, or proceed with no flags AND tell them "I put it in your inbox." Never claim a task is "added" without saying where it lives.

**Verification habit**: when routing matters, list the destination view after creating to confirm the task is actually visible there.

```
# "Add X to today"
tasks_create(title: "X", today: true)

# "Schedule X for tomorrow"
tasks_create(title: "X", scheduled: "<tomorrow>")

# "Just add X to my list"
tasks_create(title: "X")   → reply: "Added to your inbox."

# "Show me unscheduled tasks"
tasks_list(view: "inbox")
```

### Habits, supplements, chores
- `*_toggle` is idempotent — pass `done: false` to unmark.
- Habits also support `skipped: true` (e.g. "took a rest day"). Pass `done: false, skipped: true`.
- Chores have a `cadence_days` field; the list endpoint replays 180 days of events to compute "next due."
- When creating new definitions, set a clear short `title` and (optionally) a single-character `emoji`.

### Caffeine
- Brew methods: `v60`, `matcha`, `other`. `grams` is the bean/leaf dose in grams.
- Workflow for "I had a matcha": call `caffeine_event_log({method: "matcha"})`. No need to specify beans for matcha unless tracking source.
- For coffee: resolve bean via `caffeine_beans_list` first; `caffeine_bean_create({name})` if it's new.

### Cannabis
- Methods: `vape`, `edible`. `hit` = count of inhalations (for vape). `grams` for edibles.
- `effect` is free-form subjective ("relaxed", "creative", "couch-locked", etc.).

### Gut
- `bristol` is the Bristol Stool Scale (1=hard pellets, 7=watery) — **required**.
- `blood` is boolean. `volume` is `small | medium | large`.
- `discomfortStart` / `discomfortEnd` are `HH:MM` — log a window if the user describes cramping or pain.

### Nutrition
- `foods` is the **only required field** on log — a newline-separated list like `"2 eggs\ntoast with butter\nblack coffee"`.
- Macros (`proteinG`, `fatG`, `carbsG`) default to 0 if you don't have them. **Estimate them if the user gives food names** — the user expects the model to do the macro math, not ask back.
- `kcal` is auto-computed from `4*proteinG + 9*fatG + 4*carbsG + 7*alcoholG` if you don't override it.
- `mealType` is `breakfast | lunch | dinner | snack`. Pick the most reasonable one based on time of day if not stated.
- `nutrition_day_summary` returns the **rolled-up totals** for a day. Read-only — never try to write a summary; the app recomputes them automatically when entries change.
- **Full optional field set on `nutrition_entry_log` / `nutrition_entry_update`**:
  - **Meta**: `loggedAt` (ISO8601), `emoji`, `note`, `mealType`
  - **Macros (grams)**: `proteinG`, `fatG`, `carbsG`, `fiberG`, `sugarG`, `saturatedFatG`, `alcoholG`
  - **Energy**: `kcal` (override; computed if omitted)
  - **Micros (mg)**: `sodiumMg`, `cholesterolMg`, `potassiumMg`
  - **Hydration**: `waterMl`
  - Fill in any you know. Don't ask the user to enumerate — infer from food names where reasonable.

### Training
Three record types work together:
- **ExerciseDefinition** — the catalog. Stable slug `id` (`chest-press`), `name` (`Chest press`), `type` (`strength|cardio|mobility|core`), plus muscle tags `primaryMuscle` + `secondaryMuscles`.
- **SessionType** — routine template. id is the key (`upper`, `lower`, `cardio`). Lists exercises in that session.
- **ExerciseEntry** — logged set. References `sessionType` by **id** and `exercise` by **canonical name** (not id — easy footgun).

**Muscle groups** — `primaryMuscle` / `secondaryMuscles` must be one of these 10 exact values:
`chest, back, shoulders, biceps, triceps, quads, hamstrings, glutes, calves, core` (note: `quads`, not `quadriceps`). Cardio/mobility usually have none. Invalid values are rejected.

Logging workflow:
1. `training_sessions_list()` → find sessionType id
2. `training_exercises_list({type: "strength"})` → find canonical exercise name
3. `training_entry_log({sessionType, exercise, weight, sets, reps})` for strength, or `{durationMin, distanceM}` for cardio

Backfilling / fixing muscle tags (per-exercise):
1. `training_exercises_list()` → read current `primaryMuscle` (absent = unassigned)
2. `training_exercise_update({id, primaryMuscle, secondaryMuscles})` → set them; pass `primaryMuscle: ""` to clear a wrong tag

```
# "3 sets of 8 chest press at 80kg"
training_entry_log(sessionType: "upper", exercise: "Chest press", weight: 80, sets: "3", reps: "8")

# "Ran 5k in 24 min"
training_entry_log(sessionType: "cardio", exercise: "Run", durationMin: 24, distanceM: 5000)

# Fix a mis-tagged machine: Calf Press → calves
training_exercise_update(id: "calf-press", primaryMuscle: "calves")
```

### Hydration
Hydration is a **UX layer over Nutrition** — every water log is stored as a `NutritionEntry` with `foods="Water"`, `waterMl > 0`, all macros at 0. There's no separate data model.

- `hydration_log({ml})` → creates the water-only entry. Use this for plain water; don't reach for `nutrition_entry_log`.
- `hydration_today()` → today's total ml + the list of water-only entries. The total **includes water recorded on real meals** (e.g. a salad entry with `waterMl: 250` counts toward the day), so it matches the iOS Hydration view.
- `hydration_history({from, to, days})` → per-day totals over a range. Defaults to last 7 days.

```
# "I drank 500ml of water"
hydration_log({ ml: 500 })

# "How's my water today?"
hydration_today()                       → { totalMl, entries: [...] }

# "Last week"
hydration_history({ days: 7 })
```

### Groceries
- **GroceryItem** has a `low` flag (out / running out) and `lastBought` date.
- **GroceryCategory** organizes items.

Day-to-day workflow is `grocery_item_set_low(id, low)`:
- `low: true` → marks the item as out / needs buying
- `low: false` → clears flag AND auto-stamps `lastBought = today`

Don't use `grocery_item_update` for this — the convenience tool handles the lastBought stamping.

```
# "I'm out of milk"
grocery_items_list({})                  → find milk's id
grocery_item_set_low(id, low: true)

# "What do I need to buy?"
grocery_items_list({ low: true })

# "I bought milk"
grocery_item_set_low(id, low: false)
```

### Goals
- Goals are free-text intentions tagged with section keys (e.g. tag a goal with `["nutrition", "habits"]` so it shows up in those section views).
- `goals_update.sections` **replaces** the existing tags — fetch first if you want to add to them.

### Settings & Sections
- `settings_get` returns the full payload JSON. Useful keys: `section_order` (array of section keys controlling what's shown in the app *and* in this MCP tool list).
- Don't mutate `settings.sections` via `settings_update` — use `sections_update` for section label/color/order.
- `settings_update` does a **deep merge** of your patch into existing settings.

## Examples

**"What did I eat today?"**
1. `nutrition_entries_list({date: "<today>"})` — list all meals.
2. `nutrition_day_summary({date: "<today>"})` — show totals.

**"Log lunch: chicken salad, rice, olive oil"**
1. Estimate macros (e.g. ~40g protein, ~20g fat, ~50g carbs, ~600 kcal).
2. `nutrition_entry_log({foods: "chicken salad\nrice\nolive oil", mealType: "lunch", proteinG: 40, fatG: 20, carbsG: 50})`.

**"Mark my morning habits done"**
1. `habits_list()` — find habits with `bucket: "morning"`.
2. For each: `habits_toggle({id, done: true})`.

**"I had a v60 with the Ethiopian beans"**
1. `caffeine_beans_list()` — find the bean whose name matches "Ethiopian".
2. `caffeine_event_log({method: "v60", beans: "<beanId>", grams: 18})` (typical v60 dose; ask if unsure).

**"How's my chore list looking?"**
1. `chores_list()` — returns each chore with computed `dueDate` and `lastCompletedAt`.
2. Surface overdue ones first.

## Errors to expect

- `AUTHENTICATION_FAILED` / 401 → ckWebAuthToken expired, user needs to reconnect the MCP.
- `NOT_FOUND` on lookup → record doesn't exist; for `*_delete` this is fine (idempotent), for `*_update` surface it.
- Recurring task complete error → explain it must be done in the app.
- CloudKit field-type errors during writes → almost always a wrong field name; check this skill against tool descriptions.

## Don'ts

- Don't poll. Make one call per question.
- Don't ask the user to enable a section to use it — work with the tools you see.
- Don't fabricate ids. Always list first, then act.
- Don't try to write `NutritionDaySum` — it's auto-computed.
- Don't bundle multiple meals into one `nutrition_entry_log` call — log separate entries with separate `loggedAt` timestamps.
