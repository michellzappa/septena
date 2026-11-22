import { addDaysYMD, isValidTz } from "./tz.js";

// RFC 5545 read-only iCalendar (.ics) feed generator for Septena tasks
// (docs/TASK_TIMES_AND_ICAL_SPEC.md §3, issue #166).

export type IcalScope = "all" | "timed";

export interface IcalTask {
  id: string;
  title?: string | null;
  notes?: string | null;
  status?: string | null;
  kind?: string | null;
  scheduled?: string | null;
  startTime?: string | null;
  durationMinutes?: number | null;
  timeZone?: string | null;
  deadline?: string | null;
  rev?: number | null;
}

export interface BuildIcalFeedInput {
  tasks: IcalTask[];
  scope: IcalScope;
  today: string;
  nowIso: string;
  homeTimezone?: string | null;
}

const WINDOW_PAST_DAYS = 30;
const WINDOW_FUTURE_DAYS = 365;
const DEFAULT_TIMED_DURATION_MINUTES = 30;
const YMD_RE = /^\d{4}-\d{2}-\d{2}$/;
const HHMM_RE = /^([01]\d|2[0-3]):[0-5]\d$/;

function utf8ByteLength(ch: string): number {
  const cp = ch.codePointAt(0) ?? 0;
  if (cp < 0x80) return 1;
  if (cp < 0x800) return 2;
  if (cp < 0x10000) return 3;
  return 4;
}

/**
 * RFC 5545 §3.1 content line folding: at most 75 octets per physical line
 * (excluding CRLF), folding with CRLF + single SPACE without splitting
 * multi-byte UTF-8 sequences.
 */
export function foldIcalLine(line: string): string {
  let out = "";
  let chunk = "";
  let chunkBytes = 0;

  for (const ch of line) {
    const b = utf8ByteLength(ch);
    if (chunkBytes + b > 75 && chunk.length > 0) {
      out += (out.length > 0 ? "\r\n" : "") + chunk;
      chunk = " " + ch;
      chunkBytes = 1 + b;
    } else {
      chunk += ch;
      chunkBytes += b;
    }
  }
  if (chunk.length > 0 || out.length === 0) {
    out += (out.length > 0 ? "\r\n" : "") + chunk;
  }
  return out;
}

/** RFC 5545 §3.3.11 TEXT escaping (`\`, `;`, `,`, and line breaks). */
export function escapeIcalText(text: string): string {
  return text
    .replace(/\r\n/g, "\n")
    .replace(/\r/g, "\n")
    .replace(/\\/g, "\\\\")
    .replace(/;/g, "\\;")
    .replace(/,/g, "\\,")
    .replace(/\n/g, "\\n");
}

function isValidYMD(s: string | null | undefined): s is string {
  return typeof s === "string" && YMD_RE.test(s);
}

function isValidHHMM(s: string | null | undefined): s is string {
  return typeof s === "string" && HHMM_RE.test(s);
}

function ymdToBasic(ymd: string): string {
  return ymd.replace(/-/g, "");
}

function toIcalUtcStamp(iso: string): string {
  const d = new Date(iso);
  const dt = Number.isNaN(d.getTime()) ? new Date() : d;
  const yy = dt.getUTCFullYear();
  const mo = String(dt.getUTCMonth() + 1).padStart(2, "0");
  const da = String(dt.getUTCDate()).padStart(2, "0");
  const hh = String(dt.getUTCHours()).padStart(2, "0");
  const mi = String(dt.getUTCMinutes()).padStart(2, "0");
  const ss = String(dt.getUTCSeconds()).padStart(2, "0");
  return `${yy}${mo}${da}T${hh}${mi}${ss}Z`;
}

function computeTimedEnd(ymd: string, hhmm: string, durationMinutes: number): { ymd: string; hhmm: string } {
  const [h, m] = hhmm.split(":").map(Number);
  const total = h * 60 + m + durationMinutes;
  const dayOffset = Math.floor(total / 1440);
  const rem = total % 1440;
  const eh = String(Math.floor(rem / 60)).padStart(2, "0");
  const em = String(rem % 60).padStart(2, "0");
  return {
    ymd: dayOffset > 0 ? addDaysYMD(ymd, dayOffset) : ymd,
    hhmm: `${eh}:${em}`,
  };
}

export function icalEtag(rev: number, scope: IcalScope, today: string): string {
  return `W/"ical-${rev}-${scope}-${today}"`;
}

