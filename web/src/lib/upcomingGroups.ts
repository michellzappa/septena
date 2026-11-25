import type { CoreMembership } from "./core";
import type { TaskRow } from "./types";

export interface UpcomingTaskEntry {
  task: TaskRow;
  membership: CoreMembership;
}

export interface UpcomingDateGroup<T extends UpcomingTaskEntry = UpcomingTaskEntry> {
  day: string;
  label: string;
  items: T[];
}

function parseIsoDay(iso: string): Date | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  if (!match) return null;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const date = new Date(year, month - 1, day);
  if (date.getFullYear() !== year || date.getMonth() !== month - 1 || date.getDate() !== day) {
    return null;
  }
  return date;
}

function dayDiff(todayIso: string, targetIso: string): number | null {
  const a = parseIsoDay(todayIso);
  const b = parseIsoDay(targetIso);
  if (!a || !b) return null;
  const utcA = Date.UTC(a.getFullYear(), a.getMonth(), a.getDate());
  const utcB = Date.UTC(b.getFullYear(), b.getMonth(), b.getDate());
  return Math.round((utcB - utcA) / 86_400_000);
}

/**
 * Formats an Upcoming day header matching Apple `SeptenaDate.scheduleHeaderLabel`
 * and Android `formatUpcomingDayHeader`: Today, Tomorrow, weekday name within 6 days,
 * else short weekday + month + day.
 */
export function formatUpcomingDayLabel(
  dayIso: string,
  todayIso: string,
  locale?: string,
): string {
  const target = parseIsoDay(dayIso);
  if (!target) return dayIso;
  const diff = dayDiff(todayIso, dayIso);
  if (diff === 0) return "Today";
  if (diff === 1) return "Tomorrow";
  if (diff !== null && diff >= 2 && diff < 7) {
    return new Intl.DateTimeFormat(locale, { weekday: "long" }).format(target);
  }
  const today = parseIsoDay(todayIso);
  const includeYear = today !== null && target.getFullYear() !== today.getFullYear();
  return new Intl.DateTimeFormat(locale, {
    weekday: "short",
    month: "short",
    day: "numeric",
    ...(includeYear ? { year: "numeric" } : {}),
  }).format(target);
}

/**
 * Groups Upcoming tasks by their shared-core `membership.upcomingDay` (`YYYY-MM-DD`),
 * sorted ascending by date and preserving intra-day position order.
 */
export function groupUpcomingByDate<T extends UpcomingTaskEntry>(
  tasks: T[],
  todayIso: string,
  locale?: string,
): UpcomingDateGroup<T>[] {
  const buckets = new Map<string, T[]>();
  for (const item of tasks) {
    const day = item.membership.upcomingDay;
    if (!day) continue;
    const list = buckets.get(day);
    if (list) list.push(item);
    else buckets.set(day, [item]);
  }
  return Array.from(buckets.keys())
    .sort((a, b) => a.localeCompare(b))
    .map((day) => ({
      day,
      label: formatUpcomingDayLabel(day, todayIso, locale),
      items: buckets.get(day)!,
    }));
}

export function nextIsoDay(todayIso: string): string {
  const d = parseIsoDay(todayIso);
  if (!d) return todayIso;
  d.setDate(d.getDate() + 1);
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}
