---
name: septena
description: Use the Septena MCP at mcp.septena.app to read and write the user's personal life data — tasks, projects, areas, goals, habits, supplements, chores, intake trackers, symptoms, medications, gut events, and nutrition (meals/macros). Triggers when the user asks about their tasks, today's plan, what they ate, habits done today, supplements logged, chore status, symptoms or pain logged, medications taken, gut/digestive logs, or any "septena" data.
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
| Goals | `goals_list`, `goals_create`, `goals_update` |
| Settings/Sections | `settings_get`, `settings_update`, `sections_list`, `sections_update` |

### Section-gated (only visible if section is active)

| Section key | Tools |
|---|---|
| `habits` | `habits_list`, `habits_create`, `habits_toggle` |
| `supplements` | `supplements_list`, `supplements_create`, `supplements_toggle` |
| `chores` | `chores_list`, `chores_create`, `chores_complete`, `chores_uncomplete` |
| `intake` | `intake_kinds_list`, `intake_kind_create`, `intake_kind_update`, `intake_items_list`, `intake_item_create`, `intake_item_delete`, `intake_events_list`, `intake_event_log`, `intake_event_delete` |
| `symptoms` | `symptoms_list`, `symptoms_create`, `symptoms_log` |
| `medications` | `medications_list`, `medications_create`, `medications_log` |
| `gut` | `gut_events_list`, `gut_event_log` |
| `mood` | `mood_list`, `mood_log` |
| `nutrition` | `nutrition_entries_list`, `nutrition_entry_log`, `nutrition_entry_update`, `nutrition_day_summary` |
| `training` | `training_entries_list`, `training_entry_log`, `training_entry_update`, `training_exercises_list`, `training_exercise_create`, `training_exercise_update`, `training_sessions_list`, `training_session_create`, `training_session_update` |
| `hydration` | `hydration_log`, `hydration_today`, `hydration_history` |
| `groceries` | `grocery_items_list`, `grocery_item_create`, `grocery_item_set_low` |

## Conventions across all tools

- **Dates** are `YYYY-MM-DD` strings (local time). When a tool accepts `date`, omitting it means **today**.
- **Date ranges**: event-list tools (`*_events_list`, `nutrition_entries_list`) accept either `date` (single day) or `from`/`to` (inclusive range). Omitting both returns the **last 30 days**.
- **Times** are `HH:MM:SS` (24-hour) for health events, `HH:MM` for habits/supplements. Default to "now" when not given.
- **IDs** are short, opaque strings. Always echo back the `id` from a create call before referencing in update/delete.
- **Catalog/definition vs. event pattern**: `intake` trackers have a *catalog* (kinds + items), and `symptoms`/`medications` have *definitions*, each referenced by id from their events. Always call the relevant `*_list` first to resolve a name → id before logging an event against it.
- **Definition vs. day-state pattern**: habits, supplements, and chores have *definitions* (the thing) and per-date *state*. `*_list` returns definitions with today's state merged in. `*_toggle` writes the state. Don't try to create a new definition just to mark something done.

## Specific guidance

### Tasks
- Views: `today`, `inbox`, `upcoming`, `anytime`, `completed`. `anytime` is the single home for open, dateless tasks (it absorbed the former `someday` bucket). **`anytime` is NOT "all tasks"** — it excludes inbox-only items.
- `tasks_list` returns `{tasks, total, truncated}` — **`truncated: true` means more rows exist beyond `limit`**, so don't conclude a task is missing/deleted from a capped page; raise `limit` or use `tasks_get`.
- **`tasks_get(id)`** — one call for "where is this task, what's its state?": title, status, area, project, scheduled, deadline, today, completedAt, source, notes, plus a compact convo summary. Works regardless of view or status; use this instead of scanning lists to locate a known id.
- **`notes`** — the task's free-text body. Readable on `tasks_get`/`tasks_list` and writable on `tasks_create`/`tasks_update` (pass `notes`; on update, `null`/`""` clears it). This is the plain note field, distinct from the structured `TaskConvo` (artifact/handoff/thread) below.
- `tasks_complete` on a **recurring** task also creates its next occurrence and returns it as `nextOccurrence` — say when the task comes back, don't send the user to the app. If the result carries a `recurrenceWarning`, the task was still completed but the series didn't advance; relay that rather than claiming the next one is scheduled.
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

#### Provenance & view routing (critical)
**Declare provenance with `origin`** — it decides whether a task lands committed
or as a *proposal*:

- **`origin: "user_request"`** — the user explicitly asked you to create this
  task. It's **committed**: it flows straight into its natural view per the
  fields you set (table below), with no triage step.
- **`origin: "agent_suggestion"` (or omitted)** — you surfaced it yourself,
  proactively (from email, a transcript, your own initiative). It lands as a
  **proposal** in the user's **triage** pile — the "to sort" band on top of Today
  — awaiting their tap. The gateway defaults to this (secure by default), so if
  you don't set `origin`, you are proposing.

`tasks_create` returns `placement`: `"committed"` or `"inbox_proposal"`.

