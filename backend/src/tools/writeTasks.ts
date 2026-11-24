import type { ConvoTurn, TaskConvo } from "./taskShared.js";
import type { RefInput } from "../shadow/refs.js";
import { isValidReminderAt, type ReminderMode } from "../reminders.js";

// Pure task-write logic (planning, ids, recurrence and conversation helpers)
// and the tool input schemas. No I/O: src/shadow/writes.ts turns the plans
// into TaskStore pushes.

export type { ConvoTurn, TaskConvo } from "./taskShared.js";

/// The tool error for a task pointed at an area/project id that does not
/// exist, or null when `id` is one of `valid`. Pure: shared with the task
/// backend connector (src/shadow/writes.ts), which reads the containers from
/// the TaskStore instead of CloudKit.
export function unknownContainerMessage(
  kind: "area" | "project",
  id: string,
  valid: ReadonlyArray<{ id: string; title: string }>,
): string | null {
  if (valid.some((c) => c.id === id)) return null;
  const known = valid.map((c) => `${c.id} (${c.title})`).join(", ");
  return `unknown ${kind} id '${id}'. Use tasks_list_${kind}s for valid ids. Known: ${known}`;
}

// Mutators for Task records. Uses CKWS records/modify with forceUpdate.
// Identity for new tasks: base32-6 shortid per identifiers.md.

const SHORTID_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789";

/// Six characters from SHORTID_ALPHABET. Rejection sampling keeps every
/// character uniform: `b & 31` used to index past the 31-character alphabet
/// one time in 32, dropping that character and leaving a short id.
export function newTaskId(): string {
  const n = SHORTID_ALPHABET.length;
  const limit = 256 - (256 % n);
  let id = "";
  while (id.length < 6) {
    const buf = new Uint8Array(12);
    crypto.getRandomValues(buf);
    for (const b of buf) {
      if (b < limit && id.length < 6) id += SHORTID_ALPHABET[b % n];
    }
  }
  return id;
}

/**
 * Repeat rule shared by `tasks_create` and `tasks_update`. Mirrors the app's
 * own `Recurrence` JSON (`unit` / `interval` / `after_completion`), so a rule
 * set from chat is byte-identical to one set in the repeat picker. Nullable so
 * an update can clear it.
 *
 * LOCKSTEP: septena/SeptenaCore/MCP/MCPToolCatalog.swift `recurrenceSchema`.
 */
export const recurrenceJsonSchema = {
  type: ["object", "null"],
  description:
    "Repeat rule. Completing the task generates the next occurrence. after_completion=true counts the interval from the day you tick it off (\"every 3 days after completion\"); false counts from the previous scheduled date, which is what keeps a weekly/monthly/yearly task on schedule (\"every Mon/Wed/Fri\", \"last Friday of month\") and REQUIRES the task to have a scheduled date. Pass null to clear an existing rule.",
  required: ["unit"],
  properties: {
    unit: { type: "string", enum: ["day", "week", "month", "year"] },
    interval: { type: "integer", minimum: 1, default: 1, description: "Every N units. 1 = daily/weekly/monthly/yearly." },
    after_completion: {
      type: "boolean",
      default: true,
      description: "Anchor: true = from completion, false = from the previous scheduled date.",
    },
    weekdays: {
      type: "array",
      items: { type: "integer", minimum: 1, maximum: 7 },
      description: "Optional specific weekdays for fixed weekly rules (1 = Sunday .. 7 = Saturday; e.g. [2,3,4,5,6] = weekdays).",
    },
    month_day: {
      type: "integer",
      description: "Optional day of month for fixed monthly/yearly rules (1..31, or -1 for last day of month). Mutually exclusive with ordinal_weekday.",
    },
    ordinal_weekday: {
      type: "object",
      required: ["ordinal", "weekday"],
      properties: {
        ordinal: { type: "integer", enum: [-1, 1, 2, 3, 4] },
        weekday: { type: "integer", minimum: 1, maximum: 7 },
      },
      description: "Optional ordinal weekday for fixed monthly/yearly rules (e.g. { ordinal: -1, weekday: 6 } = last Friday). Mutually exclusive with month_day.",
    },
  },
} as const;

