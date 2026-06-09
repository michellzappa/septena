# Task Conversations — Handoff

**For a new agent picking this up.** Date: 2026-06-09. Read this, then the specs
in §10. Everything below is built + green on iOS+macOS unless marked otherwise.
The hourly commit bot lands changes to `main`, so assume committed.

---

## 1. What it is (one paragraph)
A task can hold a short, tap-driven **conversation** that turns a vague to-do into
a clear next step: AI **confirms** what you mean, **grounds** it, offers a few
**options** (you tap), does what it can, and **hands off** the rest. It's
**option-cards, not chat**. The reasoning is **the user's own AI** (Apple
Foundation Models on-device, Apple PCC on iOS 27, or the user's Claude over MCP) —
**Septena never runs/holds inference**. Every turn writes through the **mutators**
to one CloudKit field; the UI renders it.

## 2. Current status
| Layer | State |
|---|---|
| Data model + write path | ✅ built, verified live |
| MCP verbs (both servers) | ✅ 8 convo verbs + `tasks_get` + list `truncated` flag, lockstep, gateway deployed |
| UI (card, badge, transcript, artifact/handoff/acceptance, explainer) | ✅ built, green, in the task editor |
| AI dial (AIPolicy + Settings→AI) | ✅ built, green |
| In-app orchestrator (provider seam + router + on-device FM + trigger) | ✅ built, green — **FM output quality unverified** (needs device w/ Apple Intelligence) |
| Autonomy (scheduled drainer), `decide`/`work` on-device, real `claudeConnected` signal | ❌ not built |

## 3. Architecture & file map

**Data (engine-independent — every provider writes the same way):**
- `SeptenaCore/TaskConvo.swift` — `TaskConvo` (confirmedIntent, acceptance, `thread:[ConvoTurn]`, subtasks, artifact, handoff, endState, endStateNote, assignee) + `ConvoTurn` (seq, role:user|provider, step:confirm|ground|scope|decide|work, provider, confidence, question, options, chosen, otherText, inReplyTo, note, ts) + `ConvoArtifact`/`ConvoHandoff`/`ConvoEndState`/`ConvoAssignee` + JSON coders + `TaskEntity.conversation` accessor.
- `SeptenaCore/Persistence.swift` — `TaskEntity.conversationJSON: String?` (the store); `SeptenaTask` **carries `conversation`** (decoded in `init(_ e:)`) so badge/card read it free — **no per-row fetch**.
- `SeptenaCore/CloudKit/TaskRecord.swift` — CK field `conversationJSON` (**plaintext** so the gateway's Web Services can read it; encrypted fields are invisible there).
- `SeptenaCore/CloudKit/TasksBackend.swift` — mutators `appendConvoTurn` (assigns seq; confirm+chosen sets confirmedIntent atomically) / `setConvoAcceptance` / `setConvoEndState` / `setConvoAssignee` / `setConvoArtifact` / `setConvoHandoff` / `conversation(id:)` / `pendingReasoning(limit:)`. `fetch(id:)` has `fetchLimit=1`. **Mutators are the only writer of `conversationJSON`.**
- `SeptenaCore/Outbox.swift` — `TaskMutator` forwards the above.
- `SeptenaCore/ConvoDerived.swift` — `deriveConvo(_:)` → badge/stage/pendingReasoning (PURE). `TaskConvo.isPendingReasoning()` is the single queue rule (shared by backend + gateway).

**MCP (TWO servers, edited in LOCKSTEP — see CLAUDE.md):**
- In-app: `SeptenaCore/MCP/MCPDispatch.swift` + `MCPToolCatalog.swift` (loopback `127.0.0.1:7717`, macOS, for Claude Code).
- Gateway: `../septena-mcp-gateway/src/tools/writeTasks.ts` + `listTasks.ts` + `mcp.ts` + `skill.md` (Cloudflare Worker, for consumer chat). Deploy: `npx wrangler deploy`.
- Verbs (both): `tasks_get`, `tasks_thread_get`, `tasks_thread_append`, `tasks_set_acceptance`, `tasks_set_artifact`, `tasks_set_handoff`, `tasks_set_endstate`, `tasks_set_assignee`, `tasks_pending_reasoning`.

**UI (`Septena/Shell/Tasks/`):** *(morphing composer 2026-06-09 — the conversation lives IN the composer, which is now a detented bottom sheet that grows to fit it.)*
- `TaskComposer.swift` — `TaskComposerCard` is now the app's **standard adaptive edit drawer** (settled 2026-06-09 after the floating-card → detented-sheet → this progression): `AdaptiveEditScaffold(title:saveTitle:canSave:accent:onSave:) { ScrollView { … } }`, presented via `.adaptiveDetail` — a grouped **sheet on iPhone, a docked inspector on iPad/macOS**, exactly like every other section edit form (e.g. `EditGutEntrySheet`). **No custom detents / measuring / morph** — the content just scrolls naturally. Scaffold owns Cancel/Save (`onSave` = `persist()` + `onDone()`, then it closes); `commit()` (Return-to-save) does the same via `close()` = `adaptiveDetailClose ?? dismiss`. Content top→bottom: title/notes card, quick-add chips, `TaskAttributeBar` (the glass When/Deadline/Repeat/List pills are kept), and in edit mode `ConversationSection` + a bottom `terminalActions` block (Complete / Cancel Task / Delete — they moved out of the old … menu since the scaffold owns the toolbar). The **List pill names the destination** ("Inbox" by default, area/project once filed; `AttributePill` shows `value ?? label` so text is decoupled from the accent tint). No "Adding to …" header caption.
- `ConversationCard.swift`:
  - `ConversationCard` — **pure exchange content** (no chrome): persistent transcript, options + "Other…", artifact, handoff Link, acceptance footer, terminal rows.
  - `ConversationSection(task:accent:)` — what the composer embeds: a summary header (icon + open-question/end-state line, or "Talk it through with AI" pre-start, + badge + ⓘ) over the `ConversationCard` + `AskAIButton`. **A normal scrolling section** now (no expand mechanic). Refreshes on `.septenaTasksChanged`. **AI lives only here.**
  - `ConvoBadgeView(convo:)` (row trailing, pure), `AskAIButton(task:)`, `AIExplainerView`.
- **Hosts** present via the `taskComposerDrawer(isPresented:)` modifier (thin wrapper over `.adaptiveDetail`): `TaskListView.swift`, `TasksDestinationView.swift` (stacks above the Tasks drawer sheet), `WeekDashboardView.swift` (create-only). The composer card no longer takes an `onDismiss` — closing flows through the scaffold + the host's `isPresented` binding. No cross-surface conversation state (the old split's `conversingTask`/extra `.adaptiveDetail`/0.35s-defer are gone).
- `TaskComponents.swift` — `TaskRow.trailing` renders `ConvoBadgeView(convo: task.conversation)`.

