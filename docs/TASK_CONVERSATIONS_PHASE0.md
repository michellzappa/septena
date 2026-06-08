# Task Conversations — Phase 0 build ticket

**Plumbing, no UI.** Land the frozen data shape + the write boundary + the MCP
verbs, and prove a turn round-trips from a hand-driven Claude session. Design &
rationale live in `docs/TASK_CONVERSATIONS_PLAN.md`; this is the implementation
slice. Shape was frozen empirically across four dry-runs (code bug, epic,
human_only, agent_assisted) — see the plan's appendix.

## Done-line (what proves Phase 0 complete)

From a hand-driven Claude session over the **local** MCP (`LocalMCPServer`,
dev CloudKit):

1. `tasks_thread_append` a `confirm` turn → `confirmedIntent` is set in the same save.
2. append a `decide` provider turn carrying `options`.
3. append a `user` choice turn with `inReplyTo`.
4. `tasks_set_acceptance`, then `tasks_set_endstate`.
5. `tasks_thread_get` returns the full thread, in order.
6. it **survives app relaunch** (SwiftData) and **syncs to CloudKit dev**
   (verify by reading via the hosted MCP).

No UI, no on-device model, no router. Derived fields computed in code, logged
not shown.

## Scope

**In:** Codable shape, one additive `TaskEntity` field, `TaskMutator` methods,
local MCP verbs, a derived-state pure function, a round-trip test.
**Out (later phases):** choice-card / badge UI (Ph1), on-device provider, the
router + capability/fallback, the "Other" free-text re-interpret branch,
scheduling, the Today-budget curator, the gateway mirror UX.

## 1. Data model — one additive field

`TaskEntity` (`SeptenaCore/Models.swift:37+`): add **one** field

```swift
var conversationJSON: String?   // encoded TaskConvo; nil until first turn
```