/** Task references (docs/TASK_REFERENCES_SPEC.md §7). */
const refsJsonSchema = {
  type: "array",
  maxItems: 20,
  items: {
    type: "object",
    required: ["key"],
    properties: {
      key: {
        type: "string",
        minLength: 1,
        description:
          "What the task points at: a key (email:<Message-ID>, thread:<root Message-ID>, event:<iCal UID>, issue:<owner>/<repo>#<n>, task:<task id>, url:<web URL>), a web URL, or a message:// link. Septena stores it in normal form.",
      },
      role: {
        type: "string",
        enum: ["about", "from", "blocked_by", "follow_up"],
        description: "about (default) = the task is about it. from = the task was made from it. blocked_by and follow_up are labels.",
      },
      snapshot: {
        type: "object",
        properties: {
          title: { type: "string" },
          subtitle: { type: "string", description: "Sender, repository, organiser or host." },
          date: { type: "string" },
          url: { type: "string", description: "http or https web address." },
          rawId: { type: "string", description: "The id before normalisation." },
          account: { type: "string", description: "The mail account address." },
        },
        description: "What the app shows for it. Set the title when you know it: Septena never fetches one. No message text.",
      },
    },
  },
} as const;

export const createTaskJsonSchema = {
  type: "object",
  required: ["title"],
  properties: {
    title: { type: "string", minLength: 1 },
    today: { type: "boolean", default: false },
    starred: { type: "boolean", default: false, description: "Optional simple Important / Star marker." },
    scheduled: { type: "string", description: "YYYY-MM-DD" },
    start_time: { type: "string", description: "Optional local start time HH:MM (24-hour)." },
    duration_minutes: { type: "integer", minimum: 5, maximum: 1440, description: "Optional duration in minutes (5..1440)." },
    time_zone: { type: "string", description: "Optional IANA time zone (omit for floating local time)." },
    deadline: { type: "string", description: "YYYY-MM-DD (hard deadline)" },
    area: { type: "string", description: "Area id (e.g. 'envisioning')" },
    project: { type: "string", description: "Project id (e.g. 'septena')" },
    notes: { type: "string", description: "Free-text note body for the task." },
    recurrence: recurrenceJsonSchema,
    reminder_at: {
      type: "string",
      description: "Optional timed alert. Wall-clock YYYY-MM-DDTHH:MM (floating, default) or UTC ISO-8601 YYYY-MM-DDTHH:MM:SSZ (fixed). Agent proposals do not arm OS alerts until accepted by the user.",
    },
    reminder_mode: {
      type: "string",
      enum: ["floating", "fixed"],
      description: "Timezone mode for reminder_at: floating (device local wall-clock, default) or fixed (exact UTC instant).",
    },
    checklist: {
      type: "array",
      items: { type: "string", minLength: 1 },
      description: "Optional 1-level checklist step titles created in order on the new task.",
    },
    tags: {
      type: "array",
      items: { type: "string", minLength: 1, maxLength: 64 },
      maxItems: 20,
      description: "Optional flat tag names (resolved case-insensitively to existing tags; missing tags are created).",
    },
    refs: {
      ...refsJsonSchema,
      description: "Optional references: the email, issue, event, page or task this task is about or was made from. Use role 'from' for the item you made it from.",
    },
    origin: {
      type: "string",
      enum: ["user_request", "agent_suggestion"],
      description:
        "Provenance. user_request = the user explicitly asked (lands committed, placed where specified). agent_suggestion = you surfaced it proactively (lands unratified in the inbox to review). Omit to use this connection's default (the gateway defaults to a proposal — secure by default).",
    },
  },
} as const;

export const completeTaskJsonSchema = {
  type: "object",
  required: ["id"],
  properties: { id: { type: "string" } },
} as const;

