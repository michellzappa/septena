# Raycast extension spec

Status: proposal (2026-11-26). Rests on [ADR 0051](adr/0051-clients-in-other-apps-are-septena-surfaces.md),
ADR 0038, ADR 0050 and agent keys (#86). Tracking issue: #667. Defaults
chosen by the author are marked *(default)*. mz decided to build it on
2026-11-26.

## Why

Developers live in Raycast. A to-do app that a developer can reach from the
launcher, without a window switch, is the app they keep. The extension is a
Septena client: it shows the user's tasks and takes what the user types. It
reads nothing from other apps (ADR 0051).

## Commands

Each command uses the action IDs and the copy of `registry/actions.json` and
`registry/surfaces.json`. No new action exists only in Raycast.

| Command | Mode | What it does |
|---|---|---|
| Add Task | form, plus a quick form with a title argument | Title, notes, When (Today, a date), Deadline, project or area. Creates with `origin: user_request`. |
| Today | list | The Today page with its Inbox band, as the apps order it. |
| Inbox | list | The Inbox band alone. |
| Upcoming | list | Scheduled tasks by date. |
| Review | list | Tasks waiting for the user to accept (`needs_verify`). Accept and Send Back act as in the apps. |
| Search Tasks | list | Server search (`tasks_search`), open by default. |
| Septena Menu Bar | menu bar | The Today count, the next tasks, and Add Task. *(default)* refreshes every 10 minutes and on open. |

Row actions, in registry order: Complete, Move to Today, Defer (a date
picker), Move (project or area), Star, Open in Septena (`septask://task/<id>`),
Copy Link. Complete on a task an agent holds is refused by the server
(`human_accepts`) and shown as such. Every write the server refuses (Stop,
Pause, a limit) shows the server's own message.

Selected text: Add Task fills the title from the selected text when the user
runs it with text selected *(default)*. The extension reads nothing in the
background.

Inline parsing ("tomorrow 9am"): not in v1. It comes from the core once #133
moves parsing there. The extension never parses dates itself.

## Raycast AI

Raycast connects to MCP servers itself. The user adds
`https://api.septena.app/mcp` there, and Raycast AI gets every Septena tool
with the server's rules. The extension declares no AI tools of its own
*(default)*: a second tool set would drift from the connector. The setup page
for this is a row in AS12 (septena-site#31, one page per agent client).

## Sign-in

- **v1: an agent key** *(default)*. A password preference holds the key from
  Settings ▸ AI & Agents ▸ Agents ▸ New Agent Key. Raycast stores it
  encrypted. The key's row in the Agents list is "Raycast", so the user can
  disconnect it there.
- **v2: OAuth** with PKCE through Raycast's OAuth client, so the user signs in
  without copying a key. This needs Raycast's redirect host in
  `backend/src/oauth/redirects.ts` (`PINNED_REDIRECT_HOSTS`) and the
  device-code approval in the app. A phase of its own (RX4).

## Provenance

A task the user types in Raycast was made by the user, not by an agent. With a
key, the server today records "Added by Raycast". *(default)* Add a key kind
`client` to `POST /v1/access/keys`: writes with a client key record the user
as the author and the key's name as the place ("You, from Raycast"). The CLI
uses the same kind. The agent loop rules (claims, the human-only accept) still
apply to the key.

## Transport

- Until the REST API (#90) ships: one `tools/call` on `/mcp` per action, as
  the CLI does.
- The call code lives once, in a small package `@septena/client` that the CLI
  and the extension both use *(default)*. Raycast builds extensions from npm
  dependencies, so the package is published to npm under the `@septena` org.
  It moves to REST with #90, and no command changes.

## Where the code lives and how it ships

- Source: `tools/raycast/` in this repo, a standard Raycast extension
  (TypeScript, React, `@raycast/api`). `tools/septena-client/` holds the
  shared package.
- Store: Raycast publishes through a pull request to `raycast/extensions`.
  `npm run publish` in the extension opens it. Raycast reviews it. mz owns
  the Raycast developer account and approves the submission (outward-facing).
- CI: a workflow job runs `ray lint` and `ray build` on a pull request that
  touches `tools/raycast/` or `tools/septena-client/`.
- Platforms: Raycast for Mac and Raycast for Windows. One extension.
- Language: the Store is English. The extension reads English copy from the
  registry.
- Store copy goes through the humanizer and the Starlings `/house` standards.

## Phases

| Phase | What | Needs |
|---|---|---|
| RX0 | `@septena/client` from the CLI's call code; the CLI uses it | npm org (mz task) |
| RX1 | Extension skeleton: key preference, Add Task, Today, Search | RX0 |
| RX2 | Inbox, Upcoming, Review, row actions, menu bar | RX1 |
| RX3 | Client key kind and "You, from Raycast" provenance (backend and every app's provenance row) | #86 |
| RX4 | OAuth sign-in | redirect host, RX1 |
| RX5 | Store listing and submission | RX2, mz |

RX3 touches the provenance row on iPhone, iPad, Mac, Android and web in the
same change (same-behavior rule).

## Open questions

| Question | Default |
|---|---|
| Menu bar refresh | 10 minutes and on open |
| AI tools in the extension | None; Raycast's own MCP support |
| Selected text as title | Yes, only when the user runs Add Task |
| Client key kind | Yes, RX3 |
| Shared package name | `@septena/client` |
