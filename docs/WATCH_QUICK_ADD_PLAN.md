# Watch quick-add from suggestions — plan

> **Status (2026-06-09):** v1 SHIPPED (uncommitted), build-verified iOS + watch +
> macOS. caffeine / cannabis / mood are tappable on the wrist; training +
> fastBreak deferred. Not yet device-tested (watch side-load blocked — see the
> watch-install note). Mood/caffeine/cannabis writes need the pending prod schema
> deploy before they persist in prod.

Make the watch's "Next" suggestions actionable: tap a nudge (coffee, mood, …) to
log it from the wrist, instead of the current read-only state. All five
suggestion kinds, wired through one shared descriptor table so adding a kind is a
one-row edit — the same single-source discipline as `NextBlocks` / `DayBucket`,
not hand-rolled per-section watch code.

## Today

- Suggestions reach the watch as `NextItem(kind: "suggestion")` carrying only a
  title/subtitle (`NextFeed.flat` → `NextEntry.suggestion`). The real kind
  (`NextSuggestion.Kind`: caffeine / cannabis / training / fastBreak / mood) and
  the params needed to write an event are dropped.
- `NextItemRow` renders suggestions read-only on purpose ("no logging UI on the
  watch").
- The watch writes only Habit/Supplement/Chore/Task events
  (`WatchConnectivity.saveEvent`), dispatched off `NextBlocks` by record type.
- On the phone, a suggestion tap opens a **sheet** to capture detail (caffeine
  method/grams, mood quadrant, training type) — none are true one-tap logs.

## Design — one shared descriptor (`SuggestionBlocks`)

New SeptenaCore file, dependency-free (no SwiftUI/SwiftData) so it compiles into
the watch target exactly like `NextBlocks` and `DayBucket`. One row per kind:

```
struct SuggestionBlock {
  let kind: String          // "caffeine" — the suggestion sub-kind
  let sectionKey: String    // "caffeine" — matches SectionManifest.key
  let recordType: String    // "CaffeineEvent" — CloudKit type the watch writes
  let input: QuickLogInput  // how much UI the wrist needs
}

enum QuickLogInput {
  case oneTap                       // log immediately with defaults
  case choice([QuickChoice])        // short on-watch list (method / type)
  case moodGrid                     // the 4-quadrant mood picker
}
```

Membership in this table = "loggable from a watch suggestion." The phone's
`NextSuggestion.Kind` keeps its sheet routing, but `recordType` + the default
field-builder live here once, so phone and watch can't disagree.

v1 rows — the three suggestion kinds that log coherently from a wrist tap:

| kind      | section    | record type      | input      |
|-----------|------------|------------------|------------|
| caffeine  | caffeine   | `CaffeineEvent`  | `.choice` (v60 / matcha / other) |
| cannabis  | cannabis   | `CannabisEvent`  | `.choice` (vape / edible) |
| mood      | mood       | `MoodEvent`      | `.moodGrid` (2×2 quadrant → 3×3 emotions) |

**Deferred (read-only on the watch for v1):**
- `training` → `ExerciseEntry` requires both `sessionType` *and* a named
  `exercise`; a wrist tap can only write a degenerate set. The phone opens a full
  session builder. Add later once a wrist input model exists.
- `fastBreak` → `NutritionEntry` needs macros; no sensible zero-input write.

Both become one-row `SuggestionBlocks` additions when designed — the descriptor
is built to extend, which is the point.

## Wire change

Carry the action to the watch without bloating `NextItem`: add one optional
field

```
struct NextItem { … ; var action: QuickLogAction? }
struct QuickLogAction: Codable { let kind: String; let defaults: [String:String] }
```

`NextFeed.flat` populates `action` for suggestion rows (kind + phone-computed
defaults like the learned "usual" caffeine method). Optional ⇒ old payloads and
all non-suggestion rows decode unchanged. The widget ignores `action` (display
only); the watch uses it.

## Watch writers (`WatchConnectivity`)

Add `saveCaffeineEvent` / `saveCannabisEvent` / `saveMoodEvent` /
`saveExerciseEntry` / `saveNutritionEntry`, mirroring the existing
`saveHabitEvent` shape (record name `caffeine-event:{uuid}` etc., `date` / `time`
/ `occurredAt` stamped like the phone's mutators). Routed off the descriptor's
`recordType`, same pattern as `saveEvent` today — one `switch`, fails loud on an
unmapped type.

## Watch UI

- `.oneTap` → tap row → success haptic → write (identical to a completion).
- `.choice` → tap row → push a tiny list of the choices → write the picked one.
- `.moodGrid` → tap row → the 2×2 valence/arousal grid → write quadrant+emotion.

New small views (`QuickLogChoiceView`, `MoodQuadrantGridView`) in `SeptenaWatch/`.
Rows stay in the shared Next list; only suggestion rows with an `action` become
tappable (`NextItemRow` branches on `item.action != nil`).

## Open questions / dependencies

1. **fastBreak.** A `NutritionEntry` needs macros; a zero-input "break fast"
   marker is lossy. Options: (a) log a 0-kcal "fast broken" marker meal with a
   timestamp; (b) drop fastBreak from watch quick-add (keep read-only). Leaning
   (b) for v1 — flag for decision.
2. **Prod schema.** `CaffeineEvent` / `CannabisEvent` `occurredAt` and the whole
   `MoodEvent` type are **pending prod deploy** (see `docs/CloudKitSchema.md` and
   the prod-cutover plan). Watch writes work in dev now; prod needs that deploy
   first. Writers must tolerate the field's absence defensively.
3. **No lockstep with the hosted gateway** — this is the watch CloudKit snapshot,
   not an MCP tool, so the gateway repo is untouched.
4. **Verification.** Physical-watch side-load is currently blocked (broken
   Mac↔watch tunnel, see watch-install note) — v1 is build- + sim-verified only.

## Build order

1. `SuggestionBlocks` descriptor + `QuickLogAction` wire field + `NextFeed.flat`
   population. (foundation, no behavior change yet)
2. Watch writers, routed off the descriptor.
3. Watch UI: make suggestion rows tappable; choice + mood-grid sheets.
4. Phone: point `NextSuggestion.Kind` recordType/defaults at the shared
   descriptor so the two never drift.
