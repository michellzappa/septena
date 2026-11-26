# 0047. Decisions and open questions are typed entries in the notes log

- Status: proposed (2026-11-26), agent defaults, mz may overrule
- Date: 2026-11-26
- Deciders: mz (agent proposed)
- Builds on: [ADR 0008](0008-agent-loop-rules-live-in-the-store.md),
  [ADR 0012](0012-project-notes-are-agent-context.md),
  [ADR 0025](0025-shared-rust-core.md)
- Amends: [ADR 0044](0044-review-is-one-place.md) and
  [ADR 0046](0046-agent-work-is-a-review-group.md) (the Review groups)

## Context

Agents record decisions with `tasks_notes_log`. The tool writes a
`### <day> · <agent>` entry under `## Log` in project and area notes. The
entry has no type. Agents and mz type "mz decided" or "Claude suggested" by
hand. Nothing tells a reader what is settled, what is only a suggestion, or
what is still open.

Task questions already exist. A provider turn with options is an open
question on its task: the store ends the claim, Review shows it under
Questions, and a user turn answers it. A question about a whole project has
no place.

mz (2026-11-22): build on `tasks_notes_log`, do not add a parallel system.

## Decision

1. **A decision or a project question is a log entry with a marker line.**
   The marker is one HTML comment directly under the entry heading:
   `<!-- septena:decision id=k3m9qa state=suggested task=jb5e6r -->`.
   Markdown renderers hide it. Agents read it as text. An entry without a
   valid marker is a plain note. The notes stay the one source of truth. No
   new table, no new synced entity.
2. **The marker grammar is a wire contract.** It is fixed in
   `docs/IDENTIFIERS.md` and parsed once, in the shared Rust core. The
   backend, the Apple apps and Android call the core. Unknown keys are
   ignored, so the grammar can grow.
3. **Only the user settles.** An agent writes a decision only as
   `state=suggested`, and a question only as `state=open`. The user moves a
   suggestion to `decided` or `declined`, and a question to `closed`. The
   store refuses an agent write that settles an entry (`human_decides`). One
   exception: an agent may record `state=decided by=user` when it names a
   user turn on the linked task, and the store checks that an app actor
   wrote that turn.
4. **A task question stays a provider turn with options.** A question entry
   in the log is for a project or an area, never for one task. So there is
   one kind of question per scope, not two for the same thing.
5. **Review gains a Suggestions group**, after Finished work. Project and
   area questions join the Questions group. The badge counts Questions (both
   kinds) and Finished work. Suggestions do not count.

## Consequences

- The ADR 0012 rule (the log only grows at its end for an agent) already
  stops an agent from editing an earlier marker. The store adds one check on
  the appended text.
- App edits of a marker go through the normal notes upsert with `base`, so a
  concurrent agent append merges (`mergeText.ts`). Area notes gain `base`.
- A user who edits the raw text can break a marker. The entry then reads as
  a plain note. Nothing is lost.
- The marker tokens are English data, not copy. The apps render localized
  labels from the registry.
- A marker change is a notes revision, so the decision history is the notes
  history (`note_revisions`).
- Old entries stay plain notes. The user marks one as a decision or a
  question in the app.

## Links

`docs/DECISIONS_SPEC.md`, `docs/PROJECT_NOTES_SPEC.md`, `docs/REVIEW_SPEC.md`,
`docs/IDENTIFIERS.md`, `backend/src/shadow/notes.ts`,
`backend/src/store/TaskStore.ts` (`agentMayWriteNotes`)