export const updateTaskJsonSchema = {
  type: "object",
  required: ["id"],
  properties: {
    id: { type: "string" },
    title: { type: "string" },
    today: {
      type: "boolean",
      description: "true puts the task on Today (a When date goes). false takes it off Today: with `scheduled` it moves to that day and keeps its deadline; alone it also clears a When date or deadline that has already arrived, as the app's Remove from Today does.",
    },
    starred: { type: "boolean", description: "Set or clear the Important / Star marker." },
    scheduled: { type: ["string", "null"], description: "YYYY-MM-DD, or null to clear" },
    start_time: { type: ["string", "null"], description: "Optional start time HH:MM (24-hour), or null to clear." },
    duration_minutes: { type: ["integer", "null"], minimum: 5, maximum: 1440, description: "Optional duration in minutes (5..1440), or null to clear." },
    time_zone: { type: ["string", "null"], description: "Optional IANA time zone, or null for floating local time." },
    deadline: { type: ["string", "null"], description: "YYYY-MM-DD, or null to clear" },
    area: { type: ["string", "null"] },
    project: { type: ["string", "null"] },
    status: { type: "string", enum: ["open", "cancelled"] },
    notes: { type: ["string", "null"], description: 'Replace the whole note body, or null/"" to clear. To add or change one part, use notes_append or notes_section instead, so you never overwrite edits made since your read.' },
    notes_append: { type: "string", minLength: 1, description: "Add this text on a new line at the end of the notes. Cannot be combined with notes or notes_section." },
    notes_section: {
      type: "object",
      required: ["heading", "body"],
      properties: {
        heading: { type: "string", minLength: 1, description: "The section heading, e.g. 'Decisions' (matches '## Decisions' or 'DECISIONS')." },
        body: { type: "string", description: "The new text under that heading. A missing heading is added at the end." },
      },
      description: "Replace the text under one heading of the notes, up to the next heading. Cannot be combined with notes or notes_append.",
    },
    notes_rev: { type: "string", description: "The notesRev from your last tasks_get. When the notes changed since, the update is refused with the current notes and rev." },
    recurrence: recurrenceJsonSchema,
    reminder_at: {
      type: ["string", "null"],
      description: "Optional timed alert (YYYY-MM-DDTHH:MM or YYYY-MM-DDTHH:MM:SSZ), or null to clear.",
    },
    reminder_mode: {
      type: ["string", "null"],
      enum: ["floating", "fixed", null],
      description: "Timezone mode for reminder_at: floating or fixed.",
    },
    tags: {
      type: ["array", "null"],
      items: { type: "string", minLength: 1, maxLength: 64 },
      maxItems: 20,
      description: "Replace the task's tags by name (case-insensitive; creates missing tags). Pass [] or null to clear.",
    },
    refs: { ...refsJsonSchema, description: "Add these references, or update role and snapshot of those the task has (matched by key). The others stay." },
    refs_remove: {
      type: "array",
      maxItems: 20,
      items: { type: "string", minLength: 1 },
      description: "Remove these references, by key, URL or message:// link.",
    },
  },
} as const;

export const deferTaskJsonSchema = {
  type: "object",
  required: ["id", "until"],
  properties: { id: { type: "string" }, until: { type: "string", description: "YYYY-MM-DD" } },
} as const;

export const moveToTodayJsonSchema = {
  type: "object",
  required: ["id"],
  properties: { id: { type: "string" } },
} as const;

export interface CreateTaskInput {
  title: string;
  today?: boolean;
  starred?: boolean;
  scheduled?: string;
  start_time?: string | null;
  startTime?: string | null;
  duration_minutes?: number | null;
  durationMinutes?: number | null;
  time_zone?: string | null;
  timeZone?: string | null;
  deadline?: string;
  /** Legacy alias for `deadline` — still accepted on input for back-compat. */
  due?: string;
  area?: string;
  project?: string;
  notes?: string;
  recurrence?: RecurrenceInput | null;
  reminder_at?: string | null;
  reminderAt?: string | null;
  reminder_mode?: ReminderMode | null;
  reminderMode?: ReminderMode | null;
  checklist?: string[];
  tags?: string[];
  refs?: RefInput[];
  /**
   * Provenance (docs/TASK_ROW_LANGUAGE_SPEC.md §3.4). `user_request` commits the
   * task (placed where specified); `agent_suggestion` (or omitted — the gateway's
   * secure-by-default) lands it as an unratified proposal in the triage inbox.
   */
  origin?: "user_request" | "agent_suggestion";
}