For a **proposal**, the `today` / `scheduled` / `deadline` / `project` you set are
the *proposed disposition* the user accepts with one tap — they do **not** move
the task into `today` / `upcoming` / `anytime` until it's ratified (or until it
ages in after ~7 days unacknowledged). A **committed** task routes immediately:

| Fields you set       | View (committed now / proposal after ratify) |
|----------------------|----------------------------------------------|
| `today: true`        | `today`, `anytime`                           |
| `scheduled: <date>`  | `upcoming`, `anytime`                        |
| `deadline: <date>`   | `anytime` (no route)                         |
| None of the above    | loose capture (stays to-sort)                |

`area` and `project` tag a task for filtering but don't route it on their own.

**Footgun**: a *proposal* is NOT in `today` even when you set `today: true` — it's
in `triage`, awaiting the user's tap. For proposals, never claim "added to
today"; say you've **proposed** it ("Proposed for today — accept it in your To
sort band"). A **committed** (`user_request`) task you may report as added.

**Verification habit**: check `placement` in the create result, or
`tasks_list(view: "triage")` for proposals.

```
# "Add X to today" — proposes X for today; user taps to accept
tasks_create(title: "X", today: true)
  → "Proposed for today — accept it in your To sort band."

# "Schedule X for tomorrow"
tasks_create(title: "X", scheduled: "<tomorrow>")
  → "Queued to sort, proposed for tomorrow."

# "What haven't I sorted yet?"
tasks_list(view: "triage")

# "Show me unscheduled tasks"
tasks_list(view: "inbox")
```

### Habits, supplements, chores
- `*_toggle` is idempotent — pass `done: false` to unmark.
- Habits also support `skipped: true` (e.g. "took a rest day"). Pass `done: false, skipped: true`.
- Chores have a `cadence_days` field; the list endpoint replays 180 days of events to compute "next due."
- When creating new definitions, set a clear short `title` and (optionally) a single-character `emoji`.

### Intake (generic consumable trackers)
User-defined trackers ("kinds") for anything consumed — each has its own
methods, dose style, optional container model, variety catalog, and an
objective (log | limit | reduce | quit) wired to a real goal. Names, methods,
and varieties are the user's own vocabulary.
- **Resolve first, then act**: `intake_kinds_list()` returns every tracker's
  full config (method tokens, unit, container cap + today's container state,
  catalog noun, counts) — one call per conversation is enough. Then
  `intake_event_log({kind, method, ...})` where `kind` is an id or unique
  name and `method` is a token or label.
- A failed kind/method/item lookup returns the candidates inline — retry with
  one of them.
- **Container kinds** (`containerCap` set): "a container holds N uses". Log
  `count: lastContainerCountToday + 1` to continue the current container, or
  `count: 1` for a fresh one.
- **Objectives**: for reduce/quit kinds, days-since-last is the streak that
  matters — prefer encouragement framing when the user is abstaining.
- Caffeine, cannabis, nicotine and the like are now **intake trackers**, not
  dedicated sections — log them with `intake_event_log` against the user's
  matching kind, never a per-substance tool.

### Symptoms
- Definitions (the symptom) + events (a severity log). Call `symptoms_list`
  first to resolve a name → `symptomID`, then `symptoms_log({symptomID, severity})`.
- Treat symptoms as **outcomes**. Prefer structured `severity` (0–10),
  `bodyRegion` and `side` over burying everything in `note`; use
  `triggerNote`/`reliefNote` for possible causes and interventions.
- `symptoms_create({title})` for a new symptom the user names that isn't listed.
- Cramping, discomfort and blood belong here (not gut events).

### Medications
- Definitions (the drug) + dose events. Call `medications_list` first to resolve
  a name → `medicationID`, then `medications_log({medicationID, status})`.
- `status` is `taken | skipped | missed`: use `skipped` for an intentional skip
  and `missed` when the dose should have happened but did not.
- Medication logs are **interventions / adherence data**, distinct from
  supplement habits — don't fold them into `supplements_*`.
- `medications_create({title})` for a new medication; strength, dose, schedule
  (`daily`|`asNeeded`) and instructions are optional.

### Gut
- `bristol` is the Bristol Stool Scale (1=hard pellets, 7=watery) — **required**.
- `volume` is `small | medium | large`.
- Cramping, discomfort and blood are symptoms, not gut events — log them with `symptoms_log` so they get severity and their own timeline.

### Mood
A check-in is one point on Russell's circumplex (quadrant + arousal 1–3 + valence 1–3). Log by **emotion word** — the word fixes the coordinates, so never pass raw numbers. `emotion` is the only required field; `quadrant`/`arousal`/`valence`/`bucket` are derived. `time` (HH:MM, default now) sets the morning/afternoon/evening bucket.

Valid `emotion` values (case-insensitive; anything else is rejected):
- **hap** (pleasant, high-energy): Excited, Elated, Ecstatic, Eager, Upbeat, Joyful, Focused, Alive, Content
- **han** (unpleasant, high-energy): Enraged, Panicked, Stressed, Angry, Anxious, Frustrated, Irritated, Tense, Restless
- **lan** (unpleasant, low-energy): Bored, Discouraged, Disappointed, Sad, Lonely, Glum, Drained, Hopeless, Despondent
- **lap** (pleasant, low-energy): Mellow, Easygoing, Pleased, Calm, Grateful, Loved, Relaxed, Serene, Tranquil

