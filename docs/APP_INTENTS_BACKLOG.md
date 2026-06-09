# App Intents Backlog

Prioritized backlog for the App Intents surface. Companion to
`docs/CORE_AI_iOS27_PREP.md` (Appendix B is the summary; this is the actionable
list). Planning only — no code until the Xcode 27 beta is installed.

## Why this matters now

- **App Intents is the only *confirmed, documented* Siri/Spotlight/Shortcuts
  surface in iOS 27.** SiriKit is deprecated (news). The rumored "Siri calls
  your MCP server" path is **not** in the iOS 27 or Xcode 27 release notes —
  only in reverse-engineered iOS 26.1 beta code (Sept 2025). So investing in App
  Intents is the safe bet; system-MCP exposure is speculative.
- **Target behavior: mirror MCP.** MCP advertises a section's tools only when
  the section is enabled (`MCPToolCatalog.manifest(enabledSections:)`). App
  Intents should converge on the same gate instead of "advertise-all + silently
  re-enable on use" (today's compromise, `SectionLogIntent.swift:35-47`).

## Invariants (don't violate)

- Intents are a **façade over mutators** — never write SwiftData directly
  (`TaskMutator`, `NutritionMutator`, …). `perform()` must
  `await SeptenaServices.shared.start()` first (background launch).
- A `SectionLogIntent`'s `sectionKey` is the single tie to its section
  (manifest + enablement + catalog identity). New intents follow the existing
  one-file-per-section shape; no central switch.
- **Apple cap = 10 zero-config "Hey Siri" phrases**, build-enforced. All intents
  stay Siri/Spotlight-callable regardless; only the 10 phrases are curated.
- **MCP lockstep:** any change touching the MCP tool surface lands in the in-app
  catalog AND the hosted gateway AND the skill docs, same change.

## Status snapshot

- 17 intents across 13 loggable sections; every loggable section has ≥1 primary
  log intent. Coverage is *good for logging*, *thin for Tasks*, with one
  parity divergence (Mood).
- 18 manifest sections total; read-only/derived (sleep, github, insights) need
  no log intent. `body`/`activity` unevaluated.

## Priority table

| ID | Item | Pri | Effort | Depends |
|----|------|-----|--------|---------|
| AI-1 | Task `AppEntity` + `EntityQuery` | P0 | M | — |
| AI-2 | `CompleteTaskIntent` | P0 | S | AI-1 |
| AI-3 | `MoveToTodayIntent` + `DeferTaskIntent` | P0 | S | AI-1 |
| AI-4 | Mood MCP parity (`mood_events_list` + `mood_event_log`) | P0 | M | — |
| AI-5 | Shared "loggable AND enabled" gate | P1 | M | — |
| AI-6 | `updateAppShortcutParameters()` on section toggle | P1 | S | AI-5 |
| AI-7 | Disabled-section policy (refuse vs re-enable) | P1 | S | AI-5 + decision |
| AI-8 | Evaluate `body`/`activity` loggability | P1 | S | — |
| AI-9 | Read-intents (water/meal/today summaries) | P2 | M | AI-1 (today) |
| AI-10 | Re-curate the 10 zero-config phrases | P2 | S | AI-2/3 |
| AI-11 | Secondary write parity (update/uncomplete) | P2 | S | — |
| AI-12 | Widget / Control Center / interactive surfaces | P2 | M | AI-1 |

---

## P0 — completeness + parity

### AI-1 · Task `AppEntity` + `EntityQuery`
**Why:** Tasks is the app's core, but only `AddTaskIntent` exists. Acting on an
*existing* task by voice/Shortcut needs the system to resolve *which* task — an
`AppEntity` + `EntityQuery`. Foundation for AI-2/AI-3/AI-9.
**What:** A `TaskAppEntity` (id, title, status, today/scheduled/due, area,
project) backed by an `EntityQuery` reading the live store via
`SeptenaServices`. Query reflects enablement implicitly (no rows → empty).
**Acceptance:** Siri/Shortcuts can pick a task; query returns current Today /
inbox / upcoming sets matching the app sidebar.

### AI-2 · `CompleteTaskIntent`
**Why:** MCP has `tasks_complete`; intents don't. Highest-value missing action.
**What:** Intent taking a `TaskAppEntity` → `TaskMutator.complete`. Mirror
MCP's guard: error on recurring tasks (complete in-app so the next occurrence
spawns). Donate for prediction.
**Acceptance:** "Complete <task>" marks it done; recurring tasks refused with a
clear dialog. Parity with `tasks_complete`.

### AI-3 · `MoveToTodayIntent` + `DeferTaskIntent`
**Why:** MCP has `tasks_move_to_today` + `tasks_defer`; the two highest-value
triage actions, absent from intents.
**What:** Two intents over `TaskAppEntity`. Move → today=true, clear scheduled.
Defer → `@Parameter` date (reuse `DateParser` for relative phrasing) →
scheduled set, today cleared. Both via `TaskMutator`.
**Acceptance:** Parity with the two MCP tools; defer accepts "tomorrow"/"next
Monday".