export interface UpdateTaskInput {
  id: string;
  title?: string;
  today?: boolean;
  starred?: boolean;
  scheduled?: string | null;
  start_time?: string | null;
  startTime?: string | null;
  duration_minutes?: number | null;
  durationMinutes?: number | null;
  time_zone?: string | null;
  timeZone?: string | null;
  deadline?: string | null;
  /** Legacy alias for `deadline` — still accepted on input for back-compat. */
  due?: string | null;
  area?: string | null;
  project?: string | null;
  status?: "open" | "cancelled";
  notes?: string | null;
  notes_append?: string;
  notes_section?: { heading: string; body: string };
  notes_rev?: string;
  recurrence?: RecurrenceInput | null;
  reminder_at?: string | null;
  reminderAt?: string | null;
  reminder_mode?: ReminderMode | null;
  reminderMode?: ReminderMode | null;
  tags?: string[] | null;
  refs?: RefInput[];
  refs_remove?: string[];
}

/** Wire form of a repeat rule. `afterCompletion` is accepted as an alias for
 *  `after_completion`: a model guessing the camelCase spelling would otherwise
 *  silently get the OPPOSITE anchor. */
export interface RecurrenceInput {
  unit?: string;
  interval?: number;
  after_completion?: boolean;
  afterCompletion?: boolean;
  weekdays?: number[] | null;
  month_day?: number | null;
  monthDay?: number | null;
  ordinal_weekday?: { ordinal: number; weekday: number } | null;
  ordinalWeekday?: { ordinal: number; weekday: number } | null;
}

/**
 * Decodes and validates a wire repeat rule. Throws rather than dropping a
 * malformed one: a repeat the caller believes it set, that silently never
 * landed, is the worst outcome here — the task just quietly stops coming back.
 *
 * `scheduled` is the date the task will have AFTER this call. A fixed rule
 * (`after_completion: false`) has nothing to anchor to without one and would
 * degrade into an after-completion rule, so it is rejected instead.
 *
 * LOCKSTEP: septena/SeptenaCore/MCP/MCPDispatch.swift `recurrenceArg`.
 */
