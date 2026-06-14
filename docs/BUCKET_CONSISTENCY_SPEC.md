# Day-Bucket Consistency Spec

**Status:** audit + proposal (nothing changed yet) · **Date:** 2026-06-14

Goal: make time-of-day **buckets** look and behave the same everywhere they
appear. The data model is already single-sourced; the divergence is entirely in
*presentation* and in a few surfaces that re-derive bucket logic by hand instead
of asking the canonical type.

This started from a concrete observation: in the **Next** feed, supplements and
habits "show slightly differently." They do — and the same class of drift exists
on the watch, the complication, and in several add/edit forms.

---

## 1. The canonical model (the source of truth)

`SeptenaCore/DayBucket.swift`

- **Three cases:** `.morning`, `.afternoon`, `.evening`.
- **Cutoffs** are **user-configurable** (defaults: morning < 12, afternoon < 17,
  evening ≥ 17) via the App Group suite — `DayBucket.cutoffs`.
- **Labels:** `.title` → localized "Morning" / "Afternoon" / "Evening".
- **Icons:** `.icon` → `sunrise` / `sun.max` / `moon.stars`.
- **Persisted value:** `.rawValue` → `"morning"` / `"afternoon"` / `"evening"`.
- **Anytime:** `DayBucket.anytimeKey = "anytime"`, a sentinel that is **not a
  case** and is stored as `nil` on entities.
- **Helpers:** `DayBucket.from(date:)`, `bucket(forHour:)`, `.current`, `.order`,
  `.endHour`.

**Principle:** every surface should read buckets *through* this type — its
cutoffs, its `.title`, its `.icon`, its case set — and never re-implement any of
them.

---

## 2. What's actually consistent (keep as-is)

- **Widget** (`SeptenaWidgets/NextWidgetViews.swift`) — uses
  `bucket.title.uppercased()` + `bucket.icon`. Reference implementation.
- **`DayBucketHeader`** (`Septena/Shell/UI/DayBucketHeader.swift`) — uses
  `.title`, `.icon`, `.current` for the "Now" pill, and reads `.endHour` for the
  countdown. The other reference implementation.
- **Supplement edit form** (`EditSupplementSheet.swift`) — picker is
  `[anytimeKey] + DayBucket.allCases`, labels via `.title`, "Anytime" → `nil`.
  This is the model every bucket picker should follow.
- **`itemsForBucket` filtering** (`SeptenaCore/NextWire.swift`) — shared by
  watch + widget; no hardcoded cutoffs. The bucket subtitle is intentionally
  *stripped* after filtering on those surfaces.

---

## 3. Divergences (the work)

Grouped by class. Severity: **A** = visible inconsistency / breaks on custom
cutoffs or non-English locale; **B** = cosmetic or product-decision needed.

### Class 1 — Label rendered by hand instead of `.title`

Using `rawString.capitalized` (or hardcoded literals) instead of
`DayBucket(rawValue:)?.title`. Breaks localization, and silently mis-renders any
non-canonical value.

| Surface | Location | Severity |
|---|---|---|
| Watch nav title | `SeptenaWatch/NextWatchView.swift:12` (`conn.bucket.capitalized`) | A |
| Watch complication (rect) | `SeptenaWatchComplication/NextComplicationViews.swift:74` | A |
| Watch complication (inline) | `SeptenaWatchComplication/NextComplicationViews.swift:105` | A |
| Habit edit picker | `Septena/Sections/Habits/EditHabitSheet.swift:51` (`b.capitalized`) | A |
| Habit add-page headers | `Septena/Sections/Habits/AddHabitPage.swift:57` (`bucket.capitalized`) | B |
| Medications picker | `Septena/Sections/Medications/MedicationsDestinationView.swift:301-307` (hardcoded literals) | A |

**Fix:** one helper — `DayBucket.label(forKey:)` returning `.title`, or
`"Anytime"` for `anytimeKey`, or a safe fallback — and route every label
through it.

### Class 2 — Cutoffs hardcoded instead of `DayBucket.cutoffs`

Re-deriving the current bucket with literal `12` / `17`. Ignores the user's
configured cutoffs, so these surfaces disagree with the rest of the app whenever
the user has customized them.

| Surface | Location | Severity |
|---|---|---|
| Habits quick-add menu | `Septena/Sections/Habits/HabitsQuickAddMenu.swift:8-15` (`if h < 12 … if h < 17`) | A |
| Habits add page | `Septena/Sections/Habits/AddHabitPage.swift:8-20` (same) | A |
| Day timeline fasting band | `Septena/Shell/Dashboard/DayTimelineView.swift:229` (`eveningHour = 19`) | B* |

\* DayTimelineView's `19` is a **fasting** concept ported from `lib/fasting.ts`,
not strictly a day-bucket cutoff — but it's an independent hardcoded
time-of-day boundary that should eventually be plumbed through settings. Flag,
don't necessarily fold into `DayBucket`.

