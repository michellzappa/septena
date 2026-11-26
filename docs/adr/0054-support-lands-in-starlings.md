# 0054. Support goes to Starlings, through a native form

- Status: accepted (2026-11-26)
- Date: 2026-11-26
- Deciders: mz
- Supersedes: [docs/feedback.md](../feedback.md) (the iCloud-era feedback design)
- Spec: [SUPPORT_SPEC.md](../SUPPORT_SPEC.md)
- Starlings: `docs/SUPPORT.md` (the app channel and public forms)

## Context

Septena has no support system. Every way to reach the maker is a `mailto:`
link to a personal Envisioning address: Settings ▸ About ▸ Send feedback on
iOS, iPad, Mac and Android, seven pages on septena.app, the App Store text and
`SECURITY.md`. A message leaves no record, has no app version, and has no
diagnostics. The address is the wrong company.

Starlings already has a support system. The Septena workspace
(`septena.starlings.work`) exists. Starlings takes messages through two doors
that end at the same place, a private conversation on the workspace's intake
record with a row in Inbox:

- **The app channel** (`POST /api/support/app-intake`): a workspace's own
  backend forwards its app's support messages, signed with a shared key, and
  receives the members' replies. Bipe uses it.
- **Public forms** (`POST /api/forms/<form>`): a workspace's website posts a
  contact form. Starlings mails the sender a private link to the
  conversation. bipe.chat uses it.

mz chose on 2026-11-26: one form, no public email, support in the app as a
native form and not a web view, Starlings as the place where support is
answered, the existing rate limit, and one address only on the privacy
policy: mz@centaur-labs.io.

## Decision

- **Every support message goes to the Septena workspace in Starlings.** mz
  answers there. Septena keeps no second support inbox.
- **The apps send through the Septena backend** to the Starlings app channel.
  The form is native on every client (iOS, iPadOS, macOS, Android, web). The
  backend keeps the conversation, so the reply shows in the app.
- **The website sends to a Starlings public form.** A visitor has no app to
  read a reply in. Starlings mails the private link.
- **No public email address**, with one exception: the privacy policy names
  mz@centaur-labs.io for data requests. Security reports go through GitHub
  private vulnerability reporting.
- **Diagnostics are opt-in per message** and never include task content.

## Consequences

- Easier: one place to answer, a record of every request, the version and
  diagnostics on each message, and replies inside the app.
- Harder: Septena depends on Starlings for support. When Starlings is down,
  the backend queues the message and sends it later.
- Given up: the sender's own mail client. A reply comes in the app (or by the
  Starlings link for website senders), not as a mail thread.

## Links

Spec [SUPPORT_SPEC.md](../SUPPORT_SPEC.md). Starlings `docs/SUPPORT.md`,
`docs/FORMS.md`, `packages/contracts/src/app-intake.ts`.
