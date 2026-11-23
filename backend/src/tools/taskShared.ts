import { DOMAIN_RULES, VIEW_ALIASES } from "../generated/registries.js";

// Pure task logic shared by the live CloudKit tools (listTasks.ts,
// writeTasks.ts) and the read-only task-backend preview (src/shadow/). No
// I/O here: each data source maps its rows into these shapes, then both use
// the same view rules and conversation summary, so the two connectors cannot
// disagree on what "Today" or "pending reasoning" means.

export type TaskView =
  | "today" | "inbox" | "review" | "anytime" | "upcoming" | "completed";

export interface TaskOut {
  id: string;
  title: string;
  status: string;
  today: boolean;
  starred?: boolean;
  tags?: string[];
  scheduled?: string;
  startTime?: string;
  durationMinutes?: number;
  timeZone?: string;
  deadline?: string;
  area?: string;
  project?: string;
  completedAt?: string;
  notes?: string;
  // Day stamps (YYYY-MM-DD) that date a task's arrival on Today — the inputs
  // of `daysOnToday`. `todaySetOn` = when the explicit `today` pin was set.
  created?: string;
  todaySetOn?: string;
  // Provenance + freshness cue — needed to compute the triage band, the
  // unratified part of the Inbox. See iOS SeptenaTask.isInTriageBand.
  source?: string;
  acknowledgedAt?: number; // ms epoch; present once the user has engaged the row
  createdAt?: number;      // ms epoch
  // Row shape: "heading" = a project section divider, not a to-do. Filtered out
  // of every view (mirrors iOS TaskEntity.isHeading). Absent = task.
  kind?: string;
  // Emitted in the SAME shape tasks_create/tasks_update accept, so a read
  // round-trips into a write unchanged.
  recurrence?: {
    unit: string;
    interval: number;
    after_completion: boolean;
    weekdays?: number[];
    month_day?: number;
    ordinal_weekday?: { ordinal: number; weekday: number };
  };
  reminderAt?: string;
  reminderMode?: "floating" | "fixed";
  reminderSnoozedUntil?: string;
  checklistCount?: number;
  checklistDoneCount?: number;
  // Derived on output by `annotate` (absent = false / 0):
  // `inbox` = the row sits in Today's Inbox section in the app.
  // `daysOnToday` = days the row has carried over on Today undone; the app
  // darkens the checkbox one seventh per day (SeptenaCore todayTenureFill).
  inbox?: true;
  daysOnToday?: number;
  reviewNote?: string;
}

/// Retired view names stay accepted so existing agent calls keep working:
/// aliases come from `registry/destinations.json` (`VIEW_ALIASES`). Default is "today".
export function normalizeView(view: unknown): TaskView {
  const v = view as string | undefined;
  if (v && v in VIEW_ALIASES) {
    return VIEW_ALIASES[v as keyof typeof VIEW_ALIASES] as TaskView;
  }
  return (v as TaskView | undefined) ?? "today";
}

// Agent-cue decay window — generated from `registry/rules.json` (ADR 0015).
export const CUE_DECAY_MS = DOMAIN_RULES.cueDecayDays * 24 * 60 * 60 * 1000;

/// THE Inbox rule — mirrors SeptenaCore `TaskInbox` (Models.swift); keep the
/// two in lockstep. Inbox = open, not deleted, not a heading, no area, no
/// project. Deleted rows never reach these helpers (the readers drop them).
/// Deleting an area or project never sends tasks here: the deleting device
/// moves them to Recently Deleted.
export function isUnfiled(t: TaskOut): boolean {
  return !t.area && !t.project;
}

export function isInboxMember(t: TaskOut): boolean {
  return t.status === "open" && t.kind !== "heading" && isUnfiled(t);
}

/// Mirrors SeptenaCore TaskInbox.isUnratified + TaskEntity.isInTriageBand —
/// the unratified Inbox members, the layer above Today. Agent arm: an
/// MCP-authored row inside the freshness window (reuses the agent-cue, so
/// cue-decay = ratification-by-timeout); a dated proposal leaves once
/// acknowledged, an undated one stays for the whole window. Human arm: a
/// capture with no disposition at all (no Today pin, no date).
export function inTriageBand(t: TaskOut, nowMs: number): boolean {
  if (!isInboxMember(t)) return false;
  if (t.source === "mcp") {
    if (!t.createdAt) return false;
    if (nowMs - t.createdAt >= CUE_DECAY_MS) return false;
    if (t.today || t.scheduled || t.deadline) return !t.acknowledgedAt;
    return true;
  }
  return !t.today && !t.scheduled && !t.deadline;
}

