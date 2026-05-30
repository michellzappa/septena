# Self-Discovery Mini-Apps — Implementation Plan

Bring NavigateWithin's **Purpose / Ikigai** experience into Septena's **Goals**
tab as the first of a few small, local-AI-powered **self-discovery mini-apps**.
Mini-apps are guided reflections that run entirely on-device (Apple
FoundationModels) and emit real **Goals** as their durable output.

Status: **plan / pre-implementation.** Source app studied:
`../_/NW-App/NavigateWithin`.

---

## 1. The idea in one paragraph

Goals today is a flat grid of free-text intentions, each optionally bound to a
measurable metric. We turn it into a small **self-discovery hub**: the existing
goal grid, plus a **Discover shelf** of guided mini-apps. The first mini-app is
**Ikigai** — the four-quadrant purpose exercise from NavigateWithin. The user
fills four quadrants (love / good-at / paid-for / world-needs), the on-device
model synthesises a purpose statement, four intersections, and a set of
commitments, and a final **Review & Save** screen turns those outputs into
Goals via the existing `GoalMutator` (so they sync through CloudKit like every
other goal). The shelf is a registry, so Values / Future Self / etc. are purely
additive later.

The structural insight: NW's *Purpose → Commitments* is the same shape as
Septena's *north-star Goal → measurable Goals*. The Ikigai mini-app is, in
effect, **a guided Goal generator**.

---

## 2. Verified groundwork (why this is low-risk)

- **iOS deployment target is `26.0`** (`Septena.xcodeproj`). FoundationModels
  (`import FoundationModels`, `LanguageModelSession`, `@Generable`) is fully
  available — no minimum-OS bump. Only a **per-device availability gate** is
  needed (`SystemLanguageModel.default.availability`).
- **FoundationModels is not yet linked** anywhere in Septena — clean greenfield
  for on-device AI.
- **NW's `PurposePromptService` already runs on-device** and calls
  `LanguageModelSession()` directly; its `aiService` field is vestigial — the
  port drops it.
- **Three NW components lift almost verbatim** (same author, no license issue):
  - `Views/FlowLayout.swift` — dependency-free SwiftUI `Layout`.
  - `Views/Shared/SelectablePillsView.swift` — depends only on `FlowLayout` +
    a tint color (NW passes a `ThemeStyle`; we pass a `Color`).
  - `PurposeSuggestions.swift` — static fallback suggestion arrays.
- **`GoalMutator` API is exactly what we need** (`SeptenaCore/SeptenaServices.swift`):
  - `@discardableResult func createGoal(text:) -> Goal`
  - `func updateGoal(id:text:sections:)`
  - `func updateGoalMetric(id:metricKey:window:comparator:target:baseline:)`
  - `func deleteGoal(id:)`
- **Goals UI**: `GoalsView()` mounts directly from `RootTabView` as the `.goals`
  tab (not via a plugin destination). The shelf goes inside
  `GoalsView.content`, above the grid.
- **Conventions confirmed**: `Haptics.tick()/success()/warning()`
  (`SeptenaCore/Haptics.swift`); `SectionDrawer(sectionKey:title:onLog:)`;
  `GoalMetricCatalog.all / metric(for:) / metrics(for:) / sectionKey(for:)`
  (`Septena/Shell/Goals/GoalMetricEvaluator.swift`); onboarding pattern
  `SectionExplainerView`. The app presents everything via `.sheet` today.

---

## 3. Target architecture

Everything new lives in the **app target** (`Septena/Shell/...`), keeping
`SeptenaCore` UI-free — same boundary the existing plugins respect.

```
Septena/Shell/
├── Intelligence/                         ← NEW: on-device AI layer
│   ├── OnDeviceAI.swift                  availability gate + helpers
│   ├── PurposePromptService.swift        ported NW service + @Generable structs
│   └── Components/
│       ├── FlowLayout.swift              lifted from NW (verbatim)
│       ├── SelectablePillsView.swift     lifted from NW (Color instead of ThemeStyle)
│       └── PurposeSuggestions.swift      lifted from NW (verbatim)
└── Goals/
    ├── GoalsView.swift                   ← MODIFY: inject DiscoveryShelf
    └── Discovery/                        ← NEW
        ├── DiscoveryMiniApp.swift        protocol + DiscoveryRegistry + DraftGoal
        ├── DiscoveryShelf.swift          horizontal cards at top of Goals
        ├── ReviewAndSaveView.swift       DraftGoal[] → GoalMutator
        └── Ikigai/
            ├── IkigaiMiniApp.swift        conforms to DiscoveryMiniApp
            ├── IkigaiFlowView.swift       paged flow (steps → overview → results)
            ├── IkigaiQuadrantStep.swift   one quadrant (pills + text + AI suggest)
            └── IkigaiViewModel.swift      @Observable flow state + AI calls
```

