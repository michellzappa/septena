"use client";

import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import {
  Calendar,
  ChevronLeft,
  ChevronRight,
  CircleX,
  Clock,
  Flag,
  Repeat,
  Sunrise,
  type LucideIcon,
} from "lucide-react";
import {
  DATE_BOARD_FOCUSES_ON_OPEN,
  DEFAULT_START_TIME,
  QUICK_DURATIONS,
  addDays,
  addMonths,
  attributeLabel,
  attributeLucide,
  calendarValueLabel,
  dateBoardRows,
  dayNumber,
  dayValueLabel,
  formatDayLong,
  formatMonth,
  formatWeekday,
  isWeekend,
  monthGrid,
  stripDays,
  todayLabel,
  type DateBoardAttribute,
} from "@/lib/dateBoard";
import { registryText } from "@/lib/generated/registries";
import { useEscapeToClose } from "@/lib/useEscapeToClose";

/** The Lucide names that the date rows and pills use in `registry/icons.json`. */
const LUCIDE: Record<string, LucideIcon> = {
  calendar: Calendar,
  clock: Clock,
  flag: Flag,
  repeat: Repeat,
  sunrise: Sunrise,
  "x-circle": CircleX,
};

const BOARD_WIDTH = 348;
const VIEWPORT_MARGIN = 16;

/** The rect that the popover hangs from. */
export interface DateBoardAnchor {
  left: number;
  top: number;
  bottom: number;
}

export interface DateBoardProps {
  attribute: DateBoardAttribute;
  /** The day the board shows as chosen, or null for none. */
  value: string | null;
  today: string;
  lang: string;
  startTime?: string | null;
  durationMinutes?: number | null;
  /** When only: the Repeat row's title. The row hides without a handler. */
  repeatTitle?: string;
  onPick: (day: string) => void;
  onClear: () => void;
  onRepeat?: () => void;
  /** When only. The Add time row hides without a handler. */
  onTimeSlotChange?: (startTime: string | null, durationMinutes: number | null) => void;
}

interface DateBoardPopoverProps extends DateBoardProps {
  anchor: DateBoardAnchor;
  onClose: () => void;
}

/**
 * The When and Deadline picker: a seven-day strip that starts today, then one
 * list of same-style rows from the registry. The twin of `KitDateBoard` (Mac),
 * `TaskDateBoard` (iPhone, iPad) and `TaskDateBoard.kt` (Android).
 *
 * The keyboard walks one axis, as on the Mac: Right and Down step later, Left
 * and Up step earlier, through the days and then down the rows. Enter picks,
 * Escape closes. With the month open, the arrows move its date.
 */
