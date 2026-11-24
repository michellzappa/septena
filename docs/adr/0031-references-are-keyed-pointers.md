# 0031. A task reference is a keyed pointer, separate from a link

- Status: accepted (2026-11-24)
- Date: 2026-11-24
- Deciders: mz
- Builds on: [ADR 0003](0003-external-links-run-server-side.md) (links),
  [ADR 0015](0015-shared-registries-for-cross-platform-clients.md) (registries),
  [ADR 0025](0025-shared-rust-core.md) (shared core)
- Spec: [TASK_REFERENCES_SPEC.md](../TASK_REFERENCES_SPEC.md)

## Context

A task often comes from something else, or is about something else: an email,
a mail thread, a calendar event, an issue, a document. Septena has no place
for that pointer. `source` says who created the task. `artifact.refs` is a
list of untyped strings. The email capture spec dropped the Message-ID.

Linked projects (ADR 0003) have `extKey`, but `extKey` means that the task
**is** the remote item, and a link syncs its fields. A task that is **about**
an email must not sync with it, and one task can be about several things.

Keys are stored for the life of the account and cross every client. A change
of key format later needs a migration of all rows on all platforms.

## Decision

A reference is a row of its own (entity `taskRef`, table `task_refs`) that
holds a canonical key `<kind>:<id>` and a small snapshot. It never syncs
fields with its target. References and `extKey` share one key grammar. The
parser and the normaliser of that grammar live once, in the shared Rust core.

## Consequences

- One lookup answers "which tasks point at this?". Duplicate checks, reply
  marks and back-links all use it.
- An email reference opens in the mail app that the device has, because the
  key is the RFC Message-ID and not a provider's URL.
- Sync, export, import, history and permissions get one more entity.
- The key grammar is permanent. A new kind is an addition; a change to the
  normal form of an existing kind needs a new ADR and a migration.

## Links

#296, `docs/LINKED_PROJECTS_SPEC.md` §4, `docs/EMAIL_TO_TASK_SPEC.md`.
