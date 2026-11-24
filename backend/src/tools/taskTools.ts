import type { Tool } from "../rpc.js";
import {
  checklistAddJsonSchema,
  checklistDeleteJsonSchema,
  checklistUpdateJsonSchema,
  completeTaskJsonSchema,
  createTaskJsonSchema,
  deferTaskJsonSchema,
  getTaskJsonSchema,
  moveToTodayJsonSchema,
  pendingReasoningJsonSchema,
  setAcceptanceJsonSchema,
  setArtifactJsonSchema,
  setAssigneeJsonSchema,
  setEndStateJsonSchema,
  setHandoffJsonSchema,
  threadAppendJsonSchema,
  threadGetJsonSchema,
  updateTaskJsonSchema,
} from "./writeTasks.js";

// Definitions (name, title, description, input schema, annotations) of the task
// tools the api.septena.app connector serves. src/shadow/mcp.ts picks them by
// name. Moved here from the retired CloudKit connector (src/mcp.ts,
// mcp.septena.app, decommissioned 2026-11-20).

export const listTasksJsonSchema = {
  type: "object",
  properties: {
    view: {
      type: "string",
      enum: ["today", "inbox", "review", "anytime", "upcoming", "completed"],
      default: "today",
      description:
        "Which task list to read. 'today' = the whole Today page as the app shows it: the Inbox section first, then every task on Today. 'inbox' = only the Inbox section: tasks the user has not filed yet (no area or project) and your proposals they have not accepted. 'review' = open tasks awaiting the user's verification (`endState = needs_verify`). 'anytime' is the single home for open, dateless tasks. Rows carry `inbox: true` when they sit in the Inbox, and `daysOnToday: N` when they have carried over on Today undone for N days (the app darkens their checkbox; 7+ is long overdue for a decision).",
    },
    limit: {
      type: "integer",
      minimum: 1,
      maximum: 500,
      default: 100,
    },
    tag: {
      oneOf: [
        { type: "string", minLength: 1 },
        { type: "array", items: { type: "string", minLength: 1 } },
      ],
      description:
        "Optional tag name (or array of tag names) to filter by, case-insensitive, AND semantics (tasks must carry every listed tag).",
    },
  },
} as const;

export const listTagsJsonSchema = {
  type: "object",
  properties: {},
} as const;

export const listAreasJsonSchema = {
  type: "object",
  properties: {
    limit: { type: "integer", minimum: 1, maximum: 500, default: 100 },
  },
} as const;

export const listProjectsJsonSchema = {
  type: "object",
  properties: {
    status: { type: "string", enum: ["active", "done", "cancelled", "all"], default: "active" },
    limit: { type: "integer", minimum: 1, maximum: 500, default: 200 },
  },
} as const;

export const searchTasksJsonSchema = {
  type: "object",
  properties: {
    query: { type: "string", minLength: 1, description: "Words to find in task titles and notes. Case and accents are ignored; a word also matches longer words that start with it." },
    area: { type: "string", description: "Only tasks in this area (as tasks_list shows it)." },
    project: { type: "string", description: "Only tasks in this project (as tasks_list shows it)." },
    status: { type: "string", enum: ["open", "completed", "all"], default: "open", description: "open (default), completed, or all." },
    limit: { type: "integer", minimum: 1, maximum: 100, default: 20 },
  },
  required: ["query"],
} as const;