/// Mirrors SeptenaCore SeptenaTask.isOnToday: a `today` pin, or a scheduled /
/// deadline date that has arrived.
export function isOnToday(t: TaskOut, today: string): boolean {
  if (t.status !== "open" || t.kind === "heading") return false;
  return t.today || (!!t.scheduled && t.scheduled <= today) || (!!t.deadline && t.deadline <= today);
}

/// Today's Inbox section in the app — mirrors TaskInbox.showsInTodayInbox:
/// the triage band, then the Inbox members on Today. One bucket: the user
/// never sees "unratified" and "unfiled" as two states.
export function inInbox(t: TaskOut, today: string, nowMs: number): boolean {
  return inTriageBand(t, nowMs) || (isInboxMember(t) && isOnToday(t, today));
}

/// Mirrors SeptenaCore SeptenaTask.daysOnToday: whole days since the task
/// landed on Today (earliest of the pin stamp and any arrived scheduled /
/// deadline date, floored at `created`). 0 for a fresh agent proposal (it
/// carries its own cue) and for a legacy pin with no `todaySetOn`.
export function daysOnToday(t: TaskOut, today: string, nowMs: number): number {
  if (!isOnToday(t, today) || showsAgentCue(t, nowMs)) return 0;
  const landed: string[] = [];
  if (t.today && t.todaySetOn) landed.push(t.todaySetOn);
  if (t.scheduled && t.scheduled <= today) landed.push(t.scheduled);
  if (t.deadline && t.deadline <= today) landed.push(t.deadline);
  if (landed.length === 0) return 0;
  let earliest = landed.sort()[0].slice(0, 10);
  if (t.created && t.created.slice(0, 10) > earliest) earliest = t.created.slice(0, 10);
  const from = Date.parse(`${earliest}T00:00:00Z`);
  const to = Date.parse(`${today}T00:00:00Z`);
  if (!Number.isFinite(from) || !Number.isFinite(to)) return 0;
  return Math.max(0, Math.round((to - from) / 86_400_000));
}

/// Mirrors SeptenaTask.showsAgentCue: an unacknowledged MCP-authored row
/// inside the decay window.
function showsAgentCue(t: TaskOut, nowMs: number): boolean {
  if (t.source !== "mcp" || t.acknowledgedAt || !t.createdAt) return false;
  return nowMs - t.createdAt < CUE_DECAY_MS;
}

/// Adds the derived `inbox` and `daysOnToday` fields to an output row.
export function annotate(t: TaskOut, today: string, nowMs: number): TaskOut {
  const out = { ...t };
  if (inInbox(t, today, nowMs)) out.inbox = true;
  const days = daysOnToday(t, today, nowMs);
  if (days > 0) out.daysOnToday = days;
  return out;
}

/// Today in the app's order: the Inbox section first (triage band, then the
/// loose Today rows), then the filed rows. Stable within each part.
export function inboxFirst(tasks: TaskOut[], today: string, nowMs: number): TaskOut[] {
  const rank = (t: TaskOut) => (inTriageBand(t, nowMs) ? 0 : inInbox(t, today, nowMs) ? 1 : 2);
  return tasks.map((t, i) => ({ t, i })).sort((a, b) => rank(a.t) - rank(b.t) || a.i - b.i).map((x) => x.t);
}