export function parseRecurrenceInput(
  raw: RecurrenceInput | null | undefined,
  scheduled: string | null | undefined,
): RecurrenceRuleInput | null {
  if (raw === null) return null;          // explicit clear
  if (raw === undefined) return null;
  const unit = String(raw.unit ?? "");
  if (unit !== "day" && unit !== "week" && unit !== "month" && unit !== "year") {
    throw new Error("recurrence.unit must be one of: day, week, month, year");
  }
  const interval = raw.interval === undefined ? 1 : Number(raw.interval);
  if (!Number.isInteger(interval) || interval < 1) {
    throw new Error("recurrence.interval must be 1 or greater");
  }
  const afterCompletion = raw.after_completion ?? raw.afterCompletion ?? true;
  if (!afterCompletion && !scheduled) {
    throw new Error(
      "recurrence.after_completion=false anchors on the task's scheduled date, " +
        "so the task needs one. Set 'scheduled' in this same call, or use " +
        "after_completion=true to count from the completion day instead.",
    );
  }
  let weekdays: number[] | undefined;
  if (raw.weekdays && raw.weekdays.length > 0) {
    const clean = [...new Set(raw.weekdays.map(Number))];
    if (clean.some((w) => !Number.isInteger(w) || w < 1 || w > 7)) {
      throw new Error("recurrence.weekdays entries must be integers 1 (Sun) .. 7 (Sat)");
    }
    if (!afterCompletion && unit === "week") weekdays = clean.sort((a, b) => a - b);
  }
  const rawMonthDay = raw.month_day ?? raw.monthDay;
  const rawOrdinal = raw.ordinal_weekday ?? raw.ordinalWeekday;
  if (rawMonthDay != null && rawOrdinal != null) {
    throw new Error("recurrence.month_day and recurrence.ordinal_weekday are mutually exclusive");
  }
  let monthDay: number | undefined;
  if (rawMonthDay != null) {
    const md = Number(rawMonthDay);
    if (!Number.isInteger(md) || (md !== -1 && (md < 1 || md > 31))) {
      throw new Error("recurrence.month_day must be 1..31 or -1 (last day of month)");
    }
    if (!afterCompletion && (unit === "month" || unit === "year")) monthDay = md;
  }
  let ordinalWeekday: { ordinal: number; weekday: number } | undefined;
  if (rawOrdinal != null) {
    const ordinal = Number(rawOrdinal.ordinal);
    const weekday = Number(rawOrdinal.weekday);
    if (!Number.isInteger(ordinal) || (ordinal !== -1 && (ordinal < 1 || ordinal > 4))) {
      throw new Error("recurrence.ordinal_weekday.ordinal must be 1..4 or -1 (last)");
    }
    if (!Number.isInteger(weekday) || weekday < 1 || weekday > 7) {
      throw new Error("recurrence.ordinal_weekday.weekday must be 1 (Sun) .. 7 (Sat)");
    }
    if (!afterCompletion && (unit === "month" || unit === "year")) {
      ordinalWeekday = { ordinal, weekday };
    }
  }
  return { unit, interval, afterCompletion, weekdays, monthDay, ordinalWeekday };
}

export type RecurrenceRuleInput = {
  unit: string;
  interval: number;
  afterCompletion: boolean;
  weekdays?: number[];
  monthDay?: number;
  ordinalWeekday?: { ordinal: number; weekday: number };
};

/** The `recurrence` block a write echoes back: the same shape it accepts. */
export function recurrenceEcho(rule: RecurrenceRuleInput) {
  const out: {
    unit: string;
    interval: number;
    after_completion: boolean;
    weekdays?: number[];
    month_day?: number;
    ordinal_weekday?: { ordinal: number; weekday: number };
  } = { unit: rule.unit, interval: rule.interval, after_completion: rule.afterCompletion };
  if (rule.weekdays && rule.weekdays.length > 0) out.weekdays = rule.weekdays;
  if (rule.monthDay !== undefined) out.month_day = rule.monthDay;
  if (rule.ordinalWeekday) out.ordinal_weekday = rule.ordinalWeekday;
  return out;
}

export function parseReminderInput(
  rawAt: string | null | undefined,
  rawMode: ReminderMode | null | undefined,
): { reminderAt: string | null; reminderMode: ReminderMode | null } | undefined {
  if (rawAt === undefined) return undefined;
  if (rawAt === null || rawAt === "") return { reminderAt: null, reminderMode: null };
  const inferredMode: ReminderMode = rawMode ?? (/(?:Z|[+-]\d{2}:\d{2})$/.test(rawAt) ? "fixed" : "floating");
  if (inferredMode !== "floating" && inferredMode !== "fixed") {
    throw new Error("reminder_mode must be 'floating' or 'fixed'");
  }
  if (!isValidReminderAt(rawAt, inferredMode)) {
    throw new Error(
      inferredMode === "fixed"
        ? "reminder_at must be ISO-8601 UTC/offset (YYYY-MM-DDTHH:MM:SSZ) when reminder_mode='fixed'"
        : "reminder_at must be local wall-clock YYYY-MM-DDTHH:MM when reminder_mode='floating'",
    );
  }
  return { reminderAt: rawAt, reminderMode: inferredMode };
}

