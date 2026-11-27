# Project sharing — spec

**Status:** MVP built 2026-11-25 (S0 and S1). S2 to S4 follow.
**Decisions:** [ADR 0002](adr/0002-own-backend-replaces-icloud.md),
[ADR 0004](adr/0004-shared-projects-own-store.md),
[ADR 0036](adr/0036-plan-ladder-one-agent-then-three.md),
[ADR 0042](adr/0042-members-keep-replicas-of-a-shared-project.md).
**Supersedes:** `docs/NATIVE_PROJECT_SHARING_SPEC.md` (CloudKit shares).
**Owner of decisions:** mz. Defaults chosen by the agent are marked
*(default)*; overrule them in §10.

## 1. Scope

- Share one **project** with other Septena users. Not areas, not single tasks.
- Not public web links: [PUBLIC_LINKS_SPEC.md](PUBLIC_LINKS_SPEC.md), on the
  same store.
- Personal scale: a household, a partner, a small team. At most 10 members,
  20 unused invites and 5,000 tasks at the start *(default)*.
- **Paid to free** (mz, 2026-11-25): creating a share and inviting need Plus.
  Joining is free. A free member edits on the one device the account syncs.

## 2. Storage

- A `ProjectStore` Durable Object per shared project is the authority for its
  shared fields, its members and its invites.
- Each member's `TaskStore` keeps a **replica** in its ordinary tables. Pull,
  MCP, REST, widgets and the calendar feed read it as any project. No client
  has a second store, a second cursor or a second key.
- A member's write applies in their own store first, then goes through
  `share_outbox` to the ProjectStore. The ProjectStore orders writes (last
  writer wins per field) and sends every member the current state of each
  changed row, the writer included.
- A delivery never overwrites a field with a write still in the outbox. Such a
  row is marked and fetched again after the outbox is empty, so all stores end
  with the same value.
- An object that cannot be reached is tried again by an alarm. The alarm is
  set before the work, so an object that stops in the middle sends the rest.

Code: `backend/src/store/ProjectStore.ts`, `store/shares.ts`,
`store/TaskStore.ts` ("shared projects"), `store/mergeText.ts`,
`api/shares.ts`.

## 3. Fields