**AI dial + orchestrator:**
- `SeptenaCore/AIPolicy.swift` — `AIMode {onDeviceOnly,auto,useMyClaude}`, `AIProviderKind {onDevice,applePCC,claude}`, `AIPolicy.admissibleProviders(claudeConnected:pccAvailable:)` (most-private-first; "zero inference cost to Septena" rule). Keys `septena.ai.mode` / `septena.ai.devForceProvider`.
- `Septena/Shell/Settings/AISettingsPane.swift` — Settings→AI: the dial + explainer link + macOS dev "Force provider".
- `SeptenaCore/ReasoningProvider.swift` — `ReasoningRequest`/`Result`, `@MainActor protocol ReasoningProvider`, `ReasoningRouter.route`, `ProviderAvailability.pccAvailable` (**`if #available(iOS 27,*){return false}` — no iOS-27 symbols, compiles on 26**).
- `Septena/Shell/Intelligence/OnDeviceReasoningProvider.swift` — FM (26.0), `confirm` step via `@Generable` + `LanguageModelSession.respond`.
- `Septena/Shell/Tasks/ConversationEngine.swift` — `advance(task:claudeConnected:)`: ground → route → append (sync) or park (`assignee=.claude`). **PCC drop-in = one commented line in `syncProviders`.**

## 4. Frozen design decisions (don't relitigate without reason)
- **Confirm is a hard gate.** Don't assume meaning; offer readings.
- **Choice-cards, not chat.** Free text is the "Other…" escape hatch only.
- **No inference by Septena / no keys.** Admissible providers: Apple on-device, Apple PCC, the user's own Claude. The AI dial is the user's one **policy** lever — **NOT a per-function model matrix** (decided).
- **Disposition/stage/badge are DERIVED**, re-evaluated per turn; not stored.
- **Two completion bars:** `acceptance` = agent-done; task `status` = human-done. A done task can keep its conversation (not a bug).
- **Size is discovered:** an epic branches to `scope`/decompose, never straight to `work`.
- **Mark-for-Claude** (`assignee=claude`) is the queue's second feeder + a per-task autonomy grant.
- **Press-to-advance:** foreground nothing auto-runs; the user taps. Background = a (future) scheduled drain.

