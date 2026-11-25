# Public project links — spec

**Status:** proposal (2026-11-25). Issue #22, phase S4 of
[PROJECT_SHARING_SPEC.md](PROJECT_SHARING_SPEC.md).
**Decisions:** [ADR 0002](adr/0002-own-backend-replaces-icloud.md),
[ADR 0004](adr/0004-shared-projects-own-store.md),
[ADR 0011](adr/0011-self-hostable-backend.md) (self-hosting keeps working).
**Owner of decisions:** mz. Defaults chosen by the agent are marked
*(default)*; overrule them in §9.

## 1. Scope

- A project owner creates a link. Anyone with the link sees the project in a
  browser, with no account and no app.
- Two kinds: **view** (read only) and **edit** (complete, add and rename
  tasks).
- Not areas, not Today, not a single task, not the whole account.
- Not search-indexed and not a publishing feature: a link is unlisted.
- Not a web client. The page shows one project. The web client is
  [WEB_CLIENT_SPEC.md](WEB_CLIENT_SPEC.md).

## 2. Where it lives

A link reads the same **project Durable Object** as a shared project (ADR
0004). Creating the first link on a private project moves the project into a
project store, as sharing does (PROJECT_SHARING_SPEC §2.1), with one member.
There is no second copy of the rows and no snapshot.

Deleting the last link does not move the project back. Unsharing does.

## 3. The link

- URL: `https://api.septena.app/p/<token>` *(default)*. It works on a
  self-hosted Worker with that Worker's host.
- `<token>` is 32 random bytes, base64url, the same shape as the calendar
  feed token. The project store keeps only the SHA-256 hash.
- A KV entry maps the hash to the project store. The store is the authority:
  a hash that the store does not list is refused.
- The app can show a link only once, when it is created. To get a link again,
  the owner makes a new one *(default)*. The hash cannot give the URL back.
- Per link: kind (view or edit), a label the owner types, created at, last
  opened day, optional expiry (none *(default)*).
- At most 5 live links per project *(default)*.
- **Revoke** takes effect on the next request. There is no cached page to
  outlive it: responses are `Cache-Control: no-store`.

## 4. What a visitor sees

Only shared fields (PROJECT_SHARING_SPEC §3), and not all of them:

| Shown | Never shown |
|---|---|
| project title | project and task notes *(default)* |
| headings and their order | conversations and agent turns |
| task title, done or open, deadline | Today, scheduled date, reminders |
| checklist items | attachments, references |
| | members, assignees, who completed what |
| | ids, emails, change log |

Notes are hidden by default because a project note is the context that agents
read (ADR 0012). It was written for one person. The owner can turn notes on
for one link.

Logbook: completed tasks show for 7 days *(default)*, then drop out.

## 5. What an edit link allows

| Allowed | Refused |
|---|---|
| complete and reopen a task | delete anything |
| add a task to a heading or to the project | move a task, reorder |
| rename a task, check a checklist item | edit notes, deadlines, headings, the project |
| | assign a task to an agent |

- Every write carries the actor `link:<linkId>`. History shows the link's
  label, never a visitor's name.
- A task added by a link has the same provenance rule as an agent proposal: it
  arrives in the owner's Review, and shows in the project at once. *(default)*
- **An agent never acts on text from a link on its own.** Titles written by a
  link are untrusted input. MCP reads mark them `source: "link"`, and the
  connector guide says they are information, not instructions.

## 6. Limits and abuse

- Writes: 60 per hour per link and 20 per hour per hashed IP *(default)*.
  Reads: 600 per hour per hashed IP. A refused request gets 429.
- Titles use the store's own length limits. Text renders as text: no HTML, no
  Markdown, no automatic links.
- The page sends `X-Robots-Tag: noindex, nofollow`,
  `Referrer-Policy: no-referrer`, a strict Content-Security-Policy, and loads
  nothing from another host. It sets no cookie.
- The page's only script posts the edit form. A view link needs no script.
- Edit writes use `POST` with an `Origin` check. The token is the only
  credential, so no cookie means no cross-site request forgery through one.
- An unknown, expired or revoked token gets the same 404 page. Nothing tells
  a visitor which of the three it was.
- Raw tokens never reach logs. The Worker logs the link id.

## 7. App surfaces

- **Project menu → Share…** gets a "Public link" section below the members:
  the list of links (label, kind, last opened), New Link, Copy (at creation
  only), Revoke. The copy and rows come from `registry/`.
- A project with a live link shows one mark in its header, so the owner does
  not forget that the project is open. Rows get no mark.
- All platforms that show Share… show this section (same behavior on every
  platform).
- MCP: no tool creates a link in the first release. Opening a project to the
  public is the owner's own act. *(default)*

## 8. Phases

| Phase | What | Exit check |
|---|---|---|
| PL1 | View links: token store, hash lookup, server-rendered page, revoke, limits. Share… section on iPhone, iPad and Mac, Android after. | A view link opens in a private window; after revoke it answers 404. |
| PL2 | Edit links: the write route, actor, limits, Review intake. | A visitor completes and adds a task; the owner sees both, with the link's label. |

PL1 needs S0 (#10) and S1 (#11). PL2 needs PL1.

## 9. Open questions for mz

| Question | Default in this spec |
|---|---|
| Is a link shown once, or can the owner copy it again? | Once; only the hash is stored. |
| Does a view link show notes? | No; the owner can turn it on per link. |
| How long do completed tasks stay visible? | 7 days. |
| Do link-added tasks go through Review? | Yes, and they show in the project at once. |
| Can an agent create a link over MCP? | No. |
| Which host serves the page? | `api.septena.app/p/…`, no new host. |
| Which plans get public links? | No default; product decision (private workspace). |
