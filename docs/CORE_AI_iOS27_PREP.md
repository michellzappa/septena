# Core AI & iOS 27 Preparation Plan

Status: **planning only — no code yet** (Xcode 27 beta to be installed later).
Date: 2026-06-09. Source: WWDC 2026 + the Core AI / Foundation Models
documentation. This file is the agent + human cheat-sheet for the iOS 27 AI
push. Verify every "(news)"-tagged claim against the SDK once the beta lands.

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

### 1b. Foundation Models — what's new for iOS 27 (confirmed — Apple docs)
The framework we already use (`import FoundationModels`). New surface:

- **Private Cloud Compute routing** — `PrivateCloudComputeLanguageModel`, gated
  by the `com.apple.developer.private-cloud-compute` entitlement. Larger context
  + stronger reasoning, same privacy guarantees. **This is the drop-in our Coach
  factory already stubbed.**
- **Multimodal prompting** — `Attachment`, `AttachmentContent`,
  `ImageAttachmentContent`, `ImageReference`. **Text + image into the on-device
  model.** This is the easy food-photo path.
- **Dynamic profiles / instructions** — `LanguageModelSession.DynamicProfile`,
  `DynamicInstructions`, `SessionProperty` — runtime adaptation of behavior.
- **Custom LLM provider** — `LanguageModelExecutor` (+ `…GenerationChannel`,
  `…GenerationRequest`): plug a different backend behind the same session API.
- **Agentic workflows**, cross-session **KV-cache** reuse, **Instruments**
  profiling support.
- (news) Bigger base model (Gemini-distilled), expanded context window,
  **on-device private fine-tuning**.
- Platform floors: iOS/iPadOS/macOS/visionOS **26.0+**; **watchOS 27.0+** (so
  Foundation Models on the watch is *new* and unlocks a watch Coach).

### 1c. System MCP, Siri 2.0, Extensions *(news — verify in beta)*
- An **MCP client is now in a system framework**; users/MDM **register MCP
  servers**, and **Siri 2.0 + the Core AI routing layer can call them**.
- **Extensions framework**: users pick a preferred AI provider (Gemini / Claude
  / ChatGPT) in Settings; system AI requests route there.
- Siri 2.0: multi-turn, on-screen awareness, file analysis, cross-app steps.

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

> **STATUS (checked against shipped docs, 2026-06-09):** "Siri/Core AI calls
> your app's MCP server" is **NOT** in the iOS 27 or Xcode 27 release notes.
> MCP in Apple's shipped docs is **Xcode/developer-tooling only** (LLDB
> `lldb-mcp`, the Xcode MCP server, String Catalog tools, Agent Client Protocol,
> plugin-defined MCP servers). iOS 27 release notes don't mention MCP at all;
> App Intents remains the only documented Siri surface. The only signal for
> system MCP-in-App-Intents is reverse-engineered **iOS 26.1 beta code** (Sept
> 2025, via 9to5Mac/AppleInsider) — in development, undocumented. **Treat
> Track C as a bet, not a roadmap; do Track C0 (App Intents) regardless.**

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
2. **PCC entitlement provisioning** — approval process, availability in dev
   builds, behavior on PCC-ineligible devices/regions.
3. **System MCP registration API** — exact API, entitlement, security model;
   currently only news, not in the docs we read.
4. **Multimodal cost/latency on-device** — image prompts may be slow on older
   eligible hardware; need the confirm-gate UX to tolerate latency.
5. **Foundation Models behavior changes** — bigger model may shift `@Generable`
   output; re-test every existing prompt service against the new model.
6. **App-size + specialization time** if we ship a Core AI `.aimodel` (B1b).

## 8. Recommended sequencing

1. **Now (no Xcode 27):** this doc; design the `MealEstimate` schema + confirm
   UX on paper; spec the `PrivateCloudComputeBackend` conformance; list
   entitlement changes. *(done / in progress)*
2. **Beta day 1:** smoke-test existing FM features against the new model;
   confirm Core AI vs Foundation Models split holds; check the PCC entitlement
   and system-MCP registration APIs actually exist as the news described.
3. **First build:** Track A1 (Coach PCC) — smallest, the seam exists.
4. **Headline:** Track B1a (food photo → macros via FM multimodal). Ship behind
   availability + confirm-gate. Measure accuracy → decide on B1b.
5. **Then:** B3 (correlation narration), C1 (register MCP with system), A2/A4.
6. **Backlog:** B2, B4, B5, B6, C2/C3, B1b.

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
- **NOT in any shipped doc (rumor/contradicted):** "Siri/Core AI calls your
  app's MCP server" — only iOS 26.1 beta code analysis (Sept 2025). Gemini-as-
  Siri, bigger on-device model, on-device fine-tuning, Extensions provider
  picker — WWDC coverage, not release-noted. Treat as bets (§1c, Track C).

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
