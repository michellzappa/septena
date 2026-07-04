import { queryByDateRange, type CloudKitClient } from "../cloudkit.js";
import { getEffectiveTimezone, todayYMD, ymdNDaysAgo, nowHHMM, localToEpochMs, epochMsToHHMM } from "../tz.js";

const SHORTID_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789";
function newId(len = 6): string {
  const buf = new Uint8Array(len);
  crypto.getRandomValues(buf);
  return Array.from(buf, (b) => SHORTID_ALPHABET[b & 31]).join("");
}

function optStr(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

// ============================================================================
// Mood vocabulary — ported from SeptenaCore/MoodVocabulary.swift. MUST stay in
// lockstep: the canonical English word fixes the (quadrant, arousal, valence)
// triple, so an agent logs by word and the coordinates are derived. Words are
// ordered left→right then top→bottom: row 0 = arousal 3 (top), col 0 = valence
// 1 (left), so arousal = 3 - row, valence = col + 1.
// ============================================================================

const MOOD_WORDS: Record<string, string[]> = {
  hap: ["Excited",   "Elated",      "Ecstatic",
        "Eager",     "Upbeat",      "Joyful",
        "Focused",   "Alive",       "Content"],
  han: ["Enraged",   "Panicked",    "Stressed",
        "Angry",     "Anxious",     "Frustrated",
        "Irritated", "Tense",       "Restless"],
  lan: ["Bored",     "Discouraged", "Disappointed",
        "Sad",       "Lonely",      "Glum",
        "Drained",   "Hopeless",    "Despondent"],
  lap: ["Mellow",    "Easygoing",   "Pleased",
        "Calm",      "Grateful",    "Loved",
        "Relaxed",   "Serene",      "Tranquil"],
};
const MOOD_QUADRANTS = ["han", "hap", "lan", "lap"];

interface MoodCell { word: string; quadrant: string; arousal: number; valence: number }

function moodGrid(): MoodCell[] {
  const cells: MoodCell[] = [];
  for (const q of MOOD_QUADRANTS) {
    MOOD_WORDS[q].forEach((word, idx) => {
      cells.push({ word, quadrant: q, arousal: 3 - Math.floor(idx / 3), valence: (idx % 3) + 1 });
    });
  }
  return cells;
}

export const ALL_MOOD_WORDS = moodGrid().map((c) => c.word);

function resolveEmotion(word: string): MoodCell {
  const needle = word.trim().toLowerCase();
  const hit = moodGrid().find((c) => c.word.toLowerCase() === needle);
  if (!hit) throw new Error(`unknown emotion '${word}'. Valid: ${ALL_MOOD_WORDS.join(", ")}`);
  return hit;
}

// Daypart bucket — mirrors DayBucket (SeptenaCore/DayBucket.swift): morning
// hour < 12, afternoon hour < 17, else evening.
function moodBucket(time: string): string {
  const hour = parseInt(time.slice(0, 2), 10) || 0;
  if (hour < 12) return "morning";
  if (hour < 17) return "afternoon";
  return "evening";
}

// ---- JSON Schemas ----

export const listMoodEventsJsonSchema = {
  type: "object",
  properties: {
    date:  { type: "string", description: "YYYY-MM-DD filter. Omit to return the last 7 days." },
    from:  { type: "string", description: "YYYY-MM-DD range start (inclusive). Ignored if date is set." },
    to:    { type: "string", description: "YYYY-MM-DD range end (inclusive). Defaults to today." },
    limit: { type: "integer", minimum: 1, maximum: 500, default: 100 },
  },
} as const;

export const logMoodEventJsonSchema = {
  type: "object",
  required: ["emotion"],
  properties: {
    date:    { type: "string", description: "YYYY-MM-DD. Defaults to today." },
    time:    { type: "string", description: "HH:MM. Defaults to now (sets the morning/afternoon/evening bucket)." },
    emotion: { type: "string", enum: ALL_MOOD_WORDS, description: "Canonical emotion word (matched case-insensitively). Its quadrant/arousal/valence are derived." },
    note:    { type: "string" },
  },
} as const;

// ---- Types ----

export interface ListMoodEventsInput { date?: string; from?: string; to?: string; limit?: number }
export interface LogMoodEventInput { date?: string; time?: string; emotion: string; note?: string }

// ---- Implementations ----

export async function listMoodEvents(client: CloudKitClient, input: ListMoodEventsInput) {
  const tz = await getEffectiveTimezone(client);
  const from = input.date ?? input.from ?? ymdNDaysAgo(6, tz);
  const to   = input.date ?? input.to   ?? todayYMD(tz);

  const records = await queryByDateRange(client, {
    recordType: "MoodEvent",
    from,
    to,
    instantField: "occurredAt",
    resultsLimit: input.limit ?? 100,
  });

  const events = records.map((r) => ({
    id:       r.recordName.replace(/^mood-event:/, ""),
    date:     optStr(r.fields.date?.value) ?? "",
    time:     optStr(r.fields.time?.value) ?? (typeof r.fields.occurredAt?.value === "number" ? epochMsToHHMM(r.fields.occurredAt.value as number, tz) : ""),
    bucket:   optStr(r.fields.bucket?.value),
    quadrant: optStr(r.fields.quadrant?.value),
    arousal:  (r.fields.arousal?.value as number) ?? 0,
    valence:  (r.fields.valence?.value as number) ?? 0,
    emotion:  optStr(r.fields.emotion?.value),
    note:     optStr(r.fields.note?.value),
  }));

  return { events };
}

export async function logMoodEvent(client: CloudKitClient, input: LogMoodEventInput) {
  const cell = resolveEmotion(input.emotion);
  const tz = await getEffectiveTimezone(client);
  const id = newId(6);
  const date = input.date ?? todayYMD(tz);
  const time = input.time ?? nowHHMM(tz);
  const fields: Record<string, { value: unknown }> = {
    date:     { value: date },
    bucket:   { value: moodBucket(time) },
    quadrant: { value: cell.quadrant },
    arousal:  { value: cell.arousal },
    valence:  { value: cell.valence },
    emotion:  { value: cell.word },
    // canonical instant; legacy `time` STRING retired (derive from occurredAt).
    occurredAt: { value: localToEpochMs(date, time, tz) },
  };
  if (input.note) fields.note = { value: input.note };

  const { droppedFields } = await client.createWithFieldFallback({
    recordType: "MoodEvent",
    recordName: `mood-event:${id}`,
    fields,
    protectedFields: ["date", "quadrant", "arousal", "valence", "emotion"],
  });

  const out = { id, date, time, emotion: cell.word, quadrant: cell.quadrant, arousal: cell.arousal, valence: cell.valence };
  return droppedFields.length > 0 ? { ...out, droppedFields } : out;
}
