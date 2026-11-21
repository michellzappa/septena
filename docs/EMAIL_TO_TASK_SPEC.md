# Email-to-task forwarding address (Mail to Septena) — spec

**Status:** proposal (2026-11-21). Defaults in §6 stand unless mz overrules.
**Decisions:** [ADR 0002](adr/0002-own-backend-replaces-icloud.md), [ADR 0007](adr/0007-septena-is-the-task-app.md), [ADR 0010](adr/0010-free-server-tier-with-limits.md), [ADR 0011](adr/0011-self-hostable-backend.md).
**Builds on:** `backend/src/index.ts`, `backend/src/store/TaskStore.ts`, `docs/SYNC_SUBSCRIPTION_SPEC.md`, `Septask/SeptaskSettingsView.swift`.
**Tracking issue:** [#134](https://github.com/michellzappa/septena/issues/134).
**Owner of decisions:** mz. Defaults chosen by the author are marked *(default)*.

## 1. Goal

Give every signed-in user a personal, revocable forwarding email address (e.g. `in.<token>@mail.septena.app`) powered by **Cloudflare Email Routing** into the `backend/` Worker, so any email from any mail client (Apple Mail, Outlook, Gmail, Fastmail) lands cleanly in the Septena Inbox band.

**UX / IA ideal (progressive disclosure):** Hidden in **Settings ▸ Connections** until enabled. One tap turns it on and generates the address (with Copy + Add to Contacts); one tap rotates or disables it.

## 2. Architecture & self-hostability (ADR 0011)

- **Inbound handler:** Cloudflare Worker `email(message, env, ctx)` handler in `backend/src/index.ts` receiving catch-all traffic for `mail.septena.app` (or the self-hoster's configured `EMAIL_INBOUND_DOMAIN`; cleanly disabled with a clear Settings notice when unset on a self-hosted Worker!).
- **Address format:** `in.<20-char-base32-token>@<domain>` — unguessable, indexed in D1/KV (`inbound_email_tokens` → `userId`, `enabled`, `createdAt`, `lastUsedAt`). Rotating immediately invalidates the old token.
- **No bounce / auto-reply loops:** Unknown or disabled tokens are silently dropped (or rejected at SMTP edge with 550) — never send automated reply emails.

## 3. Parsing & task creation rules

- **Placement:** Lands in the **Inbox band** (`status: "open"`, `area: null`, `project: null`, `today: false`, `source: "email"`, unacknowledged so it appears cleanly in Inbox for filing — never silently cluttering Today).
- **Title:** Email `Subject` with leading `Fwd:` / `Re:` stripped and truncated to `textMax` (2,000 chars); fallback `"(No subject)"`.
- **Notes:** Plain-text body (or HTML stripped conservatively to clean text), trimmed of excessive quoted-reply footers when obvious, clipped to `notesMax` (100,000 chars), prefixed with a quiet 1-line header (`From: <sender>`).
- **Attachments (honoring ADR 0010 paid sync gate):**
  - If user's plan table allows synced attachments (`attachmentsSyncEnabled` + under quota) and attachment ≤ 25 MB, store in R2 and insert `attachment` row linked to the task.
  - Otherwise (Free plan or over quota), skip attachment bytes cleanly and append one short line to task notes (`"1 attachment skipped (Plus syncs attachments)."`).
- **Abuse & rate limits:** Max 50 inbound emails/day per user *(default)*, max raw MIME message size 25 MB, strip dangerous HTML/scripts (store plain text only).

## 4. Phases

| Phase | Scope | Depends on |
|---|---|---|
| **EM0 — Cloudflare Email Worker & token management** | Add `inbound_email_tokens` table + `POST /v1/email-capture/{enable,rotate,disable}` API, `email()` Worker handler + MIME parser (plain text, subject cleanup, paid-plan attachment gate, rate limit), and unit tests with real `.eml` fixtures. | None |
| **EM1 — Settings ▸ Connections UI (Mac & iOS)** | Add progressive-disclosure `"Mail to Septena"` row in `SeptaskSettingsView` (enable/disable, copy address, Add to Contacts vCard export, rotate address). | EM0 |

## 5. Verification

- `.eml` parser unit tests (multipart/alternative, UTF-8/base64 subjects, Fwd/Re stripping, attachment gating, oversized/malformed MIME).
- `backend` typecheck + tests green; `SeptenaMac` + `SeptaskMac` builds green.

## 6. Open questions

| Question | Default |
|---|---|
| Inbound domain | `mail.septena.app` via Cloudflare Email Routing (configurable `EMAIL_INBOUND_DOMAIN` for ADR 0011 self-hosters) *(default)* |
| Daily inbound cap | 50 emails/day per account *(default)* |
| Plan availability | Enabled on Free and Paid accounts; email attachments require Paid R2 sync allowance *(default)* |