/**
 * The data-source-free part of `tasks_create`: the parsed rule, provenance
 * and the result echo. Throws on a bad rule, before anything is written.
 * Used by the task backend connector.
 */
export function planCreate(input: CreateTaskInput) {
  const rule = parseRecurrenceInput(input.recurrence, input.scheduled);
  const reminder = parseReminderInput(
    input.reminder_at !== undefined ? input.reminder_at : input.reminderAt,
    input.reminder_mode !== undefined ? input.reminder_mode : input.reminderMode,
  );
  // Provenance (docs/TASK_ROW_LANGUAGE_SPEC.md §3.4): only an explicit
  // `user_request` commits; anything else lands as a proposal.
  const committed = input.origin === "user_request";
  const placement: "committed" | "inbox_proposal" = committed ? "committed" : "inbox_proposal";
  const deadline = input.deadline ?? input.due;
  const startTime = (input.start_time !== undefined ? input.start_time : input.startTime) ?? null;
  const durationMinutes = (input.duration_minutes !== undefined ? input.duration_minutes : input.durationMinutes) ?? null;
  const timeZone = (input.time_zone !== undefined ? input.time_zone : input.timeZone) ?? null;
  const echo: Record<string, unknown> = {};
  if (rule) echo.recurrence = recurrenceEcho(rule);
  if (reminder?.reminderAt) {
    echo.reminder_at = reminder.reminderAt;
    echo.reminder_mode = reminder.reminderMode;
  }
  if (startTime) {
    echo.start_time = startTime;
    if (durationMinutes !== null) echo.duration_minutes = durationMinutes;
    if (timeZone) echo.time_zone = timeZone;
  }
  return { rule, reminder, committed, placement, deadline, startTime, durationMinutes, timeZone, echo };
}

/**
 * A `tasks_update` call as data-source-free field writes. `null` clears a
 * field; an absent key leaves it alone. `heading: null` is set when the task
 * moves to a new area/project. `recurrence` is the parsed rule (null clears).
 */
export interface TaskUpdatePlan {
  fields: {
    title?: string;
    today?: boolean;
    starred?: boolean;
    scheduled?: string | null;
    startTime?: string | null;
    durationMinutes?: number | null;
    timeZone?: string | null;
    deadline?: string | null;
    area?: string | null;
    project?: string | null;
    heading?: null;
    status?: "open" | "cancelled";
    notes?: string | null;
    recurrence?: RecurrenceRuleInput | null;
    reminderAt?: string | null;
    reminderMode?: ReminderMode | null;
  };
  updated: string[];
}

/// True when validating the call's repeat rule needs the task's stored
/// `scheduled` date: a fixed-anchor rule, with no `scheduled` in this call.
export function updateNeedsStoredSchedule(input: UpdateTaskInput): boolean {
  const wantsFixedAnchor =
    input.recurrence !== undefined &&
    input.recurrence !== null &&
    (input.recurrence.after_completion ?? input.recurrence.afterCompletion ?? true) === false;
  return wantsFixedAnchor && input.scheduled === undefined;
}

/**
 * The data-source-free part of `tasks_update`. `storedScheduled` is the
 * task's current `scheduled`, needed only when `updateNeedsStoredSchedule`.
 * Throws on a bad repeat rule. Used by the task
 * backend connector.
 */
