import {
  ACTIONS_CATALOG,
  DESTINATIONS,
  ICONS,
  SURFACES_CATALOG,
  registryText,
} from "@/lib/generated/registries";

/** Which attribute the board edits. The registry picks the rows for it. */
export type DateBoardAttribute = "when" | "deadline";

export type DateBoardRowKind = "calendar" | "time" | "repeatRule" | "clear";

/** The row groups, in order. The day strip opens "pick"; a divider separates groups. */
export type DateBoardGroup = "pick" | "refine" | "remove";

export interface DateBoardRow {
  id: string;
  kind: DateBoardRowKind;
  group: DateBoardGroup;
  label: string;
  /** The Lucide name of the row's registry icon. */
  lucide: string;
}

interface RegistryRow {
  id: string;
  kind: DateBoardRowKind;
  group: DateBoardGroup;
  label?: string;
  valueLabel?: string;
  action?: string;
  attributeLabels?: ReadonlyArray<{ attribute: string; label: string }>;
  icon: string;
  attributes: readonly string[];
}

/** Today and the next six days: the same window as the Apple and Android strips. */
const STRIP_DAYS = 7;

/** The first value of "Add time" and the duration presets (`TaskTimeSlot` on Apple and Android). */
export const DEFAULT_START_TIME = "09:00";
export const QUICK_DURATIONS = [
  { minutes: 15, label: "15m" },
  { minutes: 30, label: "30m" },
  { minutes: 60, label: "1h" },
  { minutes: 120, label: "2h" },
] as const;

const registryRows = SURFACES_CATALOG.taskDateBoard.rows as unknown as readonly RegistryRow[];
const icons = ICONS as unknown as Record<string, { lucide: string }>;
const actionTitles = ACTIONS_CATALOG.actions as unknown as Record<string, { title: string }>;

/**
 * True when the board opens with its start cell focused (`taskDateBoard.openFocus`).
 * False: no cell is focused until the first arrow key or the pointer (#847).
 */
export const DATE_BOARD_FOCUSES_ON_OPEN =
  (SURFACES_CATALOG.taskDateBoard as unknown as { openFocus: string }).openFocus === "currentValue";

/** The rows under the day strip, in registry order (`surfaces.json` `taskDateBoard.rows`). */
export function dateBoardRows(attribute: DateBoardAttribute, lang: string): DateBoardRow[] {
  return registryRows
    .filter((r) => r.attributes.includes(attribute))
    .map((r) => {
      const key =
        r.attributeLabels?.find((l) => l.attribute === attribute)?.label ??
        r.label ??
        actionTitles[r.action ?? ""]?.title ??
        "";
      return { id: r.id, kind: r.kind, group: r.group, label: registryText(key, lang), lucide: icons[r.icon]?.lucide ?? "" };
    });
}

export function attributeLabel(id: string, lang: string): string {
  return registryText(SURFACES_CATALOG.taskAttributes.find((a) => a.id === id)?.label ?? id, lang);
}

export function attributeLucide(id: string): string {
  const icon = SURFACES_CATALOG.taskAttributes.find((a) => a.id === id)?.icon;
  return (icon && icons[icon]?.lucide) || "";
}

export function todayLabel(lang: string): string {
  return registryText(DESTINATIONS.find((d) => d.id === "today")?.title ?? "Today", lang);
}

export function tomorrowLabel(lang: string): string {
  return registryText(SURFACES_CATALOG.taskDateBoard.tomorrow.label, lang);
}

/** The calendar row's label when it names a value past the strip. */
export function calendarValueLabel(day: string, lang: string): string {
  const key = registryRows.find((r) => r.kind === "calendar")?.valueLabel ?? "{date}";
  return registryText(key, lang, { date: formatDay(day, lang) });
}

// Days are `YYYY-MM-DD`. All arithmetic runs in UTC, so a DST change never
// moves a day.

function utcDate(day: string): Date {
  const [y, m, d] = day.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d));
}

function toDay(date: Date): string {
  return date.toISOString().slice(0, 10);
}

export function addDays(day: string, count: number): string {
  const date = utcDate(day);
  date.setUTCDate(date.getUTCDate() + count);
  return toDay(date);
}

export function addMonths(month: string, count: number): string {
  const [y, m] = month.split("-").map(Number);
  return toDay(new Date(Date.UTC(y, m - 1 + count, 1)));
}

export function stripDays(today: string): string[] {
  return Array.from({ length: STRIP_DAYS }, (_, i) => addDays(today, i));
}

export function isWeekend(day: string): boolean {
  const weekday = utcDate(day).getUTCDay();
  return weekday === 0 || weekday === 6;
}

/** The browser's own locale when it matches the app language, for its region's date order. */
function dateLocale(lang: string): string {
  if (typeof navigator === "undefined") return lang;
  return navigator.language.split("-")[0] === lang.split("-")[0] ? navigator.language : lang;
}

function format(day: string, lang: string, options: Intl.DateTimeFormatOptions): string {
  return new Intl.DateTimeFormat(dateLocale(lang), { ...options, timeZone: "UTC" }).format(utcDate(day));
}

export function formatDay(day: string, lang: string): string {
  return format(day, lang, { weekday: "short", month: "short", day: "numeric" });
}

export function formatDayLong(day: string, lang: string): string {
  return format(day, lang, { weekday: "long", month: "long", day: "numeric", year: "numeric" });
}

export function formatWeekday(day: string, lang: string): string {
  return format(day, lang, { weekday: "short" });
}

export function formatMonth(day: string, lang: string): string {
  return format(day, lang, { month: "long", year: "numeric" });
}

export function dayNumber(day: string): number {
  return utcDate(day).getUTCDate();
}

/** A pill's value: Today, Tomorrow, or the date. */
export function dayValueLabel(day: string, today: string, lang: string): string {
  if (day === today) return todayLabel(lang);
  if (day === addDays(today, 1)) return tomorrowLabel(lang);
  return formatDay(day, lang);
}

/** The first weekday of the locale: 1 is Monday, 7 is Sunday. */
function firstWeekday(lang: string): number {
  try {
    const locale = new Intl.Locale(dateLocale(lang)) as Intl.Locale & {
      getWeekInfo?: () => { firstDay: number };
      weekInfo?: { firstDay: number };
    };
    return locale.getWeekInfo?.().firstDay ?? locale.weekInfo?.firstDay ?? 1;
  } catch {
    return 1;
  }
}

/** The days of the weeks that hold `month` (any day in it), from the locale's first weekday. */
export function monthGrid(month: string, lang: string): string[] {
  const first = `${month.slice(0, 7)}-01`;
  const lead = (utcDate(first).getUTCDay() - (firstWeekday(lang) % 7) + 7) % 7;
  const start = addDays(first, -lead);
  const monthDays = dayNumber(addDays(addMonths(first, 1), -1));
  return Array.from({ length: Math.ceil((lead + monthDays) / 7) * 7 }, (_, i) => addDays(start, i));
}
