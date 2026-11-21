import { z } from "zod";
import { isValidTz } from "../tz.js";

// Column specs for the task backend (docs/SEPTASK_BACKEND.md in the app repo,
// §5). ONE table per entity, and this file is the single source of truth for
// its columns: the DDL, the push validation and the pull decoding all derive
// from it, so they cannot drift.

type Kind = "text" | "int" | "real" | "bool" | "json";

export interface Column {
  kind: Kind;
  zod: z.ZodTypeAny;
  /// Default written on insert when the push omits the field.
  dflt?: string | number | null;
}

const ID_RE = /^[A-Za-z0-9._:-]{1,128}$/;
export const zId = z.string().regex(ID_RE, "invalid id");

const text = (max = 2_000): Column => ({ kind: "text", zod: z.string().max(max).nullable() });
const int = (): Column => ({ kind: "int", zod: z.number().int().nullable() });
const real = (): Column => ({ kind: "real", zod: z.number().finite().nullable() });
const bool = (dflt = 0): Column => ({ kind: "bool", zod: z.boolean(), dflt });
const json = (schema: z.ZodTypeAny): Column => ({ kind: "json", zod: schema.nullable() });

const NOTES_MAX = 100_000;
const zDay = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "expected YYYY-MM-DD").nullable();
const day = (): Column => ({ kind: "text", zod: zDay });
// ISO-8601 instant. The app's existing `completedAt` string shape
// (yyyy-MM-dd'T'HH:mm:ss, no zone) also passes.
const zStamp = z.string().regex(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, "expected ISO time").max(40).nullable();
const stamp = (): Column => ({ kind: "text", zod: zStamp });

// `AreaAttachment` — opaque here; the app owns its shape. Size-capped only.
const zAttachmentPointer = z.record(z.unknown()).refine(
  (v) => JSON.stringify(v).length <= 4_000,
  "attachment pointer too large",
);

// Synced app settings (Septask), one row per key in the `settings` table:
// `id` = the key, `value` = its JSON value (null = not set). Only these keys
// are accepted, each with its own schema, so validation stays as strict as a
// typed column. A new setting is a new line here: no table change. Settings
// are never deleted (a tombstone would drop every later write, §6.4); a
// cleared setting is `value: null`. Device-only preferences never come here.
export const SETTING_VALUES = {
  /// Profile name (Settings ▸ Account).
  welcomeName: z.string().max(200),
  /// Analytics level (`TelemetryClient.TelemetryLevel`).
  telemetryLevel: z.enum(["none", "minimal", "balanced", "full"]),
  /// Calendars hidden from Today / Upcoming, by `EKCalendar.title`.
  calendarHiddenTitles: z.array(z.string().max(500)).max(500),
  /// The day the "rolled into Today" notice was last dismissed.
  rolledInDismissedOn: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "expected YYYY-MM-DD"),
  /// IANA zone of the device that last opened the app. The MCP connector
  /// reads it for "today".
  homeTimezone: z.string().max(64).refine(isValidTz, "unknown time zone"),
  /// "Pause all agents" (docs/TASK_FACTORY_SPEC.md §10). While true, no
  /// agent claim succeeds and the agent queue reads as empty.
  agentsPaused: z.boolean(),
} satisfies Record<string, z.ZodTypeAny>;

export type SettingKey = keyof typeof SETTING_VALUES;
export const SETTING_KEYS = Object.keys(SETTING_VALUES) as SettingKey[];

export const MAX_ATTACHMENT_BYTES = 25 * 1024 * 1024;
export const MAX_USER_ATTACHMENT_BYTES = 2 * 1024 * 1024 * 1024;

export interface EntitySpec {
  table: string;
  columns: Record<string, Column>;
  /// Fields a push must carry when the row does not exist yet.
  requiredOnInsert: string[];
  /// When set, only these fields may change after insert.
  updatable?: string[];
}

