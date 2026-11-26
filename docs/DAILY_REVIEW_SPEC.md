# Daily review: spec

**Status:** proposal (#618). Defaults marked *(default)* stand until mz
overrules them in §11. No ADR: every choice here is reversible.
**Builds on:** `docs/REVIEW_SPEC.md` (ADR 0044, ADR 0046),
`docs/TASK_FADE_SPEC.md` §6 (Today at rollover, ADR 0014), §7 (stuck
question, #55), §8 (done first, #56), `docs/DO_SPEC.md` §8 (Worked on, not
finished, #520), `docs/TASK_DATES_SPEC.md` (date actions, ADR 0027).

## 1. Goal

At the end of the day the user sees what got done, and decides what goes on to
tomorrow. It takes less than a minute. The weekly review stays the bigger
moment: it holds faded tasks, projects and the done-first week. The daily
review holds today only.

The daily review answers the rollover in advance. It is not a second
rollover.

## 2. What exists

- Today and the Inbox band. A pin is `today == true` with `todaySetOn`.
- The rollover read rule and the `todayRollover` setting are specified
  (`TASK_FADE_SPEC.md` §6) and not built (R0 #185, R1 #54, R2 #186).
- The weekly sweep: a notice on Today on Sunday (`weeklySweep` in
  `registry/surfaces.json`), the sheet `TaskFadeSweepSheet.swift`, and
  `TaskFadeSweep.kt` on Android.
- Local notifications for timed reminders (`TaskReminderScheduler.swift`,
  `docs/TIMED_REMINDERS_SPEC.md`).
- `DayClock.today` is the day key on Apple platforms. The core reads the same
  day key.

## 3. When it appears

| Entry | When | Kind |
|---|---|---|
| **Command** "Wrap up today" | Any time. Today's page menu, Go menu on Mac, Quick Find. | Manual |
| **Card in Review** | From the review time to the day key change. | Quiet entry |
| **Notice on Today** | From the review time to the day key change, until the user opens the sheet or dismisses the notice. | The one prompt |
| **Notification** | Once, at the review time, if the user turned it on (§7). | Optional |

- The review time is 18:00 *(default)*, per account.
- The card in Review does not make the Review sidebar row show by itself, and
  it does not count in the badge (`REVIEW_SPEC.md` §2). Go ▸ Review always
  opens Review.
- The notice uses the existing notice slot (`TaskNotices.swift`, the Android
  notice row). `dismissScope` is `accountDay`: a dismiss on one device hides
  it on every device, for that day only.
- On the weekly sweep day, the weekly notice wins. The daily notice does not
  show. The command and the card still open the daily review *(default)*.
- If nothing was done today and nothing is open on Today, the notice and the
  card do not show. The command opens the sheet with its empty state.
- The review is always for the current day key. After the day key changes,
  the sheet shows the new day. The rollover (§5) handles what the user left
  open. When #140 moves the day start, the review moves with it.

## 4. What it shows

One sheet, three sections, in this order. Done comes first.

| Section | Contains | Rows |
|---|---|---|
| **Done today** | Tasks with status `done` and `completedAt` in the current day. Agent-assisted done tasks carry the agent mark. Then "Worked on, not finished": open tasks with a Do session today (#520). | Read only. Tap opens the task. |
| **Still on Today** | Open tasks that Today shows and the band does not: pins and tasks on Today by a When date or deadline. Stuck tasks are excluded. | One answer each (§4.1). |
| **Stuck** | Open tasks on Today with an unanswered stuck question (#55). | The stuck question's choices (`TASK_FADE_SPEC.md` §7). |

- Headings, deleted tasks, faded tasks and tasks in the Inbox band show in no
  section. A task shows in one section only.
- No counts of other days, no streak, no score, no percent, no comparison with
  yesterday. The Done header shows today's count only.
- An empty Done section shows one neutral line. It never says the user did
  nothing.
- The Stuck section shows only after #55 ships. "Worked on, not finished"
  shows only after #520 ships.
- The rule lives once, in the shared core (ADR 0025): `daily_review(day,
  tasks)` returns the three sections as id lists. Every client renders them.

### 4.1 The one answer per row

Each row in **Still on Today** has three answers. One tap answers the row.
The row then dims and shows its answer, with Undo. The sheet does not close.

| Answer | Write | Defer? |
|---|---|---|
| **Carry over** | Pin: `today = true`, `todaySetOn` = the next day key. A dated task: no write, the date keeps it on Today. | No (same as "Today" in `TASK_FADE_SPEC.md` §6.3) |
| **Schedule** | Opens the When picker. A pick clears the pin and sets `scheduled` (TASK_DATES_SPEC actions). | Yes, if the new day is later |
| **Let go** | Status `cancelled`, `dropReason = "user"`, `completedAt` = now. | No |

- Each answer goes through the mutator, stamps `touchedAt` and records one
  undo entry at the gesture (`TaskUndo.swift`).
- Completing a row from the sheet works as on Today. The row moves to Done.
- A row with no answer changes nothing. The rollover (§5) decides it.
- **Carry over** is a new date action in the core, `carry_over`. It writes the
  stamp one day ahead. The core reads a stamp that is ahead of the current day
  as not stale (§6.1) and as zero tenure (`today_tenure` in `views.rs`).
  Conformance vectors cover both.

## 5. Relation to the rollover

There is one end-of-day prompt: the notice (§3). The rollover is a start-of-day
read rule. It writes nothing and asks nothing at midnight (`TASK_FADE_SPEC.md`
§6.2).

| The user did | Next morning, Ask | Next morning, Clean slate |
|---|---|---|
| Carry over | On Today. Not in the band. | On Today. |
| Schedule | On its new day. | On its new day. |
| Let go | In the Logbook as let go. | In the Logbook as let go. |
| No answer, or no review | In the band as a carry-over row (§6.3). | Off Today, in its list (§6.4). |

- In Ask mode, the morning band holds only what the evening left. A user who
  answered every row gets no carry-over rows.
- In Clean slate mode, **Carry over** is the way to keep a pin for tomorrow.
- The daily review never moves a task into the Inbox band.

## 6. Settings

All keys go in `registry/settings.json`, and into `SETTING_VALUES`
(`backend/src/store/columns.ts`) for the synced ones.

| Key | Scope | Type | Default | UI |
|---|---|---|---|---|
| `dailyReviewNotice` | synced | bool | `true` | "Remind me to wrap up the day" |
| `dailyReviewTime` | synced | time `HH:mm` | `"18:00"` | Time picker below the toggle |
| `dailyReviewNotify` | device | bool | `false` | "Send a notification" |
| `dailyReviewDismissedOn` | synced | day | `null` | none |

- The settings sit with "At the start of each day" (`todayRollover`): Settings
  ▸ Tasks on every platform.
- `dailyReviewNotice = false` hides the notice, the card and the
  notification. The command stays.
- `dailyReviewDismissedOn` is set when the user opens the sheet or dismisses
  the notice.
- The labels are *(default)* copy. They go through the humanizer before they
  ship.

## 7. Notification

- One notification at most per day, per device, at the review time.
- Off by default. Permission is asked when the user turns it on, never at
  launch (same rule as `TaskReminderScheduler`).
- It fires only if the notice would show (§3).
- It is never repeated and never snoozed. It sets no app badge.
- It is removed, pending and delivered, when `dailyReviewDismissedOn` reaches
  the current day on any device, and at the day key change.
- Tapping it opens the sheet.

## 8. Registry

- `registry/surfaces.json`: the notice `dailyReview` (`kind: info`,
  `dismissScope: accountDay`, `featureId: review.daily`), and a `dailyReview`
  surface with the sheet copy: title, section titles, the three answers, the
  empty lines, the card text.
- `registry/actions.json`: the `wrapUpToday` action, with its menu placement.
  No new shortcut on iPad without a check of the system menu (`AGENTS.md`,
  iOS shortcut trap). Mac: a modifier shortcut only.
- `registry/rules.json`: no new rule. The review time is a setting.
- `registry/capabilities.json`: `review.daily`, with status per platform, then
  the generator for `docs/FEATURE_MAP.md`.

## 9. Agents (MCP)

- `tasks_list` gets `view = "day_review"`. It returns the three sections of
  §4 for the current day key, from the core rule. The tool description and
  `backend/skill.md` and `TasksSkill.swift` change in the same change.
- An agent reads the review. It does not answer rows. The three answers are
  user gestures.
- The session wrap-up card (#312) is a separate item. The daily review shows
  the tasks an agent finished, with the agent mark, and links nothing else.

## 10. Platforms and phases

iPhone, iPad, Mac and Android get the same sheet, the same entries and the
same answers in the same phase. iPhone and Android show a sheet. iPad and Mac
show the sheet over the window. The Mac AppKit shell renders it from the same
registry surface. The watch and the orb get nothing. Web and Windows render it
when they have Today.

| Phase | Content | Depends on |
|---|---|---|
| DR0 | Core: `daily_review` rule, `carry_over` date action, future-stamp reads, conformance vectors. Registry: settings, notice, surface, action, capability. No UI. | R0 (#185) |
| DR1 | Sheet, card in Review, command, notice, settings UI on iPhone, iPad, Mac and Android. | DR0 |
| DR2 | The opt-in notification on iPhone, iPad, Mac and Android. | DR1 |
| DR3 | MCP `view = "day_review"`, skill briefs. | DR0 |
| DR4 | Stuck section and "Worked on, not finished". | DR1, #55, #520 |

Each phase touches shared task code: build `Septask` and `SeptaskMac`, and
the Android workflow.

## 11. Open questions for mz

| Question | Default |
|---|---|
| Entries | Both: a command any time, and a notice from the review time |
| Review time | 18:00, one per account |
| Notice on by default | Yes |
| Notification on by default | No, opt-in per device |
| Daily notice on the weekly sweep day | No, the weekly notice wins |
| Answers per row | Carry over, Schedule, Let go |
| Does Carry over count a defer? | No |
| Carry over on a dated task | No write, the date keeps it on Today |
| Stuck rows | Show the stuck question's choices, not the three answers |
| Agents answer rows | No, read only over MCP |
| A second review after the day key changes | No, the sheet shows the new day |
| User-facing name | "Wrap up today" (copy goes through the humanizer) |
