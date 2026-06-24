# Markers — plan

One new user-creatable section for arbitrary **occurrences** — things you want to
note when they happen, with no cadence, no goal, no judgment. It is Intake's
kind→event spine, **minus the item/consumption layer**, plus one optional light
attribute. The single sanctioned **catch-all primitive** for open-ended simple
logs.

Deliberately minimal — the long-tail home for things too idiosyncratic to deserve
a bespoke section. **Not a build-your-own-section kit** (that road ends at Notion
and dissolves the app's opinionated identity). Keep it poor on purpose:
occurrences + one attribute + one pattern view.

## What belongs in Markers — and what doesn't

Markers is for occurrences that have **no existing domain**: not consumption, not
health, not a practice, not a target. The honest test before logging something as
a Marker — does it already have a home?

| If it's… | …it's not a Marker, it's… |
|---|---|
| something you consumed | **Intake** |
| a health/body signal (incl. tinnitus, pain, nausea) | **Symptoms** / Gut / Body |
| something you do on a cadence and want a streak for | **Habit** |
| a target you're tracking toward a number | **Goal** (pin it — see [Pinned goals](PINNED_GOALS_PLAN.md)) |
| **none of the above** | **Marker** |

So **ear ringing is a Symptom, not a Marker** (clinically it's tinnitus). The
genuine Marker cases are the domain-less ones: "saw something beautiful", "idea
struck", "heard from an old friend", "the cat did the thing", "felt a strange
vibe". When in doubt between Symptoms and Markers, it's probably a Symptom.

## The taxonomy it serves

| Shape | Asks | Cadence | Value | Instance |
|---|---|---|---|---|
| Practice / streak | "did I do it today?" | expected | binary | Habits |
| **Occurrence / tally** | **"when did X happen?"** | **none** | **timestamp + optional attribute** | Intake, Symptoms, Gut, **Markers** |
| Measure | "what's the number vs. target?" | periodic | scalar | Goals (pinnable) |
| Check-in / state | "how is it right now?" | sampled | scale/enum | Mood |

Markers is the **generic, domain-less instance of the Occurrence row**.
Intake/Symptoms/Gut are *specialized* instances of the same shape; Markers is the
one without a domain. It carries **no goal/target** — a target turns an occurrence
into a Goal. Read-only trend only.

## Data — two `@Model`s (Intake has three; we drop the item layer)

`SeptenaCore/Persistence.swift`:

- **`MarkerKindEntity`** — the tracker definition:
  `id` ("mk-<uuid>"), `name`, `symbol` (SF Symbol), `emoji` (optional — user picks
  symbol *or* emoji, mirroring intake kind+item), `color` (hex/hsl token like
  `IntakeKindEntity.color`), `sortIndex`, `attributeStyle` (`"none"|"enum"|"scale"`),
  `attributeOptionsJSON` (encoded `["left","right","both"]` when enum), `archivedAt`,
  `updatedAt`, `cloudKitSystemFields`.
- **`MarkerEventEntity`** — the logged occurrence:
  `id`, `occurredAt` (UTC), `kindID`, `date` (YYYY-MM-DD), `attributeValue`
  (optional string — the chosen enum token or "1".."5"), `note`, `updatedAt`,
  `cloudKitSystemFields`.

### Design call (worth sign-off): attribute as enum, not items

Model the one optional attribute as a small enum on the kind (above), **not** by
reusing intake's item layer. Reusing items gets a free picker but drags item CRUD
+ a third entity back in — exactly the complexity we're cutting — and "saw
something beautiful" (style `none`) shouldn't carry an item table. Enum keeps it
two entities, hard-capped at one attribute.

## Surfaces (walk `docs/ADDING_A_SECTION.md`)

- **Manifest** — `SeptenaCore/Sections/SectionManifest.swift`, add row:
  `key: "markers"`, `defaultLabel: "Markers"`,
  `shortDescription: "Note moments and occurrences worth tracking"`,
  `activation: .optional`, `onboarding: .optional`, `supportsDashboard: true`,
  `settingsEditor: .sectionConfig`.
- **Plugin** — `Septena/Shell/Sections/Plugins/MarkersPlugin.swift` (new),
  conform to `SectionPlugin`, register in `SectionRegistry.all`. Emit **one
  dashboard tile per marker kind** (the intake per-instance tile path). Add
  `case markers` to `HomepageDomain`; the DEBUG parity assertion catches drift.
- **Mutator** — `MarkerMutator` (mirrors `IntakeMutator`): `upsertKind(...)`,
  `archiveKind(id:)`, `logEvent(kindID:attributeValue:note:)`, `deleteEvent(id:)`.
  The write boundary for all Marker writes.
- **Destination view** — list of kinds → tap to log (one-tap when
  `attributeStyle == none`, else a tiny attribute picker) + recent occurrences.
- **Create / manage wizard** — name + EmojiSlotPicker or SF-symbol + color (reuse
  intake's pickers) + attribute config (none / enum options / 1–5 scale).
- **Patterns mode** — reuse `CompletionPatternsSection` heatmap + the Symptoms
  rhythm wheel: time-of-day histogram + frequency trend. **No goal/target** — a
  read-only trend is the ceiling.
- **Tile** — occurrence count + the consistency heatmap in the kind's color
  (occurrence ramp: 0=empty, then frequency quartiles), same vocabulary as every
  other tile.
- Quick-add, time travel (`DayClock.today`/`now` — never `Date()`), import/export,
  Next feed (occurrences are **log-only, non-nagging** — no suggestions), watch
  capture row (rides the `WatchSnapshot` blob, likely no CK deploy for the capture
  menu itself).
- **MCP both servers + skill, lockstep** — `markers_kinds_list`,
  `markers_kind_create`, `markers_kind_update`, `markers_event_log`,
  `markers_events_list`, `markers_event_delete` in
  `MCPToolCatalog.section["markers"]` + `MCPDispatch` cases + the hosted gateway.
  Keep the section skill brief in sync (the gateway's `skill.md` is generated from
  `SectionRegistry.fullSkillMarkdown()`).

## Seed suggestions (offered in onboarding)

"Saw something beautiful" 🌅 (none) · "Idea struck" 💡 (none) · "Heard from an old
friend" 📞 (none) · "Strange vibe" (scale 1–5). (Deliberately *not* ear ringing —
that's a Symptom.)

## v1 guardrails

- No goal/target. Read-only trend only.
- One optional attribute per kind, hard-capped.
- No correlation/Coach feeding in v1 (Markers are for noticing, not analysis).
  Intake feeds Coach *as consumption*; keeping Markers out of that is *why* it's a
  sibling section and not "non-consumable intake kinds".

## Promotion path

When a generic Marker earns heavy use, that's the signal to graduate it to a real,
opinionated section (or to relocate it into an existing one). Generic is the
nursery, not the destination; usage tells you what to bless. Inverse of
[pinned goals](PINNED_GOALS_PLAN.md), where a target earns front-door prominence.

## Effort

Medium — it's a full section, but the shape is a strict subset of Intake
(no item layer, no dose/unit/metric machinery, no Coach/correlation feed), so
mostly copy-and-simplify. The genuinely new code is small.
