// Pure task logic shared by the live CloudKit tools (listTasks.ts,
// writeTasks.ts) and the read-only task-backend preview (src/shadow/). No
// I/O here: each data source maps its rows into these shapes, then both use
// the same view rules and conversation summary, so the two connectors cannot
// disagree on what "Today" or "pending reasoning" means.

export type TaskView =
  | "today" | "triage" | "inbox" | "anytime" | "upcoming" | "completed";

export interface TaskOut {
  id: string;
  title: string;
  status: string;
  today: boolean;
  scheduled?: string;
  deadline?: string;
  area?: string;
  project?: string;
  completedAt?: string;
  notes?: string;
  // Provenance + freshness cue — needed to compute the triage band (and to
  // keep "today" excluding unratified rows). See iOS SeptenaTask.isInTriageBand.
  source?: string;
  acknowledgedAt?: number; // ms epoch; present once the user has engaged the row
  createdAt?: number;      // ms epoch
  // Row shape: "heading" = a project section divider, not a to-do. Filtered out
  // of every view (mirrors iOS TaskEntity.isHeading). Absent = task.
  kind?: string;
  // Emitted in the SAME shape tasks_create/tasks_update accept, so a read
  // round-trips into a write unchanged.
  recurrence?: { unit: string; interval: number; after_completion: boolean };
}

/// "someday" is the retired bucket — accepted as an alias for "anytime" so
/// existing agent calls keep working. Default view is "today".
export function normalizeView(view: unknown): TaskView {
  return ((view as string) === "someday" ? "anytime" : (view as TaskView | undefined)) ?? "today";
}

// Agent-cue decay window — keep in lockstep with iOS AgentCue.decayWindow (7d).
export const CUE_DECAY_MS = 7 * 24 * 60 * 60 * 1000;

/// Mirrors iOS TaskEntity.isInTriageBand — the unratified layer above Today.
/// Agent arm: an unacknowledged MCP-authored row still inside the freshness
/// window (reuses the agent-cue, so cue-decay = ratification-by-timeout).
/// Human arm: a loose capture with no disposition at all (the classic Inbox).
export function inTriageBand(t: TaskOut, nowMs: number): boolean {
  if (t.status !== "open" || t.kind === "heading") return false;
  if (t.source === "mcp") {
    if (t.acknowledgedAt) return false;
    if (!t.createdAt) return false;
    return nowMs - t.createdAt < CUE_DECAY_MS;
  }
  return !t.today && !t.area && !t.project && !t.scheduled && !t.deadline;
}

/// Mirrors Persistence.swift LocalCache.tasks(filter:). Keep in lockstep
/// with iOS so the two surfaces never disagree on what "Today" means.
export function matchesView(t: TaskOut, view: TaskView, today: string, nowMs: number): boolean {
  if (t.status !== "open" || t.kind === "heading") return false;
  switch (view) {
    case "today":
      // Ratified + due — the triage band (unratified) is excluded.
      if (inTriageBand(t, nowMs)) return false;
      return t.today || (!!t.scheduled && t.scheduled <= today) || (!!t.deadline && t.deadline <= today);
    case "triage":
      return inTriageBand(t, nowMs);
    case "inbox":
      return !t.today && !t.area && !t.project && !t.scheduled && !t.deadline;
    case "upcoming":
      if (t.today) return false;
      return (!!t.scheduled && t.scheduled > today) || (!!t.deadline && t.deadline > today);
    default:
      return true;
  }
}

// ---- Task conversations (TaskConvo) ----

export interface ConvoTurn {
  seq: number;
  role: "user" | "provider";          // propose (provider) vs choose (user) are separate turns
  step: "confirm" | "ground" | "scope" | "decide" | "work";
  provider?: "onDevice" | "claude" | "applePCC";   // omitted = deterministic compute (no model)
  confidence?: number;                // provider turns; the escalation trigger
  question?: string;
  options?: string[];
  chosen?: string;
  otherText?: string;
  inReplyTo?: number;                 // user turn → the proposal turn (seq) it answers
  note?: string;
  ts: string;                         // ISO-8601 (matches the app's coders)
}

export interface TaskConvo {
  confirmedIntent?: string;
  acceptance?: string;
  thread: ConvoTurn[];
  subtasks: string[];
  artifact?: { kind: string; title: string; body: string; refs?: string[] };
  handoff?: { instruction: string; actionType: "open_url" | "compose" | "call" | "none"; payload?: string };
  endState?: string;
  endStateNote?: string;
  assignee?: "me" | "local" | "claude";
}

export function isTerminalConvo(c: TaskConvo): boolean {
  return c.endState !== undefined && c.endState !== "open";
}

/// Marked for Claude, or the last provider turn was low-confidence — and not
/// yet terminal. Mirrors the in-app `pendingReasoning`.
export function awaitsReasoning(c: TaskConvo): boolean {
  if (isTerminalConvo(c)) return false;
  const lastProvider = [...c.thread].reverse().find((t) => t.role === "provider");
  const lowConf = lastProvider?.confidence !== undefined && lastProvider.confidence < 0.5;
  return c.assignee === "claude" || lowConf;
}

/// The compact conversation block `tasks_get` returns.
export function convoSummary(c: TaskConvo) {
  return {
    confirmedIntent: c.confirmedIntent,
    acceptance: c.acceptance,
    assignee: c.assignee,
    endState: c.endState,
    turns: c.thread.length,
    hasArtifact: !!c.artifact,
    hasHandoff: !!c.handoff,
    pendingReasoning: awaitsReasoning(c),
  };
}