### Data flow

```
IkigaiFlowView (on-device generation)
   → purpose statement + 4 intersections + N commitments
   → [DraftGoal]  (purpose = 1 north-star draft; each commitment = 1 draft)
ReviewAndSaveView (user checks/edits, optionally tags sections)
   → for each included DraftGoal:
        let g = goalMutator.createGoal(text: draft.text)
        goalMutator.updateGoal(id: g.id, text: draft.text, sections: draft.sections)
        // Phase 2: goalMutator.updateGoalMetric(...) when draft carries a metric
   → GoalsView refreshes from LocalCache.goals(in:) → CloudKit sync (existing)
```

No new persisted entity in Phase 1 — outputs ride the existing `Goal`
infrastructure.

---

## 4. New types (illustrative signatures)

### 4.1 `OnDeviceAI` — availability gate

```swift
import FoundationModels

@MainActor
enum OnDeviceAI {
  static var availability: SystemLanguageModel.Availability {
    SystemLanguageModel.default.availability
  }
  static var isAvailable: Bool {
    if case .available = availability { return true }
    return false
  }
  /// Human-readable reason for the empty/disabled state.
  static var unavailableReason: String? {
    switch availability {
    case .available: return nil
    case .unavailable(.deviceNotEligible):
      return "Self-discovery needs Apple Intelligence, which isn't supported on this device."
    case .unavailable(.appleIntelligenceNotEnabled):
      return "Turn on Apple Intelligence in Settings to use self-discovery."
    case .unavailable(.modelNotReady):
      return "The on-device model is still downloading. Try again shortly."
    case .unavailable:
      return "On-device intelligence is unavailable right now."
    }
  }
}
```

### 4.2 `DiscoveryMiniApp` — the registry seam

```swift
@MainActor
protocol DiscoveryMiniApp {
  static var id: String { get }            // "ikigai"
  static var title: String { get }         // "Purpose"
  static var blurb: String { get }         // one line for the card
  static var systemImage: String { get }   // SF Symbol
  static var accent: Color { get }
  /// Builds the full-screen flow. Calls `onFinish` with the goals the
  /// user chose to save (empty array if they cancelled / saved nothing).
  static func makeView(onFinish: @escaping ([DraftGoal]) -> Void) -> AnyView
}

@MainActor
enum DiscoveryRegistry {
  static let all: [any DiscoveryMiniApp.Type] = [IkigaiMiniApp.self]
}
```

### 4.3 `DraftGoal` — exercise output staged for Review & Save

```swift
struct DraftGoal: Identifiable {
  let id = UUID()
  var text: String
  var sections: [String] = []
  var include: Bool = true            // checkbox state in Review & Save
  var kind: Kind = .commitment        // .purpose | .commitment (affects styling)
  // Phase 2 — optional measurement, model-suggested from GoalMetricCatalog:
  var metricKey: String? = nil
  var metricWindow: String? = nil
  var metricComparator: String? = nil
  var metricTarget: Double? = nil
  enum Kind { case purpose, commitment }
}
```

### 4.4 `PurposePromptService` (ported)

Same prompts as NW (`buildPurposePrompt`, `buildCommitmentPrompt`,
`buildSuggestionsPrompt`, title/description + intersections variants) and the
same `@Generable` structs (`PurposeTitleAndDescription`, `PurposeIntersections`,
`AIGeneratedCommitment` + `CommitmentsResponse`, `Suggestions`). Each method
does `LanguageModelSession().respond(to: prompt, generating: T.self)`. Drop the
`ExternalAIService`/`aiService` dependency and the optional Supabase `userData`
argument (re-add a Septena-native context feed later if useful).

---

## 5. The Ikigai flow (mapped from NW `PurposeView`)

| Screen | NW source | Behaviour in Septena |
| --- | --- | --- |
| Intro | `WelcomePageView` | Short header + "Begin". Reuse `SectionExplainerView` styling or a simple custom header. |
| 4 × Quadrant | `StepView` | Pills via `SelectablePillsView`; free-text add field; "Suggest more" button → `generateSuggestions(for:currentSelections:)`. Static `PurposeSuggestions` fallback on error. |
| Overview | `OverviewPage` | 2×2 grid of selected pills; "Generate purpose" enabled when each quadrant has ≥1 item. |
| Results | `PurposeAndCommitmentsPage` | 3 sequential on-device phases with loading + 10s retry: (1) `generatePurposeTitleAndDescription`, (2) `generatePurposeIntersections`, (3) `generateCommitments`. |
| Review & Save | *(new)* | Purpose statement → 1 `DraftGoal(kind: .purpose)`; each commitment → 1 `DraftGoal(kind: .commitment)`. Checkboxes + optional section tags. Save → `GoalMutator`. |

