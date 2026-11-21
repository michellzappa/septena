// Timezone-aware date/time helpers.
//
// A Cloudflare Worker's clock is UTC. But the whole data model keys days on the
// user's LOCAL calendar date ("YYYY-MM-DD") and HH:MM, matching the iOS app
// (EventTimestamp uses TimeZone.current). So any "today" / "now" / "N days ago"
// the gateway computes must be in the user's timezone, not UTC — otherwise
// writes near local midnight land on the wrong day and default ranges are off
// by one. The effective tz is the `homeTimezone` setting the app syncs
// (src/shadow/mcp.ts effectiveTimeZone).

const DEFAULT_TZ = "UTC";

export function isValidTz(tz: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}

/** Wall-clock parts of instant `d` as seen in `tz`. */
function partsInTz(d: Date, tz: string): Record<string, string> {
  const dtf = new Intl.DateTimeFormat("en-US", {
    timeZone: tz,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  });
  const out: Record<string, string> = {};
  for (const p of dtf.formatToParts(d)) if (p.type !== "literal") out[p.type] = p.value;
  return out;
}

/** Today's local calendar date in `tz`, "YYYY-MM-DD". */
export function todayYMD(tz: string): string {
  const p = partsInTz(new Date(), tz);
  return `${p.year}-${p.month}-${p.day}`;
}

/** Current local time in `tz`, "HH:MM" (24h). */
export function nowHHMM(tz: string): string {
  const p = partsInTz(new Date(), tz);
  return `${p.hour}:${p.minute}`;
}

/** Current local time in `tz`, "HH:MM:SS" (24h). */
export function nowHHMMSS(tz: string): string {
  const p = partsInTz(new Date(), tz);
  return `${p.hour}:${p.minute}:${p.second}`;
}

/**
 * Local "HH:MM" (24h) of an instant given as UTC epoch milliseconds, in `tz`.
 * The inverse of `localToEpochMs` for display: used to derive an event's
 * wall-clock time from its `occurredAt` TIMESTAMP now that the legacy `time`
 * STRING field is no longer written.
 */
export function epochMsToHHMM(ms: number, tz: string): string {
  const p = partsInTz(new Date(ms), tz);
  return `${p.hour}:${p.minute}`;
}

/**
 * Calendar arithmetic on a "YYYY-MM-DD" string. DST-safe because it operates on
 * calendar fields via UTC, never on a wall-clock instant.
 */
export function addDaysYMD(ymd: string, n: number): string {
  const [y, m, d] = ymd.split("-").map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d));
  dt.setUTCDate(dt.getUTCDate() + n);
  const yy = dt.getUTCFullYear();
  const mm = String(dt.getUTCMonth() + 1).padStart(2, "0");
  const dd = String(dt.getUTCDate()).padStart(2, "0");
  return `${yy}-${mm}-${dd}`;
}

/** N local days before today in `tz`, "YYYY-MM-DD". */
export function ymdNDaysAgo(n: number, tz: string): string {
  return addDaysYMD(todayYMD(tz), -n);
}

/**
 * How far back an event-list tool reaches when the caller passes neither
 * `date` nor `from`/`to`. Inclusive of today, so 30 = today + the previous 29.
 *
 * Widening this costs no extra CloudKit work — `queryByDateRange` already
 * scans the full record set for the type and filters the window client-side
 * (see BACKLOG.md). The real budget is the model's context: a month of dense
 * rows (nutrition especially) is useful, a quarter mostly crowds it out.
 * Callers wanting more say so explicitly with `from`/`to`.
 *
 * MIRROR: MCPDispatch.defaultLookbackDays in ../septena-cloud.
 */
export const DEFAULT_LOOKBACK_DAYS = 30;

/** Start of the default lookback window in `tz`, "YYYY-MM-DD". */
export function defaultLookbackStart(tz: string): string {
  return ymdNDaysAgo(DEFAULT_LOOKBACK_DAYS - 1, tz);
}

/**
 * A local wall-clock (`ymd` + `hhmm`, in `tz`) → UTC epoch milliseconds.
 * Mirrors the app's EventTimestamp.from: combine date + time in local tz; when
 * no time is given default to local noon (not midnight) so a day-only event
 * survives tz shifts without slipping to the previous/next day. Used for the
 * `occurredAt` TIMESTAMP on event records.
 */
export function localToEpochMs(ymd: string, hhmm: string | undefined, tz: string): number {
  const [y, mo, d] = ymd.split("-").map(Number);
  const [h, mi] = (hhmm && hhmm.length >= 4 ? hhmm : "12:00").split(":").map(Number);
  // Treat the wall-clock as if it were UTC, then correct by the tz offset that
  // CloudKit/Intl reports for that instant. One pass is exact except within the
  // ~1h DST-transition gap, which is acceptable for a logged-event timestamp.
  const guess = Date.UTC(y, mo - 1, d, h || 0, mi || 0, 0);
  const p = partsInTz(new Date(guess), tz);
  const asUTC = Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute, +p.second);
  const offset = asUTC - guess;
  return guess - offset;
}

/**
 * Local "now" as "yyyy-MM-dd'T'HH:mm:ss" (no `Z`, no millis) in `tz`. Matches
 * the app's ckTimestampFormatter so STRING timestamp fields (e.g. Task
 * `completedAt`) compare/sort consistently with app-authored rows.
 */
export function localServerTimestamp(tz: string): string {
  const p = partsInTz(new Date(), tz);
  return `${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}:${p.second}`;
}
