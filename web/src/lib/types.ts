import { z } from "zod";

// Boundary schemas and types for the Septena web client (WEB_CLIENT_SPEC.md).

export const zDeviceStartResponse = z.object({
  code: z.string(),
  pollSecret: z.string(),
  expiresIn: z.number(),
  interval: z.number(),
  qr: z.object({
    size: z.number().int().positive(),
    modules: z.string(),
  }),
});
export type DeviceStartResponse = z.infer<typeof zDeviceStartResponse>;

export const zSessionResponse = z.object({
  accessToken: z.string(),
  expiresIn: z.number(),
  userId: z.string(),
});
export type SessionResponse = z.infer<typeof zSessionResponse>;

export const zWsTicketResponse = z.object({
  ticket: z.string(),
  expiresIn: z.number(),
});
export type WsTicketResponse = z.infer<typeof zWsTicketResponse>;

export const zPullResponse = z.object({
  resetRequired: z.literal(true).optional(),
  changes: z.array(
    z.object({
      entity: z.string(),
      row: z.record(z.string(), z.unknown()),
    }),
  ),
  nextSince: z.number().int().min(0),
  hasMore: z.boolean(),
});
export type PullResponse = z.infer<typeof zPullResponse>;

export const zOpResult = z.discriminatedUnion("status", [
  z.object({ clientOpId: z.string(), status: z.literal("applied"), rev: z.number(), seq: z.number().optional() }),
  z.object({ clientOpId: z.string(), status: z.literal("noop") }),
  z.object({ clientOpId: z.string(), status: z.literal("dropped"), rev: z.number(), reason: z.literal("deleted") }),
  z.object({
    clientOpId: z.string(),
    status: z.literal("rejected"),
    reason: z.string(),
    rule: z.string().optional(),
  }),
]);
export type OpResult = z.infer<typeof zOpResult>;

export const zPushResponse = z.object({
  appliedThrough: z.number(),
  results: z.array(zOpResult),
});
export type PushResponse = z.infer<typeof zPushResponse>;

export interface TaskRow {
  id: string;
  title: string;
  status: "open" | "done" | "cancelled" | string;
  kind?: string | null;
  heading?: string | null;
  area?: string | null;
  project?: string | null;
  created?: string | null;
  createdAt?: string | null;
  scheduled?: string | null;
  startTime?: string | null;
  durationMinutes?: number | null;
  timeZone?: string | null;
  deadline?: string | null;
  deferredDeadline?: string | null;
  today?: boolean;
  starred?: boolean;
  tags?: string[] | null;
  todaySetOn?: string | null;
  completedAt?: string | null;
  notes?: string | null;
  position?: number | null;
  todayPosition?: number | null;
  recurrenceUnit?: string | null;
  recurrenceInterval?: number | null;
  recurrenceAfterCompletion?: boolean | null;
  recurrenceAnchorDate?: string | null;
  reminderAt?: string | null;
  reminderSnoozedUntil?: string | null;
  reminderDismissedAt?: string | null;
  source?: string | null;
  sourceClient?: string | null;
  acknowledgedAt?: string | null;
  touchedAt?: string | null;
  fadedAt?: string | null;
  deletedAt?: string | null;
  updatedAt?: string | null;
  rev?: number;
  [key: string]: unknown;
}

export interface AreaRow {
  id: string;
  title: string;
  context?: string | null;
  emoji?: string | null;
  position?: number | null;
  deletedAt?: string | null;
  rev?: number;
  [key: string]: unknown;
}

export interface ProjectRow {
  id: string;
  title: string;
  status: "active" | "done" | "cancelled" | string;
  area?: string | null;
  notes?: string | null;
  position?: number | null;
  deletedAt?: string | null;
  rev?: number;
  [key: string]: unknown;
}

export interface SettingRow {
  id: string;
  value: unknown;
  rev?: number;
}

export type OutboxOp =
  | {
      clientOpId: string;
      op: "upsert";
      entity: "task" | "area" | "project" | "setting";
      id: string;
      fields: Record<string, unknown>;
      queuedAt: number;
    }
  | {
      clientOpId: string;
      op: "delete";
      entity: "task" | "area" | "project";
      id: string;
      queuedAt: number;
    };

export interface NotSyncedItem {
  clientOpId: string;
  entity: string;
  id: string;
  reason: string;
  at: number;
}

export interface StoreSnapshot {
  tasks: TaskRow[];
  areas: AreaRow[];
  projects: ProjectRow[];
  settings: Record<string, unknown>;
  outbox: OutboxOp[];
  cursor: number;
  userId: string | null;
  lastSyncedAt: number | null;
}

export type SmartDestination = "today" | "upcoming" | "anytime" | "logbook";

export type ActiveDestination =
  | { kind: "smart"; id: SmartDestination }
  | { kind: "area"; id: string }
  | { kind: "project"; id: string };

// Fruit accents from registry/tokens.json.
export const FRUIT_ACCENTS: Record<string, { light: string; dark: string; name: string }> = {
  colorful: { light: "#007AFF", dark: "#0A84FF", name: "Colorful" },
  tamarillo: { light: "#D6333F", dark: "#FF5C67", name: "Tamarillo" },
  persimmon: { light: "#E05212", dark: "#FF7738", name: "Persimmon" },
  yuzu: { light: "#C28500", dark: "#F2BF2C", name: "Yuzu" },
  carambola: { light: "#5B8C00", dark: "#9EE034", name: "Carambola" },
  haskap: { light: "#1D63DC", dark: "#4E94FF", name: "Haskap" },
  acai: { light: "#6544D6", dark: "#9B82FF", name: "Açaí" },
  pitaya: { light: "#D4266C", dark: "#FF5C9B", name: "Pitaya" },
  jabuticaba: { light: "#27272E", dark: "#E4E4EA", name: "Jabuticaba" },
};
