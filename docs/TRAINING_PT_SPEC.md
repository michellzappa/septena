# Training PT Spec — a sensible-minimum "coach brain"

Status: **spec / not built.** Scope agreed 2026-06-25.

## Why

The Training section logs well but doesn't *coach*. It shows a recommended
exercise, but it never sets a structure, never pushes progression, and never
calls out a lagging muscle — so it's easy to drift back into junk-volume,
no-overload habits. This spec adds the thin layer that makes the app behave like
a PT, **without** building a periodization engine.

A PT does four verbs. Today the app does ~half of one:

| Verb | PT does | App today |
|---|---|---|
| **Plan** | sets a weekly structure | nothing |
| **Prescribe** | "do *this* today" | weakly — `nextPendingIndex` walks a fixed routine |
| **Progress** | "add a rep / 2.5 kg vs last time" | has e1RM history, doesn't act on it |
| **Review** | "back is lagging — fix it" | data exists (`MuscleVolume`), passive |

The win is that the hard math already exists — effort-weighted hard sets per
muscle vs. target ([`TrainingMetrics`](../SeptenaCore/TrainingMetrics.swift),
[`MuscleVolume`](../Septena/Sections/Training/MuscleBalanceView.swift)). The PT
brain is mostly a **deterministic rules layer** reading data we already compute.
No LLM calls.

## The core design decision: templates are muscle targets, not machines

The user flagged the real problem: **a plan can only prescribe what's in their
gym.** A template that says "leg press 3×10" is useless if there's no leg-press
machine.

The fix is to **never bind a template to a specific exercise.** A plan template
is a list of *muscle slots with set targets per day*. The concrete exercise that
fills each slot is resolved at session start, filtered by the user's available
equipment and seeded from what they did last time. This sidesteps the equipment
problem structurally instead of hard-coding machines into plans, and it reuses
two things that already exist: `DraftSession.entries` (mutable) and the
"Alternatives" same-muscle float-up in
[`ExercisePickerSheet`](../Septena/Sections/Training/ExercisePickerSheet.swift).

```
Plan template (static)         Prescriber (at start)          Session
─────────────────────         ─────────────────────         ─────────
Lower A:                       for each slot:                Squat 4×5
  quads   4 sets   ──►          pick an exercise that    ──► RDL   3×8
  hams    4 sets                 • hits that muscle          Leg curl 3×10
  glutes  3 sets                 • user has equipment for    Calf raise 3×12
  calves  3 sets                 • prefer last-used / fav
```

Existing **Routines** stay as-is for users who want fully hand-built day lists;
a Plan is the opt-in coached layer on top.

---

## The four pieces (sensible minimum)

### 1. Plan — pick a template, don't generate one

**No plan *generator*.** Ship 3–4 hard-coded blueprints keyed to `(goal ×
days/week)`. Each blueprint is static data: a list of training days, each day a
list of `(Muscle, setTarget)`.

| Days | Blueprint | Frequency/muscle |
|---|---|---|
| 2 | Full-body A / B | 2× |
| 3 | Full-body A/B/C **or** Push / Pull / Legs | ~2× |
| 4 | Upper / Lower / Upper / Lower | 2× |

Set targets per muscle come from the goal band (strength 10–15, hypertrophy
12–20, maintain 4–8) split across that muscle's weekly sessions. These map
straight onto the existing `TrainingMetrics` defaults and the `MuscleBalance`
8–12 growth zone.

The user picks a blueprint **once** during setup (§Settings). This alone
delivers "a detailed plan, kept simple."

### 2. Prescribe — resolve today's slots into a session

When the user starts their next planned day, the prescriber builds
`DraftSession.entries` from the blueprint instead of a fixed routine list:

For each `(Muscle, setTarget)` slot, pick one exercise where:
1. `primaryMuscle == slot.muscle` **and** the exercise's `equipment` ⊆ the
   user's available equipment (§equipment model),
2. prefer the exercise the user used for that slot **last time** (continuity →
   progression works), else their most-frequent same-muscle movement, else the
   catalog default.

Reuses the alternatives logic already in `ExercisePickerSheet.isAlternative`.
The session is still fully user-mutable afterward — swap, add, skip as today.

### 3. Progress — one linear rule (double progression)

Per exercise, the plan stores a **rep range** and a **load increment**. The rule
runs at session start to set today's target, and is shown as a hint:

- Logged last time **at the top of the rep range** with **RIR ≤ 1**
  (`hard`/`max`) → **add one load increment**, reset reps to bottom of range.
- Logged in-range but not at the top → **keep load, aim +1 rep**.
- Missed the bottom of the range, or RIR ≥ 2 across the board → **hold** (repeat
  same target; flag a possible deload after N holds — *v2*).

Increments (default, user-editable in Settings): **+2.5 kg upper / +5 kg lower**;
bodyweight movements progress on reps only. This is textbook beginner linear /
double progression — deliberately the simplest honest model. No autoregulation,
no RPE math, no fatigue model in v1.

Data is already there: `DraftSession.lastByExercise`, `prBaselines`,
`recentByExercise` are frozen pre-session snapshots, and `difficulty` carries the
RIR-equivalent effort. The rule is pure function of those.

### 4. Review — on the session-conclusion page