## 5. What's left to build (priority order)
1. **Extend on-device to `decide`** (and simple `work`): more `@Generable` shapes + prompts in `OnDeviceReasoningProvider.canHandle/resolve`. Today only `confirm` runs on-device.
2. **Real `claudeConnected` signal** so `auto`/`useMyClaude` actually park for the user's Claude (today defaults false → on-device only path is live).
3. **Scheduled drainer / "work my queue"** — call `ConversationEngine.advance` per `tasks_pending_reasoning` task; + **anti-stuck brakes** (step-fingerprint, progress-requirement, budget) before unattended runs.
4. **Disposition actions:** `human_only` → bounded Today-promotion/reminder (Today-budget); `epic` → decompose into `subtasks`.
5. **Grounding depth:** `ConversationEngine.ground()` is minimal (notes/area/project) — richer context = better options.
6. **Polish:** "Other" free-text re-interpret round; optimistic post-tap update (avoid the one post-tap fetch). *(Surface — settled 2026-06-09: the composer is the standard `AdaptiveEditScaffold` + `.adaptiveDetail` drawer, like every other edit form — sheet on iPhone, inspector on iPad/macOS, natural scroll, no custom detents. See §3 UI.)*
7. **conversationJSON blob merge-on-apply** (latent): the blob is last-writer-wins, so a concurrent CloudKit fetch can clobber a fresh field (handoff was lost once under rapid writes). Fix in `TaskRecord.apply` — keep the higher-max-seq version. Low-risk in normal single-action use.

## 6. iOS 27 plan (see docs/CORE_AI_iOS27_PREP.md)
The engine is provider-agnostic, so iOS 27 = a better provider drops in:
- **PCC** becomes a real provider — uncomment the line in `ConversationEngine.syncProviders` and implement `ProviderAvailability.pccAvailable` (returns real `PrivateCloudComputeLanguageModel` availability). **Don't bump the 26.0 floor.**
- MCP exits the *on-device* loop (FM runs in-process); stays as the **cross-platform/Claude-Code front door** + (speculative) the **system-MCP** surface for Siri.

## 7. How to drive/test it (no app UI needed)
The **local server over curl** is the reliable rig (bypasses MCP-client tool-registry staleness, no iCloud token):
```
TOK=<token from macOS Settings→Local MCP Server>   # e.g. 85ac…
curl -s -X POST http://127.0.0.1:7717/mcp -H "Authorization: Bearer $TOK" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"tasks_get","arguments":{"id":"<id>"}}}'
```
Demo tasks in the inbox: `5nes8j` (home office), `c6ztwg` (bicycle), `w6bs85` (haircut), `tjrhee` (offsite, multi-turn), `wr4f4r` (insurance — completed, full agent_assisted example).

## 8. Traps / gotchas (learned the hard way)
- **MCP-client staleness:** deploying the gateway or rebuilding the app does NOT refresh a *running* Claude Code session's tool list — it must **reconnect** (`/mcp`) or restart. A subagent shares the parent's cached connection (won't help). Verify the deployed gateway via public HTTP: `curl https://mcp.septena.app/skill.md`.
- **Gateway iCloud token** expires ~8h and needs reconnecting from **both** sides (app re-mint AND the claude.ai connector) — a relaunch alone doesn't do it. The **local** server has no such token.
- **Incremental-build staleness:** after `xcodegen generate` / multi-agent edits, an incremental build can miss a changed file (badge updated, composer didn't). If behavior lags code, **⇧⌘K (Clean Build Folder) + Run**.
- **macOS opens the editor on double-click** (single click = select); iOS = single tap.
- **JSON-RPC over curl:** count your braces — a flat string arg (`acceptance`) needs one fewer `}` than a nested object (`artifact`/`handoff`); an extra brace → `-32600 Invalid Request`.
- **`tasks_list` is view-filtered + capped:** a done task lives only in `completed` (was 481 rows); use `tasks_get(id)` to inspect one task, and trust the `truncated` flag.
- **Additive-only CloudKit, dev-only:** never deploy prod schema here; `conversationJSON` auto-registers in **dev** on the app's first native write.
- **Don't re-fetch per-row** what the list already loaded — carry derived data on `SeptenaTask` (the badge perf fix).

## 9. Build commands
```
xcodegen generate                  # after adding files (project.yml is source of truth)
xcodebuild -scheme Septena    -destination 'generic/platform=iOS' -configuration Debug build
xcodebuild -scheme SeptenaMac -destination 'platform=macOS' -derivedDataPath /tmp/septena-mac-dd build   # isolated DD if Xcode holds the lock
cd ../septena-mcp-gateway && npx tsc --noEmit && npx wrangler deploy
```

## 10. Canonical docs
- `docs/TASK_CONVERSATIONS_PLAN.md` — the design/spec (north star, loop, providers, runtime).
- `docs/TASK_CONVERSATIONS_PHASE0.md` / `_PHASE1.md` — build tickets (engine / UI).
- `docs/AI_TASKS_EXPLAINER.md` — the user-facing copy (in-app + website source of truth).
- `docs/CORE_AI_iOS27_PREP.md` — the iOS 27 / Foundation Models / PCC plan.
- `CLAUDE.md` — repo invariants (mutator write boundary, two-MCP lockstep, etc.).
- Agent memory: `project_task_conversations.md`, `project_local_mcp_server.md`.
