// Recurrence arithmetic — LOCKSTEP with the app's
// `RecurrenceDateCalculator` (septena/SeptenaCore/DateParser.swift) and
// `Recurrence.occurrenceID`.
//
// Both surfaces can now complete a recurring task, and both derive the next
// occurrence's record name from (source task id + next scheduled date). That
// deterministic id is the ONLY thing stopping a phone completion and a chat
// completion of the same task from creating two records instead of converging
// on one — so if these two implementations ever disagree about the date, they
// disagree about the id, and the convergence silently stops working.
//
// This is therefore a literal port, including the month-overflow clamping and
// the catch-up loop. Change it only alongside the Swift original.

interface CivilDate {
  y: number;
  m: number; // 1-based
  d: number;
}

function parseYMD(ymd: string): CivilDate | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})/.exec(ymd);
  if (!match) return null;
  const y = Number(match[1]);
  const m = Number(match[2]);
  const d = Number(match[3]);
  if (m < 1 || m > 12 || d < 1 || d > 31) return null;
  return { y, m, d };
}

function formatYMD(p: CivilDate): string {
  const y = String(p.y).padStart(4, "0");
  const m = String(p.m).padStart(2, "0");
  const d = String(p.d).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

/** Day 0 of month `m` (1-based) is the last day of that month. */
function daysInMonth(y: number, m: number): number {
  return new Date(Date.UTC(y, m, 0)).getUTCDate();
}

function addDays(p: CivilDate, n: number): CivilDate {
  const t = new Date(Date.UTC(p.y, p.m - 1, p.d) + n * 86_400_000);
  return { y: t.getUTCFullYear(), m: t.getUTCMonth() + 1, d: t.getUTCDate() };
}

// Swift's Calendar clamps a month overflow (Jan 31 + 1 month = Feb 28/29).
// Plain JS `setMonth` rolls over into the following month instead (Mar 3), so
// the clamp is explicit here.
//
// `keepMonthEnd` mirrors the Swift `advance(_:by:_:_:keepMonthEnd:)` parameter.
// Clamping ALONE makes a fixed monthly rule decay: Jan 31 clamps to Feb 28, the
// next occurrence re-anchors on that stored date, and the series then walks
// Mar 28 → Apr 28 and never returns to month-end. Snapping a last-day-of-month
// anchor to the target month's last day keeps the chain stable
// (Jan 31 → Feb 28 → Mar 31 → Apr 30).
function addMonths(p: CivilDate, n: number, keepMonthEnd: boolean): CivilDate {
  const total = p.y * 12 + (p.m - 1) + n;
  const y = Math.floor(total / 12);
  const m = ((total % 12) + 12) % 12 + 1;
  const dim = daysInMonth(y, m);
  if (keepMonthEnd && p.d === daysInMonth(p.y, p.m)) return { y, m, d: dim };
  return { y, m, d: Math.min(p.d, dim) };
}

function toComparable(p: CivilDate): number {
  return Date.UTC(p.y, p.m - 1, p.d);
}

export interface RecurrenceRule {
  unit: string; // "day" | "week" | "month"
  interval: number; // 1+
  afterCompletion: boolean;
}

/**
 * The next scheduled date for a recurring task that was just completed, or
 * null when the rule can't produce one (unrecognized unit, unparseable date).
 *
 * `afterCompletion` picks the anchor: true counts from the completion date
 * ("every 3 days after I do it"), false counts from the task's own schedule
 * and then advances until it lands strictly past the completion date so a
 * series that fell behind catches up in one step rather than emitting a date
 * already in the past.
 */
export function nextScheduledDate(input: {
  completedOn: string;
  scheduled?: string | null;
  /** The series' logical slot (`recurrenceAnchorDate`) when this occurrence
   *  was moved as a one-off exception. A fixed rule advances from it, not
   *  from the shown date. Swift's `logicalScheduled ?? scheduled`. */
  logicalScheduled?: string | null;
  rule: RecurrenceRule;
}): string | null {
  const completed = parseYMD(input.completedOn);
  if (!completed) return null;

  const fixedAnchor = input.logicalScheduled ?? input.scheduled;
  const scheduled = fixedAnchor ? parseYMD(fixedAnchor) : null;
  const anchor = input.rule.afterCompletion ? completed : (scheduled ?? completed);
  const step = Math.max(1, input.rule.interval);

  // Month-end is preserved only on a FIXED schedule, where the anchor is the
  // previous scheduled date and the error compounds. An after-completion rule
  // anchors on whatever day the box was ticked, so snapping there would invent
  // a month-end intent the user never expressed. LOCKSTEP with Swift.
  const keepMonthEnd = !input.rule.afterCompletion;

  const advance = (p: CivilDate): CivilDate | null => {
    switch (input.rule.unit) {
      case "day":
        return addDays(p, step);
      case "week":
        return addDays(p, step * 7);
      case "month":
        return addMonths(p, step, keepMonthEnd);
      default:
        return null;
    }
  };

  let next = advance(anchor);
  if (!next) return null;

  if (!input.rule.afterCompletion) {
    const completedAt = toComparable(completed);
    // Bounded so a pathological rule can't spin a Worker request.
    for (let guard = 0; toComparable(next) <= completedAt; guard++) {
      if (guard > 10_000) return null;
      const advanced = advance(next);
      if (!advanced) return null;
      next = advanced;
    }
  }

  return formatYMD(next);
}

/**
 * Deterministic record name for a generated occurrence: FNV-1a 64 over
 * "<sourceTaskID>|<scheduled>", formatted exactly as the Swift side does
 * (`recur-` + 16 lowercase hex digits).
 */
export function occurrenceID(sourceTaskID: string, scheduled: string): string {
  const MASK = (1n << 64n) - 1n;
  let hash = 14695981039346656037n;
  for (const byte of new TextEncoder().encode(`${sourceTaskID}|${scheduled}`)) {
    hash = (hash ^ BigInt(byte)) & MASK;
    hash = (hash * 1099511628211n) & MASK;
  }
  return `recur-${hash.toString(16).padStart(16, "0")}`;
}
