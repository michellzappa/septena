# Ramble mode — voice capture and task context

**Status:** proposal (2026-11-24). Defaults in §9 stand unless mz overrules.
**Decisions:** [ADR 0007](adr/0007-septena-is-the-task-app.md), [ADR 0015](adr/0015-shared-registries-for-cross-platform-clients.md), [ADR 0020](adr/0020-registry-owns-copy-and-translations.md), [ADR 0028](adr/0028-registry-owns-vocabulary-platforms-own-interaction.md), [ADR 0029](adr/0029-one-task-page-two-depths.md), [ADR 0035](adr/0035-companion-voice-is-push-to-talk-and-confirmed.md) (proposed — shared confirm contract; companion voice is [#426](https://github.com/septena/septena/issues/426)). Does **not** depend on [ADR 0009](adr/0009-trustable-private-ai.md) (proposed): phone and Mac Ramble stays strictly on-device by default.
**Builds on:** `Septena/Shell/Intelligence/OnDeviceAI.swift`, `SeptenaCore/AIPolicy.swift`, `Septena/Shell/Tasks/TaskComposer.swift`, `Septena/Shell/Tasks/TaskDraft.swift`, `Septena/Shell/Tasks/AddTaskPage.swift`, `Septask/SeptaskKitQuickEntry.swift`, `Septask/SeptaskKitInspector.swift`, `SeptenaCore/Outbox.swift` (`TaskMutator`), `SeptenaCore/TaskUndo.swift`, `docs/INLINE_CAPTURE_PARSING_SPEC.md` (#133), `docs/COMPANION_DEVICES_SPEC.md`, `docs/TASK_PAGE_SPEC.md` (#300), `docs/HAPTICS_SPEC.md`.
**Tracking issue:** [#211](https://github.com/septena/septena/issues/211).
**Owner of decisions:** mz. Defaults chosen by the author are marked *(default)*.

---

## 1. Goal and non-goals

Let users speak freely — without phrasing commands or formatting titles — and turn unstructured speech into either:

1. **One or more new tasks** with extracted titles, concise notes, and parsed dates/lists (global capture), or
2. **Structured notes and optional checklist items appended to an existing task** (in-task enrichment).

### Product invariants

- **On-device by default.** On iPhone, iPad, and Mac, audio never leaves the device — not to Septena's backend, not to Apple speech servers, and not to third-party APIs. Structuring runs locally on Apple `FoundationModels` when available and degrades cleanly to deterministic parsing when not.
- **Audio is never stored.** PCM audio buffers live strictly in memory for the duration of one ramble and are discarded on stop or cancel. Audio is never written to disk, SwiftData, attachments, sync payloads, or logs (matching ADR 0035 #3).
- **One confirm step across every voice surface.** Speech never silently creates tasks or overwrites notes. Every utterance passes through an explicit review/confirm step before `TaskMutator` writes; cancel or silence discards without mutating. Companion devices (ADR 0035, #426) and phones/Mac share this contract (§4).
- **Mutator and undo parity.** Confirmed writes go exclusively through `TaskMutator` (`SeptenaCore/Outbox.swift`) and `TaskDraft` (`Septena/Shell/Tasks/TaskDraft.swift`), recorded as a **single atomic `TaskUndo` step** (`SeptenaCore/TaskUndo.swift`) so one `⌘Z` / shake / Undo toast reverses the entire ramble.
- **Registry owns vocabulary; platforms own interaction (ADR 0028).** Action IDs, labels, icons, shortcuts, notices, and capability flags live in `registry/*.json`; recording chrome and review sheets use each platform's standard toolkit.

### Non-goals (v1)

- Always-on wake words or background listening (explicitly banned by ADR 0035 #1).
- Storing voice memos or audio attachments on tasks (separate attachment flow).
- Cross-task mutations from a ramble ("complete my dentist task and move everything from Work to Friday"). Ramble only **creates** tasks (global mode) or **appends** to one open task (in-task mode).
- Cloud/hosted transcription or LLM structuring escalation on phones/Mac (deferred until/unless ADR 0009 is accepted and an explicit user opt-in exists).

---

## 2. Entry points and gesture model

Ramble has **two entry points** with distinct scopes so the system never has to guess whether the user wants new tasks or more context on the current task.

### 2.1 Global capture — new tasks from a ramble

Captures 1..N new tasks, seeded with the active list's default placement (`TaskDraft(filter:)` — e.g., Today when launched from Today, Project X when launched from Project X, Inbox from Quick Entry or list root), which parsed hints or user edits in the review sheet can override per item.

| Surface | Entry affordance | Notes |
|---|---|---|
| **iPhone** | Trailing mic button in `TaskListView` / `AddTaskPage` nav toolbar (next to Search), plus a `"Ramble"` row in the Magic Plus contextual menu where menus exist | **Do not attach a hold gesture to `MagicPlusOrb`** (`Septask/SeptaskRootView.swift`): Magic Plus uses a zero-delay `DragGesture` to drop inline rows. Keep Ramble on its own tap/hold mic target so drag-to-insert never regresses. |
| **iPad** | Trailing mic button in the list toolbar + keyboard shortcut `⇧⌘R` *(default)* + `AddTaskPage` mic button | Review opens as a standard `.sheet` (never `.focusedSceneValue` from split detail, per `AGENTS.md`). |
| **Mac (AppKit shell)** | Mic button inside Quick Entry (`SeptaskKitQuickEntry`, `⌃⌥Space`), in-app menu **Task ▸ Ramble…** (`⇧⌘R` *(default)*), and optional global hotkey *(off by default; §9)* | Quick Entry grows smoothly into the listening state without switching apps; Review opens in the same `KitSurfacePanel` tier or an attached sheet on the main window. |
| **Android (later phase)** | Mic FAB / top-bar icon on list screens and Quick Add sheet | Uses Android on-device `SpeechRecognizer` (`RecognizerIntent.EXTRA_PREFER_OFFLINE` / `createOnDeviceSpeechRecognizer`) with the same registry vocabulary and review contract. |

### 2.2 In-task detail — enrich an existing task

Appends structured context (cleaned prose/bullets and optional checklist items) to **one existing task** without altering its title, schedule, or existing notes unless the user edits them in the review sheet.

| Surface | Entry affordance | Where it sits |
|---|---|---|
| **iPhone / iPad Task Page & Drawer** (`TaskComposerCard` `.page` / `.drawer`) | Mic button in the Notes card header / keyboard accessory bar (`TaskMarkdownNotesEditor`) | Visible in edit mode (`editingTask != nil`); hidden in review depth (`pageDepth == .review`, ADR 0029). |
| **iPhone / iPad inline editor** (`TaskComposerCard` `.inline`) | Mic button in the notes keyboard accessory bar (`NotesTextView.inputAccessoryView`) | Opens the same compact Ramble recording + append review sheet over the list; commits to the open draft + store cleanly. |
| **Mac (`SeptaskKitInspector`, `SeptaskKitComposer`)** | Mic button trailing the `"Notes"` header in `SeptaskKitInspectorController` (`Septask/SeptaskKitInspector.swift`) and in `KitComposerCell` when notes are focused; menu action when a single task is open/selected | Flushes any unsaved typed notes before opening Ramble so the append preview shows the true current text. |

### 2.3 Recording interaction — tap-to-toggle AND hold-to-speak

ADR 0035 requires push-to-talk on a desk orb. Phones and Macs support longer rambles (30–120 seconds) and must also satisfy motor accessibility (no hold-only actions). Both gestures work on the same mic control:

- **Tap** → starts listening immediately; tapping **Stop / Done** (or `Return` / `Space` inside the listening sheet) ends capture and opens Review.
- **Press-and-hold** (≥ 350 ms) → push-to-talk; releasing ends capture and transitions straight to Review (matching ADR 0035 muscle memory for quick 3-second captures). While holding, sliding up or tapping a **Lock** chip latches into hands-free mode *(default)*.
- **Visible listening chrome:** While the microphone is hot, a dedicated listening bar/sheet is always front-and-center with an explicit `"Listening"` label, elapsed timer (`0:14`), live streaming transcript preview, audio-level meter (static under Reduce Motion), **Cancel**, and **Done** buttons — plus the OS microphone privacy indicator.
- **Limits:** Soft cap of **120 seconds** *(default)* with a quiet countdown during the final 15 seconds; reaching the cap stops cleanly and transitions to Review with all captured text intact. Initial silence timeout of **6 seconds** *(default)* when zero words have been recognized.

---

## 3. On-device pipeline (transcription + structuring)

```
  AVAudioEngine (RAM PCM buffers, never persisted)
        │
        ▼
  ┌──────────────────────────────────────────────────────────────────────┐
  │ 1. On-device Transcription (`RambleTranscriber`, SeptenaCore)        │
  │    Primary: iOS/macOS 26 `SpeechAnalyzer` + `SpeechTranscriber`      │
  │    Fallback: `SFSpeechRecognizer` (`requiresOnDeviceRecognition=true`)│
  └──────────────────────────────────────────────────────────────────────┘
        │  rawTranscript: String, locale: Locale, durationMs: Int
        ▼
  ┌──────────────────────────────────────────────────────────────────────┐
  │ 2. On-device Structuring (`RambleStructurer`, Septena/Intelligence)  │
  │    Rung 1: Apple `FoundationModels` (`LanguageModelSession` +        │
  │            `@Generable`) when `OnDeviceAI.isAvailable`               │
  │    Rung 2: Deterministic fallback (`TaskTitleParser` /               │
  │            `TitleTokenParser` #133 + `SuggestionEngine`)             │
  └──────────────────────────────────────────────────────────────────────┘
        │  VoiceReviewProposal (global tasks[] OR taskAppend)
        ▼
  ┌──────────────────────────────────────────────────────────────────────┐
  │ 3. Shared Review & Confirm Sheet (§4)                                │
  │    User inspects, edits, unchecks/merges, then taps Add / Append     │
  └──────────────────────────────────────────────────────────────────────┘
        │  explicit confirm only
        ▼
  TaskMutator (`SeptenaCore/Outbox.swift`) + ONE `TaskUndo` entry
```

### 3.1 Transcription layer (`RambleTranscriber`)

Lives in a new `SeptenaCore/Voice/` folder (compiled into `Septask` and `SeptaskMac`; `Speech.framework` and `AVFAudio.framework` linked in `project.yml`).

1. **Primary engine (iOS/iPadOS/macOS 26.0+): `SpeechAnalyzer` + `SpeechTranscriber`**
   - Deployment target is already 26.0 (`project.yml`), so `SpeechAnalyzer` is available without legacy OS forks.
   - Streams `AVAudioPCMBuffer` converted to `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` directly into an `AsyncStream<AnalyzerInput>`.
   - Runs **100% on-device** with no 60-second session ceiling and automatic punctuation/volatile-to-finalized transcript updates.
   - Uses `AssetInventory` to check whether the user's current `Locale` (falling back to preferred app languages in `CFBundleLocalizations`: `en`, `fr`, `de`, `es`, `pt-BR`) has an installed on-device speech model. If uninstalled and online, prompts a one-time system asset download with progress; if offline, reports unavailable cleanly (§6).
2. **Fallback engine: `SFSpeechRecognizer`**
   - Used only when `SpeechTranscriber` does not support the active locale on the current device.
   - **Must set `request.requiresOnDeviceRecognition = true`** and check `recognizer.supportsOnDeviceRecognition` before starting. If `false`, refuse rather than silently sending audio to Apple's servers.
3. **Audio hygiene**
   - `AVAudioSession` on iOS uses `.playAndRecord` with `.measurement` / `.spokenAudio` mode and `.duckOthers` (never `.allowBluetooth` forced over built-in when unavailable; let route-change handler preserve partial text). Deactivates session with `.notifyOthersOnDeactivation` on stop/cancel.
   - Audio buffers are never written to temporary files; the `AVAudioEngine` input tap is removed and the engine stopped in `defer` / teardown.

### 3.2 Structuring layer (`RambleStructurer`)

Lives in `Septena/Shell/Intelligence/RambleStructurer.swift`, gated through `OnDeviceAI` (`Septena/Shell/Intelligence/OnDeviceAI.swift`).

#### Rung 1 — Apple `FoundationModels` (`OnDeviceAI.isAvailable`)

Uses `LanguageModelSession()` with `@Generable` structured outputs (same pattern as `OnDeviceReasoningProvider.swift`), staying strictly inside the on-device 8,192-token window (`SystemLanguageModel.contextSize` / `tokenCount(for:)` on 26.4+):

```swift
@available(iOS 26.0, macOS 26.0, *)
@Generable
struct RambleCapturePlan: Sendable {
  @Guide(description: "Distinct actionable tasks extracted from the user's speech. Keep 1 item if the user described a single task with details.")
  let tasks: [RambleProposedTask]
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct RambleProposedTask: Sendable {
  @Guide(description: "Short, clean imperative task title without filler words or trailing dates.")
  let title: String
  @Guide(description: "Optional concise context, links, or details mentioned for this task. Nil if none.")
  let notes: String?
  @Guide(description: "Optional exact date or timing phrase spoken (e.g. 'tomorrow', 'next Friday', 'today'). Nil if none.")
  let whenPhrase: String?
  @Guide(description: "Optional deadline phrase if explicitly stated as a due date. Nil if none.")
  let deadlinePhrase: String?
  @Guide(description: "Optional exact name of a matching existing project or area from the provided list, or nil.")
  let listName: String?
  @Guide(description: "Optional short checklist steps if the user enumerated sub-steps for this one task.")
  let checklistItems: [String]
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct RambleTaskEnrichment: Sendable {
  @Guide(description: "Clean, concise Markdown notes to append to the existing task. Preserve facts, remove verbal filler, do not repeat existing notes.")
  let appendedMarkdown: String
  @Guide(description: "Optional short checklist items only if the user clearly listed sub-steps to do.")
  let checklistItems: [String]
}
```

**Grounding & deterministic post-pass (never trust raw LLM IDs or dates):**

1. **Date resolution:** `whenPhrase` and `deadlinePhrase` are parsed deterministically through `DateParser` / `TitleTokenParser` (`docs/INLINE_CAPTURE_PARSING_SPEC.md`, `#133`) relative to **`DayClock.today`** (never `Date()` directly, preserving time-travel and rollover invariants). Unparseable phrases stay in `notes` rather than silently inventing dates.
2. **List resolution:** Only compact active project/area titles (capped to top ~40 active names to protect the 8K token budget) are provided in the system prompt. Returned `listName` is matched strictly against `LocalCache.projects` / `LocalCache.areas` (case-insensitive exact/unique match); unmatched strings are ignored (never auto-create projects/areas). When no list matches, `SuggestionEngine.shared.suggest(forText:)` may still offer its normal filing hint.
3. **Token-budget guard:** Before calling `session.respond`, estimate tokens (`tokenCount(for:)` on 26.4+, else conservative `chars / 3`). If transcript + context exceeds 6,000 tokens (leaving room for structured output), skip Rung 1 and route straight to Rung 2 without throwing.
4. **Timeout & guardrail guard:** Rung 1 runs with a **5-second** soft timeout *(default)* and catches `LanguageModelSession.GenerationError` (including `.guardrailViolation` / `.exceededContextWindowSize`), falling back cleanly to Rung 2 so the user's transcript is never lost.

#### Rung 2 — Deterministic / plain-transcript fallback

Runs automatically whenever `OnDeviceAI.status != .available` (`.notEnabled`, `.modelNotReady`, `.deviceNotEligible`), when the user disables AI structuring in Settings, or when Rung 1 times out / refuses / fails:

- **Global capture:** Produces **1 proposed task** *(default)*:
  - Runs `TaskTitleParser.detect` (upgraded to `TitleTokenParser.parse` once `#133` lands) to extract date / `#project` / `@area` / `!today` hints.
  - If the cleaned transcript is ≤ 90 characters, places all of it in `title` (`notes: nil`).
  - If > 90 characters, sets `title` to the first sentence/clause (capped at 90 chars at a word boundary) and places the full transcript in `notes`.
  - Runs `SuggestionEngine.shared.suggest(forText:)` for a local list suggestion.
- **In-task enrichment:** Produces `appendedMarkdown = trimmedTranscript` and `checklistItems = []`.
- **Honest UI badge:** The Review sheet shows a quiet, non-blocking caption: `"Plain transcript"` (with a subtle info hint if Apple Intelligence is off/downloading, never a modal error).

#### Relationship to `AIPolicy` and ADR 0009

- Even when `AIPolicy.mode` is `.auto` or `.useMyClaude`, Ramble structuring defaults to **on-device only** *(default)*. Voice rambles often contain unfiltered personal thoughts; keeping them inside the device preserves trust and lets Ramble ship independently of ADR 0009 and Apple's PCC entitlement.
- If the user explicitly turns off Apple Intelligence (or a future "Off" switch in ADR 0009), Rung 1 is skipped and Rung 2 still gives full offline voice capture — satisfying ADR 0009 #5 ("Off is a full app").

---

## 4. One shared review & confirmation UX (with ADR 0035)

Issue #211 and ADR 0035 (#426, companion devices) share **one confirmation model** so users learn one mental model across desk orb, Apple Watch, iPhone, iPad, and Mac:

> **Speak → See proposed result → Edit/Adjust (where screen permits) → Explicit Confirm writes (or Cancel/Silence discards).**

### 4.1 Shared `VoiceReviewProposal` contract

```swift
enum VoiceReviewMode {
  case capture(defaultFilter: TaskFilter, proposals: [ProposedTaskDraft])
  case enrich(targetTaskID: String, targetTitle: String, existingNotes: String,
              structuredAppend: String, rawTranscript: String,
              proposedChecklist: [String])
}

struct ProposedTaskDraft: Identifiable, Equatable {
  let id: UUID
  var isIncluded: Bool = true
  var draft: TaskDraft          // reuses Septena/Shell/Tasks/TaskDraft.swift
  var checklistItems: [String]  // optional subtasks (CHECKLISTS_SPEC)
}
```

How the same contract projects onto each device class:

| Device | Utterance cap | Splitting | Review surface | Confirm / Cancel |
|---|---|---|---|---|
| **Desk orb / Watch (ADR 0035, #426)** | 20 s *(default)* | 1 utterance → 1 task (or 1 question answer); no AI split in v1 | Screen shows transcribed text | Explicit confirm tap writes; silence/timeout cancels |
| **iPhone / iPad (Ramble #211)** | 120 s *(default)* | 1..N tasks (global) or append block (in-task) | Modal `RambleReviewSheet` (`.medium` / `.large` detents) | Primary `"Add N tasks"` / `"Append to notes"` button; Cancel / swipe-down with dirty-guard discards |
| **Mac (Ramble #211)** | 120 s *(default)* | 1..N tasks (global) or append block (in-task) | `KitSurfacePanel` / attached sheet | `⌘↩` or primary button confirms; `Esc` cancels |

### 4.2 Global capture review sheet

1. **Header:** `"Review capture"` (from registry) + subtle pill when Rung 2 fallback was used (`"Plain transcript"`).
2. **Proposed task cards (1..N):**
   - Each card has a leading include/exclude toggle (checked by default; unchecking dims the card and excludes it from commit), inline-editable `title`, optional inline-editable `notes`, optional checklist preview, and flat attribute pills (`When`, `Deadline`, `List`) that open the **same single picker per attribute** required by ADR 0029 (`docs/TASK_PAGE_SPEC.md` §3).
   - If `proposals.count > 1`, show a quiet secondary action **`"Merge into one task"`** so a user can undo an overly eager AI split in one tap (combines titles/notes back into a single draft seeded from the transcript).
   - If `proposals.count == 1`, skip the include checkbox and Merge action so single-task voice capture feels as light as Quick Add.
3. **Original transcript disclosure:** Collapsed by default (`DisclosureGroup("Original transcript")`), showing the exact verbatim text transcribed on-device. Guarantees transparency (ADR 0009 #4) and lets the user copy a detail the model trimmed.
4. **Footer / toolbar actions:**
   - **Cancel** (`Esc` on Mac/iPad): discards everything without writing (`Haptics.warning()` if edited).
   - **Re-record / Add more** *(optional in R2)*: appends a second spoken take before confirming.
   - **Confirm** (`"Add task"` / `"Add N tasks"`, `⌘↩` on Mac/iPad): disabled when 0 items are included or any included item has an empty title.

### 4.3 In-task enrichment review sheet

1. **Header:** Target task's title (read-only context line) + segmented toggle **`Structured` | `Raw`** (hidden when Rung 2 ran, since only raw is available).
2. **Existing notes preview:** If `existingNotes` is non-empty, show the last 2–3 lines muted above a subtle divider labeled `"Appending below"` so the user is 100% certain prior notes are preserved.
3. **Editable append box:** Multi-line `TaskMarkdownNotesEditor` pre-filled with `appendedMarkdown` (or `rawTranscript` when `Raw` is selected).
4. **Proposed checklist items (optional):** Only shown when `proposedChecklist` is non-empty; each item has a toggle (checked by default) and editable text.
5. **Original transcript disclosure:** Collapsed by default (shown when `Structured` is active).
6. **Confirm (`"Append to notes"` / `"Append & add N steps"`):**
   - Joins existing notes + appended text with a blank line (`"\n\n"`) when existing notes are non-empty (trimmed cleanly so no stray leading blank lines accumulate).

### 4.4 Write boundary and atomic `TaskUndo`

- **Global capture confirm:**
  - Calls `draft.create(via: mutator)` for each included `ProposedTaskDraft` (and `mutator.addChecklistItem(...)` for any included checklist items), collecting `createdIDs` and immutable snapshots for redo.
  - Records **ONE** undo step via `TaskUndo.recordCreate(name: ..., ids: createdIDs, mutator: mutator, rebuild: ...)`: a single `⌘Z`, iOS shake, or Undo toast purges every task created by that ramble.
  - Posts `.septenaTasksChanged`, plays `Haptics.commit()`, and shows the standard Undo toast (`"Added 3 tasks"` + `Undo`).
- **In-task enrichment confirm:**
  - Captures `beforeNotes = task.notes` before writing.
  - Calls `mutator.update(id: task.id, notes: mergedNotes)` and `mutator.addChecklistItem(...)` for each included checklist item.
  - Wraps both in **ONE** undo entry (new `TaskUndo.recordVoiceEnrich(id:beforeNotes:afterNotes:addedChecklistItems:mutator:)` in `SeptenaCore/TaskUndo.swift`, using the existing `TaskUndo.record(name:undo:redo:)` symmetric idiom so undo restores exact `beforeNotes` and deletes the newly added checklist items without touching notes edited before the ramble).
  - Plays `Haptics.commit()`.

---

## 5. Registry additions (ADR 0015 / ADR 0020 / ADR 0028)

Before shell UI lands, declare the vocabulary once in `registry/` and regenerate via `node scripts/gen-registries.mjs`:

| Registry file | Proposed additions |
|---|---|
| `registry/capabilities.json` | `capture.ramble`: `"Ramble mode (on-device voice capture and task notes)"` (`ios`, `ipados`, `macos`: `planned` → `ships`; `android`: `planned`; `watchos`: `not_applicable` — watch uses ADR 0035 push-to-talk). |
| `registry/actions.json` | `app.ramble` (`"Ramble…"`, icon `action.mic`, shortcut `⇧⌘R` *(default)*, `featureId: "capture.ramble"`), `task.rambleNotes` (`"Add Voice Note…"`, icon `action.mic`, `selection: "single"`, `excludeDestinations: ["recentlyDeleted"]`, `featureId: "capture.ramble"`). |
| `registry/icons.json` | `action.mic` → SF Symbol `mic` / `mic.fill` (listening), Material `Mic` / `MicNone`. |
| `registry/settings.json` | Optional toggle under Tasks / AI preferences: `ramble_ai_structuring` (`"Structure voice captures on device"`, default `true`, hidden on `.deviceNotEligible` devices). |
| `registry/l10n/` | All user-facing Ramble strings (`Listening`, `Review capture`, `Add %d tasks`, `Merge into one task`, `Append to notes`, `Original transcript`, `Plain transcript`, permission & error notices) across `en`, `fr`, `de`, `es`, `pt-BR`. |

---

## 6. Privacy, permissions, offline behavior, accessibility, and failure states

### 6.1 Privacy & permissions

- **Lazy permission requests:** Microphone and Speech Recognition permissions are requested **only** when the user invokes Ramble for the first time — never at launch or in `SeptaskFirstRun`.
- **Pre-prompt rationale** *(default)*: Before the first OS permission alert, show a compact one-card prompt stating: *"Your voice is transcribed on this device and never saved or uploaded."* with **Continue** and **Not Now**.
- **Info.plist keys (both `Septask/Info.plist` and `Septask/Info-Mac.plist`):**
  - `NSMicrophoneUsageDescription`: `"Septena listens while you use Ramble mode to turn speech into tasks or notes on this device. Audio is never saved or uploaded."`
  - `NSSpeechRecognitionUsageDescription`: `"Septena transcribes your speech on this device for Ramble mode. Audio is never sent off your device."`
- **Hand-maintained entitlements (`Septask/SeptaskMac.entitlements`):**
  - Add `<key>com.apple.security.device.audio-input</key><true/>` (required for hardened runtime / App Sandbox mic access on macOS).
- **Privacy manifest (`Septask/PrivacyInfo.xcprivacy`):** No new `NSPrivacyCollectedDataTypes` entries — audio is neither collected nor linked nor transmitted.
- **Logging rule:** `SeptenaLog` may log lifecycle events, engine (`speechAnalyzer` / `sfSpeech`), structuring rung (`foundationModels` / `fallback`), duration in ms, task count, and error domain/code. It must **never** log raw audio, transcript text, or generated titles/notes.

### 6.2 Offline behavior

| Device state | Transcription | Structuring | User experience |
|---|---|---|---|
| **Offline + speech asset installed + Apple Intelligence ready** | On-device (`SpeechAnalyzer` / `SFSpeechRecognizer`) | On-device (`FoundationModels`) | Full Ramble works identically to online; confirmed writes queue locally in SwiftData/sync engine. |
| **Offline + speech asset installed + no Apple Intelligence** | On-device | Rung 2 deterministic fallback | Full Ramble works; review opens with `"Plain transcript"` chip. |
| **Offline + speech asset NOT installed for locale** | Unavailable | — | Honest inline state: `"Voice model for <Locale> isn't downloaded yet. Connect once to download it, or type instead."` with one-tap `"Type task"` / `"Type note"` fallback. |

### 6.3 Accessibility

- **Motor / Switch Control:** Tap-to-start + tap-to-stop is always a first-class path; hold-to-speak is strictly an accelerator, never required. All controls meet `.a11yMinTap` (44×44pt minimum).
- **VoiceOver:**
  - Listening start coordinates with VoiceOver so VoiceOver's own announcement is not captured as task text: post `A11y.announce("Listening", highPriority: true)` and wait ~400 ms (or until `UIAccessibility.announcementDidFinishNotification`) before unmuting the recognizer tap when `UIAccessibility.isVoiceOverRunning` is true.
  - On transition to Review, post `A11y.screenChanged()` and `A11y.announce(...)` with the concrete summary (e.g., `"3 tasks ready to review"` or `"Voice note ready to append"`).
  - Live streaming transcript is marked `.accessibilityUpdatesFrequently` so VoiceOver doesn't spam every partial word while the user speaks.
- **Reduce Motion (`DesignSpec.md` hard switch):** When `accessibilityReduceMotion` is enabled, suppress pulsing orb/waveform animations completely; render a static level meter or plain `"Listening · 0:14"` readout plus `Haptics.press()` / `Haptics.commit()`.
- **Dynamic Type:** Listening sheet, editable task cards, and transcript disclosure scale cleanly through Accessibility XXL sizes with vertical stacking (no clipped pills or horizontal truncation of titles).
- **Keyboard & Full Keyboard Access (Mac / iPad):** `⇧⌘R` opens Ramble, `Space` / `Return` stops listening, `Tab` walks proposed task cards and controls, `⌘↩` confirms, `Esc` cancels.
- **Voice Control / UI testing:** Stable `accessibilityIdentifier`s on every control (`septena.ramble.record`, `septena.ramble.stop`, `septena.ramble.confirm`, `septena.ramble.cancel`, `septena.ramble.merge`, `septena.ramble.card.<index>`).

### 6.4 Failure & fallback matrix

| Failure condition | Behavior | Haptic / Feedback |
|---|---|---|
| Microphone permission denied / restricted | Inline sheet notice explaining permission is off + `"Open Settings"` button (`UIApplication.openSettingsURLString` / macOS Privacy & Security URL) + `"Type instead"` escape. | `Haptics.warning()` |
| Speech recognition permission denied or locale lacks on-device support | Same inline notice + `"Type instead"` escape. **Never** silently enable server speech recognition. | `Haptics.warning()` |
| Audio interruption (phone call, Siri, alarm, Bluetooth route drop) | Pause capture immediately, **preserve all transcript captured so far**, show `"Paused — interruption"` with **Resume** and **Review what you said** buttons. Never discard partial speech silently. | `Haptics.warning()` |
| Empty utterance / initial 6 s silence / accidental tap | Stop cleanly, dismiss sheet without creating anything, show brief non-modal notice `"Didn't catch anything"`. | `Haptics.warning()` |
| Hits 120 s max duration | Quiet 15 s countdown; auto-stop at 2:00 and open Review with full transcript preserved. | `Haptics.threshold()` |
| `FoundationModels` unavailable, disabled, downloading, guardrail error, decode failure, or > 5 s timeout | Seamless automatic fallback to Rung 2 deterministic structuring; review opens with `"Plain transcript"` chip. Never blocks capture. | None (silent downgrade) |
| Target task deleted/synced away while user was speaking (in-task mode) | On confirm, check live task in `LocalCache`; if missing, offer `"Save as new task instead"` so the user's dictated notes are never lost. | `Haptics.warning()` |

---

## 7. Phased build breakdown

Each phase is scoped as one or more follow-up GitHub issues, gated on clean builds (`scripts/build.sh SeptaskMac 'platform=macOS'` + `Septask` when watch runtime matches) and `SeptenaCoreTests`.

| Phase | Scope | Key files | Depends on |
|---|---|---|---|
| **R0 — Registry, permissions & core voice contracts** | Add `capture.ramble`, `app.ramble`, `task.rambleNotes`, `action.mic`, and l10n strings in `registry/`; run `gen-registries.mjs`; add `NSMicrophoneUsageDescription` / `NSSpeechRecognitionUsageDescription` to `Septask/Info.plist` & `Septask/Info-Mac.plist`, and `com.apple.security.device.audio-input` to `Septask/SeptaskMac.entitlements`; define `RambleTranscriber` protocol, `VoiceReviewProposal`, and `TaskUndo.recordVoiceEnrich` with unit tests. | `registry/*.json`, `Septask/Info*.plist`, `Septask/SeptaskMac.entitlements`, `SeptenaCore/Voice/`, `SeptenaCore/TaskUndo.swift`, `SeptenaCoreTests/` | Nothing |
| **R1 — On-device transcription + structuring engine** | Implement `SpeechAnalyzerTranscriber` (iOS/macOS 26 primary + `AssetInventory` check) and `SFSpeechOnDeviceTranscriber` (`requiresOnDeviceRecognition = true` fallback); implement `RambleStructurer` (Rung 1 `FoundationModels` `@Generable` + `DayClock`-grounded date/list post-pass + token/timeout guards; Rung 2 deterministic fallback via `TaskTitleParser`/`TitleTokenParser` + `SuggestionEngine`); unit tests covering fallback, empty transcript, date grounding, and hallucinated-list rejection. | `SeptenaCore/Voice/`, `Septena/Shell/Intelligence/RambleStructurer.swift`, `project.yml`, `SeptenaCoreTests/` | R0 (benefits from `#133` NL0 when landed; works with `TaskTitleParser` before then) |
| **R2 — Shared Review UI & iPhone/iPad global capture** | Build listening chrome (tap + hold-to-speak + Reduce Motion + VoiceOver coordination) and `RambleReviewSheet` (global 1..N cards, Merge escape hatch, single-picker attribute chips per ADR 0029, collapsible transcript, atomic `TaskUndo` + toast); wire global entry points in `TaskListToolbars`, `AddTaskPage`, and Magic Plus menu (without disturbing Magic Plus drag). | `Septena/Shell/Capture/Ramble/`, `Septena/Shell/Tasks/TaskListToolbars.swift`, `Septena/Shell/Tasks/AddTaskPage.swift`, `Septask/SeptaskRootView.swift` | R1 |
| **R3 — In-task enrichment (iPhone/iPad) + macOS AppKit parity** | Add in-task append mode to `RambleReviewSheet` (before/after preview, `Structured`/`Raw` toggle, checklist extraction, missing-task recovery); wire Notes mic entry point in `TaskComposerCard` / `TaskMarkdownNotesEditor`; wire Mac global capture (`SeptaskKitQuickEntry` mic + `⇧⌘R` menu command) and Mac in-task enrichment (`SeptaskKitInspector` + `KitComposerCell`). | `Septena/Shell/Tasks/TaskComposer.swift`, `Septena/Shell/Tasks/TaskNotesEditor.swift`, `Septask/SeptaskKitQuickEntry.swift`, `Septask/SeptaskKitInspector.swift`, `Septask/SeptaskKitComposer.swift` | R2 |
| **R4 — Companion contract alignment & Android follow-up** | Verify `VoiceReviewProposal` / copy parity with companion voice `#426` (ADR 0035) once CD4 opens; port on-device Android Ramble using `SpeechRecognizer` + Rung 2 deterministic parser + Compose review sheet. | `android/`, `docs/COMPANION_DEVICES_SPEC.md` | R3, `#426` (for companion alignment) |

---

## 8. Verification criteria (for build phases)

- **Privacy audit:** Static check / unit test asserting `requiresOnDeviceRecognition == true` on every `SFSpeechAudioBufferRecognitionRequest`, zero file writes under `SeptenaCore/Voice/`, and zero transcript strings in `SeptenaLog` calls.
- **Undo tests (`SeptenaCoreTests`):** Multi-task Ramble commit undoes all N created tasks in one `TaskUndo.undo()` and recreates them on `redo()`; in-task enrichment undo restores exact `beforeNotes` and removes added checklist items without disturbing pre-existing checklist items.
- **Structurer & fallback tests (`SeptenaCoreTests`):** Rung 2 deterministic fallback handles short titles, long prose, date phrases relative to a fixed `DayClock.today`, and `#project`/`@area` hints; post-pass drops hallucinated project names not present in `LocalCache`.
- **Builds:** `scripts/build.sh SeptaskMac 'platform=macOS'` green (and `Septask` iOS when matching watchOS runtime is present), plus `node scripts/gen-registries.mjs --check` and `scripts/lint-design.sh` green.
- **Manual device testing (by mz):** Test on real iPhone and Mac — airplane mode (offline speech + FM), Apple Intelligence disabled (Rung 2 fallback), incoming call interruption during ramble, VoiceOver + Reduce Motion, and Magic Plus drag regression check.

---

## 9. Open questions

Defaults stand unless mz overrules (`docs/README.md` rule 5).

| Question | Default |
|---|---|
| Does phone/Mac Ramble ever send audio or transcripts off-device (PCC / Workers AI / Claude)? | No — strictly on-device in v1, even when `AIMode == .auto`, so Ramble ships independently of ADR 0009 *(default)* |
| Interaction gesture on the mic button | Both tap-to-toggle and hold-to-speak (≥ 350 ms), with a slide/tap Lock latch for long rambles *(default)* |
| Maximum single-ramble duration | 120 seconds, with a quiet 15-second countdown before auto-stopping into Review *(default)* |
| Initial silence timeout (zero words spoken) | 6 seconds, then dismiss cleanly with `"Didn't catch anything"` *(default)* |
| Rung 1 structuring timeout before silent fallback to Rung 2 | 5 seconds *(default)* |
| Rung 2 fallback task splitting when `FoundationModels` is unavailable | Single proposed task (title ≤ 90 chars + full transcript in notes), never heuristic multi-task splitting *(default)* |
| In-app keyboard shortcut on Mac / iPad | `⇧⌘R` (`app.ramble`), unused in `registry/actions.json` *(default)* |
| System-wide global Ramble hotkey on Mac (separate from Quick Entry `⌃⌥Space`) | Off by default — users reach Ramble via Quick Entry (`⌃⌥Space` + mic) or in-app `⇧⌘R` *(default)* |
| Pre-permission rationale card before the first OS microphone alert | Shown once before first mic prompt ("transcribed on this device, never saved or uploaded") *(default)* |
| Does Ramble expose a Settings toggle to disable AI structuring while keeping voice transcription? | Yes — `"Structure voice captures on device"` (default ON when Apple Intelligence is eligible) *(default)* |