export function planUpdate(input: UpdateTaskInput, storedScheduled?: string | null): TaskUpdatePlan {
  const f: TaskUpdatePlan["fields"] = {};
  const updated: string[] = [];
  if (input.title !== undefined) { f.title = input.title; updated.push("title"); }
  if (input.today !== undefined) { f.today = input.today; updated.push("today"); }
  if (input.starred !== undefined) { f.starred = input.starred; updated.push("starred"); }
  if (input.scheduled !== undefined) { f.scheduled = input.scheduled ?? null; updated.push("scheduled"); }
  const updStart = input.start_time !== undefined ? input.start_time : input.startTime;
  if (updStart !== undefined) {
    f.startTime = updStart === "" ? null : updStart;
    if (f.startTime === null) {
      f.durationMinutes = null;
      f.timeZone = null;
    }
    updated.push("start_time");
  }
  const updDur = input.duration_minutes !== undefined ? input.duration_minutes : input.durationMinutes;
  if (updDur !== undefined) {
    f.durationMinutes = updDur;
    updated.push("duration_minutes");
  }
  const updTz = input.time_zone !== undefined ? input.time_zone : input.timeZone;
  if (updTz !== undefined) {
    f.timeZone = updTz === "" ? null : updTz;
    updated.push("time_zone");
  }
  const updDeadline = input.deadline !== undefined ? input.deadline : input.due;
  if (updDeadline !== undefined) { f.deadline = updDeadline ?? null; updated.push("deadline"); }
  // Re-home clears BOTH the cross-field container AND any stale project section
  // FK (`heading`) — LOCKSTEP with the app's TasksBackend.moveToArea/
  // moveToProject (app repo docs/DRAG_AND_DROP.md §4).
  if (input.area !== undefined) {
    f.area = input.area ?? null;
    if (input.area) {
      f.project = null;
      f.heading = null;
    }
    updated.push("area");
  }
  if (input.project !== undefined) {
    f.project = input.project ?? null;
    if (input.project) {
      f.area = null;
      f.heading = null;
    }
    updated.push("project");
  }
  if (input.status !== undefined) { f.status = input.status; updated.push("status"); }
  if (input.notes !== undefined) { f.notes = input.notes ?? null; updated.push("notes"); }
  const rawRemAt = input.reminder_at !== undefined ? input.reminder_at : input.reminderAt;
  const rawRemMode = input.reminder_mode !== undefined ? input.reminder_mode : input.reminderMode;
  const parsedRem = parseReminderInput(rawRemAt, rawRemMode);
  if (parsedRem !== undefined) {
    f.reminderAt = parsedRem.reminderAt;
    f.reminderMode = parsedRem.reminderMode;
    updated.push("reminder_at");
  }
  // Recurrence last, so it validates against the schedule this call may have
  // just set. Present-with-null clears; absent leaves the rule alone.
  if (input.recurrence !== undefined) {
    const effectiveScheduled = input.scheduled !== undefined ? input.scheduled : storedScheduled;
    f.recurrence = parseRecurrenceInput(input.recurrence, effectiveScheduled);
    updated.push("recurrence");
  }
  return { fields: f, updated };
}

/// Tool-result warnings for a recurring completion whose series could not
/// advance. Shared wording for both connectors.
export const recurrenceWarning = {
  noNextDate: (id: string, unit: string) =>
    `Task ${id} is recurring (every ${unit}) but the next date could not be calculated, ` +
    `so no new occurrence was created. It was still marked done.`,
  createFailed: (id: string, next: string) =>
    `Task ${id} was marked done, but its next occurrence (due ${next}) could not be created. ` +
    `It will reappear when the task is next opened in the Septena app.`,
};

/// A confirm-step turn carrying a `chosen` also caches confirmedIntent in the
/// SAME write (richer `note` wins over the bare button label). Mirrors the app.
/// Undefined when the turn sets nothing. Shared with the task backend connector.
export function confirmedIntentFor(turn: Pick<ConvoTurn, "step" | "chosen" | "note">): string | undefined {
  if (turn.step === "confirm" && turn.chosen) return turn.note ?? turn.chosen;
  return undefined;
}

/// The stored artifact for a `tasks_set_artifact` call (kind defaults to
/// "note", body to ""). Shared with the task backend connector.
export function normalizeArtifact(a: { kind?: string; title: string; body?: string; refs?: string[] }): NonNullable<TaskConvo["artifact"]> {
  return { kind: a.kind ?? "note", title: a.title, body: a.body ?? "", refs: a.refs };
}

