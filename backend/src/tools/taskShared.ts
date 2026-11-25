import { DOMAIN_RULES, VIEW_ALIASES } from "../generated/registries.js";
import { deriveConversation, taskViewMembership, type CoreConversation, type CoreMembership, type CoreTask } from "../core/index.js";

// Pure task logic shared by the live CloudKit tools (listTasks.ts,
// writeTasks.ts) and the read-only task-backend preview (src/shadow/). No
// I/O here: each data source maps its rows into these shapes, then both use
// the same view rules and conversation summary, so the two connectors cannot
// disagree on what "Today" or "pending reasoning" means.

export type TaskView =
  | "today" | "inbox" | "review" | "anytime" | "upcoming" | "completed" | "faded";

export interface TaskOut {
  id: string;
  title: string;
  status: string;
  today: boolean;
  starred?: boolean;
  /// The user does this task now (docs/DO_SPEC.md §6).
  doing?: true;
  tags?: string[];
  scheduled?: string;
  startTime?: string;
  durationMinutes?: number;
  timeZone?: string;
  deadline?: string;
  // The deadline the user planned past (docs/TASK_DATES_SPEC.md I8).
  deferredDeadline?: string;
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
  // Row shape: "heading" = a project section divider, not a task. Filtered out
  // of every view (mirrors iOS TaskEntity.isHeading). Absent = task.
  kind?: string;
  // Set when the task has faded (docs/TASK_FADE_SPEC.md §4). A faded task
  // is in no list view, as in the apps.
  fadedAt?: string;
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
  // When the agent handed it over (the review view; `convos.endStateAt`).
  reviewAt?: string;
  // Added by `withTaskLinks` (absent = none): `refCount` = how many references
  // the task has; `issue` = its newest `issue` reference; `endState` = the
  // conversation's end state, when it is not `open`.
  refCount?: number;
  issue?: IssueLink;
  endState?: string;
}

/// A GitHub issue or pull request.
export interface IssueLink {
  url: string;
  repo: string;   // owner/name
  number: number;
  kind: "issue" | "pr";
}

/// The `issue` field of an `issue` reference (TASK_REFERENCES_SPEC.md §6.6).
/// `key` is in normal form: `issue:<owner>/<repo>#<n>`. The snapshot keeps
/// the spelling of the name, and only its URL says whether it is a pull
/// request, because GitHub gives both one number series.
export function issueLink(key: string, snapshot: { url?: string; rawId?: string } | null): IssueLink {
  const id = key.slice(key.indexOf(":") + 1);
  const hash = id.lastIndexOf("#");
  const number = Number(id.slice(hash + 1));
  const name = id.slice(0, hash);
  const raw = snapshot?.rawId?.split("#")[0];
  const repo = raw !== undefined && raw.toLowerCase() === name ? raw : name;
  const pr = /\/pull\/\d+/.test(snapshot?.url ?? "");
  return { url: `https://github.com/${repo}/${pr ? "pull" : "issues"}/${number}`, repo, number, kind: pr ? "pr" : "issue" };
}

