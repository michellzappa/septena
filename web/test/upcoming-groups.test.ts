import assert from "node:assert/strict";
import test from "node:test";
import {
  formatUpcomingDayLabel,
  groupUpcomingByDate,
  nextIsoDay,
  type UpcomingTaskEntry,
} from "../src/lib/upcomingGroups.ts";

function fakeTask(id: string, title: string, upcomingDay: string | null): UpcomingTaskEntry {
  return {
    task: {
      id,
      title,
      status: "open",
      today: false,
      created: "2026-11-20",
      source: "app",
    },
    membership: {
      isUnfiled: false,
      isInboxMember: false,
      inTriageBand: false,
      isOnToday: false,
      inInbox: false,
      daysOnToday: 0,
      matchesView: {
        today: false,
        inbox: false,
        upcoming: upcomingDay !== null,
        anytime: false,
      },
      dueState: null,
      deadlineRed: false,
      upcomingDay,
      arrivedOnOwn: false,
      isTracked: false,
    },
  };
}

test("formatUpcomingDayLabel matches Apple & Android schedule headers", () => {
  const today = "2026-11-25"; // Wednesday
  assert.equal(formatUpcomingDayLabel("2026-11-25", today, "en-US"), "Today");
  assert.equal(formatUpcomingDayLabel("2026-11-26", today, "en-US"), "Tomorrow");
  assert.equal(formatUpcomingDayLabel("2026-11-27", today, "en-US"), "Friday");
  assert.equal(formatUpcomingDayLabel("2026-12-01", today, "en-US"), "Tuesday");
  assert.equal(formatUpcomingDayLabel("2026-12-02", today, "en-US"), "Wed, Dec 2");
  assert.equal(nextIsoDay(today), "2026-11-26");
});

test("groupUpcomingByDate sorts buckets ascending and preserves intra-day order", () => {
  const today = "2026-11-25";
  const items = [
    fakeTask("t3", "Next week", "2026-12-03"),
    fakeTask("t1", "Tomorrow first", "2026-11-26"),
    fakeTask("t2", "Tomorrow second", "2026-11-26"),
    fakeTask("t0", "No day", null),
  ];
  const groups = groupUpcomingByDate(items, today, "en-US");
  assert.equal(groups.length, 2);
  assert.equal(groups[0].day, "2026-11-26");
  assert.equal(groups[0].label, "Tomorrow");
  assert.deepEqual(groups[0].items.map((x) => x.task.id), ["t1", "t2"]);
  assert.equal(groups[1].day, "2026-12-03");
  assert.deepEqual(groups[1].items.map((x) => x.task.id), ["t3"]);
});
