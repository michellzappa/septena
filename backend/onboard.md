---
name: onboard-septena
description: Set up a user's Septena account with real areas (with context and emoji), projects (with context), and tasks — starting from what you already know about their work and life, or a quick conversation if starting fresh.
---

# Set up Septena

You are helping this person populate their Septena account so it starts with their real areas, projects, and tasks — not an empty list and not generic filler.

## 0. Check what is already there

Before proposing anything, read the current account state so you build on it instead of creating duplicates:

- Call `tasks_list_areas`
- Call `tasks_list_projects` (with `status: "active"`)
- Call `tasks_list` with `view: "today"` and `view: "anytime"`

If areas, projects, or tasks already exist, keep them in mind and only propose additions or missing context.

## 1. Start from what you already know — or ask

Check whether you already have context or memory about this person (their work, active projects, clients, ongoing responsibilities, personal areas, open loops from prior conversations). Never read external mail, calendars, or other services unless they explicitly ask you to.

### If you know them from memory or past conversations

Draft a concrete starter structure right away from what you actually know:

- **Areas** (top-level parts of their life and work — e.g. a company, clients, home, health, side projects): give each a fitting single **emoji** and a short **context brief** in plain words (what it covers, ongoing responsibilities, key people).
- **Projects** (active initiatives inside those areas): give each a concise **context brief** using only what you genuinely know (Goal, Current state, People, Constraints). Never invent a goal or decision.
- **Tasks**: include **at least a few** real, concrete next actions they actually have on their plate, filed under the right area or project. Only set `today: true`, `scheduled`, or `deadline` when you have a real reason to.

Present the draft and ask: *"Here's a starter setup based on what I know about what you're working on. Want to tweak this, paste a list from another app, or add anything I missed?"*

### If you have little or nothing in memory

Interview them to find real work to put in Septena. Keep it conversational — one or two short questions at a time, never a wall of questions:

1. **Life and work buckets:** Ask how they divide their responsibilities. Offer common examples (Work, Clients, Home, Health, Learning, Side Projects) and let them rename, merge, or add. Each becomes an **Area** (pick a matching single **emoji** and write a short **context brief** from their answer).
2. **Active projects and ongoing work:** For each area, ask what is actually going on right now — active projects, who is involved, what they are trying to get done, and what is stuck or next.
3. **Concrete next tasks:** Pull out **at least a few** real, actionable tasks per area or project from what they tell you. Never pad the list with generic productivity filler (like "Try Septena" or "Review goals").

## 2. Confirm before writing (per area)

Show your proposed **Areas** (title, emoji, context), **Projects** (title, context brief), and **Tasks** grouped by area before calling any write tool. Let the user edit, cut, or add.

Rules for briefs:
- Write notes from the user's own words and real context — never invent goals, dates, or decisions.
- If the user says nothing about a project, leave its brief empty and mention it in the final summary.

## 3. Write notes before tasks via MCP

Once the user confirms an area (or the whole batch), write in this order so every task lands in a container that already has context:

1. **Areas:** call `tasks_area_create` with `title`, `emoji`, `notes` (the area's context), and `why: "onboarding"`. Skip any area that already exists (if an existing area has empty notes and the user confirmed a brief, write it with `tasks_notes_write`).
2. **Projects:** call `tasks_project_create` with `title`, `area` (the area `id`), `notes` (the confirmed brief — suggested headings: `Goal`, `Current state`, `People`, `Decisions`, `Constraints`), optional `githubRepo`, and `why: "onboarding"`.
3. **Tasks:** call `tasks_create` with `title`, `area` or `project` id, optional `notes`, `today`, `scheduled`, or `deadline`, and **`origin: "user_request"`** (because the user just reviewed and approved these tasks, so they land directly in the right lists rather than sitting unaccepted in the Inbox). If the user explicitly asks to review them in the Inbox instead, omit `origin`.

Echo back nothing verbose while writing — batch the calls cleanly.

## 4. Optional import from another app

If the user mentions existing tasks elsewhere:

- **Things:** point them to Septena's built-in importer in Settings (it preserves areas, projects, notes, and tasks directly). Do not try to read the Things database yourself.
- **Other apps, CSV, or pasted lists:** read what the user gives you, map it to their areas and projects, show the mapping first, and write only after they say yes.
- **After any import:** check for imported projects with empty notes and offer to write a few lines of context for each from what the user shares.

## 5. Close with one short summary

Finish with a single concise summary:
- Areas created (with emoji)
- Projects created (and any whose brief is still empty)
- Tasks added (and where they landed)
- One line explaining how they can assign a task or start a conversation with you in Septena whenever they want help moving something forward.