export function buildIcalFeed(input: BuildIcalFeedInput): string {
  const { tasks, scope, today, nowIso, homeTimezone } = input;
  const windowStart = addDaysYMD(today, -WINDOW_PAST_DAYS);
  const windowEnd = addDaysYMD(today, WINDOW_FUTURE_DAYS);
  const inWindow = (ymd: string) => ymd >= windowStart && ymd <= windowEnd;
  const dtStamp = toIcalUtcStamp(nowIso);

  const lines: string[] = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//Septena//Tasks//EN",
    "CALSCALE:GREGORIAN",
    "METHOD:PUBLISH",
    "X-WR-CALNAME:Septena Tasks",
  ];
  if (homeTimezone && isValidTz(homeTimezone)) {
    lines.push(`X-WR-TIMEZONE:${homeTimezone}`);
  }

  for (const task of tasks) {
    if (task.status !== "open") continue;
    if (task.kind === "heading") continue;

    const scheduled = isValidYMD(task.scheduled) && inWindow(task.scheduled) ? task.scheduled : null;
    const startTime = scheduled && isValidHHMM(task.startTime) ? task.startTime : null;
    const deadline = isValidYMD(task.deadline) && inWindow(task.deadline) ? task.deadline : null;

    if (scope === "timed" && !startTime) continue;

    const rawTitle = (task.title ?? "").trim() || "Untitled task";
    const notes = (task.notes ?? "").trim();
    const deepLink = `septask://task/${task.id}`;
    const description = notes ? `${notes}\n\n${deepLink}` : deepLink;
    const sequence = Math.max(0, Math.trunc(task.rev ?? 0));

    if (scheduled && startTime) {
      const duration =
        typeof task.durationMinutes === "number" &&
        Number.isFinite(task.durationMinutes) &&
        task.durationMinutes >= 5 &&
        task.durationMinutes <= 1440
          ? Math.trunc(task.durationMinutes)
          : DEFAULT_TIMED_DURATION_MINUTES;
      const end = computeTimedEnd(scheduled, startTime, duration);
      const tz = task.timeZone && isValidTz(task.timeZone) ? task.timeZone : null;
      const startStamp = `${ymdToBasic(scheduled)}T${startTime.replace(":", "")}00`;
      const endStamp = `${ymdToBasic(end.ymd)}T${end.hhmm.replace(":", "")}00`;

      lines.push(
        "BEGIN:VEVENT",
        `UID:${task.id}@septena.app`,
        `DTSTAMP:${dtStamp}`,
        `SEQUENCE:${sequence}`,
        tz ? `DTSTART;TZID=${tz}:${startStamp}` : `DTSTART:${startStamp}`,
        tz ? `DTEND;TZID=${tz}:${endStamp}` : `DTEND:${endStamp}`,
        `SUMMARY:${escapeIcalText(rawTitle)}`,
        `DESCRIPTION:${escapeIcalText(description)}`,
        `URL:${deepLink}`,
        "END:VEVENT",
      );
    } else if (scope === "all" && scheduled) {
      const sameDayDeadline = deadline === scheduled;
      const summary = sameDayDeadline ? `⚑ ${rawTitle}` : rawTitle;
      lines.push(
        "BEGIN:VEVENT",
        `UID:${task.id}@septena.app`,
        `DTSTAMP:${dtStamp}`,
        `SEQUENCE:${sequence}`,
        `DTSTART;VALUE=DATE:${ymdToBasic(scheduled)}`,
        `DTEND;VALUE=DATE:${ymdToBasic(addDaysYMD(scheduled, 1))}`,
        `SUMMARY:${escapeIcalText(summary)}`,
        `DESCRIPTION:${escapeIcalText(description)}`,
        `URL:${deepLink}`,
        "END:VEVENT",
      );
    }

    if (scope === "all" && deadline) {
      // If a date-only scheduled event already covers the exact same day, we merged the ⚑ prefix above.
      const mergedIntoScheduled = scheduled !== null && startTime === null && deadline === scheduled;
      if (!mergedIntoScheduled) {
        const uid = scheduled ? `${task.id}-deadline@septena.app` : `${task.id}@septena.app`;
        lines.push(
          "BEGIN:VEVENT",
          `UID:${uid}`,
          `DTSTAMP:${dtStamp}`,
          `SEQUENCE:${sequence}`,
          `DTSTART;VALUE=DATE:${ymdToBasic(deadline)}`,
          `DTEND;VALUE=DATE:${ymdToBasic(addDaysYMD(deadline, 1))}`,
          `SUMMARY:${escapeIcalText(`⚑ ${rawTitle}`)}`,
          `DESCRIPTION:${escapeIcalText(description)}`,
          `URL:${deepLink}`,
          "END:VEVENT",
        );
      }
    }
  }

  lines.push("END:VCALENDAR");
  return lines.map(foldIcalLine).join("\r\n") + "\r\n";
}
