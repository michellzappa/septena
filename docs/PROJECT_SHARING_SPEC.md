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
- An object that cannot be reached is tried again by an alarm. Nothing is lost.

Code: `backend/src/store/ProjectStore.ts`, `store/shares.ts`,
`store/TaskStore.ts` ("shared projects"), `api/shares.ts`.

## 3. Fields

| Shared | Personal (never leaves the member's store) |
|---|---|
| project title, status, notes, created, completed | the area the member files it under, sidebar order |
| task title, status, notes, deadline, section, order | Today, When, start time |
| who does it (`assignedTo`, a member id) | reminders, star, tags |
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
- Task row menu ▸ Assign To; a row shows the assignee when it is not you.
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