/// Mirrors Persistence.swift LocalCache.tasks(filter:). Keep in lockstep
/// with iOS so the two surfaces never disagree on what "Today" means.
export function matchesView(t: TaskOut, view: TaskView, today: string, nowMs: number): boolean {
  if (t.status !== "open" || t.kind === "heading") return false;
  switch (view) {
    case "today":
      // The whole Today page, as the app draws it: the Inbox section (which
      // includes the unratified band) plus every row due today.
      return inTriageBand(t, nowMs) || isOnToday(t, today);
    case "inbox":
      return inInbox(t, today, nowMs);
    case "upcoming":
      if (t.today) return false;
      return (!!t.scheduled && t.scheduled > today) || (!!t.deadline && t.deadline > today);
    case "anytime":
      // The app's Anytime list (LocalCache .unscheduled): open, not on Today,
      // no date at all.
      return !t.today && !t.scheduled && !t.deadline;
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

// ---- Search (tasks_search) ----

/// Lower-case, diacritics stripped, punctuation folded to spaces.
export function foldText(s: string): string {
  return s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();
}

/// How well a task matches a search query, or null for no match. Ranks an
/// exact title first, then every query word in the title, then partial word
/// overlap, so near-duplicates surface. A query word matches a title or note
/// word that starts with it ("remind" matches "reminders").
export function searchMatch(
  t: Pick<TaskOut, "title" | "notes">, query: string,
): { score: number; matched: "title" | "notes" } | null {
  const q = foldText(query);
  if (q.length === 0) return null;
  const words = [...new Set(q.split(" "))];
  const title = foldText(t.title);
  const titleWords = title.split(" ");
  const noteWords = foldText(t.notes ?? "").split(" ");
  const hits = (have: string[]) => words.filter((w) => have.some((h) => h.startsWith(w))).length;
  if (title === q) return { score: 100, matched: "title" };
  const inTitle = hits(titleWords);
  if (inTitle === words.length) return { score: 80 + (title.includes(q) ? 10 : 0), matched: "title" };
  const inNotes = hits(noteWords);
  if (inNotes === words.length) return { score: 40 + 20 * (inTitle / words.length), matched: "notes" };
  // Near match: at least half the query words, in title and notes together.
  const either = words.filter((w) => [...titleWords, ...noteWords].some((h) => h.startsWith(w))).length;
  if (either * 2 < words.length || either === 0) return null;
  return { score: 30 * (either / words.length) + 10 * (inTitle / words.length), matched: inTitle > 0 ? "title" : "notes" };
}

// ---- Task notes edits (tasks_update notes_append / notes_section) ----

/// A short version stamp of a task's notes: FNV-1a over the text, hex. An
/// agent passes it back as `notes_rev` so an edit made since its read is
/// refused, never silently overwritten. Empty and absent notes share one rev.
export function notesRev(notes: string | null | undefined): string {
  let h = 0x811c9dc5;
  for (const ch of notes ?? "") {
    h ^= ch.codePointAt(0)!;
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h.toString(16).padStart(8, "0");
}

/// Add `text` on a new line at the end of the notes.
export function appendNotes(notes: string | null | undefined, text: string): string {
  const cur = (notes ?? "").replace(/\s+$/, "");
  return cur.length === 0 ? text : `${cur}\n${text}`;
}

/// Replace the body under one heading line, up to the next heading. A heading
/// line is `#`-style (`## Decisions`) or a line in capitals (`DECISIONS`),
/// matched case-insensitively with the `#`s and a trailing colon ignored. A
/// missing heading is added at the end as `## <heading>`.
export function replaceNotesSection(notes: string | null | undefined, heading: string, body: string): string {
  const isHeading = (line: string) =>
    /^#{1,6}\s+\S/.test(line) || (/^[^a-z]*[A-Z][^a-z]*$/.test(line.trim()) && line.trim().length <= 60);
  const key = (line: string) => line.trim().replace(/^#{1,6}\s+/, "").replace(/:$/, "").trim().toLowerCase();
  const want = key(heading);
  const lines = (notes ?? "").split("\n");
  const start = lines.findIndex((l) => isHeading(l) && key(l) === want);
  const cleanBody = body.replace(/\s+$/, "");
  if (start < 0) {
    const cur = (notes ?? "").replace(/\s+$/, "");
    const section = `## ${heading.replace(/^#{1,6}\s+/, "").trim()}\n${cleanBody}`;
    return cur.length === 0 ? section : `${cur}\n\n${section}`;
  }
  let end = lines.findIndex((l, i) => i > start && isHeading(l));
  if (end < 0) end = lines.length;
  const out = [...lines.slice(0, start + 1), ...(cleanBody ? cleanBody.split("\n") : []), ...(end < lines.length ? ["", ...lines.slice(end)] : [])];
  return out.join("\n");
}
