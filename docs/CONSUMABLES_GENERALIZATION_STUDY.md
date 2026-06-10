# Consumables Generalization Study

Status: study / pre-plan. Owner: MZ. Date: 2026-06-10.

## 1. Why

Two motivations, one structural answer.

**App Review.** The binary today contains "Cannabis" as a section label,
onboarding copy ("vape and edible sessions"), localization entries, App Intents,
quick-add menus, and an MCP skill brief. Apple's guideline 1.4.3 targets apps
that *facilitate sale* of marijuana, which Septena doesn't — but reviewers flag
on keywords, and a wellness app with a first-class cannabis section invites
scrutiny, age-rating questions, and regional removal risk. The goal is not to
hide the feature; it's to stop shipping the *noun*. If the app ships a generic
consumable tracker and the user constructs a tracker they happen to name
"Cannabis", the substance becomes user data, not app content — the same way a
note-taking app isn't a cannabis app because a user writes about cannabis.

**Product.** Cannabis and caffeine are 90% the same code by shape (see §2).
Tea, nicotine, alcohol, mate, kratom, microdosing protocols, prescription
medications — every one of these would today require a new manifest row, plugin,
entity, CloudKit record type, two MCP servers, watch wiring, and a dashboard
tile. A generic consumable framework turns "new substance" from a multi-surface
engineering project into a user action.

## 2. What exists today (verified against code)

Both sections follow the identical pattern; the diff is small and instructive.