### AI-4 · Mood MCP parity *(MCP-side work, fixes the divergence)*
**Why:** `LogMoodIntent` exists but there is **no `mood_*` MCP tool** in the
in-app catalog (and presumably the gateway) — the clearest violation of "App
Intents and MCP expose the same surface." Likely a latent bug, not just an
iOS 27 item.
**What:** Add `mood_events_list` + `mood_event_log` to `MCPToolCatalog.section`
("mood") AND the hosted gateway AND the skill markdown (lockstep). Shape mirrors
the other event sections (MoodEvent reuses the retired AirReading CK slot).
**Acceptance:** `expectedNames` drift tripwire passes; mood readable/writable
over MCP exactly as it is over the intent.

---

## P1 — section-gating (the "behave like MCP" core)

### AI-5 · Shared "loggable AND enabled" gate
**Why:** MCP gates with `manifest(enabledSections:)`; App Intents have no twin
and re-enable on use. One shared predicate keeps both surfaces honest.
**What:** A single helper (`SeptenaServices` or `SectionManifest`) answering
"is sectionKey loggable AND enabled," consumed by intent `perform()` and the
shortcut-surfacing logic. Add an explicit `loggable` flag to the manifest if not
already derivable (read-only sections: sleep/github/insights/activity?).
**Acceptance:** One source of truth both MCP and intents read; no second
copy of the enabled-section logic.

### AI-6 · `updateAppShortcutParameters()` on section toggle
**Why:** App Shortcuts are OS-extracted statically; the system only re-reads
when prompted. Calling this when sections enable/disable is the supported lever.
**What:** Invoke `SeptenaShortcuts.updateAppShortcutParameters()` from the
section enable/disable mutation path.
**Acceptance:** Toggling a section updates the offered shortcut set. **Verify
reliability on the iOS 27 beta** — the in-code comment is skeptical it works.

### AI-7 · Disabled-section policy *(product decision required)*
**Why:** Decide what "behave like MCP" means at the action boundary.
**Options:** (a) **refuse/no-op** on a disabled section = strict MCP parity;
(b) **re-enable + proceed** = today.
**Recommendation:** keep (b) for an *explicit* primary log (logging = consent),
but stop *surfacing* disabled sections in Spotlight/parameter pickers (so the UI
matches MCP's "invisible when off"). Implement once the policy is chosen.
**Acceptance:** Behavior matches the chosen policy consistently across all
intents; documented in `SectionLogIntent`.

### AI-8 · Evaluate `body` / `activity` loggability
**Why:** Both are manifest sections with neither an intent nor an MCP tool.
**What:** Determine if either is user-loggable. `body` (weight/measurements)
likely yes → add a log intent + MCP tools (lockstep). `activity`
(HealthKit-derived) likely read-only → mark non-loggable, no action.
**Acceptance:** Each is explicitly loggable-with-coverage or marked read-only.

---

## P2 — enhancements / optional

### AI-9 · Read-intents
"How much water today" (`hydration_today`), "what did I eat" / day macros
(`nutrition_day_summary`), "what's on today" (tasks). Return `IntentResult` with
dialog + snippet; good widget/Control Center fodder. Not "completeness."

### AI-10 · Re-curate the 10 zero-config phrases
After AI-2/AI-3 land, the top-10 phrase slots may want Complete Task /
Move-to-Today over a low-frequency primary. Keep total ≤10; rebalance in
`SeptenaShortcuts`.

### AI-11 · Secondary write parity
`goals_update`, `chores_uncomplete` (undo), `nutrition_entry_update`,
`training_entry_update` have MCP tools but no intent. Low voice value — add only
on demand.

### AI-12 · Widgets / Control Center / interactive surfaces
The same intents can back interactive widgets, Control Center controls, and
Lock Screen actions. Reach play, not completeness.

---

## iOS 27 known-issues watchlist (from the release notes — confirmed)

- **W-1 (174869053):** "Siri might generate unexpected responses when triggering
  an AppShortcut phrase with an App enum value." Audit which intents use
  `AppEnum` parameters (caffeine method, cannabis method, mood quadrant,
  training session type…) — phrase-driven enum capture may misbehave.
- **W-2 (175031314):** Non-SF-Symbol custom images for app entities may not
  appear in Siri. Affects AI-1 if `TaskAppEntity` uses custom imagery.
- **W-3 (175534195):** Default values may not apply for `Set`-type parameters;
  workaround is an explicit `@Parameter` default (e.g. empty set).

## Cross-references
- `docs/CORE_AI_iOS27_PREP.md` — the umbrella iOS 27 AI plan (Track C / App
  Intents = Appendix B).
- `SeptenaCore/MCP/MCPToolCatalog.swift` — the authoritative action surface to
  mirror.
- `Septena/App/Intents/SectionLogIntent.swift` — the intent spine + the
  static-extraction / re-enable compromise this backlog revisits.