export const ENTITIES = {
  task: {
    table: "tasks",
    columns: {
      title: text(),
      status: text(32),
      kind: text(32),
      heading: { kind: "text", zod: zId.nullable() },
      area: { kind: "text", zod: zId.nullable() },
      project: { kind: "text", zod: zId.nullable() },
      created: day(),
      scheduled: day(),
      deadline: day(),
      today: bool(),
      todaySetOn: day(),
      completedAt: stamp(),
      notes: text(NOTES_MAX),
      // Manual order inside the task's own list (Inbox, area, project).
      position: real(),
      // Manual order on Today, kept apart from `position` so reordering Today
      // never reshuffles the home list (Things' model). Null until the row is
      // first ordered on Today; readers fall back to `position`.
      todayPosition: real(),
      recurrenceUnit: text(16),
      recurrenceInterval: int(),
      recurrenceAfterCompletion: bool(),
      recurrencePaused: bool(),
      recurrenceSeriesID: text(128),
      recurrenceAnchorDate: day(),
      source: text(64),
      sourceClient: text(64),
      acknowledgedAt: stamp(),
      createdAt: stamp(),
      // Task fade user signals (docs/TASK_FADE_SPEC.md §3, ADR 0006).
      touchedAt: stamp(),
      deferCount: { kind: "int", zod: z.number().int().min(0), dflt: 0 },
      fadedAt: stamp(),
      dropReason: { kind: "text", zod: z.enum(["faded", "user"]).nullable() },
      effort: { kind: "text", zod: z.enum(["light", "heavy"]).nullable() },
    },
    requiredOnInsert: ["title", "status"],
  },
  area: {
    table: "areas",
    columns: {
      title: text(),
      context: text(NOTES_MAX),
      emoji: text(16),
      attachment: json(zAttachmentPointer),
      position: int(),
    },
    requiredOnInsert: ["title"],
  },
  project: {
    table: "projects",
    columns: {
      title: text(),
      status: text(32),
      area: { kind: "text", zod: zId.nullable() },
      created: day(),
      completedAt: stamp(),
      notes: text(NOTES_MAX),
      context: text(NOTES_MAX),
      githubRepo: text(200),
      attachment: json(zAttachmentPointer),
      position: int(),
    },
    requiredOnInsert: ["title", "status"],
  },
  attachment: {
    table: "attachments",
    columns: {
      taskId: { kind: "text", zod: zId },
      filename: text(512),
      contentType: text(200),
      byteCount: { kind: "int", zod: z.number().int().min(0).max(MAX_ATTACHMENT_BYTES) },
      position: real(),
      createdAt: stamp(),
      // Set by the server when the bytes land in R2, never by a push.
      uploadedAt: { kind: "text", zod: z.never() },
    },
    requiredOnInsert: ["taskId", "filename", "contentType", "byteCount"],
    // Bytes are bound to taskId/byteCount/contentType at upload; only the
    // display fields may change after that.
    updatable: ["filename", "position"],
  },
  // The non-turn half of `TaskConvo` (SeptenaCore/TaskConvo.swift), keyed by
  // the task id. Turns are their own append-only table (§5.3).
  convo: {
    table: "convos",
    columns: {
      confirmedIntent: text(NOTES_MAX),
      acceptance: text(NOTES_MAX),
      subtasks: json(z.array(zId).max(500)),
      artifact: json(z.object({
        kind: z.string().max(64),
        title: z.string().max(2_000),
        body: z.string().max(NOTES_MAX),
        refs: z.array(z.string().max(2_000)).max(100).optional(),
      })),
      handoff: json(z.object({
        instruction: z.string().max(2_000),
        actionType: z.enum(["open_url", "compose", "call", "none"]),
        payload: z.string().max(2_000).optional(),
      })),
      endState: text(32),
      endStateNote: text(NOTES_MAX),
      assignee: { kind: "text", zod: z.enum(["me", "local", "claude"]).nullable() },
      // The human's stop on agent work for this task. Only an app actor may
      // set or clear it (TaskStore.apply refuses an agent write), so an agent
      // cannot restart itself. While set, agent writes to the task fail.
      stoppedAt: stamp(),
      // The agent claim (docs/TASK_FACTORY_SPEC.md §5). Server-owned: set
      // only by TaskStore.claim / release, never by a push.
      claimedBy: { kind: "text", zod: z.never() },
      claimUntil: { kind: "text", zod: z.never() },
      // Fresh claims since the human last wrote a turn. The run budget: at
      // AGENT_RUN_BUDGET the agent must ask before it may claim again.
      runsSinceUser: { kind: "int", zod: z.never() },
    },
    requiredOnInsert: [],
  },
  // One row per `SETTING_VALUES` key. The push schema for this entity is
  // built from `SETTING_VALUES` (ops.ts), not from this column's `zod`, so
  // each key keeps its own type.
  setting: {
    table: "settings",
    columns: {
      value: { kind: "json", zod: z.unknown() },
    },
    requiredOnInsert: [],
  },
} satisfies Record<string, EntitySpec>;

