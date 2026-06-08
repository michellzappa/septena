# Task Conversations — Phase 1 build ticket

**Make it visible and tappable.** Phase 0 landed the engine (shape + mutator + MCP
verbs, both servers). Phase 1 turns the conversation from MCP-only JSON into a
surface in the app: a **choice card** on the task detail + a **ball-in-court badge**
on the task row, scoped to the `agent_doable` disposition. Design rationale:
`docs/TASK_CONVERSATIONS_PLAN.md`. Engine: `docs/TASK_CONVERSATIONS_PHASE0.md`.

## Done-line (the milestone that proves the whole arc)

From a hand-driven Claude session (over `septena-local` or the gateway):

1. I `tasks_thread_append` a `confirm` provider turn with `options` on a real task.
2. In the app, that task's detail shows the **question + options as tappable buttons**, and its row shows the **🟡 badge**.
3. You **tap an option** → a `user` choice turn is written (via `TaskMutator`), optimistically; the card advances and the badge flips.
4. I `tasks_thread_get` and **see your choice**.

That round-trip *in the UI* — simple input → AI asks → you tap → progress — is the
Phase 1 deliverable. No autonomy, no scheduler, one disposition.

## Scope

**In:** `derive()` pure function; a `ChoiceCard` view; conversation rendering in
`TaskDetailView`; the row badge; tap→write capture; the "Other" free-text path.
**Out (later):** the scheduled drainer + anti-stuck (Phase 1.5); `agent_assisted`
artifact/handoff UI, `human_only` Today-budget, `epic` decompose UI (breadth);
on-device provider. Render only `confirm`/`decide` cards; ignore other steps' UI.

## 1. Derived state — the pure function Phase 0 deferred

New `SeptenaCore/ConvoDerived.swift`:

```swift
enum ConvoDisposition { case unknown, agentDoable, agentAssisted, humanOnly, decisionNeeded, needsVerify, reference }
enum ConvoStage { case open, clarifying, inProgress, awaitingHuman, terminal }
enum ConvoBadge { case needsYou, working, youOnly, done, wontDo }   // 🟡 🔵 ⚪ ✅ ⚫

struct ConvoDerived {
  var disposition: ConvoDisposition
  var stage: ConvoStage
  var badge: ConvoBadge
  var nextAction: String
  var pendingReasoning: Bool
}

func deriveConvo(_ convo: TaskConvo, taskStatus: TaskStatus) -> ConvoDerived
```

Rules (from the dry-runs): unconfirmed intent ⇒ `needsYou`; an unanswered provider
turn (last turn is `provider` with `options`, no following `user` reply) ⇒
`needsYou`; agent owns the next move (e.g. just confirmed, grounding pending) ⇒
`working`; terminal `endState` ⇒ `done`/`wontDo`; `human_only` ⇒ `youOnly`.
`pendingReasoning` reuses the Phase-0 rule (assignee==claude OR last provider turn
confidence < 0.5, not terminal). **Pure, unit-testable, no I/O.**

## 2. Reading the conversation in the view

`TaskDetailView` takes a `SeptenaTask` (wire struct) — which does **not** carry the
conversation. Two clean options; pick one:
- **(a) Read by id** in the view via a `@MainActor` read (`taskMutator.conversation(id:)`
  or a `LocalCache` accessor), refreshed on `.septenaTasksChanged` + `.onAppear`.
- **(b) Carry it** on `SeptenaTask` (decode in `init(_ entity:)`), like `source`/`position`.

Recommend **(a)** — keeps `SeptenaTask` lean and the convo always fresh from the
mirror (CloudKit sync from the gateway lands in SwiftData → posts `.septenaTasksChanged`).

## 3. The ChoiceCard view

New `Septena/Shell/Tasks/ConversationCard.swift`:
- Renders the **latest unanswered provider turn**: `question` as the prompt, each
  `option` as a full-width tappable button (DesignSpec row anatomy, `SectionTheme`
  color), plus an **"Other…"** button revealing a text field (writes `otherText`).
- Shows resolved turns above as a compact **decision log** (question → chosen).
- At terminal: render `endState` + `endStateNote` (e.g. "Needs verify: …"); no buttons.
- Keyboard: options focusable, Return = activate, per `project_keyboard_nav`.
- Reads `DayClock` for any timestamps, never `Date()`.

## 4. Integrate into TaskDetailView

Add a **Conversation** `Section` to `TaskDetailView` (`Septena/Shell/Tasks/TaskDetailView.swift`),
above Notes, shown only when `convo` is non-empty. Renders the `ConversationCard`.
Follows the existing adaptive surface (push-on-regular / sheet-on-iPhone) — the
card is content, it must **not** own a NavigationStack or dismiss
(`project_adaptive_edit_pattern`).

## 5. The row badge

In `TaskComponents.swift` `CheckableRow`'s **trailing slot**, render the
`ConvoBadge` glyph for tasks whose `derive().badge != nil` and that have a
conversation. Distinct from the existing **agent-cue dot** (`showsAgentCue`) — that's
"freshly agent-created"; this is "ball in whose court." Don't double-render; if both
apply, badge wins. Colors via `SectionTheme`.

## 6. Capture: tap → write

Tapping an option calls `TaskMutator.appendConvoTurn(id:_:)` with a `user` turn:
`{ role:.user, step: <proposal's step>, chosen: <label>, inReplyTo: <proposal seq> }`
(or `otherText` for the free-text path). Mutator does the optimistic write + CloudKit
queue + posts `.septenaTasksChanged`; the view re-reads and the card/badge advance.
**Never fabricate the agent's next turn** — after the user taps, the ball is the
agent's (badge → 🔵); the next provider turn arrives via MCP.

## Sequence

1. `deriveConvo()` + **unit tests** (pure, fast — no app needed).
2. `ConversationCard` view + a SwiftUI `#Preview` with a stub `TaskConvo`.
3. Wire into `TaskDetailView` (read path §2a) — see a real (hand-seeded) convo render.
4. Row badge in `CheckableRow`.
5. Capture write + re-read; run the **Done-line** round-trip with a live Claude turn.

## Traps

- `SeptenaTask` ≠ `TaskEntity`: the convo isn't on the wire struct — read it by id (§2).
- Badge vs agent-cue dot are different signals — don't conflate.
- Card is content, not a navigator (no NavigationStack/dismiss ownership).
- Read `DayClock.today`/`.now`, never `Date()`.
- The conversation updates arrive via CloudKit sync (gateway-authored turns) — the
  view must refresh on `.septenaTasksChanged`, not just `.onAppear`.
- `xcodegen generate` after adding `ConvoDerived.swift` + `ConversationCard.swift`.
- MCP/lockstep unaffected (no tool changes in Phase 1) — but if rendering reveals a
  needed field, it lands in both servers + docs in the same change.
