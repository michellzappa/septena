// Timezone-aware date/time helpers.
//
// A Cloudflare Worker's clock is UTC. But the whole data model keys days on the
// user's LOCAL calendar date ("YYYY-MM-DD") and HH:MM, matching the iOS app
// (EventTimestamp uses TimeZone.current). So any "today" / "now" / "N days ago"
// the gateway computes must be in the user's timezone, not UTC — otherwise
// writes near local midnight land on the wrong day and default ranges are off
// by one. The effective tz comes from the user's Settings record.

import { getSettings } from "./tools/getSettings.js";
import { logEvent } from "./util.js";
import type { CloudKitClient } from "./cloudkit.js";

const DEFAULT_TZ = "UTC";

export function isValidTz(tz: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}

/**
 * Effective IANA timezone for the user: the travel tz when travel_mode is on
 * (and set), else the home tz, else UTC. Reads the `app` Settings record's
 * `time` block (home_timezone / travel_mode / travel_timezone).
 *
 * The UTC fallback is a correctness hazard, not a benign default: it silently
 * stamps every event in UTC and shifts default day-ranges. The iOS app now
 * publishes the device's `home_timezone` on launch, so a populated record is
 * the norm — any fallback means the user has never opened the app, or the
 * record is malformed. We emit `tz_fallback_utc` with a precise `reason` so
 * that's observable in `wrangler tail` instead of failing invisibly.
 */
export async function getEffectiveTimezone(client: CloudKitClient): Promise<string> {
  let reason = "no_settings_record";
  try {
    const { settings } = await getSettings(client);
    const time = (settings as Record<string, unknown> | undefined)?.time as
      | { home_timezone?: unknown; travel_mode?: unknown; travel_timezone?: unknown }
      | undefined;
    if (time && typeof time === "object") {
      const travel = typeof time.travel_timezone === "string" ? time.travel_timezone : "";
      if (time.travel_mode === "on" && travel && isValidTz(travel)) return travel;
      const home = typeof time.home_timezone === "string" ? time.home_timezone : "";
      if (home && isValidTz(home)) return home;
      reason = home ? "invalid_home_tz" : "no_home_tz";
    } else {
      reason = "no_time_block";
    }
  } catch {
    reason = "settings_error";
  }
  logEvent("tz_fallback_utc", { reason });
  return DEFAULT_TZ;
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
