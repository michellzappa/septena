# Support spec

**Status:** accepted (2026-11-26). Rests on [ADR 0054](adr/0054-support-lands-in-starlings.md).
Replaces [feedback.md](feedback.md). Milestone: Launch Septena. Label: `track:launch`.

## 1. Goal

A person who needs help writes one message in one form, in the app or on
septena.app. mz answers it in Starlings. The reply reaches the person in the
app, or by a private link for a website sender. No public page or screen
shows an email address, except the privacy policy.

## 2. Today (2026-11-26)

| Surface | Today | After |
|---|---|---|
| Settings ▸ About ▸ Send feedback (iOS, iPadOS, macOS) | `mailto:` in `Septask/SeptaskSettingsView.swift` | Native Contact Support form (§4) |
| Settings ▸ About ▸ Send feedback (Android) | `mailto:` in `android/.../ui/SettingsSurfaces.kt` | Native form |
| Settings ▸ About (web client) | `web/src/components/SettingsModal.tsx` | Native form |
| Mac Help menu | Help only | Help, then **Contact Support…** |
| septena.app `/support` | `mailto:` | The website form (§6) |
| septena.app About, brand page, compare pages, help "write to us" | `mailto:` from `lib/site.ts` `CONTACT_EMAIL` | Link to `/support` |
| septena.app privacy policy | `mailto:` | mz@centaur-labs.io (the one address) |
| App Store text (`docs/APPSTORE-SEPTASK.md`, site `content/appstore-review.json`) | "write to mz@envisioning.com" | "use Contact Support in Settings" |
| `SECURITY.md` | personal email | GitHub private vulnerability reporting |

The interim fix (2026-11-26) changed every remaining address to
mz@centaur-labs.io. The phases below remove them.

## 3. Shape

```
iOS / iPadOS / macOS / Android / web client
   │  POST /v1/support/messages
   ▼
api.septena.app (backend/)  ── D1 septena-support: the conversation
   │  POST /api/support/app-intake   (signed "intake")
   ▼
septena.starlings.work  ── intake record, one private thread per sender, Inbox row
   │  POST /v1/support/replies       (signed "reply")
   ▼
api.septena.app  ── stores the reply, mails a notice, the app shows it

septena.app /support form
   │  POST /api/forms/contact   (CORS: septena.app, www.septena.app)
   ▼
septena.starlings.work  ── same intake record; Starlings mails a private link
```

Both doors end on the same Starlings intake record. mz answers both in the
same Inbox.

## 4. The app form

One entry point per client: `Support.open()`. It is called from:

- Settings ▸ About ▸ **Contact Support** (the registry surface
  `send_feedback` becomes `contact_support`).
- The Mac Help menu: **Contact Support…**, a registry action
  (`registry/actions.json`, `support.open`), after Help.
- *(Later, SUP5)* Get Help on error alerts (`StoreHealthNotice`, sync
  failures).

The screen has two parts:

1. **Your conversation.** Earlier messages and replies, oldest first. Empty
   on first use. An unread reply shows a dot on the Contact Support row.
2. **New message.**
   - Message: multi-line, required, 1 to 4,000 characters.
   - Email: shown only when signed out, and then required. Signed in, the
     account email is used and not shown.
   - **Include diagnostics**: a toggle, off *(default)*. Below it, one line
     that lists what it adds.
   - A link to Help above the field: "Most answers are in Help."
   - Send. On success the message joins the conversation. On failure the text
     stays in the field with an error and Try Again (no state without an
     exit).

Presentation: a sheet on iPhone and iPad, a window sheet on Mac, a full
screen on Android, a modal on the web client. Same fields, same order, same
words on every client. Copy lives in the registry with its translations and
goes through the humanizer skill.

### Diagnostics

Only when the toggle is on, per message. Never task, project or area content,
titles or notes.

- platform, OS version, device model
- app version and build
- signed in or not, plan
- last sync time, last sync error code and its request id
- `StoreHealthState` failure count

## 5. The backend

New module `backend/src/support/`. Storage: D1 database `septena-support`
*(default; a new database, not `SIGNUPS`, which the website owns)*.

### Who is the sender

