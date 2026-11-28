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