**Fix:** these should call `DayBucket.from(date:)` / `bucket(forHour:)` instead
of inlining the comparison.

### Class 3 — The bucket **case set** disagrees per surface

Different surfaces expose different sets of buckets, so the same concept offers
different choices depending on where you are.

| Surface | Bucket set offered | Divergence |
|---|---|---|
| Canonical | morning / afternoon / evening (+ anytime sentinel) | — |
| Habits (plugin starters + intent) | morning / anytime / evening | **no afternoon**; **has anytime** even though the section model treats habits as always-bucketed |
| `HabitIntents.HabitBucket` | morning / anytime / evening | hand-rolled enum, can't reach afternoon via Siri |
| Habits edit form | server-provided `[String]` | whatever the server sends; no anytime |
| Supplements | anytime + morning/afternoon/evening | ✅ canonical |
| Medications | anytime + morning/afternoon/evening + **bedtime** | **5th case** `"bedtime"` not in `DayBucket` |

Two real product questions fall out of this (see §5): does **habits** support
"anytime" or not (the code says both), and is **bedtime** a legitimate 4th
bucket or should medications fold into the canonical three?

### Class 4 — Presentation treatment differs within Next

Same feed, different chrome per item type. This is the original "shows slightly
differently."

| Aspect | Habits | Supplements |
|---|---|---|
| Section header | per-bucket: `"\(bucket) Habits"` → "Morning Habits" (`NextItemsSection.swift:1271`) | flat `"Supplements"` (`NextItemsSection.swift:663`) |
| Model `bucket` type | `String` (required) | `String?` (nil = anytime) |
| Linger default | **off** (strict current bucket) | **on** (persist until taken) |
| Unknown-bucket fallthrough | hidden (`return false`, `NextItemsSection.swift` `habitsNow`) | shown (`return true`, `supplementsNow`) |
| Icon in header | yes (via bucket) | yes (section icon) |
| Watch nav title | bucket name | bucket name |

