# 0057. Agent responses and hooks stay typed data, not generative UI

- Status: proposed (2026-11-26), agent default; mz may overrule
- Date: 2026-11-26
- Deciders: mz
- Builds on: [ADR 0008](0008-agent-loop-rules-live-in-the-store.md),
  [ADR 0028](0028-registry-owns-vocabulary-platforms-own-interaction.md),
  [ADR 0050](0050-septena-publishes-its-agent-contract.md),
  [ADR 0051](0051-clients-in-other-apps-are-septena-surfaces.md)

## Context

On 2026-11-26 we evaluated [A2UI](https://a2ui.org/) (v1.0), a declarative
protocol that lets AI agents stream native UI component trees
(`createSurface`, `updateComponents`, `updateDataModel`) mapped to a
client-side component catalog.

Septena already has four native client toolkits (SwiftUI on iOS/iPadOS/watchOS,
AppKit on macOS, Jetpack Compose on Android, and Web), plus headless callers
(CLI, Raycast, Claude Code, scheduled runners). Its agent surfaces rest on four
established rules:

- **One constrained prompt pattern** (`docs/AGENT_PROMPT_SPEC.md`,
  `docs/TASK_CONVERSATIONS_PLAN.md`): every agent question collapses to a
  kicker, a question, 2 to 4 vertical choices, and "Tell the agent instead".
  That constraint forces grounding and keeps the surface usable on phone and
  watch.
- **Vocabulary in the registry, layout in each platform** (ADR 0028): Septena
  rejects server-driven UI languages because they fight native focus, keyboard
  handling, accessibility, and list rendering.
- **Store-enforced loop state** (ADR 0008): `TaskStore` reads structured fields
  (`options`, `chosen`, `endState`) directly to release claims, refill run
  budgets, and derive Review groups.
- **Pointer-only hooks** (ADR 0008, `backend/src/api/agentWake.ts`): outbound
  webhooks and the SSE wake stream carry `{ event, rev, taskId, at }` only, so
  task text never arrives as an instruction through the event feed.

Adopting A2UI in agent turns, MCP responses, or wake hooks would violate ADR
0008 and ADR 0028, add renderer and catalog maintenance across four toolkits
(including AppKit and watchOS, which have no official A2UI renderers), and
bloat payloads for headless and CLI callers.

## Decision

1. **Do not adopt A2UI in hooks, task turns, or default MCP responses.**
   - Wake webhooks and the SSE event stream stay pointer-only.
   - Task turns (`ConvoTurn`), Review hand-offs, and `AgentPrompt` stay typed
     domain records rendered by each platform's own native controls.
   - Default MCP and `/v1` responses stay plain JSON per ADR 0050.
2. **Adopt five design rules learned from A2UI where they fit Septena:**
   - **Closed, registry-owned catalogs for rich deliverables.** If
     `ConvoArtifact` (`kind`) or `ConvoHandoff` (`actionType`) grows beyond
     plain Markdown and basic actions, define a small, fixed set of typed kinds
     in `registry/entities.json`. Agents never send HTML, scripts, or arbitrary
     layout trees.
   - **Plain-text fallback and tolerant decoding everywhere.** Every new
     artifact kind, end-state, or action type must remain readable from plain
     `title` and `body` (or `instruction`) on Watch, CLI, Raycast, and older
     app builds. Clients must decode unknown enum/kind strings gracefully
     rather than failing the whole conversation (extending the `.unknown`
     pattern in `SeptenaCore/TaskConvo.swift` to Android, Web, and the shared
     core).
   - **Data separated from presentation.** Loop-control fields (`question`,
     `options`, `chosen`, `otherText`, `endState`, `handoff`) stay flat,
     first-class fields on the task conversation so `TaskStore` enforces rules
     without parsing any presentation structure.
   - **Flat, LLM-friendly write schemas.** Keep MCP tool inputs and future
     structured artifact payloads shallow (flat lists of small objects with
     simple IDs) rather than deeply nested trees, following A2UI's
     adjacency-list insight for reliable model output.
   - **Capability negotiation before any future UI surface.** If Septena later
     exposes interactive cards inside third-party chat hosts (for example via
     MCP Apps `ui://` resources or A2UI, per ADR 0051), deliver them only when
     the client explicitly negotiates that capability. Default tool responses
     stay compact JSON.

## Consequences

- No third-party UI runtime or cross-platform renderer catalog to maintain or
  version-pin across SwiftUI, AppKit, Compose, watchOS, and Web.
- `TaskStore` keeps deterministic control over claims, budgets, Stop, Pause,
  and Review grouping.
- Headless runners, CLI, and MCP clients stay fast and token-efficient.
- Trade-off: agents cannot invent bespoke forms or novel interactive widgets
  inside the Septena app. Richer agent deliverables require adding a typed
  `artifact.kind` to the registry and rendering it natively on each platform.

## Links

- [A2UI](https://a2ui.org/)
- `docs/AGENT_PROMPT_SPEC.md`, `docs/TASK_CONVERSATIONS_PLAN.md`,
  `docs/TASK_FACTORY_SPEC.md`, `docs/AGENT_SURFACE_SPEC.md`
- `SeptenaCore/TaskConvo.swift`, `backend/src/api/agentWake.ts`,
  `backend/src/shadow/mcp.ts`
- ADR 0008, ADR 0028, ADR 0050, ADR 0051