```
# "I'm feeling anxious this afternoon"
mood_log({ emotion: "Anxious" })

# "How was my mood this week?"
mood_list({ from: "<monday>", to: "<sunday>" })
```

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

**Muscle groups** — `primaryMuscle` / `secondaryMuscles` must be one of these 16 exact values:
`chest, frontDelts, sideDelts, rearDelts, triceps, lats, upperBack, biceps, forearms, quads, hamstrings, glutes, calves, adductors, abs, lowerBack` (camelCase exactly; `quads`, not `quadriceps`). Cardio/mobility usually have none. Invalid values are rejected.

Logging workflow:
1. `training_exercises_list({type: "strength"})` → find canonical exercise name
2. `training_entry_log({sessionType, exercise, weight, sets, reps})` for strength, or `{durationMin, distanceM}` for cardio (pass the sessionType id, e.g. `upper`, `lower`, `cardio`)

Backfilling / fixing muscle tags (per-exercise):
1. `training_exercises_list()` → read current `primaryMuscle` (absent = unassigned)
2. `training_exercise_update({id, primaryMuscle, secondaryMuscles})` → set them; pass `primaryMuscle: ""` to clear a wrong tag

**Session-type templates (routines)** — the user's splits (`upper`, `lower`, `cardio`, a custom `push`/`pull`/`legs`, …). Fields: `id` (canonical key), `label`, `emoji`, `exercises` (canonical exercise NAMES), `kind` (`strength|cardio|mobility|mixed`).
- `training_sessions_list()` → enumerate routines. Do this to resolve a `sessionType` id before logging, or to show the user their setup.
- `training_session_create({id, label, …})` → add a routine. `id` is the canonical key you'll then pass as `sessionType` when logging.
- `training_session_update({id, …})` → rename, re-emoji, edit the exercise list, change `kind`. **There is no delete** — pass `archived: true` to remove a routine from pickers without losing data (`archived: false` restores it).

```
# "3 sets of 8 chest press at 80kg"
training_entry_log(sessionType: "upper", exercise: "Chest press", weight: 80, sets: "3", reps: "8")

# "Ran 5k in 24 min"
training_entry_log(sessionType: "cardio", exercise: "Run", durationMin: 24, distanceM: 5000)

# Fix a mis-tagged machine: Calf Press → calves
training_exercise_update(id: "calf-press", primaryMuscle: "calves")

# "Set up a Push / Pull / Legs split"
training_session_create(id: "push", label: "Push", emoji: "💪", kind: "strength",
                        exercises: ["Chest press", "Overhead press", "Triceps pushdown"])

# "I don't use the cardio day anymore" — archive, don't delete
training_session_update(id: "cardio", archived: true)
```

### Hydration
Hydration is a **UX layer over Nutrition** — every water log is stored as a `NutritionEntry` with `foods="Water"`, `waterMl > 0`, all macros at 0. There's no separate data model.

- `hydration_log({ml})` → creates the water-only entry. Use this for plain water; don't reach for `nutrition_entry_log`.
- `hydration_today()` → today's total ml + the list of water-only entries. The total **includes water recorded on real meals** (e.g. a salad entry with `waterMl: 250` counts toward the day), so it matches the iOS Hydration view.
- `hydration_history({from, to, days})` → per-day totals over a range. Defaults to last 30 days.

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
1. `intake_kinds_list()` — find the user's coffee/caffeine tracker (`kind`) and its method tokens.
2. `intake_items_list({kind})` — resolve the "Ethiopian" bean → item id.
3. `intake_event_log({kind, method: "v60", item: "<itemId>"})`.

**"Took my ibuprofen"**
1. `medications_list()` — resolve "ibuprofen" → `medicationID`.
2. `medications_log({medicationID, status: "taken"})`.

**"Splitting headache, about a 7"**
1. `symptoms_list()` — find or (via `symptoms_create({title: "Headache"})`) make the symptom → `symptomID`.
2. `symptoms_log({symptomID, severity: 7})`.

**"How's my chore list looking?"**
1. `chores_list()` — returns each chore with computed `dueDate` and `lastCompletedAt`.
2. Surface overdue ones first.

## Errors to expect

- `AUTHENTICATION_FAILED` / 401 → ckWebAuthToken expired, user needs to reconnect the MCP.
- `NOT_FOUND` on lookup → record doesn't exist; for `*_delete` this is fine (idempotent), for `*_update` surface it.
- `recurrenceWarning` on a complete → the task IS done, but its next occurrence wasn't created. Say both parts.
- CloudKit field-type errors during writes → almost always a wrong field name; check this skill against tool descriptions.

## Don'ts

- Don't poll. Make one call per question.
- Don't ask the user to enable a section to use it — work with the tools you see.
- Don't fabricate ids. Always list first, then act.
- Don't try to write `NutritionDaySum` — it's auto-computed.
- Don't bundle multiple meals into one `nutrition_entry_log` call — log separate entries with separate `loggedAt` timestamps.
