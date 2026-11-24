# 0033. Drop the GitHub integration; issue links are references

- Status: accepted (2026-11-24)
- Date: 2026-11-24
- Deciders: mz
- Supersedes: [ADR 0032](0032-github-issues-are-followed-not-mirrored.md)
- Builds on: [ADR 0031](0031-references-are-keyed-pointers.md)

## Context

ADR 0032 replaced the GitHub mirror with a smaller integration: follow, browse,
pull and send. A review the same day found that the smaller one still asks
people for a habit (link each task by a set gesture), needs a GitHub App, and
has no known demand. Connected agents already read GitHub with their own
access and write to Septena through MCP. The apps already show an issue link
that is parsed from conversation text, with one parser in Swift and a second
in TypeScript.

## Decision

Septena does not connect to GitHub. An issue or pull request is a reference of
kind `issue`, like an email or a web page. The issue links that exist today
become references, and the text parsers and the row chip go away. An agent
that has GitHub access may move a task to Review when its issue closes.

## Consequences

- No GitHub App, tokens, webhooks or access checks.
- An issue link has no live state. It opens in the browser, and GitHub decides
  who may read it.
- Link parsing lives once, in the shared core.
- A project keeps `githubRepo`, so an agent knows where its work lives.
- Reopen this when several users ask for it unprompted.

## Links

`docs/TASK_REFERENCES_SPEC.md` §6.6, #386, #387