The linger + nil-bucket differences are **legitimate** (supplements genuinely
have an "anytime" concept; habits don't). The **header asymmetry** is the part
that reads as inconsistent and is the cheapest, highest-value fix.

---

## 4. Proposed unified rules

1. **One label path.** Add `DayBucket.label(forKey: String?) -> String`
   (`nil`/`anytimeKey` → "Anytime"; valid case → `.title`; else a safe
   fallback). Every header, picker, nav title, and complication uses it. No more
   `.capitalized` on raw strings, no more hardcoded "Morning"/"Bedtime"
   literals.
2. **One cutoff path.** No surface compares `hour < 12`. Current-bucket
   resolution always goes through `DayBucket.from(date:)` /
   `bucket(forHour:)` so custom cutoffs propagate everywhere.
3. **One icon rule — ✅ RESOLVED (2026-06-14): icons only where glanceable or
   functional, never beside a bucket *word*.** A time-of-day glyph next to the
   literal "Morning" is decoration (and `circle.dashed` for anytime is
   meaningless), so text headers stay title-only — matching the existing
   "section headers are title-only" convention. Bucket icons are kept only on
   the **Next widget** (glanceable, space-constrained) and the **Settings
   cutoff rows** (the glyph pairs with the value it configures). Removed the
   leading glyph from `DayBucketHeader` (the habits/supplements drawer
   accordions); the iOS Next header was already title-only. Watch nav +
   complication stay icon-less by the same rule.
4. **One picker shape.** Every bucket picker is
   `[anytimeKey] + DayBucket.allCases` (anytime first), labels via rule 1 —
   matching the supplement form. Sections that don't support anytime drop the
   first item but keep the order.
5. **One Next header shape.** Decide a single header treatment (see §5) and
   apply it to both habits and supplements.
6. **Typed bucket on the wire where feasible.** `NextComplicationData.bucket`
   and the watch connectivity bucket should resolve to `DayBucket` (or carry the
   key and resolve at the edge) rather than passing bare capitalized strings.

---

## 5. Open product decisions (need a call before coding)

1. **Habits + "anytime":** ✅ **RESOLVED (2026-06-14) — match supplements.**
   Habits get full `[anytime] + morning/afternoon/evening`, same picker/label/
   filter behavior as supplements. Adds real anytime support to habits (model +
   `HabitDayItem.bucket` becomes optional / anytime-aware, like
   `SupplementDayItem`), and Next must treat habit nil-bucket like supplements
   (show all day). Touches habits model, mirror loader, Next filtering, both MCP
   surfaces + skill briefs.
2. **Habits + "afternoon":** ✅ **RESOLVED (2026-06-14) — restore.** Part of
   "match supplements": habits starters, `EditHabitSheet`, and
   `HabitIntents.HabitBucket` all carry the full anytime + 3-bucket set.
3. **Medications "bedtime":** ✅ **RESOLVED (2026-06-14) — fold into "evening".**
   No 4th canonical bucket; keep the set at three for less complexity. Work:
   drop the `"bedtime"` option from the medications dose/definition pickers
   (`MedicationsDestinationView.swift:301-307`), and migrate any existing rows /
   starters with `bucket == "bedtime"` → `"evening"` (idempotent, deterministic).
   Verify no other surface reads `"bedtime"`.
4. **Next header treatment:** ✅ **RESOLVED (2026-06-14) — current-bucket header
   for both.** Both habits and supplements show one "{current bucket} {section}"
   header (matching what habits already did), via the shared
   `bucketSectionHeader`. Not per-bucket *grouping* inside the strip — the Next
   strip is the now-view, so one header reading the current bucket is the
   coherent choice; full per-bucket grouping stays in the section drawers.
5. **Linger defaults:** ✅ **RESOLVED (2026-06-14) — keep, documented.** Habits
   strict / supplements carry-over by default is intentional and now expressed
   through one shared rule (`isDueNow`) plus the countdown-only-when-strict
   header treatment, so the difference reads as deliberate, not a bug.

---

## 6. Suggested sequencing

- **Phase 1 + bedtime fold — ✅ DONE (2026-06-14, iOS+Mac+Watch green, gateway
  typecheck clean).** Added `DayBucket.label(forKey:)` and routed every label
  through it (habit edit/add forms, watch nav title, both complication views,
  medications subtitle); replaced the hardcoded `12`/`17` in
  `HabitsQuickAddMenu` with `DayBucket.current` (`AddHabitPage` already used
  `DayBucket`). Dropped `bedtime` from the medications picker (now
  `DayBucket`-driven), added an idempotent `MedicationsMutator.migrateBedtimeBuckets()`
  (bedtime → evening) run at services start, and fixed the medications `bucket`
  enum in **both** MCP surfaces (in-app catalog `midday`/`bedtime` →
  `afternoon`; gateway description string). Added `DayBucket.swift` to the
  watch-complication target so it gets canonical localized labels.
  - Remaining cleanup (lower priority, Class 1/2 leftovers): `DayTimelineView`'s
    hardcoded fasting `eveningHour = 19` (separate fasting concept — plumb via
    settings later); `WelcomeHeader.TimeBand`'s 8-band hardcoded greeting
    segmentation (independent of buckets, intentionally finer-grained — leave
    unless we want it cutoff-aware).
- **Phase 2 (Next header) — ✅ DONE (2026-06-14, iOS+Mac+Watch green).**
  Replaced the habits-only `habitBucketHeader` with a shared
  `bucketSectionHeader(_:tint:showsCountdown:)` used by **both** habits and
  supplements, so each reads "{current bucket} {section}" ("Morning Habits" /
  "Morning Supplements") via canonical `DayBucket.label`. The "time left in
  bucket" countdown chip now shows only when the section is *strict*
  (`!linger`) — meaningful as a deadline only when the item drops off at the
  cutoff; a lingering section (supplements by default) carries over, so no
  misleading timer.
- **Phase 3 (habits match supplements) — ✅ DONE (2026-06-14, iOS+Mac+Watch
  green, gateway typecheck clean).** Habits are now anytime-aware and offer the
  full bucket set, *without* a model/schema change: `HabitDayItem.bucket` stays
  a `String`, but `"anytime"` is a valid value (`loadHabitsDay` already derives
  bucket groups from stored values, so it groups + renders for free; no CK
  deploy). Specifics:
  - **DRY filter:** new `DayBucket.isDueNow(bucketKey:linger:now:)` is the single
    rule for "is this due now" — anytime → always; bucketed → its window, plus
    later windows when lingering. Both the phone (`habitsNow`/`supplementsNow`)
    and the watch/widget snapshot (`itemsForBucket`) call it, replacing two
    separately-maintained copies. Habits now show anytime items all day (the
    old code dropped them).
  - **Forms:** `EditHabitSheet` mirrors `EditSupplementSheet` — `[anytime] +
    morning/afternoon/evening`, labels via `DayBucket.label`, vestigial
    `buckets` param dropped. New-habit default stays morning (supplements default
    anytime — each keeps the default fitting its nature; both offer the full set).
    `EditSupplementSheet`'s private `bucketLabel` folded into `DayBucket.label`.
  - **Intents / plugin / MCP:** `HabitIntents.HabitBucket` gains `afternoon`
    (full set morning/afternoon/evening/anytime); HabitsPlugin skill briefs +
    starter comment updated; habits `bucket` enum gains `afternoon` in **both**
    MCP surfaces (in-app catalog + gateway).

> MCP note: any change to the bucket *case set* (esp. bedtime, or habits'
> anytime/afternoon) must land in **both** MCP surfaces (in-app
> `SeptenaCore/MCP/` and the hosted gateway) plus the skill briefs, per the
> lockstep rule.
