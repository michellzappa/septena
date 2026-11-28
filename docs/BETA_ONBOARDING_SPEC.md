# Beta onboarding

- Status: accepted (2026-11-28); built in `backend/src/api/beta.ts`, `backend/src/store/betaInvites.ts` and septena/site `app/beta/page.tsx`
- Decision: [ADR 0064](adr/0064-beta-by-invite-code-tied-to-email.md)
- Surfaces: septena/site `/beta`, `api.septena.app` (join, grants, mail,
  admin), App Store Connect (TestFlight group)

The beta is a small group by invitation. A person gets a code from mz, types
it with their email on `septena.app/beta`, and Apple's TestFlight invite
arrives. A year of Pro follows that email to whatever account they make.

All copy below went through the humanizer pass and `/house/language`. It
names install paths per device on purpose: these are the download actions,
the one place copy may name a platform. Copy never says when a new build
ships: testers do not need it, and TestFlight tells them.

## 1. The journey

| Step | Where | What the person sees | What runs |
|---|---|---|---|
| 1 | mz's own mail or message | The invite mail (§4.1) with a code and a link that carries it | mz makes the code on `/admin` |
| 2 | `septena.app/beta?code=…` | The page, code filled in. They type their email and press **Join the beta** | `POST /v1/beta/join` |
| 3 | Same page | “You’re in” with the Mac download and what to try first | Backend adds the email to the TestFlight group, writes the beta row, makes the plan link, sends §4.2 |
| 4 | Their inbox | Apple’s TestFlight invite, then our welcome mail | Apple sends its own mail |
| 5 | TestFlight, or the Mac download | Install. Sign in with any provider | At sign-in, a matching verified email gets the grant |
| 6 | The app, for a week | Their own list, an agent, Review | Nothing new in the app |
| 7 | Day 4, their inbox | The check-in mail (§4.3) | Backend cron, once per tester |
| 8 | `/support?from=beta` | The Support form, marked as beta | Starlings Septena inbox |
| 9 | Launch day | The launch mail (§4.4) | mz sets the launch date on `/admin`; every beta grant gets its end date |

## 2. Data and API (backend)

Both tables live in `AccountStore`, next to plan links.

- `beta_codes`: `id`, `code` (uppercase), `label`, `maxUses`, `useCount`,
  `endsAt`, `createdAt`, `closedAt`, `revokedAt`.
- `beta_testers`: `email` (lowercase, key), `codeId`, `joinedAt`,
  `ascTesterId`, `ascState` (`invited` | `failed`), `planLinkId`,
  `grantedUserId`, `grantedAt`, `welcomeSentAt`, `checkinSentAt`.
- `beta_settings`: `launchAt` (null until mz sets it).

`POST /v1/beta/join` with `{ email, code }`, CORS for `septena.app`:

| Case | Status | Page shows |
|---|---|---|
| New email, live code | 200 `joined` | §3 success |
| Email already joined | 200 `already_joined` | “You’re already in. I sent Apple’s invite again.” (resends through `betaTesterInvitations`) |
| Unknown, closed, ended or used-up code | 400 `bad_code` | “That code doesn’t work. Check it against your invite.” One answer for all four, so a guess learns nothing. |
| Not an email | 400 `bad_email` | “That email address doesn’t look right.” |
| Over 5 tries per IP in 10 minutes | 429 | “Too many tries. Wait a few minutes and try again.” |
| App Store Connect refused or timed out | 502 `apple_unavailable` | “Apple didn’t take the invite just now. Try again in a few minutes.” The row stays `failed` and does not use the code. |

App Store Connect: `POST /v1/betaTesters` with the email and the group. Apple
mails the invite itself. Secrets on the backend Worker: `ASC_KEY_P8`,
`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_BETA_GROUP_ID`. The group is the
existing external group (“Public beta”, the one `testflight-distribute.mjs`
fills), with its public link turned off, so no new beta review is needed.

The grant: one entitlement row `grant:beta`, plan `pro`, `expiresAt` null
until `launchAt` is set, then `launchAt + 12 months`. Three writers, and the
first one wins:
1. Join, when an `email:` identity with that address exists.
2. `resolveProviderLogin` and email sign-in, when the verified email matches
   a beta row with no `grantedUserId`.
