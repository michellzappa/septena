import type { Tool } from "../rpc.js";
import {
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
      enum: ["today", "inbox", "anytime", "upcoming", "completed"],
      default: "today",
      description:
        "Which task list to read. 'today' = the whole Today page as the app shows it: the Inbox section first, then every task due today. 'inbox' = only the Inbox section: tasks the user has not filed yet (no area or project) and your proposals they have not accepted. 'anytime' is the single home for open, dateless tasks. Rows carry `inbox: true` when they sit in the Inbox, and `daysOnToday: N` when they have carried over on Today undone for N days (the app darkens their checkbox; 7+ is long overdue for a decision).",
    },
    limit: {
      type: "integer",
      minimum: 1,
      maximum: 500,
      default: 100,
    },
  },
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

export const TASK_TOOLS: Tool[] = [
  {
    name: "tasks_list",
    title: "List tasks",
    description:
      "List Septena tasks for a given view (today, inbox, upcoming, anytime, completed). 'today' is the whole Today page the user sees: the Inbox section first, then the filed tasks due today. 'inbox' is that Inbox section alone: unfiled tasks (no area or project) plus your proposals the user has not accepted. The user sees ONE Inbox; never describe it as two piles. Each row carries `inbox: true` when it sits in the Inbox, and `daysOnToday: N` when it has carried over on Today undone for N days (the app darkens its checkbox; flag rows at 7+ as stuck). Returns {tasks, total, truncated}; truncated=true means more rows exist beyond limit.",
    inputSchema: listTasksJsonSchema,
    annotations: { title: "List tasks", readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "tasks_get",
    title: "Get task",
    description:
      "Inspect a single task by id: title, status, area, project, scheduled, deadline, today, completedAt, source, and a compact conversation summary. One call answers 'where is this task and what's its state?' regardless of view or status.",
    inputSchema: getTaskJsonSchema,
    annotations: { title: "Get task", readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "tasks_list_projects",
    title: "List projects",
    description: "List Septena projects available for task assignment, optionally filtered by status.",
    inputSchema: listProjectsJsonSchema,
    annotations: { title: "List projects", readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "tasks_list_areas",
    title: "List areas",
    description: "List Septena areas available for task assignment (top-level containers like 'home', 'envisioning').",
    inputSchema: listAreasJsonSchema,
    annotations: { title: "List areas", readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "tasks_create",
    title: "Create task",
    description: "Create a new Septena task. Returns the new id and its placement. Set `origin` to declare provenance: `user_request` when the user explicitly asked (lands committed, placed where specified) or `agent_suggestion` when you surfaced it yourself (lands as a PROPOSAL in the user's inbox to review). Omit → the gateway proposes (secure by default).",
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
    description: "Update fields on an existing task. Any subset of title, today, scheduled, deadline, area, project, status (cancelled).",
    inputSchema: updateTaskJsonSchema,
    annotations: { title: "Update task", readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "tasks_defer",
    title: "Defer task",
    description: "Defer a task to a future date (sets scheduled, clears today).",
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
];
