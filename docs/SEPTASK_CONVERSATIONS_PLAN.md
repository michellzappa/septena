# Task Conversations in the AppKit shell — plan

Not built yet. This is the plan for §2 of `docs/SEPTASK_APPKIT_PARITY.md`,
written to be picked up cold. Read `docs/SEPTASK.md` ("AppKit shell on
macOS") for the shell's working rules first — everything here follows them:
presentation-only, mutators as the write boundary, no re-derived semantics.

## What it is

`TaskConvo` (`SeptenaCore/TaskConvo.swift`) is the persisted record of an
agent's work on a task: an append-only turn log, a terminal end-state, an
optional artifact (what the agent produced) and handoff (the human's last
mile), acceptance criteria, and an assignee. It's stored as JSON in
`TaskEntity.conversationJSON` — one field, no new record types — and the MCP
gateway writes it live, so this isn't dormant data waiting for a UI; agent
rows in Today can already carry a real conversation the shell currently
shows no trace of beyond the (now-drawn) unread-context dot.

The SwiftUI reference implementation is `ConversationCard`
(`Septena/Shell/Tasks/ConversationCard.swift`) + `ConversationEngine`
(same directory) — read both before starting; this plan doesn't restate
their logic, only how to bring it into AppKit.

## Where it surfaces

**Primarily the inspector** (`SeptaskKitInspectorController`,
`SeptaskKitInspector.swift`) — a task's conversation is detail, the same
tier as notes and dates, and the inspector already has the vertical real
estate a transcript needs. Add a collapsible "Conversation" section below
Notes, shown only when `task.conversation.hasStarted`.

**Secondarily the composer's Discuss pill** (`SeptaskKitComposer.swift`,
`KitComposerCell`) — SwiftUI's `TaskAttributeBar` shows a Discuss pill only in
edit mode when no conversation exists yet; pressing it starts one. Add a
`case discuss(NSView)` to `KitComposerCell.Action`, shown only when
`!task.conversation.hasStarted`, wired the same way the other pills reuse
existing presentation surfaces.

Do NOT build a third surface (no conversation tab, no separate window) —
two is already one more than ideal; a third would be actual scope creep
against "presentation only."

## Data flow — read

Nothing new. `SeptenaTask.conversation` is already decoded on every read
(`init(_:)` in `SeptenaCore/Models.swift`), so `LocalCache.tasks`/`allTasks`
already carry it — the inspector's existing `LocalCache` read gets the
transcript for free. No new fetch, no new cache.

## Data flow — write

All through `TaskMutator` (`SeptenaCore/Outbox.swift`), which already has
the full write surface:

- `appendConvoTurn(id:_:)` — post a `ConvoTurn`. A USER turn choosing a
  provider's option: `role: .user, step: <matching the proposal's step>,
  chosen: <label>, inReplyTo: <the proposal turn's seq>`. Free text instead
  of a button: same shape with `otherText` instead of `chosen`.
- `setConvoAcceptance(id:_:)`, `setConvoEndState(id:_:note:)`,
  `setConvoAssignee(id:_:)`, `setConvoArtifact(id:_:)`,
  `setConvoHandoff(id:_:)` — the rarer, mostly-agent-authored fields. The
  shell only needs to READ these for v1; writing them from the UI (e.g., a
  human overriding assignee) can wait.
- `acknowledge(id:)` — clears the agent cue. Call this the moment the
  inspector/composer opens on a row where `task.showsAgentCue()` is true, so
  opening the conversation is what dismisses the "unread" glow — matches
  what "engaging with it" means in `TaskCheckboxModel`'s corner-dot comment.
  This is also item §3's still-open half — landing it here closes both gaps
  in one change.

`propose` turns (the provider asking a question) are NEVER authored from
this shell — those come from the agent/gateway. The shell only ever appends
USER turns (choose / other-text) and reads everything else.

## UI pieces to build

Small, in dependency order:

1. **`KitConversationView`** (new file, `SeptaskKitConversation.swift`) — an
   `NSStackView` of transcript rows inside a scroll view, mirroring
   `ConversationCard.transcriptRow`: role-tinted leading glyph, the turn's
   text, timestamp. Read-only rendering first — get turns on screen before
   building the reply UI.
2. **Question block** — the SwiftUI `questionBlock`'s shape: the provider's
   `question` text, then its `options` as buttons in an `NSStackView`
   (reuse `KitPillButton` from the composer — same "recessed capsule"
   language, don't invent a second button style), plus a free-text
   `NSTextField` for the "other" escape hatch. Choosing a button or
   submitting text both call `appendConvoTurn` with the right `inReplyTo`.
3. **Artifact block** — `ConvoArtifact`'s `title`/`body` in a bordered
   `NSTextView` (read-only, selectable — it's often meant to be copied out).
4. **Handoff button** — one `NSButton` rendering `ConvoHandoff.instruction`;
   action depends on `actionType`: `.openURL` → `NSWorkspace.shared.open`,
   `.compose`/`.call` → build the appropriate `mailto:`/`tel:` URL and open
   it the same way, `.none` → no button, just show the instruction text.
5. **Wire into the inspector** — `SeptaskKitInspectorController.show(_:)`
   populates `KitConversationView` alongside notes; `refresh()` re-reads it
   like everything else there. Call `mutator.acknowledge(id:)` here per the
   note above.
6. **The Discuss pill** — last, since it depends on knowing how a
   conversation actually starts server-side (check `ConversationEngine` for
   whether "starting" is a mutator call, an MCP round-trip, or a local
   placeholder turn — this determines whether the pill can work at all
   without the gateway in the loop, or whether it should be scoped out).

## Explicit non-goals for v1

- Editing/deleting a turn — the log is meant to be append-only and
  auditable; don't add affordances SwiftUI doesn't have either.
- Rendering `subtasks` (epic decompose) as a nested list — surface the count
  only; full traversal is a separate feature.
- Any new mutator methods. Everything needed already exists on
  `TaskMutator`.
- Animating turn arrival — plain reload is fine for v1; the settle-beat
  infrastructure (`KitMotion`) is there if it's worth reusing later.

## Testing note

Per this repo's rule, no automated tests and no simulator — this is manual
verification once built. `SeptenaTask.showsAgentCue()`/`conversation` will
only be populated on rows the MCP gateway has actually touched, so testing
needs either a real agent-created task (ask Claude to create one via the
`septena` skill) or a hand-seeded `TaskConvo` via
`mutator.appendConvoTurn`/`setConvoAcceptance` in a throwaway debug call —
don't add permanent demo-seed data for this to `DemoSeed.swift` without
asking first, since conversation shape is exactly the kind of thing that
goes stale silently.