export function DateBoardPopover(props: DateBoardPopoverProps) {
  const { attribute, value, today, lang, anchor, onPick, onClear, onRepeat, onTimeSlotChange, onClose } = props;
  const days = useMemo(() => stripDays(today), [today]);
  const beyondStrip = value !== null && !days.includes(value);
  const [timeOpen, setTimeOpen] = useState(Boolean(props.startTime));
  const [calendarDay, setCalendarDay] = useState<string | null>(null);
  // Escape closes the month calendar first, then the board.
  useEscapeToClose(true, () => (calendarDay ? setCalendarDay(null) : onClose()));

  const rows = useMemo(
    () =>
      dateBoardRows(attribute, lang).filter((row) => {
        if (row.kind === "repeatRule") return Boolean(onRepeat);
        if (row.kind === "time") return Boolean(onTimeSlotChange);
        return true;
      }),
    [attribute, lang, onRepeat, onTimeSlotChange],
  );
  // The open time controls replace the Add time row, so it takes no focus.
  const focusRows = rows.filter((row) => !(row.kind === "time" && timeOpen));
  const cellCount = days.length + focusRows.length;

  // The first arrow key focuses the cell that holds the task's value, else Today.
  const startFocus = (() => {
    if (value !== null && days.includes(value)) return days.indexOf(value);
    if (!beyondStrip) return 0;
    return days.length + Math.max(0, focusRows.findIndex((row) => row.kind === "calendar"));
  })();
  // null while no cell is focused: the board opens that way, so a cell that
  // only holds the task's value never reads as the keyboard highlight.
  const [focus, setFocus] = useState<number | null>(() => (DATE_BOARD_FOCUSES_ON_OPEN ? startFocus : null));

  const boardRef = useRef<HTMLDivElement | null>(null);
  const [position, setPosition] = useState<{ left: number; top: number } | null>(null);

  // Below the anchor, or above it when the board does not fit below.
  useLayoutEffect(() => {
    const place = () => {
      const board = boardRef.current;
      if (!board) return;
      const { offsetWidth, offsetHeight } = board;
      const maxLeft = window.innerWidth - offsetWidth - VIEWPORT_MARGIN;
      const maxTop = window.innerHeight - offsetHeight - VIEWPORT_MARGIN;
      const below = anchor.bottom + 6;
      const top = below <= maxTop ? below : anchor.top - offsetHeight - 6;
      setPosition({
        left: Math.max(VIEWPORT_MARGIN, Math.min(anchor.left, maxLeft)),
        top: Math.max(VIEWPORT_MARGIN, Math.min(top, maxTop)),
      });
    };
    place();
    window.addEventListener("resize", place);
    return () => window.removeEventListener("resize", place);
  }, [anchor, calendarDay, timeOpen]);

  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null;
    boardRef.current?.focus({ preventScroll: true });
    return () => previous?.focus?.({ preventScroll: true });
  }, []);

  const pick = (day: string) => {
    onPick(day);
    onClose();
  };

  const activate = (row: (typeof rows)[number]) => {
    switch (row.kind) {
      case "calendar":
        setCalendarDay((open) => (open ? null : (value ?? today)));
        break;
      case "clear":
        onClear();
        onClose();
        break;
      case "repeatRule":
        onClose();
        onRepeat?.();
        break;
      case "time":
        setTimeOpen(true);
        onTimeSlotChange?.(DEFAULT_START_TIME, props.durationMinutes ?? null);
        break;
    }
  };

  const onKey = (e: KeyboardEvent) => {
    // The app and the surface under the board bind the same keys, so no key
    // leaves the board.
    e.stopPropagation();
    // The time field, the duration pills and the month buttons keep their keys.
    if (e.target instanceof Element && e.target.closest("[data-date-board-control]")) return;
    const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[e.key];
    if (step !== undefined) {
      e.preventDefault();
      if (calendarDay) {
        const vertical = e.key === "ArrowUp" || e.key === "ArrowDown";
        setCalendarDay(addDays(calendarDay, vertical ? step * 7 : step));
      } else {
        setFocus((i) => (i === null ? startFocus : Math.max(0, Math.min(cellCount - 1, i + step))));
      }
    } else if (e.key === "Enter") {
      e.preventDefault();
      if (calendarDay) pick(calendarDay);
      else if (focus === null) return;
      else if (focus < days.length) pick(days[focus]);
      else if (focusRows[focus - days.length]) activate(focusRows[focus - days.length]);
    }
  };

  // Capture on the window runs before every other key handler on the page.
  const onKeyRef = useRef(onKey);
  onKeyRef.current = onKey;
  useEffect(() => {
    const handler = (e: KeyboardEvent) => onKeyRef.current(e);
    window.addEventListener("keydown", handler, true);
    return () => window.removeEventListener("keydown", handler, true);
  }, []);

  return createPortal(
    // The portal's events still bubble to the React parent, which closes or
    // selects on a click.
    <div
      className="fixed inset-0 z-[60]"
      onClick={(e) => {
        e.stopPropagation();
        onClose();
      }}
      onContextMenu={(e) => {
        e.preventDefault();
        e.stopPropagation();
        onClose();
      }}
    >
      <div
        ref={boardRef}
        role="dialog"
        aria-label={attributeLabel(attribute, lang)}
        tabIndex={-1}
        onClick={(e) => e.stopPropagation()}
        style={{
          left: position?.left ?? anchor.left,
          top: position?.top ?? anchor.bottom,
          width: BOARD_WIDTH,
          visibility: position ? "visible" : "hidden",
        }}
        className="absolute max-h-[calc(100vh-32px)] max-w-[calc(100vw-32px)] overflow-y-auto rounded-xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)] p-2.5 text-sm shadow-xl outline-none"
      >
        <div className="grid grid-cols-7 gap-1">
          {days.map((day, i) => {
            const isCurrent = day === value;
            return (
              <button
                key={day}
                type="button"
                tabIndex={-1}
                aria-label={formatDayLong(day, lang)}
                aria-pressed={isCurrent}
                onMouseEnter={() => setFocus(i)}
                onClick={() => pick(day)}
                className={`flex min-w-0 flex-col items-center gap-0.5 rounded-[10px] py-2 ${cellGround(
                  focus === i && !calendarDay,
                  isCurrent || isWeekend(day),
                )}`}
              >
                <span
                  className={`max-w-full truncate text-[11px] ${
                    isCurrent ? "text-[var(--accent)]" : "text-[var(--text-muted)]"
                  }`}
                >
                  {i === 0 ? todayLabel(lang) : formatWeekday(day, lang)}
                </span>
                <span
                  className={`text-base tabular-nums ${
                    isCurrent ? "font-semibold text-[var(--accent)]" : "text-[var(--text-primary)]"
                  }`}
                >
                  {dayNumber(day)}
                </span>
              </button>
            );
          })}
        </div>

        {rows.map((row, i) => {
          // The strip opens the first group; a divider goes where the group changes.
          const divider = row.group !== (i === 0 ? "pick" : rows[i - 1].group);
          const rule = divider && <div className="my-1.5 border-t border-[var(--border-subtle)]" />;
          if (row.kind === "time" && timeOpen) {
            return (
              <div key={row.id}>
                {rule}
                <TimeControls
                  lang={lang}
                  lucide={row.lucide}
                  startTime={props.startTime ?? DEFAULT_START_TIME}
                  durationMinutes={props.durationMinutes ?? null}
                  onChange={(start, duration) => onTimeSlotChange?.(start, duration)}
                  onClear={() => {
                    setTimeOpen(false);
                    onTimeSlotChange?.(null, null);
                  }}
                />
              </div>
            );
          }
          const index = days.length + focusRows.indexOf(row);
          const named = row.kind === "calendar" && beyondStrip && value !== null;
          let label = row.label;
          if (named) label = calendarValueLabel(value, lang);
          else if (row.kind === "repeatRule") label = props.repeatTitle ?? row.label;
          return (
            <div key={row.id}>
              {rule}
              <button
                type="button"
                tabIndex={-1}
                aria-pressed={named || undefined}
                aria-expanded={row.kind === "calendar" ? Boolean(calendarDay) : undefined}
                onMouseEnter={() => setFocus(index)}
                onClick={() => activate(row)}
                className={`flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left ${cellGround(
                  focus === index && !calendarDay,
                  named,
                )}`}
              >
                <RowIcon lucide={row.lucide} />
                <span className="min-w-0 flex-1 truncate text-[var(--text-primary)]">{label}</span>
              </button>
              {row.kind === "calendar" && calendarDay && (
                <MonthCalendar
                  day={calendarDay}
                  value={value}
                  today={today}
                  lang={lang}
                  onMove={setCalendarDay}
                  onPick={pick}
                />
              )}
            </div>
          );
        })}
      </div>
    </div>,
    document.body,
  );
}