3. The personal plan link (ADR 0043, one use, plan `pro`, label
   `beta: <code label>`), claimed on the web.

The admin page gets a Beta section: codes (code, label, uses of limit,
joined, granted, close, take back), a “New code” form, a lookup by one email,
and the launch date. It lists no emails.

## 3. The page (`/beta`)

Short. Four blocks, two pictures. The old “New builds” block and the long
agent test plan are gone: the welcome mail carries the test plan, and nobody
needs a build schedule.

**Title:** The Septena beta
**Byline:** A small group, by invitation.

**Join with your code** (the form, then a three-step drawing: your code,
Apple’s invite, Septena on your devices; lines and one accent dot, as the
list-keeper drawings)

> Type the email you want to use and the code from your invite. Apple sends
> you a TestFlight invite, and I send a short note on what to try.

Fields: Email, Code. Button: **Join the beta**. Under it: “Your email goes to
Apple for the invite and to Septena for your Pro year. [Privacy](/privacy).”

Success state, in place of the form:

> **You’re in.** Apple’s TestFlight invite and a note from me are on their way
> to {email}. Open Apple’s mail on your phone or tablet to install. On a Mac,
> [download Septena](/mac/download).

**Give it a real week** (the `agents` scene, playing)

> Put a real piece of your list in Septena and use it for a few days. Then
> connect Claude or another agent and give it one task you can check. It asks
> you in the app when it needs you, and you decide in Review when the work is
> done.

**Tell me what you find**

> When something breaks, confuses you or just works, send it through Support.
> Say what you tried and what you expected. If an agent was involved, add the
> prompt.
> **Send a note** (to `/support?from=beta&page=%2Fbeta#contact`)

**Your thank-you**

> Everyone in the beta gets a year of Pro from the day Septena launches. It
> belongs to the email you joined with, so it reaches any account you make
> with it, on any device.

## 4. The mails

All mails go from `notify@septena.app` with the name “Michell from Septena”,
plain HTML in the confirm-page style (system sans, Persimmon button, light
and dark), with a text part. No reply address: the feedback link is the
way back (ADR 0054).

### 4.1 Invite (mz sends it himself)

Subject: **You’re invited to the Septena beta**

> Hi {name},
>
> I’m letting a small group into the Septena beta, and I’d like you in it.
>
> Your code is **{CODE}**. Open septena.app/beta?code={CODE}, type the email
> you want to use, and Apple sends you a TestFlight invite.
>
> Use it on your real list for a week, then tell me what got in your way.
> Everyone in the beta gets a year of Pro.
>
> Please keep the code to yourself.
>
> Michell

### 4.2 Welcome (sent at join)

Subject: **You’re in the Septena beta**

> Thanks for testing Septena.
>
> Apple sends its own mail from TestFlight. Open it on your phone or tablet
> to install. On a Mac, download the app here: {mac link}.
>
> What I’d like you to try this week:
>
> 1. Move a real piece of your list in. Give some tasks a day, and finish a
>    few.
> 2. Connect Claude or another agent ({agents link}). Give it one task you can
>    check, answer its question in the app, then Accept or Send back its work
>    in Review.
> 3. While an agent works on a task, press Stop, or Pause all agents, and see
>    what happens.
>
> (As sent, the list is the ten items of `registry/beta.json`, and the mail
> adds: “The beta notes which of these parts you used and when, never what
> you wrote.”)
>
> When something breaks, confuses you or works well, tell me here:
> {feedback link}. Say what you tried and what you expected. If an agent was
> involved, add the prompt.
>
> Your year of Pro starts the day Septena launches. It goes to any account
> you make with {email}. If you sign in with another address, or with Hide My
> Email, open this link once to claim it: {plan link}
>
> Michell

### 4.3 Check-in (day 4, once)

Subject: **How is Septena so far?**

> You joined the beta four days ago. What has got in your way? One line is
> enough: {feedback link}
>
> {only when no account has the grant yet:} Your Pro year isn’t on an
> account yet. Sign in to Septena, then open the claim link in my first mail,
> “You’re in the Septena beta”.