| Aspect | Caffeine | Cannabis |
|---|---|---|
| Manifest key | `caffeine`, icon `cup.and.saucer` | `cannabis`, icon `leaf` |
| Event entity | `CaffeineEventEntity` | `CannabisEventEntity` |
| Common fields | `id, occurredAt, date, method, grams?, note?, updatedAt, cloudKitSystemFields` | same |
| Extra fields | `beans: String?` (→ `CaffeineBeanEntity.id`) | `strain: String?` (legacy), `hit: Int?` |
| Method vocabulary | `v60 \| matcha \| aeropress \| espresso \| other` (display map in `CaffeinePlugin.label(for:)`) | `vape \| edible` (`CannabisPlugin.label(for:)`) |
| Catalog | `CaffeineBeanEntity` (`id, name, sortIndex`), starter seeds in onboarding | none locally; gateway-managed `CannabisStrain` CK type (iOS doesn't touch it) |
| Config | `CaffeineConfig { beans, methods? }` | `CannabisConfig { usesPerCapsule }` (default 3) |
| Stateful quick-add | no — static method choice | yes — `CannabisCapsule` (Continue Hit N / New capsule / Edible), state carried to watch via `NextWire.cannabisUsesPerCapsule` / `cannabisLastVapeHit` |
| Flourish | `.bloom`, magnitude scaled by dose (`CaffeineCommit`) | `.ripple`, no magnitude axis |
| Aim metrics | `caffeine.cup_count[,_week]` — counts events | `cannabis.event_count[,_week]` — counts events |
| MCP tools | `caffeine_events_list/event_log/event_delete`, `caffeine_beans_list/bean_create/bean_delete` | `cannabis_events_list/event_log/event_delete` |
| CK record types | `CaffeineEvent` (`caffeine-event:{id}`), `CaffeineBean` | `CannabisEvent` (`cannabis-event:{id}`), plus gateway-only `CannabisStrain` |
| Today log / time travel | yes (`todayCapableKeys`, `timeTravelCapableKeys`) | yes |
| Next feed | suggestion kind in `SuggestionBlocks.all` (read-only nudge, not a completable `NextBlocks` member) | same, but stateful (capsule-aware) |
| HomepageDomain | `case caffeine` | `case cannabis` |
| Intents | `CaffeineIntents.swift` | `CannabisIntents.swift` |

The generalizable core is plain: **a timestamped event with a method drawn from
a per-substance vocabulary, an optional dose (amount and/or count), an optional
reference into a per-substance item catalog, and a note.** Everything else —
flourish choice, capsule statefulness, starter seeds, metric labels — is
per-substance *configuration*, not per-substance *code*.

## 3. The generic model

Three new entities (CloudKit record types are additive, so these coexist with
the legacy types):

```
ConsumableKindEntity            // one user-defined tracker ("Caffeine", "Tea", …)
  id            String          // stable, e.g. "ck-<uuid>"; NOT the display name
  name          String          // user-editable display name
  symbol        String          // SF Symbol, user-picked
  sortIndex     Int
  unit          String?         // "g" | "mg" | "ml" | nil (count-only)
  doseStyle     String          // "amount" | "count" | "both" | "none"
  countNoun     String?         // "hit" | "cup" | "puff" — label for the count axis
  containerCap  Int?            // nil = no container model; N = capsule/pack of N uses
  catalogNoun   String?         // "Beans" | "Strains" | nil = no item catalog
  flourish      String          // "bloom" | "ripple" | … (motion vocabulary)
  metricMode    String          // "countEvents" | "sumAmount"
  templateID    String?         // which built-in template seeded it, if any
  archivedAt    Date?           // hide-don't-delete, mirroring section semantics

ConsumableItemEntity            // generalizes CaffeineBeanEntity
  id, kindID, name, sortIndex, archivedAt?

ConsumableEventEntity           // generalizes both event entities
  id, kindID, occurredAt, date  // date = YYYY-MM-DD local, indexed, as today
  method        String          // value from the kind's method list
  itemID        String?         // → ConsumableItemEntity
  amount        Double?         // in kind.unit
  count         Int?            // hits/uses (capsule math reads this)
  note          String?
  updatedAt, cloudKitSystemFields
```

Methods live on the kind as ordered structured rows (value, label, symbol,
default amount, "uses container" flag). They can be a JSON-encoded column on
`ConsumableKindEntity` — CloudKit additive-schema friendly, and method
vocabularies are small. A separate `ConsumableMethodEntity` is cleaner
relationally but adds a fourth record type and sync ordering concerns for
little gain.

Mapping check — can the generic model express today's data losslessly?

- Caffeine event `method=v60, beans=<id>, grams=18` → `method=v60,
  itemID=<id>, amount=18` with kind `{unit: "g", doseStyle: "amount",
  catalogNoun: "Beans"}`. ✓
- Cannabis vape `method=vape, hit=2` → `method=vape, count=2` with kind
  `{doseStyle: "count", countNoun: "hit", containerCap: 3}`. ✓
- Cannabis edible `method=edible, grams=0.1` → `method=edible, amount=0.1`
  (the "edible doesn't use the container" flag lives on the method row). ✓
- `strain` (legacy, no longer set in-app) → migrate non-nil values into
  `ConsumableItemEntity` rows + `itemID`. ✓

### 3.1 Naming — one noun everywhere

Today's sections keep a tight noun discipline: `caffeine` (key) →
`CaffeineEventEntity` (class) → `CaffeineEvent` (CK record type) →
`caffeine-event:{id}` (recordName) → `caffeine_event_log` (MCP tool) →
`caffeine.cup_count` (metric key) → `caffeineEvent` (export table). The
generic section must keep that discipline — one noun spanning section key,
entity prefix, record types, recordName prefixes, tool prefix, metric prefix,
and export tables — or greps, docs, and the two MCP servers fray.

Two candidates. **`consumable`**: precise, unambiguous, but long and clinical
(`consumable_event_log`, "Consumables" as a tab). **`intake`**: short,
neutral, reads naturally everywhere (`intake_event_log`,
`intake.<kindID>.count`, `intake-event:{id}`, "Intake" as a label); mild
ambiguity with nutrition/hydration "intake" is acceptable since those
sections never use the word in identifiers. **Recommendation: `intake`.**
Concretely: section key `intake`; classes `IntakeKindEntity` /
`IntakeItemEntity` / `IntakeEventEntity`; CK record types `IntakeKind` /
`IntakeItem` / `IntakeEvent`; recordNames `intake-kind:{id}` /
`intake-item:{id}` / `intake-event:{id}` (migration ids
`intake-event:caffeine:<legacyID>` etc.); tools `intake_*`; metrics
`intake.<kindID>.*`. The default display label "Intake" is just
`SectionManifest.defaultLabel` — renamable per user like any section, and
kind names are where the real nouns live anyway.

Two DB rules regardless of noun choice: kind ids are opaque (`ik-<uuid>` or
similar), never derived from user-entered names — names are mutable, ids are
forever (metric keys, item links, and wire payloads all hang off them). And
method *values* stored on events are the stable lowercase tokens from the
method rows, not display labels, mirroring how `v60`/`vape` work today.

> The remainder of this study uses `Consumable*` / `consumable_*` as working
> names; if `intake` is confirmed, the rename is mechanical.

## 4. The aspect catalog — what must be customizable

This is the heart of the study: every axis on which caffeine and cannabis
differ today, restated as user-facing configuration. A kind is "reconstructed"
by choosing values on these axes.

**Identity.** Name, SF Symbol, color. Color already works this way —
`SectionEntity` stores per-key user colors and `SectionTheme` resolves them —
so the precedent exists; kinds need the same treatment at kind granularity.

**Method vocabulary.** An ordered list of (label, symbol, default dose). This
replaces both hardcoded enums and both `label(for:)` switches. The "Manage
types" affordance caffeine already has (`CaffeineTypeSheet`) becomes the
generic method editor. Symbols come from a curated picker, not free-text.

**Dose semantics.** Four styles cover the observed space: amount-only
(caffeine grams), count-only (vape hits), both (edibles with mg), none (pure
event logging). `countNoun` and `unit` make the UI read naturally ("Hit 2",
"18 g"). The aim-metric question "count events or sum dose?" becomes
`metricMode`. One extension earns its place once the design space is examined
(§4.1): an optional per-method *normalized dose factor* (`normUnit` on the
kind, `normPerUnit` on each method/item row) so heterogeneous methods sum
meaningfully — an espresso and a V60 differ in grams of beans but both reduce
to mg of caffeine; beer/wine/spirits reduce to standard drinks. Without it,
cross-method sums are physically meaningless and only event counts are honest.

**Container statefulness.** `CannabisCapsule` is the one piece of real *logic*
that looks substance-specific, but it isn't — "a container holds N uses;
continue or start fresh" describes vape capsules, cigarette packs, pill
blisters, and a bag of coffee equally well. Generalize to `containerCap: Int?`
on the kind plus a per-method "consumes container" flag. `CannabisCapsule`
becomes `ConsumableContainer` with the same three-choice output (Continue
(use N) / New container / non-container methods), and the
`NextWire.cannabisUsesPerCapsule/cannabisLastVapeHit` fields generalize to a
small per-kind array (see §6, watch).

**Item catalog.** Optional, named by `catalogNoun`. Beans, strains, teas,
brands. Generalizes `CaffeineBeanEntity` and absorbs the gateway-only
`CannabisStrain` concept. Starter seeds become template data (see Templates).

**Commit feel.** Flourish motion + whether magnitude scales with dose. Today
this is `LogFlourish(motion: .bloom)` vs `.ripple` declared in code; it
becomes a kind field over the existing motion vocabulary.

**Aim metrics.** Generic per-kind metrics generated at runtime:
`consumable.<kindID>.count` / `.count_week` (and `.sum_amount` when
`metricMode == "sumAmount"`), labels built from the kind's name and
`countNoun`. Goals reference metric keys as strings already, so user-defined
metric keys fit — but key stability matters: keys must embed the kind *id*,
never the name, so renames don't orphan goals. Add one more generic metric:
`consumable.<kindID>.days_since_last`. It costs nothing to compute and it's
the metric that matters for the *reduction/abstinence* posture — half the
plausible kinds (nicotine, alcohol, cannabis itself) are things users track in
order to do less of, where streak-of-zero is the goal shape, not a daily
budget.

**Correlation features.** Both sections contribute lever-role daily series via
`CorrelationFeatures` (caffeine: `caffeine_g`, `caffeine_cups`,
`last_caffeine_hour`; cannabis: `cannabis_sessions`, `cannabis_g`). All three
shapes generalize per kind: event count, summed amount, and last-intake hour —
the latter is the interesting one (timing vs. sleep). New substances then
automatically join sleep/mood correlation discovery.

**Notifications.** Neither section declares nudges today; the generic section
can defer this. The plugin protocol slot (`notificationDescriptors`) stays
empty for v1.

**Templates.** The reconstruction story needs a starting point. Ship a small
set of *innocuous* built-in templates — Caffeine (the full current config:
methods v60/matcha/aeropress/espresso/other, bean catalog with current starter
seeds, grams, bloom), Tea, and a blank Custom. Deliberately do NOT ship
cannabis, alcohol, or nicotine templates — that would put the nouns back in
the binary. The custom-kind editor must therefore be good enough that
rebuilding cannabis takes under a minute: name + leaf symbol + two methods
(one with container semantics, one with amount) + container cap. Consider a
template *import* path (JSON paste / file) so configs can be shared without
being shipped; an MCP tool (`consumable_kind_create`) gives the chat agent the
same power — "set me up a cannabis tracker like I had" becomes one tool call
by the user's own agent operating on user data.

**Today log, time travel, import/export.** All three derive mechanically:
`todayCapableKeys`/`timeTravelCapableKeys` gain the host section's key once;
the export contribution emits three generic tables (`consumableKind`,
`consumableItem`, `consumableEvent`) whose schema text is generated from live
kinds so the LLM-prompt generator stays accurate.

### 4.1 Expressiveness check — the consumable design space

The test of the aspect catalog: configure plausible kinds on paper and see
where the model strains. Cleanly expressible, with their configs:

| Kind | Methods | Dose style | Container | Catalog | Norm. dose |
|---|---|---|---|---|---|
| Caffeine | v60, matcha, espresso, … | amount (g) | — | Beans | mg caffeine |
| Tea | green, black, oolong, herbal | amount (g) or none | — | Teas | mg caffeine (0 for herbal) |
| Cannabis | vape (container), edible | count + amount | cap N | Strains | mg THC (optional) |
| Nicotine | cigarette, vape, gum, pouch | count | pack of 20 | Brands | mg nicotine |
| Alcohol | beer, wine, spirits, cocktail | amount (ml) | — | Bottles/labels | standard drinks |
| Energy drinks / mate / soda | per-brand methods | count | — | Brands | mg caffeine |
| Kratom / nootropics | toss-wash, capsule, tea | amount (g) | blister of N | Strains/compounds | — |
| Microdosing | sublingual, capsule | amount (µg/mg) | — | Batches | — |
| CBD / oils | tincture, capsule, topical | amount (mg) | — | Products | mg CBD |
| Sugar / sweets ("vice" logging) | chocolate, dessert, soda | count | — | optional | g sugar |

Notable: the container model covers cigarette packs and pill blisters as
naturally as vape capsules, and the catalog covers brands/batches/labels as
naturally as beans — neither needed new mechanism. The two additions the
exercise forced are already folded into §4: the normalized dose factor and the
`days_since_last` metric.

Where the model deliberately *stops* — these strain points define the
section's boundary rather than demand more schema:

- **Scheduled/protocol consumption** (prescription meds, microdose day-on/
  day-off protocols). Scheduling, reminders, and adherence are the
  Supplements/Habits shape, not the intake shape. Boundary rule: if the
  primary question is "did I take what I was supposed to?", it's a
  supplement; if it's "what did I happen to consume?", it's a consumable. A
  kind can log med *events* fine; it just doesn't nag.
- **Rich-payload consumption** (food → macros, water → volume goals against
  daily targets). Nutrition and hydration stay separate sections; §9 already
  notes the kind schema shouldn't preclude a future fold-in.
- **Pharmacokinetics** ("caffeine currently in system" decay curves). Would
  need `halfLifeMinutes` on the kind plus a live-computed series. Genuinely
  attractive (pairs with `last_intake_hour` correlation) but not required for
  parity — listed as future work, enabled by the normalized-dose factor.
- **Inventory** (grams left in the bag, bottles in the cellar). Stock
  tracking is the Groceries shape; the container model is per-session state,
  not stock. Out of scope.
- **Multi-ingredient events** (a cocktail is alcohol + sugar; pre-workout is
  caffeine + half a dozen compounds). One event belongs to one kind; users
  who care log two events or lean on the normalized-dose factor of the
  dominant ingredient. Compound events would force a many-to-many model the
  rest of the app has no precedent for.

The pattern across the table: *stimulants and substances consumed in
discrete, self-initiated sessions* fit perfectly; *scheduled regimens,
composite meals, and stock management* belong to neighboring sections. That's
a coherent product boundary, not an accident of schema.

### 4.2 Creating and customizing kinds — the UX

The aspect catalog is only as good as the flow that sets it. Four moments:

**First enable (host-section onboarding).** Standard `SectionPlugin.onboarding`
sheet, following the existing two patterns combined: a `SectionExplainerView`-
style intro ("Track anything you consume — each tracker gets its own methods,
doses, and history") above a multi-select template picker (Caffeine, Tea —
exactly the §4 template set), mirroring `CaffeineOnboardingView`'s starter
rows. Selecting templates creates those kinds; "Skip" creates none and lands
on the empty state. Additive-only invariant holds: re-running shows existing
kinds as "Already added".

**Creating a kind — and the second, and the fifth.** Entry points: the
destination's empty state ("Create a tracker"), the kind switcher's last row
("New tracker…"), and the `consumable_kind_create` MCP tool. Creation is a
short wizard over the §4 axes, phrased as plain questions, not schema:

1. *Identity* — name, symbol (curated picker), color.
2. *Measurement* — "How do you measure it?" → amount (pick unit) / count
   (name the unit: "hits", "cups") / both / just log it. Optional: "comes in
   containers with limited uses?" → cap N.
3. *Methods* — at least one row (label + symbol + optional default dose);
   prefilled with a single "Default" row so this step is skippable.
4. *Varieties* — "Track named varieties?" → catalog noun + optional first
   items.

The 15-second path matters more than the full path: name + symbol → Create
must work (one default method, doseStyle "none"), with every axis editable
later. Templates are just pre-filled wizards — "Custom" starts blank. This is
also the cannabis reconstruction story from §7: two methods, one with
container semantics, under a minute.

**Customizing a kind that exists.** Editing lives on the kind's own page —
the generalization of caffeine's "Manage types" (`CaffeineTypeSheet`): a
Manage sheet with methods (reorder/add/edit), varieties, and kind settings
(measurement, container cap, flourish, metric mode, color, archive). The
Settings detail pane stays read-only catalog display, exactly the existing
caffeine-beans-in-Settings convention — editing happens at the destination.

**Editing with history present — the safety rules.** Renames of kinds,
methods, and items are always free (ids and stored tokens are stable; only
labels change). Methods archive rather than delete; an event whose method row
is archived falls back to `token.capitalized`, which is literally today's
`default:` case in both `label(for:)` helpers. Changing `unit` never rewrites
stored amounts — the UI warns that history will read in the new unit
(rewriting would corrupt; refusing to change would trap typos). Changing
`containerCap` affects only future quick-add suggestions. Widening
`doseStyle` (count → both) is free; narrowing hides the field going forward
but keeps stored values. Deleting a kind follows section semantics: archive
(hide surfaces, keep data), with true delete only via the existing
export-then-purge path.

**Multiples ergonomics.** Kinds carry `sortIndex` (user-ordered, like beans).
With one kind, the drawer's "+" shows that kind's methods flat — today's
caffeine feel exactly; with several, "+" nests kind → methods, and the
container-aware "Continue (use N)" rows bubble to the top as `SuggestionBlocks`
does now. Each kind gets a dashboard-tile toggle (default on, Option C renders
tile-per-kind) so a six-kind power user doesn't drown the homepage.

## 5. Architecture options

The framework constraint: section identity is compile-time. `SectionManifest.all`
is a static array; `HomepageDomain` is an enum; `MCPDispatch` is a switch;
watch and widgets are hand-wired per section. Three options:

**A. One host section, kinds inside ("Consumables" / suggested key: `intake`).**
One manifest row, one plugin, one `HomepageDomain` case, one destination that
renders per-kind pages. This is exactly the proven Habits/Supplements pattern —
fixed section, user-defined rows — extended one level (user-defined rows that
each have their own sub-config and event stream). Cheapest; zero framework
surgery. Cost: kinds don't get their own top-level tabs/tiles; the dashboard
tile aggregates or shows per-kind chips.

**B. Dynamic section instances.** Each kind becomes a real section
(`consumable:<id>` keys) with its own tile, tab, color, drawer. Honest but
expensive: manifest becomes partially data-driven, `HomepageDomain` needs a
parameterized case, settings/section-reorder/onboarding all need to handle
synthetic keys, and the watch/widget hand-wiring breaks the "compiled-in
membership" guarantees (`NextBlocks`-style single-source tables assume static
keys). Estimated multi-month; touches every invariant in CLAUDE.md.