/** One highlight language: the selection wash for focus and hover, a neutral ground for the rest. */
function cellGround(focused: boolean, neutral: boolean): string {
  if (focused) return "bg-[var(--bg-selected)]";
  return neutral ? "bg-[var(--bg-hover)]" : "";
}

function RowIcon({ lucide }: { lucide: string }) {
  const Icon = LUCIDE[lucide];
  return (
    <span className="flex w-[22px] shrink-0 justify-center text-[var(--text-secondary)]">
      {Icon && <Icon className="h-4 w-4" />}
    </span>
  );
}

function MonthCalendar({
  day,
  value,
  today,
  lang,
  onMove,
  onPick,
}: {
  day: string;
  value: string | null;
  today: string;
  lang: string;
  onMove: (day: string) => void;
  onPick: (day: string) => void;
}) {
  const grid = monthGrid(day, lang);
  const month = day.slice(0, 7);
  const previous = addMonths(month, -1);
  const next = addMonths(month, 1);
  const pageButton =
    "rounded-md p-1 text-[var(--text-secondary)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]";
  return (
    <div className="px-1 pt-1 pb-2">
      <div className="flex items-center justify-between px-1 pb-1">
        <span className="text-xs font-semibold text-[var(--text-primary)]">{formatMonth(day, lang)}</span>
        <span className="flex gap-1">
          <button
            type="button"
            data-date-board-control
            aria-label={formatMonth(previous, lang)}
            onClick={() => onMove(previous)}
            className={pageButton}
          >
            <ChevronLeft className="h-4 w-4" />
          </button>
          <button
            type="button"
            data-date-board-control
            aria-label={formatMonth(next, lang)}
            onClick={() => onMove(next)}
            className={pageButton}
          >
            <ChevronRight className="h-4 w-4" />
          </button>
        </span>
      </div>
      <div className="grid grid-cols-7 gap-0.5 text-center">
        {grid.slice(0, 7).map((d) => (
          <span key={d} className="truncate py-1 text-[10px] text-[var(--text-muted)]">
            {formatWeekday(d, lang)}
          </span>
        ))}
        {grid.map((d) => {
          const isCurrent = d === value;
          const ink =
            isCurrent || d === today
              ? "text-[var(--accent)]"
              : d.startsWith(month)
                ? "text-[var(--text-primary)]"
                : "text-[var(--text-muted)]";
          return (
            <button
              key={d}
              type="button"
              tabIndex={-1}
              aria-label={formatDayLong(d, lang)}
              aria-pressed={isCurrent}
              onClick={() => onPick(d)}
              className={`rounded-lg py-1.5 text-xs tabular-nums hover:bg-[var(--bg-selected)] ${ink} ${
                isCurrent ? "font-semibold" : ""
              } ${cellGround(d === day, isCurrent)}`}
            >
              {dayNumber(d)}
            </button>
          );
        })}
      </div>
    </div>
  );
}