Only a hash of the plan link is stored, so this mail points at the welcome
mail instead of repeating the link. The launch mail does the same.
>
> Michell

### 4.4 Launch (when mz sets the launch date)

Subject: **Your year of Pro has started**

> Septena is out today, and your year of Pro runs until {date}. Thank you for
> testing it with me.
>
> Michell

## 5. Decisions

Decided 2026-11-28 (mz took the defaults; overrule any of them):

| Decision | Answer |
|---|---|
| Does the Pro year need a sent note, as Codex’s page said? | No. Joining is enough. |
| Pro during the beta, or only from launch? | Pro from the claim, ending 12 months after launch. |
| A day-4 check-in mail? | Yes, one, and none after it. |

## 6. Work, in order

1. Backend: tables, `POST /v1/beta/join`, App Store Connect client (reuse the
   ES256 signer from `scripts/testflight-distribute.mjs`), grant hook in
   sign-in, plan link at join, the four mails, day-4 cron, admin section,
   `gen:contract`. Unit tests for the store and the grant hook.
2. Secrets on the backend Worker from the local App Store Connect key: `backend/scripts/setup-beta-secrets.sh`.
3. Privacy page: a “Beta” block (what is stored, that Apple gets the email).
4. Site: the page in §3, the join form, the three-step drawing, Codex’s
   Support form changes.
5. mz: turn off the public TestFlight link, make the first code, send §4.1.

## 7. The checklist in the app

mz, 2026-11-28 (ADR 0064 amendment): the beta asks for feedback on ten
parts of the app. The checklist is a normal project in the tester's list,
and the backend measures which parts the tester really used. Only an account
that holds a tester's Pro grant gets any of this. No badges, no reminders.

### 7.1 The seeded project

- **The items** live in `registry/beta.json`: inbox-today, do,
  second-device, fade, connect-agent, review-stop, discuss, move-in, siri,
  capture. The `project` block holds the project's title and notes.
- **When:** the first time a tester's grant lands on an account
  (`claimPlusLink`, which the sign-in grant also runs), `GET /v1/beta` for a
  tester who has none yet (testers granted before seeding shipped), and the
  hourly sweep. The tester row records `seededAt` when seeding starts, so it
  runs once per account, even when the tester deletes the project. A seed
  that fails before it writes anything clears `seededAt` and runs again.
  Seeding never fails a sign-in or a claim.
- **What:** one project, "Septena beta", with no area and the registry
  notes. One open task per item, in registry order: title = the item title
  without its Markdown links, notes = the `try` line. Each link in the title
  becomes one `about` reference (a URL key on `https://septena.app` + path,
  snapshot title = the link words). `source` is `app`, `addedVia` is null.
- **How:** one push through `TaskStore.push`, checked against the push
  schema, with the actor `system:beta`. It syncs to every device like any
  other write. The tester row keeps `seedProjectId` and `seedTaskIds`
  (item id to task id).
- **The Today card:** the first time the app sees a tester, one card
  (`cardTitle`, `cardBody`) opens the project (`cardOpen`) or closes for good
  (`cardDismiss`).

### 7.2 What the backend measures

Content-free: times and counts, never task text. A **user write** is a change
by an app session (`app:` actor). Agents (`mcp:`), the server (`system:`)
and other members of a shared project (`member:`) are not the user. The
seeded project and its tasks never count. Readings come from the account's
own tables (`TaskStore.betaUsage`); the tester row stores the result, and a
first time never moves later and never goes away (a device that signed out
or an agent that was disconnected still counts).

| Item | Did it, first at |
|---|---|
| inbox-today | A task whose insert had no area, no project and no Today, that a later user write gave Today, an area or a project (change log). |
| do | The earliest `do_sessions.startedAt`. |
| second-device | The `firstSeen` of the second device (devices row with a live session). A new sign-in on the same device is a new session, so it counts too. |
| fade | `fadeSweptAt` set (the weekly question answered), or a task dropped with `dropReason` "faded". |
| connect-agent | The earliest `connections.createdAt`. |
| review-stop | A user write that moves a conversation's `endState` off `needs_verify` (Accept or Send back), or sets `stoppedAt`, or turns `agentsPaused` on; or a conversation with `stoppedAt` set. |
| discuss | The earliest user turn in a thread that has a provider turn whose provider is not `claude`: the app's own model ran it. A thread with only a connected agent's turns does not count. |
| move-in | A task with `addedVia` "import". |
| siri | A task with `addedVia` "shortcut". |
| capture | A task with `addedVia` "quick-entry", "quick-add" or "share". |