**Dropped from NW** (not needed / replaced): `Session`/`SessionManager`,
coin/unlock gating, `SupabaseManager`, `PlausibleAnalytics` calls (Septena has
its own analytics via `trackScreen`), EventKit reminder export (Septena has
Tasks), `TokenUsageBar` (optional), and NW's bespoke `ThemeStyle` (use Septena
`Theme` / `SectionTheme` + `Haptics`).

**Presentation**: `.fullScreenCover` for the immersive multi-step flow. (The app
currently uses `.sheet` everywhere; full-screen is a deliberate exception for a
take-over experience. If we'd rather match convention exactly, a `.sheet`
wrapping a `NavigationStack` also works — minor call, easy to switch.)

---

## 6. GoalsView integration

In `Septena/Shell/Goals/GoalsView.swift`:

- Add state: `@State private var activeMiniApp: AnyDiscoveryMiniApp? = nil`
  (a small identifiable wrapper around the metatype, for `.fullScreenCover(item:)`).
- At the **top of `content`** (and surfaced prominently in the empty state),
  render the shelf, gated on availability:

  ```swift
  if OnDeviceAI.isAvailable {
    DiscoveryShelf(onOpen: { activeMiniApp = $0 })
  }
  ```

- Present the active mini-app and absorb its output:

  ```swift
  .fullScreenCover(item: $activeMiniApp) { app in
    app.type.makeView(onFinish: { drafts in
      saveDrafts(drafts)     // createGoal + updateGoal(sections:) per included draft
      activeMiniApp = nil
      Task { await load() }  // refresh grid
    })
  }
  ```

- `saveDrafts(_:)` iterates included drafts, creating + tagging goals through
  `goalMutator`. (Phase 2 also calls `updateGoalMetric` when a draft carries a
  metric.)

When the device can't run on-device AI, the shelf is simply hidden (existing
empty/grid behaviour unchanged) — optionally a single muted row showing
`OnDeviceAI.unavailableReason`.

---

## 7. Phased delivery

### Phase 0 — Spike (½ day)
**Goal:** prove FoundationModels works inside Septena on the real device.
- Link `FoundationModels.framework` to the Septena app target.
- Add `OnDeviceAI.swift`.
- Throwaway button that runs the Ikigai purpose prompt with hard-coded inputs
  and logs the `@Generable` result.
- **Done when:** structured `PurposeTitleAndDescription` round-trips on device;
  `OnDeviceAI.isAvailable` reflects reality.

### Phase 1 — Ikigai MVP (2–3 days)
**Goal:** complete Ikigai → real goals in the grid, synced.
1. Lift `FlowLayout`, `SelectablePillsView` (Color param), `PurposeSuggestions`.
2. Port `PurposePromptService` + `@Generable` structs.
3. Build `IkigaiViewModel` + `IkigaiFlowView` + `IkigaiQuadrantStep` (steps →
   overview → 3-phase results) with loading + 10s retry.
4. Build `ReviewAndSaveView` (DraftGoal list → `GoalMutator`).
5. Add `DiscoveryMiniApp` protocol + `DiscoveryRegistry` + `IkigaiMiniApp`.
6. Add `DiscoveryShelf`; inject into `GoalsView`; wire `.fullScreenCover` + save.
- **Done when:** on a supported device, running Ikigai end-to-end creates the
  selected goals (visible in the grid, present in CloudKit); shelf hidden on
  unsupported devices; **no `SeptenaCore` / Persistence / CKEngine / Manifest
  changes required.**

### Phase 2 — Depth (later, optional)
- **Persist the reflection** as a new `Reflection` entity using the **MoodPlugin
  template** end-to-end: DTO in `SeptenaCore/Models.swift` → `@Model` entity +
  CloudKit schema in `Persistence.swift` → `ReflectionMutator` in
  `SeptenaServices.swift` → `CKEngine` wiring (recordProvider /
  applyFetchedRecord / applyDeletedRecord) → add to `LocalStore.container`
  schema. Lets the user revisit / re-run and lets goals link back to their
  source reflection.
