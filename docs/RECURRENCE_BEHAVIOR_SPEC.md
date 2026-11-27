# Recurrence behavior for missed tasks

**Status** · Product proposal

A repeat rule describes when something comes due and what happens when the previous occurrence is still open. The same Repeat editor should cover chores, habits, and independently owed tasks. These are examples of how to use repetition. Users choose the behavior on the task.

See [Recurrence V2](RECURRENCE_V2_SPEC.md) for calendar rules and [Checklist projects](PROJECT_CHECKLIST_SPEC.md) for items users bring back manually.

## Repeat editor

Keep the existing cadence controls as the first choice. A repeat can follow a **Fixed schedule** such as every Tuesday or run **After completion** such as three months after changing a filter. For fixed schedules, put **If missed** under the repeat options and summarize the choice next to the cadence. Default new fixed schedules to **Keep one open**.

| If missed | What stays open | Example |
| --- | --- | --- |
| **Keep one open** | The current item stays open until handled. Intervening scheduled dates create no extra rows. | Three weeks of laundry still appear as one item. |
| **Start fresh next time** | The previous occurrence expires when the next scheduled occurrence begins. The new one is available with a fresh checkbox. | Monday’s missed stretch is gone when Tuesday’s opens. |
| **Keep each occurrence** | Each date produces a separate obligation that stays open until handled. | Three missed weekly timesheets accumulate as three rows. |

For **After completion**, hide **If missed**. The current task stays open. Completing it starts the next interval from the completion date.

## Occurrences and history

- **Keep one open.** Preserve the original scheduled date while the item is overdue. After late completion, look for the first scheduled slot after both that occurrence and its completion. A late Tuesday chore does not shift the entire series to Thursday.
- **Start fresh next time.** Show the current occurrence until completion or the next scheduled boundary. A completed occurrence goes to the Logbook. Expiry removes an unfinished occurrence from actionable lists without recording a completion. A task that repeats on weekdays refreshes at its next weekday slot.
- **Keep each occurrence.** Create one occurrence per due slot, even if earlier ones are open. On return after an absence, show any still-owed occurrences with their own original dates. Completing one affects that occurrence only.
- Use the series scheduling time zone for boundaries. Date-only slots begin at the start of the scheduled local day. Timed slots begin at their scheduled time. Devices that reconnect after a boundary reconcile against the same scheduled slots.
- Apply a change to **If missed** from the next scheduled slot. Keep existing open obligations until the user handles them. Preserve the behavior of existing series when the field is absent.

## Shared behavior

The shared core decides which scheduled slots are due, which are still open, and what completion changes. Identify each slot by series and scheduled time so the same occurrence can be reconciled from Apple, Android, Web, and the backend without duplicates. Support current and missed occurrences when the app has been closed. Use the same rule for agent and app writes. Undo restores the user’s completion without duplicating a successor or reversing another device’s later edit.

## Acceptance checks

- After three missed weeks, laundry appears once, a daily stretch has only its current occurrence available, and three weekly timesheets appear separately.
- Completing Tuesday’s chore on Thursday leaves Tuesday as the next scheduled weekday. Completing a filter change late schedules the next change from the actual completion date.
- The next habit slot opens after day rollover. The expired item creates no Logbook completion, and a completed item appears once.
- Two devices reconcile the same missed slots after being offline and agree on dates, completion, and the number of open items.
- A pre-existing repeat behaves the same after upgrade, including when completed late.
