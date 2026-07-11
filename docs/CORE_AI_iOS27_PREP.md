# Core AI & iOS 27 Preparation Plan

Status: **research-verified, pre-implementation** (Xcode 27 beta not yet
installed). Date: 2026-06-09; **updated 2026-07-11** after a verification pass
against Apple's shipped first-party pages: the [PCC developer page]
(https://developer.apple.com/private-cloud-compute/), the [WWDC26 Apple
Intelligence guide](https://developer.apple.com/wwdc26/guides/apple-intelligence/),
and session notes for 241 ("What's new in the Foundation Models framework"),
339 ("Bring an LLM provider to the Foundation Models framework"), 319 ("Build
with the new Apple Foundation Model on Private Cloud Compute"), 324/325 (Core
AI), 298/299 (Evaluations), 334/335 (fm CLI / prompt hill-climbing), 240/295/
343/344/345 (App Intents & Siri). Facts tagged *(verified 2026-07-11)* are
confirmed first-party; remaining "(news)" tags still need the beta. This file
is the agent + human cheat-sheet AND the sequenced plan (§8) for the iOS 27 AI
push.

---

## 0. The one distinction that reframes everything

iOS 27 exposes **three separate AI layers**. They are easy to conflate; the URL
the user sent (`developer.apple.com/documentation/coreai`) is only the first.

| Layer | One line | What it's for | Septena today |
|---|---|---|---|
| **Core AI** | Run *any* compiled model on Apple silicon (CPU/GPU/ANE). The **Core ML successor**. | Bringing your **own** model (e.g. a food-recognition net). | **Unused.** |
| **Foundation Models** | Apple's **on-device LLM**, 3-line Swift API. | Summarize / extract / reason / generate structured output. | **Heavily used.** |
| **System MCP** *(news)* | OS-level MCP **client**; Siri 2.0 + Core AI routing can call registered MCP servers. | Letting the system/assistant drive your app's tools. | Server + gateway already shipped. |

Consequence: "target iOS 27 for our existing AI" is almost entirely
**Foundation Models** work — *not* Core AI. Core AI only enters if we ship a
**custom compiled model** (the high-accuracy food-photo path).

---

## 1. What iOS 27 actually ships

### 1a. Core AI (confirmed — Apple docs)
The Core ML replacement for running models on-device. Workflow:

1. Convert a model → `.aimodel` via the **Core AI PyTorch Extensions** Python
   package (`apple.github.io/coreai-torch`).
2. Drag `.aimodel` into Xcode (appears in Compile Sources). **Requires the
   Metal Toolchain** (Xcode ▸ Settings ▸ Components) or builds fail.
3. `let model = try await AIModel(contentsOf: url)` — async because it
   **specializes** the model for the current device across all compute units.
4. `let fn = try model.loadFunction(named: "main")` → an `InferenceFunction`.
5. Build inputs as `NDArray(shape:scalarType:)` (write via `mutableView(as:)`);
   images are `CVMutablePixelBuffer` described by `ImageDescriptor`.
6. `var out = try await fn.run(inputs: ["input": ndArray])`.
7. Read `out.remove("prediction")?.ndArray` (or `.pixelBuffer`).

Key types: `AIModel`, `AIModelAsset`, `AIModelCache` (caches specialized
artifacts — specialization is expensive), `InferenceFunction`,
`InferenceFunctionDescriptor`, `InferenceValue`, `NDArray`/`NDArrayDescriptor`,
`ImageDescriptor`, `ComputeStream`, `ComputeUnitKind`, `SpecializationOptions`,
`AssetError`. **Availability: iOS/iPadOS/macOS/visionOS 27.0+ (beta).**
On-device, offline, no per-inference cost.

### 1b. Foundation Models — what's new for iOS 27 *(verified 2026-07-11)*
The framework we already use (`import FoundationModels`). Verified new surface:

- **`LanguageModel` protocol** — any model can back a `LanguageModelSession`
  via `LanguageModelSession(model:)`. Confirmed conformers:
  `SystemLanguageModel` (on-device), `PrivateCloudComputeLanguageModel`
  (Apple's server model), open-source `CoreAILanguageModel` (local models on
  the ANE) and `MLXLanguageModel` (Mac GPU), **plus first-party Swift packages
  from Anthropic and Google** so frontier cloud models drop into the same
  session/tool/@Generable APIs (auth via OAuth, token in Keychain, billed
  per-token to the *user's* account). Session 339 also names a
  `LanguageModelExecutor` protocol as the provider extension point.
- **Private Cloud Compute routing** — `PrivateCloudComputeLanguageModel`:
  **32,000-token context**, reasoning-capable, per-request
  `ContextOptions(reasoningLevel: .light / .deep)`, and a usage-accounting API
  (`response.usage.input.totalTokenCount / .cachedTokenCount`,
  `output.totalTokenCount / .reasoningTokenCount`). No API key, no account
  setup; prompts not stored. **This is the drop-in our Coach factory already
  stubbed.** Eligibility & limits → §1d.
- **Multimodal prompting** — image attachments to the on-device model:
  `Attachment(UIImage/NSImage/CGImage/CIImage/CVPixelBuffer/fileURL)` inline in
  the prompt builder. Any size/aspect; bigger images cost tokens + latency.
  This is the easy food-photo path (our `MealPhotoModelAnalyzer` is already
  written against it).
- **System tools the model can call** — Vision-backed **`OCRTool`** (structured
  text from images) and **`BarcodeReaderTool`**, plus a **Spotlight search
  tool** enabling *fully local RAG* over the Core Spotlight index (our
  `SpotlightIndexer` already donates entities — rare head start).
- **`LanguageModelSession.DynamicProfile`** — declarative, SwiftUI-style
  `body: some DynamicProfile` composing `Profile { Instructions {…} + tools }`
  with `switch`-driven mode changes and per-branch `.model(…)` /
  `.reasoningLevel(…)` modifiers. **One session keeps its conversation history
  across profile/model/tool swaps.** Also `GenerationOptions.ToolCallingMode`
  for finer tool-calling control.
- **Introspection (shipped in iOS 26.4 — usable NOW at our 26.0 floor via
  #available(26.4))** — `SystemLanguageModel.contextSize` (**8,192 tokens**
  on-device — not 4,096) and `tokenCount(for:)`. iOS 26.4 also shipped an
  improved on-device model + relaxed guardrail false-positives.
- **Rebuilt on-device model in the 27 SDK** — better logic/instruction
  following/tool calling, native vision. Apple explicitly warns to **re-test
  every prompt against the new model** (our 9 FM files, all prompt services).
- **Evaluations framework** (sessions 298/299) — verify AI features "across
  dynamic conditions, beyond unit tests"; plus **`fm` CLI + Python SDK**
  (334) and prompt hill-climbing workflow (335); Foundation Models
  **Instruments** template (243).
- **Open-sourcing** — the core framework goes open source (runs wherever Swift
  runs, incl. Linux servers); a faster-moving *utilities* package carries
  experimental blocks: Profile modifiers for transcript management, a **Skill
  API** for procedural knowledge, and a Chat-Completions-standard server
  interface.
- Platform floors: iOS/iPadOS/macOS/visionOS **26.0+**; **watchOS 27.0+**
  brings Foundation Models *and PCC* to the watch (unlocks a watch Coach).

### 1c. System MCP, Siri 2.0, Extensions *(news — verify in beta)*
- An **MCP client is now in a system framework**; users/MDM **register MCP
  servers**, and **Siri 2.0 + the Core AI routing layer can call them**.
- **Extensions framework**: users pick a preferred AI provider (Gemini / Claude
  / ChatGPT) in Settings; system AI requests route there.
- Siri 2.0: multi-turn, on-screen awareness, file analysis, cross-app steps.

### 1d. PCC third-party access — eligibility & mechanics *(verified 2026-07-11)*
Source: developer.apple.com/private-cloud-compute/ + session 241.

- **Cost: zero.** "No cloud API cost" for eligible developers.
- **Eligibility (ALL three):** (1) enrolled in the **App Store Small Business
  Program**; (2) **fewer than 2 million first-time App Store downloads** across
  all the account's apps; (3) the **Private Cloud Compute entitlement**
  assigned to the account (request form:
  developer.apple.com/contact/request/private-cloud-compute/). Septena
  trivially clears (2); (1) and (3) are **account actions to start now** —
  they gate everything in Track A.
- **User-side limits:** users get daily PCC usage; **iCloud+ subscribers get
  higher limits**. Design for limit exhaustion (fall back to on-device, say so
  honestly in the UI).
- **Testing:** TestFlight and ad-hoc installs are allowed and **do not count**
  toward the 2M first-time-download threshold.
- **Privacy:** prompts not stored; independently verifiable — consistent with
  our "zero inference cost to Septena, nothing leaves the user's trust
  boundary" admissibility rule in `AIPolicy`.
- **Platforms:** "where Apple Intelligence is available"; PCC explicitly
  reaches **watchOS 27**.

---

## 2. Current AI surfaces in Septena (inventory)

| # | Surface | Mechanism | File(s) | iOS 27 angle |
|---|---|---|---|---|
| 1 | **Coach** (streaming chat, follow-ups, goal/commitment proposal) | Foundation Models `LanguageModelSession` streaming + `@Generable` | `Septena/Shell/Goals/Discovery/Coach/CoachBackend.swift` | **PCC routing** (stub already present, lines 162–164); watch Coach |
| 2 | **Purpose / Values / Virtue** (self-discovery, "Examined Week") | FM `@Generable` guided generation; Swift computes facts, model interprets | `Septena/Shell/Intelligence/{Purpose,Values,Virtue}PromptService.swift` | PCC for deeper reflection; multimodal not needed |
| 3 | **Availability gate** | `SystemLanguageModel.default.availability` | `Septena/Shell/Intelligence/OnDeviceAI.swift` | Extend enum-switch with any new iOS 27 cases; surface PCC vs on-device |
| 4 | **Correlations / Insights** | Pure statistics (Pearson, permutation p, Benjamini-Hochberg FDR, tertiles) — **not** an LLM | `Septena/Sections/Insights/CorrelationEngine.swift`, `CorrelationFeatures.swift` | Candidate for **FM narration** layer (engine stays statistical) |
| 5 | **Inbox suggestion** | On-device multinomial Naive Bayes over task history | `SeptenaCore/SuggestionEngine.swift` | Optional FM upgrade; current one is good + cheap, low priority |
| 6 | **In-app MCP server** | Loopback `127.0.0.1:7717`, bearer token, macOS | `SeptenaCore/MCP/LocalMCPServer.swift`, `MCPDispatch.swift`, `MCPToolCatalog.swift`, `MCPAccessScope.swift` | **Register with system MCP** so Siri/Core AI can call it |
| 7 | **Hosted Claude gateway** | CloudKit Web Services token → `mcp.septena.app` | `SeptenaCore/ClaudeGatewayProvider.swift` | Re-evaluate vs the Extensions provider model |
| 8 | **Task conversations** | Persisted multi-turn state, provider = `onDevice` \| `claude` | `SeptenaCore/TaskConvo.swift` | On-device turns → FM; reasoning turns → PCC |
| 9 | **Siri / App Intents** | Pre-declared intent slots (`SectionLogIntent` + per-section) | `Septena/App/Intents/*` | Siri 2.0 baseline rises; MCP may supersede some |
| 10 | **Meal photos** | `PhotosPicker` → store `PHAsset.localIdentifier`, thumbnail only | `Septena/Sections/Nutrition/*`, `SeptenaCore/PhotosBridge.swift` | **No intelligence yet → the headline new feature** |

**Gaps with data but no intelligence:** meal photo analysis, package-label OCR,
gut free-text → structured triggers, training rep/form from video, goal/task
decomposition, correlation narration.

---

## 3. Track A — Upgrade existing Foundation Models features for iOS 27

Goal: keep the 26.0 floor, light up iOS 27 capabilities behind availability
checks. Lowest risk, highest certainty (all confirmed APIs).

- **A1. Wire the Private Cloud Compute backend (Coach).** The factory already
  has the seam. Add a `PrivateCloudComputeBackend: CoachBackend` that wraps a
  PCC-routed session, add the `com.apple.developer.private-cloud-compute`
  entitlement (hand-maintained `*.entitlements`), and uncomment the factory
  branch. Decision needed: *when* to escalate to PCC (always? long transcripts?
  user toggle? offline → on-device fallback). Coach is the natural first PCC
  consumer because reasoning quality is the whole point.
- **A2. PCC for Purpose / Virtue reflection.** Same pattern; these benefit from
  a bigger context window (the Examined Week feeds a lot of evidence). Keep the
  deterministic fallbacks (`fallbackReadings`) — they already cover no-model.
- **A3. Availability surfacing.** Extend `OnDeviceAI` to distinguish on-device
  vs PCC availability and any new `@unknown` cases, and to show "needs network /
  Apple Intelligence" states honestly. Re-audit the `@unknown default`.
- **A4. watchOS Coach / Next reflection.** Foundation Models reaches watchOS
  27. Evaluate a minimal on-watch reflective surface (watch section wiring is
  hand-done, not manifest-driven — see CLAUDE.md).
- **A5. Instruments pass.** Use the new agentic-flow Instruments support to
  profile Coach/Virtue latency once on beta hardware.

## 4. Track B — New capabilities

### B1. Food photo → macros (the headline). Two implementations:

**B1a. Foundation Models multimodal (DO THIS FIRST).**
Feed the existing meal photo as an `ImageAttachmentContent` into a
`LanguageModelSession`, with a `@Generable` output:

```
@Generable struct MealEstimate {
  let items: [FoodItem]   // name, portion, confidence
  let kcal: Double; let protein_g: Double; let carbs_g: Double
  let fat_g: Double; let fiber_g: Double
}
```

- Reuses the FM stack we already understand; **on-device, private, no model to
  ship**. Confirm-gated (never auto-writes) and pre-fills the existing
  `NewNutritionEntrySheet` fields, which the user can correct.
- Mutator boundary preserved: estimate → fill sheet → user confirms →
  `NutritionMutator` writes. No new write path.
- Open question: accuracy of macro estimation from a single photo. Treat output
  as a *draft*, show confidence, always editable.

**B1b. Core AI custom nutrition model (later / only if B1a underperforms).**
Convert/ship a food-recognition or portion/macro `.aimodel`, run via
`AIModel` + `InferenceFunction` with the photo as a pixel buffer. Higher
accuracy ceiling, but real cost: model sourcing/licensing, conversion via Core
AI PyTorch Extensions, Metal Toolchain, app-size growth, `NDArray` plumbing,
per-device specialization caching. **Gate behind a measured accuracy gap from
B1a — don't build speculatively.**

### B2. Package-label OCR → macros.
Camera/photo of a nutrition label → text → structured macros. Likely
VisionKit/Vision text recognition (deterministic) + FM to parse messy label
text into the `MealEstimate` shape. Complements B1 (cooked food vs packaged).

### B3. Correlation narration.
Keep `CorrelationEngine` statistical (the FDR-gated trust model is the
load-bearing safety property — do **not** let an LLM invent correlations).
Add an FM layer that *narrates* already-computed trusted pairs in plain
language, in the Virtue "facts computed in Swift, model only interprets" style.

### B4. Gut / notes free-text → structure.
FM extraction (or `NaturalLanguage`) of trigger foods / symptoms from free-text
gut notes into structured, correlatable signals. Feeds `CorrelationFeatures`.

### B5. Goal / task decomposition.
FM-assisted breakdown of a goal or task into subtasks — confirm-gated, routed
through existing mutators. Fits the Task Conversations design.

### B6. Training rep/form from video (Core AI, exploratory).
Vision pose estimation or a custom `.aimodel` for rep counting/form. Highest
effort, no current video capture path — park unless prioritized.

## 5. Track C — System MCP & assistant positioning *(SPECULATIVE — see status)*

> **STATUS (checked against shipped docs, 2026-06-09; re-checked 2026-07-11):**
> "Siri/Core AI calls your app's MCP server" is **NOT** in the iOS 27 or Xcode
> 27 release notes. MCP in Apple's shipped docs is **Xcode/developer-tooling
> only** (LLDB `lldb-mcp`, the Xcode MCP server, String Catalog tools, Agent
> Client Protocol, plugin-defined MCP servers). iOS 27 release notes don't
> mention MCP at all; App Intents remains the only documented Siri surface —
> and the 2026-07-11 verification pass of the WWDC26 Apple Intelligence guide
> confirms it: the documented Siri surface is **App Intents schemas** (entity
> schemas feeding the Spotlight semantic index; intent schemas for
> natural-language actions with "no specific phrases to define"), the new
> **View Annotations API** (map views to entities for on-screen awareness:
> `NSUserActivity` primary entity, per-view `.appEntityIdentifier`, List
> selection annotations), and the new **AppIntentsTesting framework** (session
> 295 — validate Siri/Shortcuts/Spotlight through real system pathways). The
> only signal for system MCP-in-App-Intents remains reverse-engineered **iOS
> 26.1 beta code** (Sept 2025). **Treat C1+ as a bet, not a roadmap; Track C0
> (App Intents schemas + annotations + testing) is now the confirmed, richer
> path — do it regardless.**

Septena already has the rare asset everyone else will be scrambling to build: a
working MCP server over its own data (`MCPToolCatalog` + `MCPDispatch` +
`MCPAccessScope` over mutators), plus a hosted gateway.

### iOS 27 exposes TWO parallel "tell the assistant what we can do" surfaces
They are independent mechanisms — not the same thing, not a replacement for each
other:

| | **App Intents** | **System MCP** |
|---|---|---|
| Nature | Compiled, on-device, zero infra | JSON-RPC tool server the system AI calls |
| iOS 27 status *(news)* | **Mandatory Siri surface; SiriKit deprecated.** Compiler bakes actions/entities into bundle metadata; OS knows our actions without launching the app | System gains an MCP **client**; Siri 2.0 / Core AI routing can invoke a registered MCP server "for your data, your APIs, your tools" |
| Best for | Atomic actions: "log a coffee", Shortcuts, widgets, Spotlight, Control Center | Rich / multi-step / data-query: "summarize what I ate and flag protein gaps" |
| Septena has | `Septena/App/Intents/*` (per-section) | `SeptenaCore/MCP/*` + hosted gateway |

**MCP is a new front door, not a replacement for our data layer.** Behind both
doors the real write boundary stays the **mutators** — exactly the separation our
`MCPDispatch → mutator` design already proves. Nothing replaces the mutators or
CloudKit; MCP/App Intents are façades over them.

- **C0. Strengthen App Intents.** They're now the *mandatory* Siri path, so the
  atomic quick-add actions should have clean, well-titled intents regardless of
  the MCP work. This is the safe, confirmed-direction bet.
- **C1. Register the in-app tool layer with the system MCP host** so Siri 2.0 /
  Core AI can call Septena tools via the **same `MCPDispatch`/`MCPToolCatalog`**
  (reuse schemas, routing, and `MCPAccessScope` tiers). The leverage: the
  expensive part — a clean tool layer over mutators — already exists; iOS 27 work
  is mostly a new *transport/adapter*, not new logic. **Unknown to verify:** the
  registration API + entitlement, and whether "host" means in-process-on-device
  (iOS sandbox dislikes long-lived listeners) or a network-reachable endpoint
  (which might point the system at the *gateway* instead of `LocalMCPServer`).
- **C2. Bridge-drop analysis (the hosted gateway).** The gateway exists for
  **off-device, any-platform, phone-off** reach (Claude in a PC browser, the
  Claude app on Anthropic's cloud; reads CloudKit directly). System MCP lets the
  **on-device** assistant reach data locally — so we could drop the bridge *only
  for Apple-device-originated assistant access*, not universally. A cloud model
  on another machine still can't be reached by the iPhone's MCP client. So:
  keep the bridge for cross-platform reach; system MCP is additive on-device
  first. Dropping it later is a *product* call ("assistant access = your Apple
  devices") that would also retire the 8h-token refresh fragility, the reconnect
  nudges, and one of the two lockstep MCP surfaces.
- **C3. Extensions provider model.** If users pick Claude/Gemini/ChatGPT as the
  system AI provider, Apple-device requests to "Claude" could route via Core AI →
  local MCP (no bridge); off-device "Claude" still needs the bridge. Reposition
  the gateway as "works without adopting Apple's stack / cross-platform," not as
  the only path.
- **C4. Avoid a third lockstep surface.** We already maintain the Swift in-app
  server and the TS gateway in lockstep (CLAUDE.md). Route system MCP through the
  existing `MCPDispatch` so the on-device path reuses the Swift catalog — don't
  fork a third tool definition.

---

## 5.5 Track D — Unified model architecture *(new 2026-07-11, all verified APIs)*

The 2026 framework turns our hand-rolled provider plumbing into platform
primitives. This is the "integrated" consolidation track: one session API,
every backend, one tool layer.

- **D1. Collapse backends onto the `LanguageModel` protocol.** Today we carry
  bespoke seams: `CoachBackend` (3 conformances), `ReasoningProvider` +
  `ReasoningRouter`, `ClaudeGatewayProvider` for in-app Claude. The platform
  now provides the same abstraction: `LanguageModelSession(model:)` over
  `SystemLanguageModel` / `PrivateCloudComputeLanguageModel` / **Anthropic's
  Swift package**. Target state: `AIPolicy` resolves a `any LanguageModel`
  (onDeviceOnly → system; auto → PCC-else-system; useMyClaude → Anthropic
  package with the user's own OAuth token in Keychain, billed to *their*
  account — preserving the zero-inference-cost-to-Septena rule), and Coach /
  prompt services / task conversations all consume plain sessions. Keep the
  thin domain protocols only where they add scope enforcement; delete the
  transport code. NOTE: the hosted MCP *gateway* is the opposite direction
  (external Claude → Septena data) and stays.
- **D2. Coach on `DynamicProfile`.** Personas become profile branches;
  escalation becomes `.model(pcc).reasoningLevel(.deep)` on the branch that
  proposes goals/commitments while chat stays streaming-light — one session,
  history preserved across swaps (today a persona/model change means a fresh
  session).
- **D3. Task Conversations steps as profile modes.** `confirm / ground /
  scope / decide / work` map 1:1 to profile branches with per-step tools and
  models — `.confirm` on-device, `.decide`/`.work` on PCC when admissible;
  park-for-Claude remains the fallback disposition.
- **D4. Tool-calling instead of prompt-stuffing.** `CoachContextBuilder` (576
  lines) precomputes and inlines everything into an 8K-token window. Give
  sessions read-only FM `Tool`s generated from the same shapes as
  `MCPToolCatalog` (list tools only, `MCPAccessScope`-filtered by `CoachScope`)
  so the model fetches what it needs; budget with
  `tokenCount(for:)`/`contextSize` (26.4 APIs — adoptable before iOS 27).
  **Do not fork a third tool definition** — derive from the existing catalog
  (MCP-lockstep rule extends to this surface).
- **D5. Local RAG via the Spotlight tool.** `SpotlightIndexer` already donates
  entities; attaching the Spotlight search tool gives Coach/conversations
  retrieval over the user's own index with zero new infrastructure. Honor the
  Spotlight opt-out setting.
- **D6. Evaluations harness.** Stand up Evaluations-framework suites for the
  regression-prone prompt services (Virtue readings, meal estimate, coach
  goal/commitment proposals, convo confirm) + `fm` CLI for offline prompt
  iteration. This is how we absorb Apple's "the model changes under you every
  OS release — re-test" warning permanently, not just once.

---

## 6. Deployment-target & availability strategy

- Floor stays **26.0** (project.yml). Do **not** bump to 27.0 — that strands
  every device that can't run the beta and most users for a year.
- All iOS-27 APIs (`AIModel`, `PrivateCloudComputeLanguageModel`,
  `ImageAttachmentContent`, system MCP registration) behind
  `if #available(iOS 27, *)` / `@available`, with the existing on-device or
  deterministic fallbacks underneath. The Coach factory's three-way
  (PCC → on-device → echo) is the template for every new surface.
- Entitlements are **hand-maintained**; PCC and any MCP-registration
  entitlement get added by hand, not via XcodeGen.
- **MCP lockstep still applies**: any tool-shape change lands in the in-app
  server *and* the hosted gateway *and* the skill docs in the same change.

## 7. Risks / unknowns to resolve on the beta

1. **Macro-from-photo accuracy** — the make-or-break for B1; measure before
   committing to B1b.
2. **PCC entitlement provisioning** — criteria + request form now known (§1d);
   still unknown: approval latency, behavior in dev builds before approval,
   and on PCC-ineligible devices/regions. Also NEW: daily user limits are
   real — UX must degrade to on-device gracefully mid-conversation.
3. **System MCP registration API** — exact API, entitlement, security model;
   currently only news, not in the docs we read.
4. **Multimodal cost/latency on-device** — image prompts may be slow on older
   eligible hardware; need the confirm-gate UX to tolerate latency.
5. **Foundation Models behavior changes** — the on-device model is *rebuilt*
   for 27 (and was already refreshed in 26.4); Apple explicitly warns output
   shifts across OS versions. Re-test every prompt service — and make it
   permanent via the Evaluations framework (D6), not a one-off.
6. **App-size + specialization time** if we ship a Core AI `.aimodel` (B1b).

## 8. Recommended sequencing (rewritten 2026-07-11 post-verification)

**Phase 0 — unblock (now; mostly account/no-Xcode-27 work)**
1. **Account actions, start immediately (lead-time gated):** enroll the
   developer account in the **App Store Small Business Program**; submit the
   **PCC entitlement request** (§1d). Everything in Track A waits on this.
2. Install **Xcode 27 beta**; smoke-test all 9 FM files against the rebuilt
   on-device model (Apple's explicit re-test warning); confirm
   `MealPhotoModelAnalyzer` activates (`#if compiler(>=6.4)` flips on).
3. **Adoptable pre-27:** D6 evaluations for existing prompt services; D4's
   token budgeting via the **iOS 26.4** `contextSize`/`tokenCount` APIs.

**Phase 1 — PCC wiring (the stubbed seams; needs entitlement)**
4. A1 Coach PCC: `PrivateCloudComputeBackend` at `CoachBackend.swift:161-164`;
   entitlement added by hand to every `*.entitlements`; escalation policy =
   `AIPolicy` (`auto` prefers PCC when available; `onDeviceOnly` never);
   `.light` reasoning for streaming chat, `.deep` for goal/commitment
   proposals; on-device fallback on daily-limit exhaustion, surfaced honestly.
5. Task conversations: flip `ProviderAvailability.pccAvailable`
   (`ReasoningProvider.swift:55`), register the PCC provider in
   `ConversationEngine.syncProviders` (`ConversationEngine.swift:16`) —
   `.decide` turns resolve inline instead of parking for Claude.
6. A3 `OnDeviceAI` + Settings ▸ AI status board grow a PCC row (available /
   needs-network / limit-hit / no-entitlement), including the iCloud+ nuance.
7. A2: Purpose/Virtue/Values move deep-reflection calls to PCC (32K window
   fits the whole Examined Week evidence; on-device + `fallbackReadings`
   remain underneath).

**Phase 2 — the headline (multimodal nutrition)**
8. B1a food photo → macros: activate the written analyzer, run the D6 eval on
   real meal photos, ship confirm-gated. Measure accuracy → gate B1b.
9. B2 label/barcode capture: same session gains `OCRTool` +
   `BarcodeReaderTool` (packaged-food path; barcode → item identity is new
   leverage the June plan didn't have).

**Phase 3 — integration refactor (Track D)**
10. D2/D3 DynamicProfile for Coach + conversation steps; D1 backend collapse
    (incl. `useMyClaude` via the Anthropic Swift package replacing bespoke
    in-app Claude transport); D4 tool-calling Coach; D5 Spotlight RAG.

**Phase 4 — reach**
11. A4 watch Coach/reflection (FM + PCC on watchOS 27); C0 App Intents
    schemas + View Annotations + AppIntentsTesting; close the
    Appendix-B intent coverage gaps.
12. B3 correlation narration (engine stays statistical); B4 gut free-text →
    structure; B5 goal decomposition.

**Backlog / gated:** B1b Core AI custom model (only on measured B1a accuracy
gap), B6 video form analysis, C1–C3 system-MCP bets (re-check each beta).

---

### Appendix — confirmed vs news (re-checked against release notes 2026-06-09)

- **Confirmed — framework docs:** all Core AI types + workflow (§1a); Foundation
  Models PCC / multimodal / dynamic-profile / executor symbols + 26.0 floor /
  watchOS 27 (§1b).
- **Confirmed — Xcode 27 release notes:** Core AI is real (model viewer, Metal
  execution + known issues); Foundation Models Instrument; MCP **as IDE tooling
  only** (LLDB `lldb-mcp`, Xcode MCP server, String Catalog tools, Agent Client
  Protocol, plugin MCP servers); Gemini in the *coding assistant*; SDKs ship
  iOS/iPadOS/macOS/tvOS/visionOS 27, Swift 6.4.
- **Confirmed — iOS 27 release notes:** Private Cloud Compute (HomeKit, Apple
  Intelligence Report). App Intents/Siri known issues (W-1/W-2/W-3 in the App
  Intents backlog). **No MCP mention at all.**
- **Verified 2026-07-11 (first-party pages, added in this revision):** PCC
  third-party eligibility triple + zero cost + TestFlight rules (§1d);
  `PrivateCloudComputeLanguageModel` 32K context + `reasoningLevel` +
  usage-accounting API; `LanguageModel` protocol + Anthropic/Google Swift
  packages + open-source `CoreAILanguageModel`/`MLXLanguageModel`;
  `DynamicProfile` with `.model()`/`.reasoningLevel()` modifiers +
  history-preserving swaps; `OCRTool`/`BarcodeReaderTool`/Spotlight RAG tool;
  iOS 26.4 `contextSize` (8,192 on-device) + `tokenCount(for:)`; rebuilt
  on-device model with vision; Evaluations framework + `fm` CLI + Python SDK;
  FM open-sourcing + utilities package (Skill API, Chat Completions bridge);
  watchOS 27 FM + PCC; App Intents schemas + View Annotations +
  AppIntentsTesting as the confirmed Siri surface; Core AI framework
  (3B–70B models, TorchConverter, AOT compile, Instruments).
- **STILL corrected/rumor:** on-device model context is **8,192** tokens, not
  4,096; "Gemini-distilled" base model was never confirmed (Apple says
  "rebuilt from the ground up"); on-device private fine-tuning — not in any
  verified page. "Siri/Core AI calls your app's MCP server" — still only iOS
  26.1 beta code analysis (Sept 2025). Gemini-as-Siri, Extensions provider
  picker — WWDC coverage, not release-noted. Treat as bets (§1c, Track C1+).

---

## Appendix B — App Intents inventory, gaps & section-gating (Track C0 detail)

App Intents are now the **mandatory** Siri surface (SiriKit deprecated). They
should mirror MCP's section-gating: a section's actions are live only when the
section is enabled. **Today they don't** — see "Gating" below.

### Current intents (17, all writes) — `Septena/App/Intents/*` + `Septena/App/AddTaskIntent.swift`
tasks `AddTaskIntent` · supplements `MarkSupplementTaken`/`AddSupplement` ·
hydration `LogWater` · caffeine `LogCaffeine` · nutrition `LogMeal` · habits
`MarkHabitDone`/`AddHabit` · groceries `MarkGroceryLow`/`AddGroceryItem` ·
cannabis `LogCannabis` · training `LogTraining` · mood `LogMood` · chores
`CompleteChore`/`AddChore` · goals `AddGoal` · gut `LogGutEntry`.
10 ship a zero-config "Hey Siri" phrase (Apple cap = 10); the rest need a
once-off phrase assignment but are all Siri/Spotlight-callable.

### Coverage vs. MCP write tools (completeness)
- **Tasks (priority).** MCP has create/complete/update/defer/move_to_today;
  intents have only `AddTaskIntent`. Add **`CompleteTaskIntent`** +
  **`MoveToTodayIntent`/`DeferTaskIntent`** (needs a Task `AppEntity` +
  `EntityQuery` for resolution).
- **Mood (lockstep divergence).** `LogMoodIntent` exists but there is **no
  `mood_*` MCP tool** in the in-app catalog (or gateway). Add `mood_events_list`
  + `mood_event_log` to BOTH (MCP lockstep), or mood is the odd surface out.
- **`body` / `activity` sections** have neither intent nor MCP tool. Decide
  loggability: body (weight/measurements) likely → add both; activity
  (HealthKit-derived) likely read-only → skip.
- **Low priority:** goals_update, chores_uncomplete, nutrition/training _update
  — rarely voice actions; skip unless asked.
- **Correctly absent:** sleep (Oura), github, insights are read-only/derived.
- **Optional read-intents (widgets, not completeness):** "how much water today"
  (`hydration_today`), "what did I eat" (`nutrition_day_summary`), "what's on
  today" (tasks).

### Gating — make App Intents behave like MCP
MCP gates via `MCPToolCatalog.manifest(enabledSections:)`. App Intents instead
advertise all 17 always and **silently re-enable** a section on use, because App
Shortcuts are OS-extracted statically at install/update and can't be filtered by
runtime `SectionEntity.isEnabled` (`SectionLogIntent.swift:35-47`). To converge:
1. **Shared gate (do regardless):** one "is this section loggable AND enabled"
   helper that BOTH MCP and App Intents read — the App Intents twin of
   `manifest(enabledSections:)`.
2. **Runtime levers that work:** parameter `EntityQuery` already reflects live
   data (disabled section → empty picker); call
   `SeptenaShortcuts.updateAppShortcutParameters()` from the section
   enable/disable mutation to prompt re-extraction (**reliability: verify on iOS
   27 beta** — the in-code comment is skeptical).
3. **Policy decision (owner: product):** on a *disabled* section, intent should
   either (a) refuse/no-op (true MCP parity) or (b) re-enable + proceed
   (current). Recommendation: keep re-enable for an explicit primary log, but
   stop *surfacing* disabled sections in Spotlight/pickers.
4. **iOS 27 may moot this:** if Siri 2.0 routes rich actions via system MCP
   (already correctly gated), share MCP's gate rather than reinvent it.
