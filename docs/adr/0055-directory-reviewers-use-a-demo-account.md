# 0055. Directory reviewers use a demo account behind a reviewer code

- Status: accepted (2026-11-26)
- Date: 2026-11-26
- Deciders: mz
- Issue: [#85](https://github.com/michellzappa/septena/issues/85)
- Code: `backend/src/shadow/reviewer.ts`, `POST /oauth/pair/reviewer`,
  `POST /v1/admin/reviewer/prepare`, `backend/scripts/reviewer-seed.mjs`

## Context

The Claude and ChatGPT connector directories test a connector before they
list it. Their reviewers must connect `api.septena.app/mcp` without help.
Septena connects an agent with a pairing code that a signed-in app approves.
A new account starts only from Sign in with Apple on iPhone or iPad, and
those apps are not public yet. Email sign-in exists but is switched off
(#564). A reviewer has no way in.

mz chose on 2026-11-26: a demo account that reviewers can use without him.

## Decision

1. **One demo account with invented sample data.** It belongs to nobody. It
   holds areas, projects and tasks written for the review, and a Pro grant so
   reviewers from both directories can connect at the same time.
2. **The pairing page offers it only in reviewer mode, and only for the
   reviewer code.** Reviewer mode is on when the secrets `REVIEWER_CODE` and
   `REVIEWER_ACCOUNT_ID` are both set and `REVIEWER_MODE_UNTIL` (optional) has
   not passed. The page then shows a "Directory reviewer?" form. A reviewer
   types the code from the submission notes; the server compares it in
   constant time and approves the pairing for the demo account only.
3. **An ordinary connection never lands in the demo account.** Without the
   code the page pairs exactly as before. The code is never logged, wrong
   codes count against the IP (five per pairing window), and any missing or
   malformed value turns reviewer mode off.
4. **The demo account is filled through the public tools.** An admin route
   gives it an app session and the Pro grant and returns a short-lived
   connector token. The seed script writes the sample data with that token
   through the MCP tools, then revokes it. It writes nothing when the data is
   already there.

## How to turn it off

Delete the `REVIEWER_CODE` secret (`wrangler secret delete REVIEWER_CODE`),
or let `REVIEWER_MODE_UNTIL` pass. The form disappears and the route answers
404. Agents already connected to the demo account keep working until they are
disconnected; they only ever see the sample data.

## Consequences

- Anyone with the code can connect an agent to the demo account and change
  its sample data. That is the point: reviewers try the write tools. The code
  goes only into the directory submission forms.
- The demo account is a normal account to the server. Plan limits, Stop and
  Pause all agents apply to it as to any account.
- When a directory asks for a re-review, rerun the seed script on a fresh
  account id, or reuse the account as it is.