export type EntityName = keyof typeof ENTITIES;
export const ENTITY_NAMES = Object.keys(ENTITIES) as EntityName[];

/// Fields a push may set (server-owned columns excluded).
export function pushableFields(spec: EntitySpec): Record<string, z.ZodTypeAny> {
  const out: Record<string, z.ZodTypeAny> = {};
  for (const [name, col] of Object.entries(spec.columns)) {
    if (col.zod instanceof z.ZodNever) continue;
    out[name] = col.zod;
  }
  return out;
}

function sqlType(kind: Kind): string {
  switch (kind) {
    case "int":
    case "bool":
      return "INTEGER";
    case "real":
      return "REAL";
    default:
      return "TEXT";
  }
}

export function createTableSQL(spec: EntitySpec): string {
  const cols = Object.entries(spec.columns).map(([name, col]) => {
    const d = col.dflt === undefined ? "" : ` DEFAULT ${typeof col.dflt === "string" ? `'${col.dflt}'` : col.dflt}`;
    return `"${name}" ${sqlType(col.kind)}${d}`;
  });
  return `CREATE TABLE IF NOT EXISTS ${spec.table} (
    id TEXT PRIMARY KEY,
    ${cols.join(",\n    ")},
    rev INTEGER NOT NULL,
    updatedAt TEXT NOT NULL,
    deletedAt TEXT
  );
  CREATE INDEX IF NOT EXISTS ${spec.table}_rev ON ${spec.table}(rev);`;
}

/// Columns a table created by an older deploy is missing. Columns are only
/// ever added (never renamed or dropped), so `ALTER TABLE ADD COLUMN` brings
/// any older table up to date.
export function addMissingColumnsSQL(spec: EntitySpec, existing: Set<string>): string[] {
  return Object.entries(spec.columns)
    .filter(([name]) => !existing.has(name))
    .map(([name, col]) => {
      const d = col.dflt === undefined ? "" : ` DEFAULT ${typeof col.dflt === "string" ? `'${col.dflt}'` : col.dflt}`;
      return `ALTER TABLE ${spec.table} ADD COLUMN "${name}" ${sqlType(col.kind)}${d}`;
    });
}

export function encodeValue(col: Column, v: unknown): string | number | null {
  if (v === null || v === undefined) return null;
  switch (col.kind) {
    case "bool":
      return v ? 1 : 0;
    case "json":
      return JSON.stringify(v);
    default:
      return v as string | number;
  }
}

export function decodeRow(spec: EntitySpec, row: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = { id: row.id, rev: row.rev, updatedAt: row.updatedAt };
  if (row.deletedAt) {
    out.deletedAt = row.deletedAt;
    return out;
  }
  for (const [name, col] of Object.entries(spec.columns)) {
    const v = row[name];
    if (v === null || v === undefined) {
      out[name] = col.kind === "bool" ? false : (col.dflt ?? null);
    } else if (col.kind === "bool") {
      out[name] = v === 1;
    } else if (col.kind === "json") {
      out[name] = JSON.parse(v as string);
    } else {
      out[name] = v;
    }
  }
  return out;
}
