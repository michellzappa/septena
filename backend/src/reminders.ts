// Timed task reminder rules (docs/TIMED_REMINDERS_SPEC.md). The shift and
// arm rules are the shared core's (`reminders.rs`, ADR 0025 C3 #249),
// verified by `registry/conformance/reminders.json`. Only the wire-format
// check stays here: it validates input at the API boundary.

const FLOATING_RE = /^\d{4}-\d{2}-\d{2}T([01]\d|2[0-3]):[0-5]\d$/;
const FIXED_RE = /^\d{4}-\d{2}-\d{2}T([01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;

export { shiftReminderForRecurrence, shiftReminderOnReschedule, shouldArmReminder } from "./core/index.js";

export type ReminderMode = "floating" | "fixed";

export function isValidReminderAt(value: string, mode?: ReminderMode | null): boolean {
  if (mode === "fixed") return FIXED_RE.test(value);
  if (mode === "floating") return FLOATING_RE.test(value);
  return FLOATING_RE.test(value) || FIXED_RE.test(value);
}