- **Signed in:** the bearer token. `reporter.ref` is `user:<userId>`.
- **Signed out:** the app makes a random 32-byte support key on first send
  and keeps it in the keychain (Apple) or encrypted preferences (Android) or
  `localStorage` (web). It sends `X-Septena-Support-Key`. `reporter.ref` is
  `install:<sha256(key)>`. The backend stores only the hash. Email is
  required.
- A person who signs in later keeps the signed-out conversation: the app
  sends the key once with the token, and the backend moves the rows to the
  user *(default)*.

### Routes

| Route | Caller | Does |
|---|---|---|
| `POST /v1/support/messages` | apps | Validates (Zod), stores, forwards to Starlings. Body: `message_id` (uuid, the idempotency key), `text`, `email?`, `diagnostics?`. Answers 202 with the stored message |
| `GET /v1/support/messages` | apps | The sender's conversation and the unread count |
| `POST /v1/support/read` | apps | Marks replies read |
| `POST /v1/support/replies` | Starlings | Verifies the `reply` signature, stores the reply (idempotent on `message_id`), mails a notice |

- **Rate limit:** the existing pattern, 5 messages a minute and 30 a day per
  `reporter.ref`, and per IP for signed-out senders.
- **Forwarding:** `kind: "report"` when diagnostics are on, else
  `"message"`. `report.platform` is `ios`, `ipados`, `macos`, `android` or
  `web`. The signature is HMAC-SHA256 of `intake.<timestamp>.<rawBody>` with
  `APP_INTAKE_KEY` (a wrangler secret, 64 hex, decoded to 32 bytes).
- **Starlings down:** the row stays `pending`. The hourly cron sends pending
  rows again, oldest first. The app shows the message as sent: it is stored.
- **Reply notice:** when the sender has an email, the backend mails it
  through the `EMAIL` binding: the reply text, and "Open Septena, Settings,
  About, Contact Support to answer." *(default: the mail carries the reply
  text)*. A push notification is later (SUP5).
- **Retention:** 365 days, then the cron deletes the rows.
- Never log a message body, an email or a support key.

## 6. The website form

septena.app `/support` keeps its help search and gets the form: name, email,
message, and the help pages that match before Send. It posts to
`https://septena.starlings.work/api/forms/contact`. Starlings mails the
sender a private link to the conversation, in English. The page carries
`from=site` and the site version, as Starlings' own support page does.

Help's "write to us" (`components/help-answered.tsx`) links to
`/support?from=help&page=<href>`.

## 7. Starlings

Work in `envisioning/starlings`:

1. Open the app channel for the `septena` workspace: `APP_INTAKE_KEY` and
   `APP_INTAKE_REPLY_URL = https://api.septena.app/v1/support/replies`.
2. Widen `appIntakeReportSchema.platform` with `ipados`, `macos`, `web`, and
   `appIntakeReporterSchema` with an optional `email`, so a member can see
   who wrote. A contract change on both sides.
3. A `contact` entry in `packages/contracts/src/deployment-forms.ts` for
   `septena`: `files: 'thread'`, origins `https://septena.app` and
   `https://www.septena.app`, an English mail.

## 8. Phases and issues

| Phase | Repo | Issue | Depends on |
|---|---|---|---|
| S0 | septena | ADR 0054, this spec, `SECURITY.md`, interim address fix | none |
| ST1 | envisioning/starlings | #1430 Septena app channel and contact form | none |
| SUP1 | septena | #675 Backend support routes | ST1 for a live round trip |
| SUP2 | septena | #676 Native Contact Support on every client | SUP1 |
| SUP3 | septena-site | septena-site#41 `/support` form, no address on any page | ST1 |
| SUP4 | septena + septena-site | septena-site#42 App Store text | SUP2, SUP3 |
| SUP5 | septena | #677 Get Help on error alerts, push on reply, screenshots | SUP2 |

## 9. What mz does by hand

- Turn on the Support work module for the Septena workspace in Starlings
  Admin, if ST1 cannot do it in code.
- Check the sender address of Starlings' mail for Septena.
- Upload the App Store text after SUP4 (App Store uploads are mz's).

## 10. Open questions

| Question | Default |
|---|---|
| A new D1 database or a table in an existing one | New database `septena-support` |
| Diagnostics toggle starts on or off | Off |
| Reply notice mail carries the reply text | Yes |
| A signed-out conversation moves to the account at sign-in | Yes |
| Help pages matched in the app before Send | Later; v1 shows a link to Help |