- **Model-suggested metrics**: add a `@Generable` field constrained to the real
  `GoalMetricCatalog` keys (FoundationModels `@Guide` / enum constraint) so a
  commitment like "swim twice a week" auto-attaches
  `training.session_count, calendarWeek, gte 2`. Plays straight into
  `updateGoalMetric`.
- **Mini-app #2**: Values or Future Self (purely additive — new folder under
  `Discovery/`, one line in `DiscoveryRegistry.all`).

### Phase 3 — Polish (optional)
- Promote self-discovery to a real `SectionPlugin` (its own onboarding + MCP
  skill) if we want an agent to read the purpose statement as cross-section
  context, or want it as a first-class section with a manifest entry.

---

## 8. Decisions taken (with rationale)

- **Home = top of the Goals tab**, not a new tab or a per-mini-app section.
  Matches the request ("bring it INTO Goals") and keeps outputs co-located with
  where goals already live.
- **Phase 1 persists nothing new** — outputs become Goals only. Fastest path to
  a working loop; rides existing CloudKit; defers schema work until the flow
  feels right.
- **Ship Ikigai alone, registry-first.** The `DiscoveryMiniApp` seam means #2 is
  additive, but we don't build speculative mini-apps now.
- **On-device only.** No API keys, no network, privacy-preserving — consistent
  with NW's shipped approach and Septena's CloudKit-as-source-of-truth model.

Open for your call before we start:
- Full-screen cover vs. sheet for the flow (default: full-screen cover).
- Whether Phase 1 also lets the user tag sections per draft in Review & Save
  (default: yes, optional) vs. leaving tagging to the existing `EditGoalSheet`.

---

## 9. Risks & mitigations

| Risk | Mitigation |
| --- | --- |
| FoundationModels unavailable on a given device (AI off / ineligible HW / model downloading) | `OnDeviceAI.isAvailable` gate hides the shelf; `unavailableReason` explains why. The API itself is always present at iOS 26. |
| On-device latency / occasional empty generation | Port NW's loading state + 10s retry buttons per phase; keep one `LanguageModelSession` active at a time per flow. |
| `@Generable` + `Codable` interplay | NW already ships both annotations together; copy that pattern. |
| Scope creep into a full section/plugin | Phase 1 is explicitly registry-in-Goals only; SectionPlugin promotion is deferred to Phase 3. |
| `SeptenaClient` ≤4-parallel HTTP rule (from project memory) | Not applicable — FoundationModels is local, not HTTP. Noted to avoid confusion. |

---

## 10. Phase 1 file checklist

**Create**
- `Septena/Shell/Intelligence/OnDeviceAI.swift`
- `Septena/Shell/Intelligence/PurposePromptService.swift`
- `Septena/Shell/Intelligence/Components/FlowLayout.swift`
- `Septena/Shell/Intelligence/Components/SelectablePillsView.swift`
- `Septena/Shell/Intelligence/Components/PurposeSuggestions.swift`
- `Septena/Shell/Goals/Discovery/DiscoveryMiniApp.swift`
- `Septena/Shell/Goals/Discovery/DiscoveryShelf.swift`
- `Septena/Shell/Goals/Discovery/ReviewAndSaveView.swift`
- `Septena/Shell/Goals/Discovery/Ikigai/IkigaiMiniApp.swift`
- `Septena/Shell/Goals/Discovery/Ikigai/IkigaiFlowView.swift`
- `Septena/Shell/Goals/Discovery/Ikigai/IkigaiQuadrantStep.swift`
- `Septena/Shell/Goals/Discovery/Ikigai/IkigaiViewModel.swift`

**Modify**
- `Septena/Shell/Goals/GoalsView.swift` — inject `DiscoveryShelf`, add
  `.fullScreenCover`, add `saveDrafts(_:)`.
- `Septena.xcodeproj/project.pbxproj` — link `FoundationModels.framework`; add
  new files to the app target.

**Untouched in Phase 1:** `SeptenaCore/*` (Models, Persistence, SeptenaServices,
CKEngine, SectionManifest), `SectionRegistry`.

---

## 11. Verification

- **Phase 0:** device log shows a valid structured purpose result; toggling
  Apple Intelligence flips `OnDeviceAI.isAvailable`.
- **Phase 1:** run the app (`/run` or Xcode), open Goals, run Ikigai end-to-end,
  confirm selected goals appear in the grid and persist across relaunch (local
  mirror) and propagate to CloudKit; confirm the shelf is hidden on a device
  without Apple Intelligence.