Per the agreed surface: after a session is **saved**, the
[`SessionCompleteSheet`](../Septena/Sections/Training/SessionCompleteSheet.swift)
gains a compact "This week / Next up" block below the existing stats:

- **Per-lift progression outcome** (this session): e.g. *"Bench — hit 4×5 @ RIR 1
  → +2.5 kg next time."*
- **Weekly muscle review** (one line, incisive): *"11 of 16 muscles in zone.
  Hamstrings 5 under — your next Lower day closes it."* Straight from
  `MuscleVolume.setsPerMuscle` (now effort-weighted) vs. the growth zone.
- **Next session preview**: which planned day is next and its headline lifts.

This is presentation of data we already have — no new computation.

---

## Equipment model (the hard part, minimised)

Add a small controlled vocabulary, not a free-for-all.

**`Equipment` enum** (new, SeptenaCore) — keep it to the substitution-relevant
set:

```
barbell · dumbbell · machine · cable · bodyweight · kettlebell · bands
```

Two additions:

1. **On the exercise** — `equipment: [Equipment]` on `ExerciseDefinition` +
   `ExerciseDefinitionEntity` (most lifts are single-equipment; an array allows
   "goblet squat = dumbbell|kettlebell"). New CloudKit field on the
   `ExerciseDefinition` record → **additive prod-schema deploy**. Back-compat:
   nil/empty = "unknown", treated as always-available so nothing breaks for
   existing seeded exercises until they're tagged.
2. **On the user** — `availableEquipment: Set<Equipment>` in Settings, **default
   = all** (assume full gym, so the prescriber never starves and existing users
   see no change). A "home / dumbbell-only" user unchecks the rest and the
   prescriber + alternatives float-up filter accordingly.

Catalog tagging: the seed catalog (server `TrainingExportResponse`) gains the
field; until the server ships tags, equipment is editable per-exercise in
[`ExerciseCatalogView`](../Septena/Sections/Training/ExerciseCatalogView.swift)
and via the `training_exercise_*` MCP tools (**both servers**, per the MCP
lockstep rule in CLAUDE.md).

This is the only schema change in the minimum. Everything else rides existing
fields.

---

## Settings ▸ Training (config surface)

New **"Plan"** section in
[`TrainingDetailContent`](../Septena/Shell/Sections/Plugins/TrainingPlugin.swift),
above the existing Effort scale / Rest timer:

- **Goal** — Strength · Hypertrophy · Maintain  (`@AppStorage "training.goal"`)
- **Days per week** — 2 / 3 / 4  (`@AppStorage "training.daysPerWeek"`)
- **Available equipment** — multi-select of the `Equipment` vocabulary
  (`@AppStorage "training.equipment"`, default all)
- **Load increments** — upper / lower step (advanced; sensible defaults)
- **Plan on/off** — master toggle; off = today's behaviour exactly (routines +
  recommended exercise), so this is purely additive and reversible.

Goal + days select the blueprint; equipment parameterises the prescriber;
increments drive progression. Three answers configure all four verbs. This also
feeds the existing `suggestedGoals()` so the goal ring/targets stay in sync (the
targets-as-goals bridge).

---

## Explicitly out of scope (so it ships)

- ❌ Generated/periodised programs, mesocycles, scheduled deloads
- ❌ Autoregulation / RPE-based load math / fatigue modelling
- ❌ AI / LLM-generated plans — all rules are deterministic on local data
- ❌ Cardio/mobility programming — v1 is strength only
- ❌ Exercise-technique coaching, form cues, video
- ❌ Calendar scheduling / "rest day" enforcement (just show what's next)

Deferred to v2: deload suggestion after repeated holds; smarter substitution
ranking; per-session readiness from sleep/HRV; cardio plan.

---

## Build order (phased, each phase green + leave-able)

1. **Equipment field** — `Equipment` enum, add to model + entity + CloudKit
   record + export; back-compat nil = available; tag-in-catalog UI + MCP (both
   servers + skill). *Prod schema deploy gated behind the freeze.*
2. **Settings ▸ Plan section** — the `@AppStorage` config + master toggle
   (inert until wired). Ships independently.
3. **Blueprints + prescriber** — static blueprint data; `start(plan:)` that
   resolves muscle slots → `DraftSession.entries` filtered by equipment, seeded
   from last-used. Behind the toggle.
4. **Linear progression rule** — pure function over `lastByExercise` +
   `difficulty`; sets today's target; hint on the exercise card.
5. **Conclusion review block** — per-lift outcome + weekly muscle line + next-up,
   on `SessionCompleteSheet`.

Phases 2–5 need no schema deploy. Phase 1 is the only CloudKit change and is the
critical-path dependency for equipment-aware prescription.

## Where it hooks (quick reference)

- Model/equipment: `SeptenaCore/Models.swift`, `SeptenaCore/Persistence.swift`
- Volume/targets: `SeptenaCore/TrainingMetrics.swift`
- Prescriber / session: `DraftSession` (Models.swift),
  `TrainingDestinationView.start(...)`, `ExercisePickerSheet`
- Review: `SessionCompleteSheet.swift`, `MuscleVolume` (MuscleBalanceView.swift)
- Settings + goals: `TrainingPlugin.swift` (`TrainingDetailContent`,
  `suggestedGoals`, `aimMetrics`)
- MCP parity: in-app `SeptenaCore/MCP/` **and** `../septena-mcp-gateway`
