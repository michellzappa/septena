# 0038. Agents are the integrations; Septena connects to no source

- Status: accepted (2026-11-25)
- Date: 2026-11-25
- Deciders: mz
- Extends: [ADR 0033](0033-no-github-integration-issue-links-are-references.md)
  (the same rule, for every source)
- Amends: [ADR 0003](0003-external-links-run-server-side.md) (no capture feeds)

## Context

Other task apps connect to many services: a button in Slack, a starred mail,
an issue tracker that syncs. Each connection needs an app registration, stored
tokens, webhooks and upkeep. Each one moves items and leaves the judgment to
the user: a "send to Septena" button still makes the user read, decide and
press. A connected agent already reads those services with the user's own
access, and it can decide which items are tasks. ADR 0033 dropped GitHub for
this reason, one service at a time.

## Decision

- **An agent reads the source and proposes tasks. Septena never connects to a
  source.** Slack, mail accounts, issue trackers, meeting notes and document
  tools get no connector, no capture feed and no button in their product.
- **A source is offered as a prompt** the user gives to the agent they have.
  The prompts live in one registry, and every surface renders it.
- **Septena owns what makes a proposal safe to repeat:** the reference to the
  item, the duplicate check, the memory of what the user turned down, and the
  Inbox where the user accepts. These are store rules, so they hold for every
  agent (ADR 0008).
- **Septena still builds plumbing that must work with no agent:** one-time
  imports, the calendar (feed and display), the mail forwarding address, the
  system's own capture (Share, Shortcuts, Siri) and one public API.
- **Starlings links (#12) are not decided here.** The other linked-project
  providers are not planned.

## Consequences

- No third-party tokens for sources, and no privacy text for them.
- The quality of a proposal depends on the user's agent. A user without an
  agent gets nothing from Slack, so connecting one must be easy (#103).
- A source needs no work from us beyond a tested prompt and, when its links
  have several spellings, a key rule in the core.
- #15 (capture feeds, Gmail first) is closed as not planned.
- Reopen this for one source when several users ask for it unprompted and an
  agent cannot do it.

## Links

`docs/TASK_REFERENCES_SPEC.md`, `docs/LINKED_PROJECTS_SPEC.md`, ADR 0039,
#496 duplicate check, #497 turned-down items, #498 Slack keys, #500 filed
suggestions, #501 source prompts, #90 public API, #134 mail forwarding
