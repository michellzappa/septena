# 0051. A Septena client inside another app is a Septena surface, not a source integration

- Status: accepted (2026-11-26)
- Date: 2026-11-26
- Deciders: mz
- Clarifies: [ADR 0038](0038-agents-are-the-integrations.md)
- Spec: [RAYCAST_EXTENSION_SPEC.md](../RAYCAST_EXTENSION_SPEC.md)

## Context

ADR 0038 says Septena connects to no source: no connector, no capture feed
and no "send to Septena" button in another product. On 2026-11-26 mz decided
to build a Raycast extension (#666). Raycast is another product, so the rule
needs a line between the two cases.

## Decision

- **A client is a Septena surface.** A client shows the user's Septena data
  and takes what the user types into it. The CLI (#653) and a Raycast
  extension are clients. They run inside another app, but they read no data
  from that app.
- **A source integration reads another service's items.** It stays banned
  (ADR 0038). A client never reads mail, chat, issues or documents from the
  app it runs in, and never adds a button to that app's own items.
- **A client is built on the public surface only.** It uses an agent key
  (#86) or OAuth, the public API (#90) or the MCP connector, and the server's
  rules. It holds no task rule of its own: a rule lives in the core or on the
  server (ADR 0025).
- **A client follows the same-behavior rule.** Its actions use the IDs and
  the copy in `registry/actions.json` and `registry/surfaces.json`.
- **Text the user selects is the user's input.** A client may offer the
  selected text or the clipboard as a task title when the user runs a
  command, as the system Share sheet does. It reads nothing in the
  background.

## Consequences

- The Raycast extension (#667) and the CLI are allowed. A Slack shortcut, a
  Gmail add-on or a "Save to Septena" browser button on a page's items stay
  banned.
- Each client is code we maintain, in this repo, against a public contract.
  A contract change must keep every client working (ADR 0050).
- A store listing is outward-facing: mz submits or approves it.

## Links

ADR 0038, ADR 0050, #86 agent keys, #90 public API, #653 CLI, #666
registries, #667 Raycast extension
