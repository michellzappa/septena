import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

const HUMAN_ACTOR = "app:mac-test";
let seq = 0;
const opId = (prefix = "icalop") => `${prefix}_${++seq}_${Date.now()}`;

describe("Private read-only iCal feed (IC1 #166)", () => {
  it("folds lines at 75 octets without splitting multi-byte UTF-8 characters", async () => {
    const { foldIcalLine } = await import("../src/ical.ts");

    const ascii = "SUMMARY:" + "A".repeat(160);
    const foldedAscii = foldIcalLine(ascii);
    for (const part of foldedAscii.split("\r\n")) {
      assert.ok(Buffer.byteLength(part, "utf8") <= 75, `line exceeded 75 octets: ${Buffer.byteLength(part, "utf8")}`);
    }
    assert.equal(foldedAscii.replace(/\r\n /g, ""), ascii);

    // 4-byte emoji + 3-byte CJK near the 75-octet boundary
    const utf8Line = "SUMMARY:" + "🚀".repeat(25) + "予定を確認する".repeat(10);
    const foldedUtf8 = foldIcalLine(utf8Line);
    for (const part of foldedUtf8.split("\r\n")) {
      assert.ok(Buffer.byteLength(part, "utf8") <= 75, `UTF-8 line exceeded 75 octets: ${Buffer.byteLength(part, "utf8")}`);
      // Ensure valid UTF-8 (no replacement chars / half surrogate)
      assert.equal(Buffer.from(part, "utf8").toString("utf8"), part);
    }
    assert.equal(foldedUtf8.replace(/\r\n /g, ""), utf8Line);
  });

  it("escapes RFC 5545 TEXT fields and uses CRLF everywhere", async () => {
    const { escapeIcalText, buildIcalFeed } = await import("../src/ical.ts");

    assert.equal(escapeIcalText("A, B; C\\D\r\nLine 2\nLine 3"), "A\\, B\\; C\\\\D\\nLine 2\\nLine 3");

    const ics = buildIcalFeed({
      scope: "all",
      today: "2026-11-22",
      nowIso: "2026-11-22T12:00:00Z",
      homeTimezone: "Europe/Berlin",
      tasks: [
        {
          id: "t-escape",
          title: "Meet Alice, Bob; check C:\\plan",
          notes: "Line one\nLine two, with; punctuation",
          status: "open",
          scheduled: "2026-11-23",
          rev: 7,
        },
      ],
    });

    assert.ok(ics.endsWith("\r\n"));
    // No bare LF anywhere
    assert.equal(ics.replace(/\r\n/g, "").includes("\n"), false);
    const unfolded = ics.replace(/\r\n /g, "");
    assert.ok(unfolded.includes("X-WR-TIMEZONE:Europe/Berlin\r\n"));
    assert.ok(unfolded.includes("SUMMARY:Meet Alice\\, Bob\\; check C:\\\\plan\r\n"));
    assert.ok(
      unfolded.includes(
        "DESCRIPTION:Line one\\nLine two\\, with\\; punctuation\\n\\nseptask://task/t-escape\r\n",
      ),
    );
    assert.ok(unfolded.includes("SEQUENCE:7\r\n"));
  });

  it("maps timed tasks (floating, TZID, default 30m, midnight rollover), all-day, deadlines, scope, and date window", async () => {
    const { buildIcalFeed, icalEtag } = await import("../src/ical.ts");

    const tasks = [
      // Timed with explicit duration + TZID
      {
        id: "t-timed-tz",
        title: "Dentist",
        notes: "Bring card",
        status: "open",
        scheduled: "2026-11-25",
        startTime: "14:00",
        durationMinutes: 60,
        timeZone: "Europe/Berlin",
        rev: 3,
      },
      // Timed crossing midnight with default 30m when durationMinutes is null
      {
        id: "t-midnight",
        title: "Late deploy",
        status: "open",
        scheduled: "2026-11-25",
        startTime: "23:45",
        durationMinutes: null,
        timeZone: null,
        rev: 4,
      },
      // Date-only scheduled with a later deadline
      {
        id: "t-both",
        title: "File taxes",
        status: "open",
        scheduled: "2026-11-26",
        deadline: "2026-12-01",
        rev: 5,
      },
      // Date-only scheduled and deadline on the SAME day -> merged single event with ⚑
      {
        id: "t-sameday",
        title: "Pay rent",
        status: "open",
        scheduled: "2026-11-30",
        deadline: "2026-11-30",
        rev: 6,
      },
      // Deadline only
      {
        id: "t-deadline-only",
        title: "Renew passport",
        status: "open",
        deadline: "2026-12-10",
        rev: 7,
      },
      // Excluded: done, heading, out of window (>30d past, >365d future)
      { id: "t-done", title: "Done task", status: "done", scheduled: "2026-11-25", startTime: "09:00", rev: 8 },
      { id: "t-heading", title: "Section", status: "open", kind: "heading", scheduled: "2026-11-25", rev: 9 },
      { id: "t-old", title: "Ancient", status: "open", scheduled: "2026-09-01", startTime: "09:00", rev: 10 },
      { id: "t-far", title: "Far future", status: "open", scheduled: "2028-01-01", startTime: "09:00", rev: 11 },
    ];

    const allIcs = buildIcalFeed({
      scope: "all",
      today: "2026-11-22",
      nowIso: "2026-11-22T12:00:00Z",
      tasks,
    }).replace(/\r\n /g, "");

    assert.ok(allIcs.includes("UID:t-timed-tz@septena.app\r\n"));
    assert.ok(allIcs.includes("DTSTART;TZID=Europe/Berlin:20261125T140000\r\n"));
    assert.ok(allIcs.includes("DTEND;TZID=Europe/Berlin:20261125T150000\r\n"));

    assert.ok(allIcs.includes("UID:t-midnight@septena.app\r\n"));
    assert.ok(allIcs.includes("DTSTART:20261125T234500\r\n"));
    assert.ok(allIcs.includes("DTEND:20261126T001500\r\n"));

    assert.ok(allIcs.includes("UID:t-both@septena.app\r\n"));
    assert.ok(allIcs.includes("DTSTART;VALUE=DATE:20261126\r\n"));
    assert.ok(allIcs.includes("DTEND;VALUE=DATE:20261127\r\n"));
    assert.ok(allIcs.includes("UID:t-both-deadline@septena.app\r\n"));
    assert.ok(allIcs.includes("SUMMARY:⚑ File taxes\r\n"));
    assert.ok(allIcs.includes("DTSTART;VALUE=DATE:20261201\r\n"));
    assert.ok(allIcs.includes("DTEND;VALUE=DATE:20261202\r\n"));

    // Same-day scheduled + deadline merges cleanly into one event
    assert.ok(allIcs.includes("UID:t-sameday@septena.app\r\n"));
    assert.ok(!allIcs.includes("UID:t-sameday-deadline@septena.app"));
    assert.ok(allIcs.includes("SUMMARY:⚑ Pay rent\r\n"));

    assert.ok(allIcs.includes("UID:t-deadline-only@septena.app\r\n"));
    assert.ok(allIcs.includes("SUMMARY:⚑ Renew passport\r\n"));

    assert.ok(!allIcs.includes("t-done"));
    assert.ok(!allIcs.includes("t-heading"));
    assert.ok(!allIcs.includes("t-old"));
    assert.ok(!allIcs.includes("t-far"));

    // Scope "timed" includes ONLY scheduled tasks with startTime
    const timedIcs = buildIcalFeed({
      scope: "timed",
      today: "2026-11-22",
      nowIso: "2026-11-22T12:00:00Z",
      tasks,
    }).replace(/\r\n /g, "");

    assert.ok(timedIcs.includes("UID:t-timed-tz@septena.app"));
    assert.ok(timedIcs.includes("UID:t-midnight@septena.app"));
    assert.ok(!timedIcs.includes("t-both"));
    assert.ok(!timedIcs.includes("t-sameday"));
    assert.ok(!timedIcs.includes("t-deadline-only"));

    assert.equal(icalEtag(42, "all", "2026-11-22"), 'W/"ical-42-all-2026-11-22"');
  });

  it("manages token lifecycle, scope changes, instant revocation, and task snapshot in TaskStore", async () => {
    const { store } = await createTestTaskStore();
    const { sha256Base64Url } = await import("../src/util.ts");

    assert.equal(store.getIcalFeed(), null);

    // Push one dated task + homeTimezone setting
    store.push(
      [
        {
          clientOpId: opId(),
          op: "upsert",
          entity: "task",
          id: "task-1",
          fields: {
            title: "Morning review",
            status: "open",
            scheduled: "2026-11-23",
            startTime: "09:00",
            durationMinutes: 45,
          },
        },
        {
          clientOpId: opId(),
          op: "upsert",
          entity: "task",
          id: "task-undated",
          fields: { title: "Someday idea", status: "open" },
        },
        {
          clientOpId: opId(),
          op: "upsert",
          entity: "setting",
          id: "homeTimezone",
          fields: { value: "Europe/Berlin" },
        },
      ],
      HUMAN_ACTOR,
    );

    const token1 = "a".repeat(43);
    const hash1 = await sha256Base64Url(token1);
    const created = store.setIcalFeed(token1, hash1, "all");
    assert.equal(created.prevTokenHash, null);
    assert.equal(created.feed.scope, "all");

    const snap = store.readIcalSnapshot(hash1);
    assert.ok(snap);
    assert.equal(snap.scope, "all");
    assert.equal(snap.homeTimezone, "Europe/Berlin");
    assert.equal(snap.tasks.length, 1);
    assert.equal(snap.tasks[0].id, "task-1");

    // Wrong token hash is rejected immediately
    assert.equal(store.readIcalSnapshot("wrong-hash"), null);

    // Update scope without rotating token
    const scoped = store.setIcalScope("timed");
    assert.equal(scoped?.token, token1);
    assert.equal(scoped?.scope, "timed");
    assert.equal(store.readIcalSnapshot(hash1)?.scope, "timed");

    // Rotate token -> old hash immediately fails, new hash succeeds
    const token2 = "b".repeat(43);
    const hash2 = await sha256Base64Url(token2);
    const rotated = store.setIcalFeed(token2, hash2, "timed");
    assert.equal(rotated.prevTokenHash, hash1);
    assert.equal(store.readIcalSnapshot(hash1), null);
    assert.ok(store.readIcalSnapshot(hash2));

    // Delete feed -> revokes immediately
    const deleted = store.deleteIcalFeed();
    assert.equal(deleted.prevTokenHash, hash2);
    assert.equal(store.getIcalFeed(), null);
    assert.equal(store.readIcalSnapshot(hash2), null);
  });
});
