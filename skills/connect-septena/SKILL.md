---
name: connect-septena
description: Connect to a person's Septena tasks at api.septena.app/mcp and check that the connection works. Use when a person asks you to set up Septena, or when a Septena call fails because the sign-in is missing, expired or read-only.
---

# Connect to Septena

Septena is a task app. The person's tasks live on Septena's server. You reach
them over MCP at `https://api.septena.app/mcp` (streamable HTTP, OAuth with
PKCE). The setup steps for each client are in
https://septena.app/agents.md.

## Pick the way in

| Your client | Way in |
| --- | --- |
| Can open a browser for OAuth | Add the server and sign in. |
| Cannot open a browser (a script, a scheduled job, a headless runner) | An agent key, sent as `Authorization: Bearer sk1.…`. |

Do one step at a time. Wait for the person to confirm a step before you give
the next one.

## Procedure: a client with OAuth

1. **Add the server** `https://api.septena.app/mcp` in your client.
2. **Start the sign-in.** A browser page opens. The person can approve with a
   Septena app they already use (a QR code or an 8-character code), or create
   an account or sign in with email on that page.
3. **Tell the person how to approve with the app:** Settings, then AI &
   Agents, then Connect Claude. They type the code, press Continue, name the
   agent and press Approve.
4. **Wait** until the browser page says the sign-in is done.

## Procedure: no browser

If the person already has an agent key, use it. They make one in the app:
Settings, then AI & Agents, then Agents, then New Agent Key. The app shows the
key once. Never print it, log it or write it into a file in a repository.

If they have no key, create their account, or connect to the one they have,
with an email confirmation:

1. `POST https://api.septena.app/v1/agent/signup/start` with
   `{"email": "<their email>", "agentName": "<your name>", "access": "write", "timeZone": "<IANA time zone>"}`.
   `access` is `"write"` by default, or `"read"` for read-only.
2. Tell the person to open the confirmation link that Septena emailed them
   and approve. The link works for 10 minutes.
3. `POST https://api.septena.app/v1/agent/signup/poll` with
   `{"requestId": "...", "pollSecret": "..."}` about every 3 seconds. `202`
   means the person has not answered. `410` means they declined or the link
   expired: stop and tell them.
4. On `200`, store the `key` securely and send it as a Bearer token to
   `https://api.septena.app/mcp`. When the reply has `created: true`, the
   account is new: follow https://api.septena.app/onboard.md.

A refused signup call carries `error.code` and `error.hint`. Follow the hint.
Send the call again only when `error.retryable` is `true`.

## Check the connection

1. Call `tasks_orientation`. It returns the server's guide, every tool by
   family, and which areas have a brief.
2. A write refused as `read_only` means the connection was made before
   Septena let agents write. The person removes the connector and adds it
   again.
3. A `401` or `unauthorized` means the sign-in expired or the person
   disconnected the agent. Connect again.

## Next

- Before you create a task: [add-a-task-once](https://septena.app/skills/add-a-task-once/SKILL.md).
- To work a task: [work-a-task](https://septena.app/skills/work-a-task/SKILL.md).
- The full brief: https://api.septena.app/skill.md.
