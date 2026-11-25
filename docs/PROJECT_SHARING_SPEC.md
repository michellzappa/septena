# Project sharing — spec

**Status:** accepted, not started. Written and accepted 2026-11-19. Open questions keep their defaults until mz overrules them.
**Decisions:** [ADR 0002](adr/0002-own-backend-replaces-icloud.md),
[ADR 0004](adr/0004-shared-projects-own-store.md).
**Supersedes:** `docs/NATIVE_PROJECT_SHARING_SPEC.md` (CloudKit shares). The
product decisions of that spec carry over where marked *(carried)*; its
storage design does not.
**Owner of decisions:** mz. Defaults chosen by the agent are marked
*(default)*; overrule them in §10.

## 1. Scope

- Share one **project** with other Septask/Septena users. *(carried)*
- Not areas. An area is a wider privacy boundary. Revisit after projects work.
  *(carried)*
- Not public web links. A view or edit link for people without an account is
  a separate feature on the same store, specified later.
- Personal scale: a household, a partner, a small team. Not a team tool with
  workloads and permissions matrices.

## 2. Storage

```
member A's user DO            shared project DO            member B's user DO
  personal fields  ◄─ relay ─  project, tasks, headings ─ relay ─►  personal fields
  (Today, area, …)              members, invites, changes          (Today, area, …)
```

- **One Durable Object per shared project.** It holds the project row, its
  tasks and headings, the member list, pending invites, and its own change log
  with its own `rev` sequence.
- **Personal fields stay in each member's user DO**, keyed by task id (§3).
- **Each user DO relays** changes from the project DOs it belongs to into its
  own change log *(default)*. A client keeps one cursor and one pull loop, as
  today. The relay entry carries the project DO's `rev`, so a user DO that
  missed changes can catch up from that project's log.
- Writes from a client to a shared task go to the project DO through the
  user's API session. The Worker checks membership and role on every request.

### 2.1 Sharing an existing project

Sharing moves the project and its tasks from the owner's user DO into a new
project DO, in one transaction per DO:

1. Create the project DO and copy project, tasks and headings in.
2. In the owner's user DO, replace those rows with a pointer (`sharedIn:
   <projectDO>`) and keep the owner's personal fields.
3. The change log records it as one `share` op, so every device of the owner
   swaps the rows in one pull.

Unsharing (owner only) runs it backwards into the owner's user DO. Members
lose the project; their personal fields for it are dropped.

## 3. Fields

| Lives in the project DO (shared) | Lives in each user DO (personal) |
|---|---|
| project title, notes, status, context | area the member files the project under |
| task title, notes, status, deadline | today, todaySetOn, todayPosition |
| heading, position (order in the project) | scheduled date |
| assignee (a member or an agent) | personal reminders |
| recurrence | |
| attachments | |
| created by, completed by | |

- **Conversation turns** stay private per member in v1 *(carried)*: each
  member's turns live in that member's user DO, keyed by task id. Exception:
  turns written by an agent on a task assigned to the agent are shared, so
  every member sees the agent's questions and results (§6).
- **Order:** members share one order inside the project. Last writer wins on
  reorder, no CRDT *(carried)*. Today order is personal.

## 4. Identity

Task ids are bare and project/area ids are short ids, unique only within one
user (`docs/IDENTIFIERS.md`). Two users can hold the same id.

- The client's local unique key becomes `<storeId>:<id>`, where `storeId` is
  `me` for the user DO and the project DO's id for a shared project.
  *(carried in spirit: the CloudKit spec's `localKey`)*
- New rows created inside a project DO get ids minted by the project DO, so
  there is no collision inside one store.
- MCP and export keep showing the short id, plus the project id for context.

## 5. Members, roles, invites

- **Roles:** `owner` (one), `editor`, `viewer`.
- **Owner:** rename, archive, unshare, manage members, hard purge.
- **Editor:** add, edit, complete, reorder, soft-delete tasks; edit headings.
- **Viewer:** read only; may still plan the tasks in their own Today.
- **Invite:** the owner creates an invite (email, or a link with a one-time
  token that expires in 7 days *(default)*). The invitee signs in to Septask
  and accepts. The owner sees pending invites and can revoke them.
- **Leaving:** a member can leave. The owner cannot leave; they unshare or
  transfer ownership.
- **Moving tasks out:** a member may not move a shared task into a private
  project *(carried)*. They can copy it. The owner can move it out, which
  removes it for everyone after a confirm.
- **Deletes:** soft-delete round-trips for editors; hard purge and restore
  are owner-only *(carried)*.

## 6. Agents and shared projects

A shared project can be factory intake (`docs/TASK_FACTORY_SPEC.md`).

- Assigning a task to an agent is visible to every member.
- The agent acts as the member who assigned it. Its writes carry that
  member's id plus the agent actor (`mcp:<client>` or `runner:<host>`).
- Its questions go to the member who assigned the task, not to everyone.
- MCP tools see shared projects the user belongs to and respect the role
  *(default; the CloudKit spec said no, because of the two-server burden; the
  backend removes that burden)*.

## 7. Linked + shared

A shared project can also be a linked project
(`docs/LINKED_PROJECTS_SPEC.md` §6A). The link belongs to the project DO. It
uses the connection of the member who created it. If that member leaves, the
link pauses until another member reconnects it.

## 8. App surfaces

- **Project header:** "Share…" for the owner; member avatars; "Shared with
  you" label for members. *(carried)*
- **Rows:** no collaboration chrome by default. An assignee avatar shows only
  when the assignee is not you. *(carried, extended)*
- **Sidebar:** a shared project sits in the area the member chose, or in a
  "Shared with you" group when they chose none. Never fabricate an area row.
  *(carried)*
- **Activity:** a project-level "Recent changes" list from the project DO's
  change log: who did what. No per-row history in v1.
- Reuse the canonical selection and row language. No new highlight style
  (`CLAUDE.md`, "One selection/target language per surface").

## 9. Phases

| Phase | What | Exit check |
|---|---|---|
| S0 | Project DO, membership checks, relay into user DOs, local `<storeId>:<id>` key. No UI; a debug action shares a project between two test accounts. | Edits on account A appear on account B's devices; personal fields stay separate. |
| S1 | Share / invite / accept / leave / unshare UI on iOS and Mac. Editor and owner roles. | mz and one other person run one shared project for a week. |
| S2 | Viewer role, activity list, assignee avatars, push notification on assignment. | — |
| S3 | Agents on shared projects (§6), linked + shared (§7). | An agent works a task in a shared project; only the assigning member gets its questions. |
| S4 | Public web link (view / edit): [PUBLIC_LINKS_SPEC.md](PUBLIC_LINKS_SPEC.md). | — |

## 10. Open questions for mz

| Question | Default in this spec |
|---|---|
| Do members see each other's conversation turns? | No, except agent turns on agent-assigned tasks. |
| Can MCP and agents read and write shared projects? | Yes, by role. |
| Invite link lifetime | 7 days, one use. |
| Relay through the user DO, or clients pull each project DO directly? | Relay. |
| Does a free account get sharing, or is it paid? | No default; product decision (private site repo). |
