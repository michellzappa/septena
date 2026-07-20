# Training PT Spec — a sensible-minimum "coach brain"

Status: **partially built.** Scope agreed 2026-06-25.

- **Verb 3 (Progress) ships**, but as a *simpler model than §3 describes* — see
  [§3](#3-progress--reps-before-load-as-built). Read that section, not the
  original double-progression sketch, for what actually runs.
- Verbs 1 (Plan) and 2 (Prescribe) are still unbuilt: there is no plan/template
  layer, so nothing stores a per-exercise rep range or load increment.
- Verb 4 (Review) ships as the weekly muscle-balance block.

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
| **Progress** | "add a rep / 2.5 kg vs last time" | ✅ built — `TrainingProgression` |
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

### 3. Progress — reps before load (as built)

Implemented in
[`TrainingProgression`](../Septena/Sections/Training/TrainingProgression.swift);
rendered as the "Aim 62.5 kg × 5" nudge row with a one-tap **Apply** inside each
exercise card's expanded editor in
[`TrainingDestinationView`](../Septena/Sections/Training/TrainingDestinationView.swift).

**Why it diverges from the original sketch above.** That sketch needed a stored
per-exercise **rep range**, which lives in the plan/template layer — verb 1,
still unbuilt. Rather than invent a global rep range (wrong for a 3-rep squat
*and* a 15-rep lateral raise), the shipped rule keeps the same *principle* —
reps get earned before load moves — using only what the frozen snapshot knows.

The rule, off `lastByExercise` (frozen at session start so hints can't shift
mid-set) plus `recentByExercise` for stall detection:

| Last set rated | Suggestion | Why |
|---|---|---|
| **unrated** | repeat load & reps | no evidence of room; asks for a rating |
| **max** (RIR 0) | +1 rep, same load | already at this load's ceiling |
| **hard** (RIR 1), load stalling | +1 rep, same load | two sessions at this load already |
| **hard** (RIR 1) | +1 load step | the one case with room for a plate |
| **moderate** (RIR 2) | +1 rep, same load | reps have room, not the load |
| **easy** (RIR 3+) | +2 load steps | well within reserve |

Three guards that make it a coach rather than a ratchet:

1. **Unrated never adds load.** A bare `default:` branch swept unrated in with
   `hard` and added a plate every session forever. Unrated is now its own case.
2. **Proportional cap** (`maxJumpFraction = 0.10`). The equipment step is an
   absolute number of kilos, so an unguarded +5 kg machine step is 5% on a
   100 kg leg press and 25% on a 20 kg cable fly. Multi-step jumps are trimmed
   to ~10% of the last load. One step is always allowed — you can't add less
   than the smallest thing on the rack.
3. **Stall detection.** Two logged sessions at the same load means the load
   isn't the thing to change; earn a rep instead.

The **load step** is the equipment's natural increment from
[`WeightCadence`](../Septena/Shell/UI/WeightCadence.swift) — barbell 2.5 kg,
dumbbell 2 kg, machine 5 kg, micro 1 kg, inferred from the exercise name. This
replaces the sketch's "+2.5 upper / +5 lower": equipment predicts the addable
increment better than body region does, and it's the same step the weight
stepper already uses.

**Non-destructive by construction.** The hint never auto-fills the entry — an
aspirational load in a log the user might Save unchanged would corrupt the
history the rule reads from. The bump is a deliberate tap.

**Setting:** Training ▸ Session ▸ *Progression hints* (on by default,
`training.progressionHints`, device-local like the effort scale). One toggle is
the whole surface — the increment isn't user-editable because per-exercise
increments belong to the plan layer, not a global override.

Still deferred: per-exercise rep ranges and increments (needs verb 1), deload
prescription after repeated stalls, bodyweight-movement progression (reps-only
lifts have no `weight`, so they get no hint today).

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
ranking; per-session readiness from sleep/HRV; cardio plan; per-exercise rep
ranges and load increments (blocked on the plan/template layer, verb 1).

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