**C. Hybrid (recommended).** Host section as in A for identity, settings,
registry, and MCP — but the *dashboard* renders one tile per kind (a tile loop
under the single `HomepageDomain.intake` case, mirroring how
`WeekDashboardView` already iterates data within a tile), and the section
destination is a kind switcher with per-kind time travel. Users get the feel
of per-substance sections; the framework keeps its static spine. Per-kind
colors ride on a kind field rather than `SectionEntity` (one section = one
SectionEntity row stays true).

Decision drivers: if the long-term vision is "users compose arbitrary
sections", B is the destination and C is a way-station that doesn't preclude
it (kind IDs can later be promoted to section keys). If consumables are the
only domain that needs this, C is the end state.

## 6. Surface-by-surface audit (Option C)

Per `docs/ADDING_A_SECTION.md`, plus the generalization-specific work:

- **Manifest** — one new row (`intake`), neutral copy ("Track what you
  consume — coffee, tea, anything"). Add to `todayCapableKeys` +
  `timeTravelCapableKeys`. Retire `caffeine`/`cannabis` rows only at the end
  (phase 4), since manifest keys anchor migration.
- **Plugin** — `IntakePlugin` implementing the full `SectionPlugin` surface
  generically: `logActions` built from enabled kinds (kind → submenu of
  methods, container-aware), `detailPaneContent` listing kinds, export
  contribution per §4, `aimMetrics`/`evaluateAim` generated from kinds,
  `mcpSkill` describing the generic tools.
- **Mutator** — `ConsumableMutator` as the single write boundary (CLAUDE.md
  invariant): kind/item/event CRUD, optimistic local write, CK enqueue,
  notifications. Absorbs `CaffeineMutator`'s `addBean` shape.
- **Destination** — generic kind page: stat strip, day list, method quick-add,
  item catalog editor, method editor, kind settings. Build once, parameterized
  by kind; `SectionDrawer`-wrapped with `viewingDate` threading.
- **Quick add / Next suggestions** — `SuggestionBlocks` rows become data-driven
  for this section: one suggestion block per kind, `input: .choice` built from
  the kind's methods, container-aware via the generalized `ConsumableContainer`.
  `NextWire` gains a compact per-kind state list (replacing the two cannabis
  fields, which stay temporarily for old watch builds — wire structs are
  versioned by tolerance, keep fields additive).
- **Watch** — the watch is hand-wired; v1 ships phone-side first. Watch picks
  up generic kinds in a follow-up by rendering `SuggestionBlocks` rows it
  receives over `NextWire` instead of compiled-in ones. Old cannabis wiring
  keeps working through migration because the wire fields remain.
- **MCP — both servers, one change.** New generic tools:
  `consumable_kinds_list`, `consumable_kind_create/update`,
  `consumable_items_list/item_create/item_delete`,
  `consumable_events_list/event_log/event_delete` — every event tool takes
  `kind` (id or unique name). Land in `MCPToolCatalog` + `MCPDispatch` and the
  gateway worker in the same change (lockstep rule), regenerate the gateway
  `skill.md` from `SectionRegistry.fullSkillMarkdown()`. The generated skill
  text teaches the agent to resolve kinds first (`consumable_kinds_list()` →
  log against the match) — the substance nouns appear only in the *user's*
  kind names at runtime, never in shipped skill text. Keep `caffeine_*` /
  `cannabis_*` tools as deprecated aliases during migration (gateway can keep
  them longer; it's outside App Review), then drop from the iOS binary.
- **Intents / Siri** — replace `CaffeineIntents`/`CannabisIntents` with a
  generic `LogConsumableIntent` whose kind/method parameters are dynamic
  `AppEntity` queries over user kinds. Spoken phrases then come from user
  data, not compiled strings.
- **Goals** — metric keys `consumable.<kindID>.*`; one-time remap of existing
  goals referencing `caffeine.cup_count*` / `cannabis.event_count*` during
  migration.
- **Correlations** — generic per-kind lever series in `CorrelationFeatures`.
- **CloudKit** — add 3 record types (additive, safe). `docs/CloudKitSchema.md`
  gains their field tables. Old types remain in schema forever (additive-only)
  but stop being written; that's fine — schema record-type names are not
  App-Review-visible, only binary strings are.
- **Hygiene sweep** — `Localizable.xcstrings`, `DemoSeed`, `ScreenshotTests`,
  `Plausible` event names, `SectionExplainer` copy, `docs/` examples: purge
  cannabis strings from anything compiled into or shipped with the binary.
  Grep gate in CI: the iOS target must not contain the substring `cannabis`
  (case-insensitive) after phase 3.

## 7. Migration plan — caffeine as the proving ground

Caffeine-first is right: it's the richer section (catalog + methods + settings
+ onboarding), it's not review-sensitive (no pressure while iterating), and if
the generic shape can absorb caffeine without losing the bean catalog,
capsule-less quick-add, and dose-scaled flourish, cannabis is a strict subset
plus the container model.

**Phase 1 — foundations (no user-visible change).** Entities + CK record
types + `ConsumableMutator` + `ConsumableContainer` (generalized capsule
math, unit-tested against `CannabisCapsule`'s behavior). Dev-schema deploy,
then Prod (additive).

**Phase 2 — caffeine migrates.** Seed a `ConsumableKindEntity` from the
Caffeine template; copy `CaffeineBeanEntity` → items, `CaffeineEventEntity` →
events (local rewrite + enqueue CK inserts; precedent: the idempotent
`occurredAt` repair pass in `SeptenaCore/CloudKit/Migration.swift`, which
already touches both entities). One-way cutover flag in settings so
old records become read-only history; **old-version skew** is the sharp edge —
an old build on a second device will keep writing `CaffeineEvent` records, so
the migrator must re-run idempotently (migrate-on-sight keyed by legacy id
embedded in the new event id, e.g. `consumable-event:caffeine:<legacyID>`).
Caffeine UI switches to the generic destination behind the host section while
the `caffeine` manifest key still points at it (label and color preserved).
Goals remapped. MCP aliases in place.

**Phase 3 — cannabis reconstructs.** Same data migration (strain → items,
hit → count, capsule config → `containerCap`). Because no cannabis template
ships, migration synthesizes the kind *from the user's existing data* — name
from the old section's user label, methods from observed `method` values,
container cap from `CannabisConfig.usesPerCapsule`. For an existing user the
result is indistinguishable from today; a fresh user builds it via the custom
editor or asks their agent to. Then the hygiene sweep (§6) removes the noun
from the binary.

**Phase 4 — retire legacy.** Remove `caffeine`/`cannabis` manifest rows,
plugins, entities (local mirror classes stay one release for the migrator,
then go), intents, MCP tools from the iOS binary. Gateway keeps aliases as
long as desired. CK types remain dormant per additive-only.

Each phase is independently shippable; phase 2 alone is a worthwhile
refactor even if phase 3 never ships.

### 7.1 Data migration mechanics

**Field maps.** Lossless by construction (§3 showed the inverse direction);
the migrator is a dumb copy plus three renames:

| Legacy | → Generic |
|---|---|
| `CaffeineEventEntity.{id, occurredAt, date, note, updatedAt}` | same fields, `kindID = <caffeine kind>` |
| `.method` | `.method` (vocabulary copied verbatim into the kind's method rows) |
| `.beans` (bean id) | `.itemID` (item id derived from bean id, below) |
| `.grams` | `.amount` (kind unit "g") |
| `CaffeineBeanEntity.{id, name, sortIndex}` | `ConsumableItemEntity`, `kindID` set |
| `CannabisEventEntity.{id, occurredAt, date, method, note, updatedAt}` | same, `kindID = <cannabis kind>` |
| `.hit` | `.count` |
| `.grams` | `.amount` |
| `.strain` | `.itemID` — distinct non-nil strain strings become items first, then events link |
| `CaffeineConfig.methods` | method rows on the kind |
| `CannabisConfig.usesPerCapsule` | `kind.containerCap` |

Run the existing `Migration.swift` `occurredAt` repair *before* migrating, so
`.distantPast` placeholder rows are healed once, in the old format, by code
that already knows how.

**Deterministic IDs are the whole trick.** Every migrated record's id is a
pure function of its source: `consumable-event:caffeine:<legacyID>`,
`consumable-item:caffeine:<beanID>`, `consumable-item:cannabis:<slug(strain)>`,
and fixed ids for the two migration-created kinds. Consequences, in order of
importance: (1) *idempotence* — re-running is an upsert, never a duplicate;
(2) *multi-device convergence* — two devices migrating independently produce
byte-identical record names, so CloudKit's last-writer-wins makes concurrent
migration safe with no coordination, no "which device migrates" election;
(3) *late-arrival safety* — a legacy record that syncs in months later
migrates on sight to the same id it would have gotten on day one.

**Migrate-on-sight pipeline.** The migrator is not a one-shot pass but a
standing rule, active from cutover until the legacy entities are deleted from
the codebase: any legacy record observed — at migration kickoff (full local
scan), or arriving later via `CKSyncEngine` from an old build on another
device — is upserted into its generic twin. Updates propagate by `updatedAt`
comparison (legacy newer than generic twin → re-copy fields; otherwise
ignore, the generic side has been edited and wins). Legacy *deletions* from
old builds do not propagate — acceptable: the skew window is short, and the
failure mode is a resurrected log entry, not data loss. All writes go through
`ConsumableMutator` (the write-boundary invariant holds for migrators too).

**Disposition of legacy records: keep, don't delete.** Stop writing them,
leave them in CloudKit and the local mirror until phase 4. This follows the
app's own "hiding must never delete user data" instinct, keeps a trivial
rollback path (flip the cutover flag back; nothing was destroyed), and avoids
a mass-delete sync storm. Export switches to the generic tables at cutover so
the legacy rows stop being user-visible. At phase 4 the local entity classes
go; the dormant CK records cost nothing (additive-only schema keeps the types
anyway).

**Cutover flag.** Per-section (`caffeine`, later `cannabis`), stored in
synced settings so every *new-build* device knows logging goes to generic;
old builds ignore it and keep writing legacy, which migrate-on-sight absorbs.
Quick-add, suggestions, intents, and MCP write-tools all check the flag —
reads can dual-source during the transition (union legacy + generic by id
prefix) but the simpler posture is: migrate first, then flip, then read only
generic.

**Satellite state, same change:** goals (`caffeine.cup_count*` →
`consumable.<kindID>.count*` key rewrite), `ResponseCache` settings blobs
(`settings.cannabis` → kind config), and `NextWire` — keep emitting
`cannabisUsesPerCapsule`/`cannabisLastVapeHit` from generic data so old watch
builds keep their capsule-aware quick-add until the watch generalizes.

**Verification.** Post-migration, assert per kind: legacy row count == twin
count; per-day counts match for the trailing 90 days; every `beans`/`strain`
reference resolved to an item; sum of `grams` == sum of `amount`. Surface as
a debug-build report before the cutover flag flips, and keep the check
runnable (it doubles as the migrate-on-sight health monitor during skew).

## 8. App Review posture (summary)

After phase 3 the binary contains: a generic intake tracker, caffeine/tea
templates, a symbol picker that includes `leaf` among hundreds, and no
substance nouns beyond coffee/tea. User-created kind names are user data,
same review status as note contents. Screenshots/metadata never show a
cannabis tracker. The MCP gateway (not reviewed by Apple) and the user's own
chat agent carry the convenience layer. Residual considerations: the App
Store age rating stays as-is (nothing in-binary changed category); demo seeds
and marketing materials must use the templates only. This is risk
*reduction*, not a guarantee — note in the release checklist that 1.4.3
interpretations shift, so keep the posture conservative. (Not legal advice;
worth a scan of current guidelines at submission time.)

## 9. Open questions

1. Naming: §3.1 recommends `intake` as the single noun — confirm, then the
   remaining question is only manifest copy tone (the description sets the
   review posture).
2. Does the dashboard get one aggregate tile or one tile per kind (Option C
   leans per-kind; cap at enabled kinds ≤ N)?
3. Should nutrition/hydration/gut eventually fold into the same model? Out of
   scope, but the kind schema shouldn't preclude it (they're consumable events
   with richer payloads).
4. Template import format — JSON paste vs. file vs. MCP-only. MCP-only is
   zero new UI and fits the agent-first posture.
5. Per-kind colors: extend `SectionTheme` keyed by `intake.<kindID>`, or a
   color field on the kind entity? (Leaning kind entity — theme stays
   section-keyed.)
6. What happens to the gateway-managed `CannabisStrain` records — migrate into
   `ConsumableItem` via a gateway job, or leave dormant?

## 10. Decision summary

Generalize via Option C: one `intake` host section, user-defined
`ConsumableKindEntity` rows configured along the aspect axes in §4 (identity,
methods, dose semantics, container statefulness, item catalog, commit feel,
metrics). Prove the shape by migrating caffeine first (phases 1–2); cannabis
then reconstructs from its own data with zero shipped nouns (phase 3); retire
legacy code (phase 4). The one genuinely novel mechanism to build is the
generalized container model and data-driven quick-add/wire plumbing — all
other surfaces follow existing Habits/Supplements precedent.