**Ticked** = the seeded task for the item is done.

`addedVia` (registry enum `taskAddedVia`) comes from the app push. The
server writes "agent" on a task an MCP connector creates (agent keys
included: they work over MCP). No REST path creates a task for an agent
key, so the server writes no "api" today. The watch's REST create sends no
`addedVia`.

Further readings, all per tester and content-free:

- **Repeat use.** Active days = distinct UTC days with at least one user
  write, settings and the seeded rows left out, and so are writes of the fade
  clock alone (`fadedAt`, `touchedAt`), which the app makes by itself. Week n
  after `joinedAt` = days [7(n−1), 7n). The backend keeps weeks 1, 2 and 4,
  and the time of the third active day of week 1.
- **Agent loops.** One task where an agent worked (any `mcp:` change on the
  task, its conversation or its turns, a claim included), a provider turn
  with a question has a later user turn, and a user write set a done end
  state (`agent_done`, `human_done`, `agent_assisted_done`; Accept in Review
  writes `agent_assisted_done`). Counted in total and in the last 7 days.
- **A normal week** (last 7 days): tasks the user added (inserts by a user
  write; headings and imports left out), tasks the user completed (status
  to done), tasks the user moved to Today (`today` to true).
- **The funnel:** joined, signed in (grant on an account), first own task
  added, first task completed, 3+ active days in week 1, day-7 answer given.
  Apple's invite accepted is unknown to us, so it is not a step.

The account summary (ADR 0043/0058) carries the product-wide versions of
the last two for every account (`agentLoops7d`, `userTasksAdded7d`,
`userTasksDone7d`, `userMovedToday7d`), so the Product page and the daily
snapshot show them with history.

The measurement runs on `GET /v1/beta`, on the admin lookup, and in the
hourly sweep for the testers whose reading is older than 6 hours.

### 7.3 The day-7 question

Once, on day 7 after the join (hourly sweep, as the day-4 check-in, which
stays):

Subject: **One question about Septena**

> You have had Septena for a week now. I have one question, and one tap
> answers it.
>
> **How would you feel if you could no longer use Septena?**
>
> [Very disappointed] [Somewhat disappointed] [Not disappointed]
>
> You can change your answer later with the same buttons.
>
> Michell

Each button links to `api.septena.app/beta/answer/<token>?a=very|somewhat|not`.
The token is random per tester; only its hash is stored. GET shows the
answer with a button and stores nothing, so a mail scanner answers nothing.
POST stores `answer` and `answeredAt` on the tester row; a later answer
replaces it. The thanks page offers the feedback link.

### 7.4 Admin

The Beta card on the Plans page: the codes; the funnel per code and in
total, with the drop between steps; per item, testers who did it and who
ticked it; per week (1, 2, 4), testers whose week has ended and those active
on 3+ days in it; medians of a normal week and of agent loops; the day-7
answers and the share of "very" among them (the usual bar is 40%). A lookup
by one email (a POST form, never in a URL) shows that tester's items (did:
date or no, ticked: yes or no), funnel dates, active days per week, week
counts, loops and answer. No list of emails anywhere.

### 7.5 API

`GET /v1/beta?platform=ios|ipados|macos|web|android|windows|linux`
answers `{ member: false }`, or `{ member: true, projectId, cardDismissedAt,
copy: { cardTitle, cardBody, cardOpen, cardDismiss } }`. `projectId` is null
only while the seed has not run. `platform` is still required; the answer no
longer depends on it.

`POST /v1/beta/progress` takes only `{ dismissCard: true }` and answers 204,
or 404 for a non-tester. The item ticks, “I tried it” and “I used it this
week” are gone: ticking is the task's own checkbox.