export const TASK_TOOLS: Tool[] = [
  {
    name: "tasks_list",
    title: "List tasks",
    description:
      "New here? Call tasks_orientation first. List Septena tasks for a given view (today, inbox, review, upcoming, anytime, completed). 'today' is the whole Today page the user sees: the Inbox section first, then the filed tasks on Today. 'inbox' is that Inbox section alone: unfiled tasks (no area or project) plus your proposals the user has not accepted. 'review' lists open tasks waiting for the user to check and accept (`needs_verify`). The user sees ONE Inbox; never describe it as two piles. Each row carries `inbox: true` when it sits in the Inbox, and `daysOnToday: N` when it has carried over on Today undone for N days (the app darkens its checkbox; flag rows at 7+ as stuck). Returns {tasks, total, truncated}; truncated=true means more rows exist beyond limit.",
    inputSchema: listTasksJsonSchema,
    annotations: { title: "List tasks", readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "tasks_orientation",
    title: "How to work here",
    description: "Call this first when you connect. Returns how to work in Septena: the workflow and house rules, every tool grouped by family with when to use it, and the user's areas with whether each has a brief. Some hosts show the server instructions late or never; this tool returns the same text on demand.",
    inputSchema: { type: "object", properties: {} },
    annotations: { title: "How to work here", readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "tasks_search",
    title: "Search tasks",
    description: "Find tasks by words in their title or notes, best match first, with near matches so near-duplicates surface. Call it before tasks_create to check that the task does not exist yet. Filter by area, project and status (open by default; completed or all). Rows have the tasks_list shape plus `matched` (title or notes). Returns {tasks, total, truncated}.",
    inputSchema: searchTasksJsonSchema,
    annotations: { title: "Search tasks", readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "tasks_get",
    title: "Get task",
    description:
      "Inspect a single task by id: title, status, area, project, scheduled, deadline, today, completedAt, source, and a compact conversation summary. One call answers 'where is this task and what's its state?' regardless of view or status. Pass include_notes for the project and area notes: the context to read before deciding anything about the task.",
    inputSchema: getTaskJsonSchema,
    annotations: { title: "Get task", readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "tasks_list_projects",
    title: "List projects",
    description: "List Septena projects available for task assignment, optionally filtered by status. Each project carries its notes (the context for its tasks) and noteRev.",
    inputSchema: listProjectsJsonSchema,
    annotations: { title: "List projects", readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "tasks_list_areas",
    title: "List areas",
    description: "List Septena areas available for task assignment (top-level containers like 'home', 'envisioning'). Each area carries its notes and noteRev.",
    inputSchema: listAreasJsonSchema,
    annotations: { title: "List areas", readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "tasks_list_tags",
    title: "List tags",
    description: "List the user's existing tags with open task counts so you reuse their vocabulary instead of inventing synonyms.",
    inputSchema: listTagsJsonSchema,
    annotations: { title: "List tags", readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "tasks_create",
    title: "Create task",
    description: "Create a new Septena task. Call tasks_search first so you do not create a duplicate. Returns the new id and its placement. Set `origin` to declare provenance: `user_request` when the user explicitly asked (lands committed, placed where specified) or `agent_suggestion` when you surfaced it yourself (lands as a PROPOSAL in the user's inbox to review). Omit → Septena files it as a proposal (secure by default). Septena sets no limit on parallel calls, but some hosts do: for many tasks, create them in sequence or small groups and tasks_search before you retry a refused create.",
    inputSchema: createTaskJsonSchema,
    annotations: { title: "Create task", readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
  },
  {
    name: "tasks_complete",
    title: "Complete task",
    description: "Mark a task done. For recurring tasks, this also creates the next occurrence.",
    inputSchema: completeTaskJsonSchema,
    annotations: { title: "Complete task", readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "tasks_update",
    title: "Update task",
    description: "Update fields on an existing task. Any subset of title, today, scheduled, deadline, area, project, status (cancelled), notes. To add to the notes, prefer notes_append (one new line at the end) or notes_section (replace the text under one heading) over resending the whole body, and pass notes_rev from tasks_get so an edit made since your read is refused, not overwritten.",
    inputSchema: updateTaskJsonSchema,
    annotations: { title: "Update task", readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "tasks_defer",
    title: "Defer task",
    description: "Set a task’s When to a future date (sets scheduled, clears today).",
    inputSchema: deferTaskJsonSchema,
    annotations: { title: "Defer task", readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "tasks_move_to_today",
    title: "Move task to Today",
    description: "Pin a task to Today (sets today=true, clears scheduled).",
    inputSchema: moveToTodayJsonSchema,
    annotations: { title: "Move task to Today", readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "tasks_thread_get",
    title: "Get task conversation",
    description: "Read a task's conversation (TaskConvo: confirmedIntent, acceptance, thread of turns, artifact, handoff, endState, assignee).",
    inputSchema: threadGetJsonSchema,
    annotations: { title: "Get task conversation", readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "tasks_thread_append",
    title: "Append to task conversation",
    description: "Append one turn to a task's conversation. Provider turns propose (question+options); user turns choose (chosen+inReplyTo). A confirm-step turn carrying a chosen also sets confirmedIntent — put the resolved intent sentence in note.",
    inputSchema: threadAppendJsonSchema,
    annotations: { title: "Append to task conversation", readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
  },
  {
    name: "tasks_set_acceptance",
    title: "Set task acceptance criteria",
    description: "Set the agent-done bar (what 'done' means for the agent's deliverable). Distinct from task completion, which is the human's bar.",
    inputSchema: setAcceptanceJsonSchema,
    annotations: { title: "Set task acceptance criteria", readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "tasks_set_endstate",
    title: "Set task conversation end state",
    description: "Record the conversation's terminal end-state.",
    inputSchema: setEndStateJsonSchema,
    annotations: { title: "Set task conversation end state", readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "tasks_set_assignee",
    title: "Set task assignee",
    description: "Route a task: me | local | claude, or null to let the router decide. Setting claude marks it for the reasoning queue.",
    inputSchema: setAssigneeJsonSchema,
    annotations: { title: "Set task assignee", readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "tasks_set_artifact",
    title: "Set task artifact",
    description: "Attach the agent's deliverable to a task (agent_assisted): the research/table/draft you produced. Distinct from the handoff (the human's last-mile action).",
    inputSchema: setArtifactJsonSchema,
    annotations: { title: "Set task artifact", readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "tasks_set_handoff",
    title: "Set task handoff",
    description: "Set the human last-mile, rendered as a tappable action button. The agent is done; the task stays open until the human does this.",
    inputSchema: setHandoffJsonSchema,
    annotations: { title: "Set task handoff", readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "tasks_pending_reasoning",
    title: "List tasks awaiting reasoning",
    description: "List tasks awaiting reasoning: marked for Claude, or whose last provider turn was low-confidence, and not yet terminal.",
    inputSchema: pendingReasoningJsonSchema,
    annotations: { title: "List tasks awaiting reasoning", readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "tasks_checklist_add",
    title: "Add checklist items",
    description: "Append one or more 1-level checklist steps to a task.",
    inputSchema: checklistAddJsonSchema,
    annotations: { title: "Add checklist items", readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
  },
  {
    name: "tasks_checklist_update",
    title: "Update checklist item",
    description: "Rename, check/uncheck, or reorder a checklist item on a task. Checking all items does not auto-complete the parent task.",
    inputSchema: checklistUpdateJsonSchema,
    annotations: { title: "Update checklist item", readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "tasks_checklist_delete",
    title: "Delete checklist item",
    description: "Delete a checklist item from a task.",
    inputSchema: checklistDeleteJsonSchema,
    annotations: { title: "Delete checklist item", readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
  },
];