/// Adds `refCount`, `issue` and a non-open `endState` to an output row.
export function withTaskLinks(
  t: TaskOut,
  l: { endState: string | null; refCount: number; issue: { key: string; snapshot: { url?: string; rawId?: string } | null } | null } | undefined,
): TaskOut {
  if (!l) return t;
  const out = { ...t };
  if (l.refCount > 0) out.refCount = l.refCount;
  if (l.issue) out.issue = issueLink(l.issue.key, l.issue.snapshot);
  if (l.endState && l.endState !== "open") out.endState = l.endState;
  return out;
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

/// List membership is the shared core's (`views.rs`, ADR 0025 C3 #249): the
/// same rule the apps run, verified by `registry/conformance/task-views.json`.
/// These helpers only map a row into the core's snapshot and read one field.
/// Deleted rows never reach them (the readers drop them).

/// The row as the core reads it.
export function coreTask(t: TaskOut): CoreTask {
  return {
    id: t.id,
    title: t.title,
    status: t.status,
    kind: t.kind ?? null,
    area: t.area ?? null,
    project: t.project ?? null,
    created: t.created ?? null,
    createdAt: t.createdAt !== undefined ? new Date(t.createdAt).toISOString() : null,
    scheduled: t.scheduled ?? null,
    deadline: t.deadline ?? null,
    deferredDeadline: t.deferredDeadline ?? null,
    today: t.today,
    todaySetOn: t.todaySetOn ?? null,
    source: t.source ?? null,
    acknowledgedAt: t.acknowledgedAt !== undefined ? new Date(t.acknowledgedAt).toISOString() : null,
    starred: t.starred === true,
    recurrenceUnit: t.recurrence?.unit ?? null,
    recurrenceAfterCompletion: t.recurrence ? t.recurrence.after_completion : null,
    fadedAt: t.fadedAt ?? null,
    startTime: t.startTime ?? null,
    durationMinutes: t.durationMinutes ?? null,
    timeZone: t.timeZone ?? null,
    reminderAt: t.reminderAt ?? null,
    reminderSnoozedUntil: t.reminderSnoozedUntil ?? null,
  };
}

// One core call per row, day and instant: a list request asks several
// questions of each row.
const memo = new WeakMap<TaskOut, { key: string; m: CoreMembership }>();

/// The core's membership of one row on `today` at `nowMs`.
export function membership(t: TaskOut, today: string, nowMs: number): CoreMembership {
  const key = `${today}|${nowMs}`;
  const hit = memo.get(t);
  if (hit && hit.key === key) return hit.m;
  const m = taskViewMembership(coreTask(t), today, new Date(nowMs).toISOString());
  memo.set(t, { key, m });
  return m;
}


/// No area and no project.
export function isUnfiled(t: TaskOut): boolean {
  return !t.area && !t.project;
}

/// The unratified Inbox members, the layer above Today.
export function inTriageBand(t: TaskOut, today: string, nowMs: number): boolean {
  return membership(t, today, nowMs).inTriageBand;
}

/// A Today pin, or a When date or deadline that has arrived.
export function isOnToday(t: TaskOut, today: string, nowMs: number): boolean {
  return membership(t, today, nowMs).isOnToday;
}

/// Today's Inbox section in the app.
export function inInbox(t: TaskOut, today: string, nowMs: number): boolean {
  return membership(t, today, nowMs).inInbox;
}

/// Whole days the row has carried over on Today undone.
export function daysOnToday(t: TaskOut, today: string, nowMs: number): number {
  return membership(t, today, nowMs).daysOnToday;
}

/// Adds the derived `inbox` and `daysOnToday` fields to an output row.
export function annotate(t: TaskOut, today: string, nowMs: number): TaskOut {
  const m = membership(t, today, nowMs);
  const out = { ...t };
  if (m.inInbox) out.inbox = true;
  if (m.daysOnToday > 0) out.daysOnToday = m.daysOnToday;
  return out;
}

/// Today in the app's order: the Inbox section first (triage band, then the
/// loose Today rows), then the filed rows. Stable within each part.
export function inboxFirst(tasks: TaskOut[], today: string, nowMs: number): TaskOut[] {
  const rank = (t: TaskOut) => {
    const m = membership(t, today, nowMs);
    return m.inTriageBand ? 0 : m.inInbox ? 1 : 2;
  };
  return tasks.map((t, i) => ({ t, i })).sort((a, b) => rank(a.t) - rank(b.t) || a.i - b.i).map((x) => x.t);
}

/// The app's lists. `today`, `inbox`, `upcoming` and `anytime` are the
/// core's; any other view (completed, review) filters elsewhere and only
/// needs an open, non-heading row here.
export function matchesView(t: TaskOut, view: TaskView, today: string, nowMs: number): boolean {
  switch (view) {
    case "today":
    case "inbox":
    case "upcoming":
    case "anytime":
      return membership(t, today, nowMs).matchesView[view];
    case "faded":
      // The app's Faded pile: open tasks the fade pass took out of their list.
      return t.status === "open" && t.kind !== "heading" && !!t.fadedAt;
    default:
      return t.status === "open" && t.kind !== "heading";
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

/// The conversation as the core reads it.
export function coreConversation(c: TaskConvo): CoreConversation {
  return {
    confirmedIntent: c.confirmedIntent ?? null,
    thread: c.thread.map((t) => ({ seq: t.seq, role: t.role, options: t.options ?? null, confidence: t.confidence ?? null })),
    artifactExists: !!c.artifact,
    handoffExists: !!c.handoff,
    endState: c.endState ?? null,
    endStateNote: c.endStateNote ?? null,
    assignee: c.assignee ?? null,
  };
}

/// Marked for Claude, or the last provider turn was low-confidence, and not
/// terminal: the core's `pendingReasoning` (`convo.rs`).
export function awaitsReasoning(c: TaskConvo): boolean {
  return deriveConversation(coreConversation(c), new Date().toISOString()).pendingReasoning;
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