/// The stored handoff for a `tasks_set_handoff` call (actionType defaults to
/// "none"). Shared with the task backend connector.
export function normalizeHandoff(h: {
  instruction: string;
  actionType?: "open_url" | "compose" | "call" | "none";
  payload?: string;
}): NonNullable<TaskConvo["handoff"]> {
  return { instruction: h.instruction, actionType: h.actionType ?? "none", payload: h.payload };
}

export const threadGetJsonSchema = {
  type: "object",
  required: ["id"],
  properties: { id: { type: "string" } },
} as const;

export const threadAppendJsonSchema = {
  type: "object",
  required: ["id", "turn"],
  properties: {
    id: { type: "string" },
    turn: {
      type: "object",
      required: ["role", "step"],
      properties: {
        role: { type: "string", enum: ["user", "provider"] },
        step: { type: "string", enum: ["confirm", "ground", "scope", "decide", "work"] },
        provider: { type: "string", enum: ["onDevice", "claude", "applePCC"] },
        confidence: { type: "number" },
        question: { type: "string" },
        options: { type: "array", items: { type: "string" } },
        chosen: { type: "string" },
        otherText: { type: "string" },
        inReplyTo: { type: "integer" },
        note: { type: "string" },
      },
    },
  },
} as const;

export const setAcceptanceJsonSchema = {
  type: "object",
  required: ["id", "acceptance"],
  properties: { id: { type: "string" }, acceptance: { type: "string" } },
} as const;

export const setEndStateJsonSchema = {
  type: "object",
  required: ["id", "endState"],
  properties: {
    id: { type: "string" },
    endState: {
      type: "string",
      enum: ["agent_done", "human_done", "agent_assisted_done", "needs_verify", "decomposed", "reminder_set", "promoted_to_today", "wont_do", "open"],
    },
    note: { type: "string", description: "e.g. needs_verify: what to verify" },
  },
} as const;

export const setAssigneeJsonSchema = {
  type: "object",
  required: ["id", "assignee"],
  properties: {
    id: { type: "string" },
    assignee: { type: ["string", "null"], enum: ["me", "local", "claude"] },
  },
} as const;

export const pendingReasoningJsonSchema = {
  type: "object",
  properties: { limit: { type: "integer" } },
} as const;

export const getTaskJsonSchema = {
  type: "object",
  required: ["id"],
  properties: {
    id: { type: "string" },
    include_notes: { type: "boolean", description: "Also return the task's project and area notes with their noteRev. Default false." },
  },
} as const;

export const setArtifactJsonSchema = {
  type: "object",
  required: ["id", "artifact"],
  properties: {
    id: { type: "string" },
    artifact: {
      type: "object",
      required: ["title"],
      properties: {
        kind: { type: "string", description: "e.g. availability-table, draft-email, summary" },
        title: { type: "string" },
        body: { type: "string" },
        refs: { type: "array", items: { type: "string" } },
      },
    },
  },
} as const;

export const setHandoffJsonSchema = {
  type: "object",
  required: ["id", "handoff"],
  properties: {
    id: { type: "string" },
    handoff: {
      type: "object",
      required: ["instruction"],
      properties: {
        instruction: { type: "string" },
        actionType: { type: "string", enum: ["open_url", "compose", "call", "none"] },
        payload: { type: "string", description: "URL / email / phone for the action" },
      },
    },
  },
} as const;

export const checklistAddJsonSchema = {
  type: "object",
  required: ["task_id", "items"],
  properties: {
    task_id: { type: "string", description: "Owning task id." },
    items: {
      type: "array",
      minItems: 1,
      maxItems: 200,
      items: { type: "string", minLength: 1 },
      description: "Checklist step titles to append in order.",
    },
  },
} as const;

export const checklistUpdateJsonSchema = {
  type: "object",
  required: ["id"],
  properties: {
    id: { type: "string", description: "Checklist item id." },
    title: { type: "string", minLength: 1 },
    checked: { type: "boolean" },
    position: { type: "number" },
  },
} as const;

export const checklistDeleteJsonSchema = {
  type: "object",
  required: ["id"],
  properties: {
    id: { type: "string", description: "Checklist item id." },
  },
} as const;
