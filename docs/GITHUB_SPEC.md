# GitHub — spec

**Status:** accepted 2026-11-24, not started.
**Decisions:** [ADR 0032](adr/0032-github-issues-are-followed-not-mirrored.md),
[ADR 0031](adr/0031-references-are-keyed-pointers.md),
[ADR 0003](adr/0003-external-links-run-server-side.md).
**Builds on:** `docs/TASK_REFERENCES_SPEC.md` R0 (#386), the Review contract
(`docs/TASK_FACTORY_SPEC.md` §3.1), the project field `githubRepo`.
**Replaces:** the GitHub parts of `docs/LINKED_PROJECTS_SPEC.md`.
**Owner of decisions:** mz. Defaults are marked *(default)*, see §8.

## 1. Four actions

| Action | What happens | Writes to GitHub |
|---|---|---|
| **Follow** | A tracked issue closes, and its task goes to Review. | No |
| **Browse** | A project with a repository shows its open issues live. They are not tasks. | No |
| **Pull** | One issue becomes one task with a reference. | No |
| **Send** | One task becomes one issue, after a confirm sheet. | Creates the issue |

Nothing else writes to GitHub. Completing, editing, moving or deleting a task
leaves the issue alone.

## 2. Follow

- A task follows an issue when it has a reference with kind `issue` and role
  `tracked`. A reference with another role is only a pointer.
- Pull, Send and agents that file an issue for a task write role `tracked`.
- All tracked issues of an open task are closed: the store sets
  `endState = needs_verify` and an `endStateNote` that says how each issue
  closed (completed or not planned). The human accepts or sends back.
- A tracked issue reopens while the task waits in Review for this reason: the
  earlier `endState` comes back. After the human accepts, nothing happens.
- The reference snapshot (title, state) is refreshed. Task fields are not.
- An issue that moves to another repository: the old reference is replaced by
  one with the new key. An issue that is deleted or no longer readable: the
  task stays as it is and stops following.
- Existing tasks: one backfill turns artifacts of kind `github-issue` into
  `tracked` references *(default)*. A closed issue sends its task to Review.

## 3. Browse and pull

- A project's repository is `githubRepo`. One repository per project
  *(default)*.
- The project page shows a collapsed Issues section with the open count. Open,
  it lists issues with the "waiting on you" labels first, then the newest.
- "Waiting on you" is a list of labels on the project. Empty *(default)*.
- Pull requests are left out.
- The Worker reads GitHub and caches briefly. Issues are never stored as
  tasks and never appear in Today, Inbox, search or counts.
- An issue that already has a task shows that task. Pull on it opens the task.
- Pull creates a task with the issue title, in this project, with no notes.
  The body stays on GitHub, one tap away.

## 4. Send

- A confirm sheet shows the repository, the title and the body. The person
  can edit all three. It says when the repository is public.
- On success the task gets a `tracked` reference and `endState = decomposed`.
- No undo on GitHub. The sheet says so.
- The outbound call has an idempotency key, so a retry makes one issue.

## 5. Connection

- A GitHub App. Permission: Issues read. Write is asked for when Send ships.
- The App private key and webhook secret are Worker secrets. Installation
  tokens expire after one hour and are not stored.
- **An `installation_id` from a redirect is not proof.** Connect runs the
  GitHub user authorization once, checks that this user can see the
  installation and which of its repositories, then drops the user token.
- Access is checked again every day. A user who lost access to a repository
  stops following it. The exact endpoint is an open point of G0. If none works
  without a user token, G0 stops and asks mz.
- Webhooks `issues` and `installation`: signature verified, delivery id
  deduplicated. GitHub does not redeliver failed webhooks, so an hourly check
  with `since` and an ETag covers the misses *(default)*.
- Text from GitHub is data, never instructions to an agent.
- A self-hosted backend without App credentials hides all of this.

## 6. MCP

- No new tool for Follow: agents write `refs` with role `tracked`, and
  `tasks_list view="review"` shows the result.
- `tasks_project_create` keeps `githubRepo`.
- Agents do not get Send. They already file issues with their own GitHub access.

## 7. Phases

| Phase | What | Exit check |
|---|---|---|
| G0 | Connection, role `tracked`, webhook and hourly check, Follow, backfill, issue state on the chip. Needs #386. | Closing an issue on GitHub moves its task to Review on every device. Reopening it moves the task back. |
| G1 | Issues section on the project page, "waiting on you" labels, Pull. | An issue pulled on the phone is one task, and no other issue became a task. |
| G2 | Send, write permission. | A task sent from the Mac is one issue, and its close brings the task to Review. |

## 8. Open questions for mz

| Question | Default |
|---|---|
| Backfill existing tasks with a filed issue? | Yes, once. |
| Repositories per project? | One. |
| "Waiting on you" labels? | None until the person picks them. |
| How often does the check for missed webhooks run? | Hourly. |