function TimeControls({
  lang,
  lucide,
  startTime,
  durationMinutes,
  onChange,
  onClear,
}: {
  lang: string;
  lucide: string;
  startTime: string;
  durationMinutes: number | null;
  onChange: (startTime: string, durationMinutes: number | null) => void;
  onClear: () => void;
}) {
  return (
    <div data-date-board-control className="px-2.5 py-2">
      <div className="flex items-center gap-2.5">
        <RowIcon lucide={lucide} />
        <span className="flex-1 text-[var(--text-primary)]">{registryText("Time", lang)}</span>
        <input
          type="time"
          aria-label={registryText("Time", lang)}
          value={startTime}
          // An empty field is a half-typed time. Clear is the only way to remove it.
          onChange={(e) => e.target.value && onChange(e.target.value, durationMinutes)}
          className="font-mono-tabular rounded-lg bg-[var(--bg-hover)] px-2 py-1 text-xs text-[var(--text-primary)] outline-none"
        />
        <button
          type="button"
          onClick={onClear}
          className="rounded-md px-1.5 py-1 text-xs text-[var(--text-muted)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
        >
          {registryText("Clear", lang)}
        </button>
      </div>
      <div className="mt-2 flex gap-1.5 pl-8">
        {QUICK_DURATIONS.map((preset) => {
          const isOn = durationMinutes === preset.minutes;
          return (
            <button
              key={preset.minutes}
              type="button"
              aria-pressed={isOn}
              onClick={() => onChange(startTime, isOn ? null : preset.minutes)}
              className={`rounded-full border px-2.5 py-0.5 text-xs ${
                isOn
                  ? "border-transparent bg-[var(--bg-selected)] font-medium text-[var(--text-primary)]"
                  : "border-[var(--border-subtle)] text-[var(--text-secondary)] hover:bg-[var(--bg-hover)]"
              }`}
            >
              {preset.label}
            </button>
          );
        })}
      </div>
    </div>
  );
}

/** A When or Deadline pill: the attribute, its value, and the board on click. */
export function DateBoardButton({
  red = false,
  className = "px-2.5 py-1",
  ...board
}: DateBoardProps & { red?: boolean; className?: string }) {
  const [anchor, setAnchor] = useState<DateBoardAnchor | null>(null);
  const { attribute, value, today, lang, startTime } = board;
  const Icon = LUCIDE[attributeLucide(attribute)];
  return (
    <>
      <button
        type="button"
        aria-haspopup="dialog"
        aria-expanded={anchor !== null}
        onClick={(e) => setAnchor(anchorOf(e.currentTarget))}
        className={`inline-flex items-center gap-1.5 rounded-lg bg-[var(--bg-hover)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] ${className}`}
      >
        {Icon && <Icon className="h-3.5 w-3.5" />}
        <span>{attributeLabel(attribute, lang)}</span>
        {value && (
          <span className={red ? "text-[var(--overdue-red)]" : "text-[var(--text-primary)]"}>
            {dayValueLabel(value, today, lang)}
          </span>
        )}
        {startTime && <span className="font-mono-tabular text-[var(--text-primary)]">{startTime}</span>}
      </button>
      {anchor && <DateBoardPopover {...board} anchor={anchor} onClose={() => setAnchor(null)} />}
    </>
  );
}

export function anchorOf(element: Element): DateBoardAnchor {
  const { left, top, bottom } = element.getBoundingClientRect();
  return { left, top, bottom };
}