| Shared | Personal (never leaves the member's store) |
|---|---|
| project title, status, notes, created, completed | the area the member files it under, sidebar order |
| task title, status, notes, deadline, section, order | Today, When, start time |
| who does it (`assignedTo`, a member id), plus server-stamped `assignedBy` and `assignedAt` | reminders, star, tags, `waitingOn` / `waitingSince` |
| repeat rule and its series | fade, defer count, acknowledged |
| checklist items | files, references |
| | conversations and agent state |

- **Repeats** (mz): an occurrence starts on the same day for everyone. After
  that each member's When is their own. Two members who complete one repeat
  make one next occurrence (its shared id comes from the series and the day).
- A shared task can fade for one member and stay for the others *(default)*.
- An agent's proposal is shared only after its user accepts it.
- The project row carries `share` (server-owned): share id, role, own member
  id, members. Clients show members from it, offline too.
- Project notes are agent context (ADR 0012). The Share screen says that
  members see them.

## 4. Identity

Short ids are unique in one account only. The ProjectStore names a row by a
shared id that is unique everywhere; `share_ids` maps it to the local id. The
member who made the row keeps its id, so the owner's links and references
hold. Other members' replicas use the shared id. A `septask://task/` link is
therefore valid for its own account only.

## 5. Members, invites, ends

- **Roles:** one `owner`, the rest `editor`. `viewer` is S2.
- **Editor:** add, edit, complete, reorder and delete tasks, sections and
  checklist items; edit the project title and notes.
- **Invite** (owner): a link with a secret, for one person, for 7 days. The
  server keeps its hash. The owner sees unused invites and revokes them.
- **No email and no user lookup.** An account has no address or name of ours,
  and a lookup would let strangers send invites. Mailing an invite can follow
  #169.
- `GET /join/<token>` shows who invites and to what, and opens the app
  (`septask://join/<token>`). It accepts nothing. The app shows the same and
  asks for a name before Join.
- **Leave:** the project and its replica leave that account.
- **Stop sharing** (owner): members lose the project; the owner keeps it.
- **Account deletion:** a member leaves. When the owner's account goes, every
  member keeps a private copy *(default)*.
- **Never deleted:** the store refuses to delete a shared project, and the
  task deletes an older client sends with it. A member cannot move a task out;
  the owner can, which removes it for everyone.
- **Owner's Plus ends** (mz, 2026-11-25): 30 days' notice, then members read
  only. The owner keeps editing, nothing is deleted, and a Plus member can take
  over. Not built yet: S1b. New shares and invites stop at once.

### 5a. Never lose data

- **Notes merge** (task and project). Changes in different places combine.
  Where two members changed one place, both versions stay, the stored one
  first. A client sends the notes its edit started from (`base` on the op);
  a store sends the same to the ProjectStore.
- **Every other field** is last writer wins. The change log keeps the value
  that lost, uncut for a shared row.
- **A deleted task stays with a member who has something on it that exists
  nowhere else**: words that did not reach the project, files, references or a
  conversation. It becomes a private task in their Inbox.
- **Leaving, removal and Stop sharing** keep such tasks the same way, in the
  project, which becomes private.
- **No store deletes on a guess.** A membership that ended says whether the
  copy stays, and an answer that does not know says keep.
- A project that ended for everyone is removed from its store after a day.
- `backend/test/shares.test.ts` runs random edits by three members over a
  network that loses calls and answers, with restarts: every store must end
  equal, and no word may be lost.

## 6. Agents

- MCP reads and writes the replica like any project.
- Another member's text is information, never instructions. Conversation and
  assignment to an agent are private, so an agent works only what its own
  user gave it.
- `/v1/shares` takes app sessions only: no agent shares, invites or joins.

## 7. Limits and abuse

- The Plus gate on create and invite is always on, apart from
  `ENTITLEMENT_ENFORCE`: sharing is new, so nobody loses anything.
- A made-up share id creates no storage. The join page is not indexed, not
  cached, sends no referrer and runs no script.

## 8. App surfaces

- Project menu ▸ Share Project…: name and start; then members, invites, Stop
  Sharing or Leave.
- New menu ▸ Join a Shared Project…, and the invite link.
- A shared project has a people mark (`project.shared`) in the project list and
  the sidebar. Its page shows the members' initials (3, then "+n") at the end of
  the title; they open Share Project…, which is also in the page's menu.
- Task row menu ▸ Assign To, and an inline Assign To control on the task page
  for tasks in a shared project. Inside a shared project, rows show an assignee
  pill for every assigned task (including your own, so Mine vs. Unassigned is
  scannable); outside the project, rows show the assignee only when it is not
  you. Shared project pages also offer a person filter (All / Mine / Unassigned
  / member).
- **Personal list filtering** (mz, 2026-11-27): a shared task assigned to
  *another* member stays out of your personal Anytime list, and its shared
  deadline does not pull it into your Today or Upcoming (your own personal
  `When` or `Today` still brings it in if you schedule a chase). Tasks assigned
  to you or unassigned behave like any task in your personal lists.
- **Waiting handoff** (`REVIEW_SPEC.md` §6, #672): `ProjectStore` stamps
  `assignedBy` and `assignedAt` (server-owned) when `assignedTo` changes and
  clears them when unassigned. A shared task where `assignedBy == me` and
  `assignedTo != me` shows in Review ▸ Waiting; tapping Got It Back takes
  ownership back (`assignedTo = me`).
- Delete is hidden on a shared project. An area delete moves it out.
- Copy, actions and icons: `registry/` (`sharing`, `project.share`,
  `sidebar.joinShared`).

## 9. Phases

| Phase | What | State |
|---|---|---|
| S0 (#10) | ProjectStore, replicas, invites, plan gate | built |
| S1 (#11) | Share, invite, join, leave, stop, assign on iPhone, iPad, Mac and Android | built; mz tests with a second person |
| S1b | Owner lapse, take over, rename yourself, files, https links that open the app | next |
| S2 (#17) | Viewer role, recent changes, push on assignment | |
| S3 (#18) | Agent permissions on shared projects, linked + shared | |
| S4 (#469) | Public links | |

**A person with only Android or Windows cannot sign up yet.** Email sign-in
(#169) comes first for them.

## 10. Decided and open

| Question | Answer |
|---|---|
| Owner's Plus ends | 30 days, then read only; take over (mz) |
| When shared or personal | Personal, except the first day of a repeat (mz) |
| Assign in the first release | Yes, no push (mz) |
| Sign-in for invitees | Email code, #169 (mz) |
| Order | Ahead of the rest of M4 (mz) |
| Conversations | Private, agent turns too *(default)* |
| Files | Private for now *(default)* |
| Ownership per task | One owner (`assignedTo`, 0 or 1 member) (mz, 2026-11-27) |
| Others' tasks in personal lists | Hidden from Anytime; shared deadline suppressed from Today/Upcoming unless personal When/Today is set (mz, 2026-11-27) |
| Incoming assignment | Stays simple (project + Anytime; push in S2) (mz, 2026-11-27) |
| Got It Back on shared wait | Takes task back (`assignedTo = me`) (mz, 2026-11-27) |