One field = one additive CloudKit column (prod deploy is additive-only — do NOT
deploy prod here; dev only). The whole conversation serializes to JSON to avoid
new CloudKit record types (matches the plan §5). Filtering for the queue is
client-side (consistent with the gateway's client-side date filtering).

## 2. Codable shape (`SeptenaCore`, new file `TaskConvo.swift`)

```swift
struct TaskConvo: Codable {
  var confirmedIntent: String?          // denormalized cache of the confirm turn
  var acceptance: String?               // agent-done bar (≠ task status = human-done)
  var thread: [Turn] = []
  var subtasks: [String] = []           // child task ids (epic decompose)
  var artifact: Artifact?               // agent_assisted deliverable
  var handoff: Handoff?                 // human last-mile → terminal action button
  var endState: String?                 // EndState raw; nil until terminal
  var endStateNote: String?             // e.g. needs_verify: *what* to verify
  var assignee: String?                 // "me"|"local"|"claude"; nil = router-decided
}

struct Turn: Codable {
  var seq: Int
  var role: String                      // "user" | "provider"  (propose ≠ choose)
  var step: String                      // confirm|ground|scope|decide|work
  var provider: String?                 // "onDevice"|"claude"; nil = deterministic compute
  var confidence: Double?               // provider turns; the escalation trigger
  var question: String?
  var options: [String]?
  var chosen: String?
  var otherText: String?                // free-text escape hatch (branch handled in Ph2 UI)
  var inReplyTo: Int?                   // user turn → the proposal turn it answers
  var note: String?
  var ts: Date
}

struct Artifact: Codable { var kind: String; var title: String; var body: String; var refs: [String]? }
struct Handoff:  Codable { var instruction: String; var actionType: String; var payload: String? }  // actionType: open_url|compose|call|none
```

## 3. Write boundary — `TaskMutator` methods

Add to the Tasks mutator (`SeptenaCore/CloudKit/TasksBackend.swift`), following
the existing `fetch(id:)` → mutate → `commitAndPush(entity, op:)` pattern. Each
method decodes `conversationJSON`, mutates, re-encodes, commits + pushes.

```swift
func appendTurn(id: String, _ turn: Turn)                 // assigns seq; if confirm+chosen, also sets confirmedIntent (ONE save)
func setAcceptance(id: String, _ line: String)
func setArtifact(id: String, _ a: Artifact)
func setHandoff(id: String, _ h: Handoff)
func setEndState(id: String, _ state: String, note: String?)
func setAssignee(id: String, _ assignee: String?)
func addSubtask(id: String, child: String)
```

Invariant: **only the mutator writes `conversationJSON`** — views, App Intents,
and both MCP servers go through these (mutators are the write boundary).

## 4. Derived state — pure function (no storage)

`func derive(_ task: TaskEntity) -> ConvoDerived` returning
`{ disposition, stage, size, pendingReasoning, badge, nextAction }` computed from
the stored facts (last turn, confirmedIntent, endState, assignee, confidence).
Used by the queue filter now; by the UI in Ph1. Logged, not shown.

`pendingReasoning == true` when: a step's last provider turn has low `confidence`
**OR** `assignee == "claude"` (the queue's two feeders — plan §6).

## 5. MCP verbs (local server first — this repo)

Dispatch in `SeptenaCore/MCP/MCPDispatch.swift` + declarations in
`MCPToolCatalog.swift`, mirroring the existing `tasks_update` pattern
(`case "…": return try …`):

| verb | does |
|---|---|
| `tasks_thread_get(id)` | returns the decoded `TaskConvo` |
| `tasks_thread_append(id, turn)` | `m.appendTurn` (handles confirm→confirmedIntent atomically) |
| `tasks_set_acceptance(id, line)` | `m.setAcceptance` |
| `tasks_set_endstate(id, state, note?)` | `m.setEndState` |
| `tasks_set_assignee(id, assignee)` | `m.setAssignee` |
| `tasks_pending_reasoning(limit)` | tasks where `derive(...).pendingReasoning` (client-side filter) |

(`set_artifact`/`set_handoff`/`add_subtask` can follow once Ph1 needs them.)

## 6. Sequence (smallest testable first)

1. **Codable shape** (`TaskConvo.swift`) + the one `TaskEntity` field. Build.
2. **`TaskMutator` methods** + a **local unit test** that round-trips a turn
   in-process (no CloudKit, no MCP) — surface B from the plan.
3. **Local MCP verbs** → run the **Done-line** from a Claude Code session on the
   loopback server — surface C.
4. **CloudKit dev** sync verify (read back via hosted MCP) + add the field row to
   `docs/CloudKitSchema.md` — surface D.
5. ✅ **DONE — gateway mirrored** (`../septena-mcp-gateway`, `tsc` clean):
   `src/tools/writeTasks.ts` (6 functions + schemas, read-modify-write the
   `conversationJSON` field via `lookupRecord` + `modifyRecords` forceUpdate),
   `src/mcp.ts` (GLOBAL_TOOLS + callTool cases), `skill.md` (hand-maintained,
   served raw), and the app's `TasksPlugin.mcpSkill` brief. **Pending:**
   `wrangler deploy` + the live round-trip (needs an app native write first so
   `conversationJSON` registers in the dev CK schema).

## Status (2026-06-08)

Code complete + compiling on **both** MCP surfaces (iOS+macOS build green; gateway
`tsc --noEmit` clean). Lockstep holds — verbs, shapes, and docs match. **Not yet
verified live:** the round-trip done-line (needs the Mac app relaunched from this
build with Local MCP enabled) and the gateway deploy. All changes uncommitted.

## Traps (carried from CLAUDE.md + prior sessions)

- **Additive-only CloudKit; dev only.** Do not deploy prod schema in Phase 0.
- **Mutator is the only writer** of `conversationJSON`.
- **Gateway is a separate repo**; keep `skill.md` in sync (step 5).
- `LocalMCPServer` already fixed NaN-JSON-crash + `@Model.id`→`PersistentIdentifier`;
  reuse that dispatch path, don't reintroduce.
- `xcodegen generate` after adding `TaskConvo.swift` (project.yml is source of truth).
```
