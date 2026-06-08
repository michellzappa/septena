# Localization Plan — Septena (FR / DE / ES …)

**Status:** Phase 0 in progress · **Scope (v1):** French, German, Spanish · iPhone + Mac first (Watch/Widgets deferred) · **Created:** 2026-06-04

This plan takes Septena from *zero* UI localization to a regen-safe, multi-language foundation, then through extraction, formatting, translation, and store metadata. It is grounded in an audit of the actual codebase — see "Current state" before trusting any generic localization advice.

---

## Current state (audited)

- **No UI localization infrastructure.** No `.xcstrings`, `.strings`, or `.lproj` anywhere. The project is en-only today: `developmentRegion = en`, `knownRegions = (Base, en)`.
- **App Intents are already localized** — Siri/Shortcuts intents use `LocalizedStringResource` throughout `Septena/App/Intents/`. That surface is half-done.
- **Scale:** ~242 Swift files, ~67k lines, ~900 hardcoded user-facing literals across 6 targets (iOS, Mac, Watch, Watch Complication, Live Activity, Widgets) + shared `SeptenaCore`.
- **Modern tooling is available.** Deployment target iOS/macOS/watchOS **26**, Xcode 26 → **String Catalogs (`.xcstrings`)** are the right tool. **SwiftUI auto-localizes `Text("…")` / `Label` / `Button` literals for free** once a catalog exists, so the mechanical lift is far smaller than the 900 count suggests.
- **`project.yml` + xcodegen is the source of truth.** The `.xcodeproj` is generated; any localization config added via the Xcode UI is wiped on the next `xcodegen generate`. This is the #1 gotcha (see below).
- **One real input-locale nuance**, not a 5-alarm bug: `Septena/Sections/Caffeine/EditCaffeineEntrySheet.swift:196` does `","→"."` before `Double()`. It actually *works* for simple comma-decimal input (`"3,5"` → `3.5`); it only fails on grouping separators nobody types for coffee grams. The surrounding `yyyy-MM-dd` / `HH:mm` formatters are **storage** I/O and should stay fixed-format.

### The xcodegen ↔ String Catalog mechanism (verified)

- xcodegen has **no `knownRegions` setting** and **no String Catalog awareness**. Its only localization lever is `options.developmentLanguage`; `knownRegions` is *derived* from `.lproj` folders, which String Catalogs don't use.
- Therefore the regen-safe way to declare supported languages is **`CFBundleLocalizations`** in each target's Info.plist — which xcodegen fully supports via `info.properties`. The catalog still compiles all its languages into the bundle at build time regardless of `knownRegions`.

> Source: [XcodeGen ProjectSpec](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md), [String Catalogs FAQ](https://www.fline.dev/the-missing-string-catalogs-faq-for-xcode-15/).

---

## Decisions to lock first

1. **User-content vs. app-chrome boundary (most important).** Never translate user-entered or user-renamable content: task/project/area names, supplement names, the 36 mood-emotion words, section titles if user-renamed (`sections_update` exists). These get `Text(verbatim:)` so they're excluded from the catalog. *Default: app chrome + fixed catalog vocabulary localized; anything user-entered/renamable is verbatim.*
2. **Default seed content** (`SeptenaCore/DemoSeed.swift`, default sections/supplements). *Default: localize visible default section titles only; leave deeper seed data English for v1.*
3. **Measurement system is a separate axis from language.** "mg / g / kg / ml / kcal" are SI — identical in FR/DE/ES, so **not** translation work. The real items are the decimal separator and whether to wire the latent, unused `AppUnits { weight, distance }` (`SeptenaCore/Models.swift:1410`) for metric↔imperial. *Default: fix the separator now; defer imperial to its own project.*
4. **Locales & surfaces.** FR/DE/ES; iPhone + Mac in v1, Watch/Widgets second.
5. **Translation method.** *Default: machine-first (Apple/DeepL/Claude) into the catalog, then native-speaker review.*

---

## Phased overview

- **Phase 0 — Foundations** *(this phase)*: regen-safe infra + conventions + one screen translated end-to-end. De-risks everything else.
- **Phase 1 — Extraction & refactor**: catalog auto-extraction; mark verbatim; convert plurals; localize enum/computed strings; restructure interpolations with translator comments. *(1b: Watch + Widgets catalogs.)*
- **Phase 2 — Dynamic & formatting**: locale-aware number/date display sweep; AI greeting locale prompt + localized fallbacks; localize notifications at fire time.
- **Phase 3 — Translate & QA**: glossary/don't-translate list → machine pass → native review → per-locale device QA (truncation, grammar).
- **Phase 4 — App Store metadata** *(parallel track)*: localized name/subtitle/keywords/description, "What's New", screenshots per locale.

---

## Phase 0 — Foundations (detailed)

**Goal:** infrastructure that **survives `xcodegen generate`**, with one screen fully translated in fr/de/es and pseudoloc-clean. Nothing else touched.

**Definition of done:** launching with `-AppleLanguages (de)` renders the pilot screen in real German, German text doesn't clip, and re-running `xcodegen generate` undoes none of it.

### Task 1 — xcodegen integration + empirical spike *(linchpin; do first, alone)*
1. Branch `localization-phase0`.
2. In `project.yml`: add `options.developmentLanguage: en`; add `CFBundleLocalizations: [en, fr, de, es]` to `targets.Septena.info.properties` **and** `targets.SeptenaMac.info.properties`.
3. Create `Septena/Localizable.xcstrings` (en source; fr/de/es). Seed it with a handful of **existing** UI literals + translations so SwiftUI auto-resolves them (no Swift edits needed).
4. `xcodegen generate` → inspect `project.pbxproj` (`knownRegions`?) and generated `Septena/Info.plist` (`CFBundleLocalizations`?). Build; confirm `fr.lproj/de.lproj/es.lproj` land in the built `.app` and contain the translations.
5. **Record the verdict** (see "Spike results" below): does `CFBundleLocalizations` alone make iOS+Mac offer the languages, or is a knownRegions workaround needed?

### Task 2 — Multi-target string convention
- **iOS + Mac share one catalog** at `Septena/Localizable.xcstrings` (both targets compile `Septena/` + `SeptenaCore/`).
- **Shared `SeptenaCore` strings resolve via `Bundle.main`** → land in whichever app bundle runs. ✅ iOS/Mac automatically. **Full `SeptenaCore`** compiles into iOS + Mac only; Watch/Widgets/LiveActivity/Complication pull just a few files — flag any user-facing copy there for their own catalogs (Phase 1b).

### Task 3 — Formatting foundation *(establish pattern + 1 reference fix; do NOT sweep)*
- Rule: **display → `.formatted()` (locale-aware); storage → keep fixed `yyyy-MM-dd` / `HH:mm`.**
- Add a locale-aware input-parse helper; replace the Caffeine `","→"."` hack as the reference implementation.
- Note for the sweep: `String(format: "%.1f", x)` is **not** locale-aware (always emits `.`) → switch display sites to `x.formatted(.number…)` in Phase 2.
- Convert one display formatter (`"MMM d"` / `"EEEE"` in Sleep or Body) to `.formatted(.dateTime…)` as the reference; defer the rest.

### Task 4 — Pilot one screen end-to-end
Recommend **Settings**: pure chrome, zero user-data-boundary risk, no formatting entanglement, long enough to surface German truncation. Extract literals → mark any user content `verbatim` → machine-translate fr/de/es.

### Task 5 — Pseudolocalization + font check
- Scheme/launch arg running an **accented, double-length** pseudolanguage; eyeball the pilot for clipping (German ≈ +30%).
- Verify **Fraunces** carries ß and accented caps (É, Ü, Ñ).

### Task 6 — Gate + commit
Re-run `xcodegen generate`, confirm no regression, commit `project.yml` + regenerated `project.pbxproj` + catalog **together** (one unit).

### Spike results (Task 1 — 2026-06-04, xcodegen 2.45.3)

Setup: branch `localization-phase0`; added `options.developmentLanguage: en` + `CFBundleLocalizations: [en, fr, de, es]` to the Septena + SeptenaMac `info.properties`; created `Septena/Localizable.xcstrings` (3 test keys, fr/de/es); `xcodegen generate`.

Findings:
- **xcodegen is idempotent on `project.pbxproj`** — a no-op regenerate produced zero pbxproj drift (only an unrelated `SeptenaWatch.xcscheme` reformatted by 12 lines — pre-existing version noise, not localization).
- **`knownRegions` auto-populates from the catalog.** After regenerate: `(Base, de, en, es, fr)`. xcodegen 2.45.3 reads `.xcstrings` languages directly — **correcting the earlier assumption** that it would stay `(Base, en)` and require a workaround. `CFBundleLocalizations` is therefore *belt-and-suspenders* (explicit/authoritative), not strictly required — keep it anyway so languages are declared even if the catalog is ever emptied.
- **One catalog serves iPhone + Mac.** The single `Septena/Localizable.xcstrings` is wired as `text.json.xcstrings` into the Resources phase of **both** the Septena (iOS) and SeptenaMac targets — no duplication. Convention validated.
- **`CFBundleLocalizations [en, fr, de, es]`** present in both generated `Septena/Info.plist` and `Septena/Info-Mac.plist`; `developmentRegion = en`.
- **All regen-safe** — every change lives in `project.yml`; nothing in the Xcode UI.
- **Build confirmed** (iOS sim, exit 0): the `.app` contains `de.lproj / es.lproj / fr.lproj`, each with the compiled translations (e.g. fr `Settings` → `Réglages`), and the bundle `Info.plist` carries `CFBundleLocalizations [en, fr, de, es]`. Full pipeline (project.yml → xcodegen → xcstringstool → bundle) works end-to-end.

Net: the linchpin risk (xcodegen wiping localization config) is **retired**. The recommended setup is simply: catalog under `Septena/` + `CFBundleLocalizations` in `project.yml`.

---

## Groundwork log (Phase 1 prep)

**Extraction (build-time, auto):** the iOS target populated `Septena/Localizable.xcstrings` to ~344 keys. Composition: ~246 real phrases (158 short chrome + 88 long sentences — the bulk of the translation work), 73 with format args, 6 plural hacks, 37 non-linguistic.

**Triage — DONE:** 37 non-linguistic keys marked `shouldTranslate:false` (symbols `· • ×`, SI units `kg/ml`, stat codes `n=%@`/`%@C`/`30d`, axis labels `x̄ = …`). Surgical edit — Xcode formatting preserved, JSON valid, key set unchanged. They now skip every translation pass.
- Judgment calls flagged for later: `of %@` is a **sentence fragment** (real fix = kill the source string-concatenation, not don't-translate); `PR` and `→ %@ %@ in 7d` left English as compact stat lines.

**Remaining groundwork before any translation starts:**
1. **Plurals** — convert the 6 `count == 1 ? "" : "s"` hacks to catalog plural variations. Needs a *source* change: pass the count as a number (`%lld`), not a pre-formatted string, so Xcode can key plural rules on it.
2. **Non-auto strings (biggest gap)** — computed `String` (enum `displayName`s, view-model strings, greeting fallbacks) don't auto-extract. Audit + wrap chrome in `String(localized:)` so it lands in the catalog.
3. **Comments** — add translator context to the 73 format strings, ideally via `Text("…", comment:)` at source (durable across re-extraction).
4. **Formatting** — locale-aware number parse (replace the Caffeine `,`→`.` hack) + convert display date formatters to `.formatted()` (Phase 0 Task 3).
5. **Pick the translation mechanism** — in-catalog editor vs. export `.xcloc`/`.xliff` to a service / DeepL / Claude.

### Audit results — the non-auto-extracted gap

Four parallel read-only sweeps. The ~307 real catalog strings are a **floor**. Beyond them:

**Chrome to wrap (mechanical → `LocalizedStringResource` / `String(localized:)`): ~180**, across ~30 files:
- settings/welcome/add-menu/layout enums ~58 · Models/DayBucket/Recurrence/Muscle/`friendlyLabel` ~28 · Discovery mini-apps (Values/Ikigai/Virtue) ~30 · CorrelationEngine strength + markdown report ~15 · error enums (Withings/Migration/Gateway/Import) ~20 · notifications ~12 (fire-time) · Widgets/Watch/LiveActivity ~20
- **Key move:** change computed chrome props from `-> String` to `-> LocalizedStringResource`. That both extracts them AND makes existing `Text(x.label)` call sites localize — so the "372 bypass sites" mostly fix themselves at the source.

**Vocabulary / data — product decision: ~350 (most deferrable)**
- Mood 4 quadrant + 4 blurb + 36 emotion words = 44 · Section names 16 + descriptions 16 · Macros 13 · Exercise library ~200 · Demo seed ~60 (DEBUG/screenshot only → exclude)

**Bypass call sites:** 372 `Text(stringVar)`, but the 8 `Text(verbatim:)` are all correct and most show USER DATA (correctly unlocalized). Actionable subset = the chrome enums above.

**Targets with NO catalog yet:** SeptenaWidgets, SeptenaWatch (+Complication), SeptenaLiveActivitiesExtension (Phase 1b). SeptenaCore needs none — its `String(localized:)` extracts into the iOS/Mac app catalog (compiled-in source).

**v1 chrome surface (deferring exercises + demo seed): ~490 strings ×3**, plus whichever vocabulary sets are opted in.

**Scope decisions (LOCKED):**
- Exercise library (~200) → **keep English** (mark don't-translate; revisit v2).
- Mood vocabulary (44: 4 quadrants + 4 blurbs + 36 emotion words) → **translate**.
- Section names + descriptions (32) + macro labels (13) → **translate**.
- Demo seed (~60) → **exclude** (DEBUG/screenshot-only).
- **Locked v1 surface ≈ 307 + 180 + 44 + 45 ≈ ~575 strings × 3 languages.**

### Execution roadmap (post-groundwork)
1. **Wrap chrome → `LocalizedStringResource`/`String(localized:)`** (~270 = 180 chrome + 44 mood + 45 section/macro), batched by area. Mark exercises don't-translate. (Fixes extraction + bypass sites together.)
2. **Plurals** — 6 hacks → catalog plural variations (pass counts as numbers).
3. **Comments** — 73 format strings get translator context (`Text("…", comment:)`).
4. **Formatting** — locale-aware number parse (Caffeine) + display date formatters.
5. **Phase 1b** — own catalogs for Widgets / Watch / LiveActivity (~20).
6. **Translate** (pick mechanism) → native review → pseudoloc QA.
7. **Ship locales incrementally** — add a language to `CFBundleLocalizations` only when it's translated enough (avoids mixed UI).

### Localization convention (the structure)
The repeatable structure every wrap follows:
- **One canonical store** — `Septena/Localizable.xcstrings`. Auto-extraction keeps it synced with code; pt-BR (and future languages) live here.
- **Chrome** → `String(localized: "…", comment: "Feature: context")`, co-located in the type that owns the string. The `comment:` gives translators context **and** groups the catalog by feature (Xcode sorts/filters by comment).
- **Return types stay `String`** — wrapping the *literal* (not changing the property's type) means zero call-site breakage; `Text(x.label)` then shows the localized value.
- **User data / stored values stay canonical English** — e.g. `MoodEvent.emotion` persists the English word; localize only at the display layer (never the array/storage).
- **Per-batch pt-BR fill is reproducible**: add `String(localized:)` in code → add the pt-BR value to the catalog → build-verify `pt-BR.lproj` → commit clean files only.

### Milestone B progress
- ✅ **Batch 1** — Welcome greeting (fallbacks + tone labels + AI prompt writes in the app's language) + DayBucket (Manhã/Tarde/Noite). `abd6200`.
- ✅ **Batch 2** — Mood quadrant titles + blurbs (8) + Macro labels (13).
- ⏳ **Deferred (careful)** — 36 mood emotion words: stored on `MoodEvent.emotion`, so keep `words(for:)` English and add a display-only localizer at the (clean) sites `EditMoodEntrySheet` / `AddMoodPage`.
- 🚧 **Blocked on active WIP** — section names (`SectionManifest`), settings enums (`SettingsView`), dashboard tiles. Wrap once those files are committed.
- 🔎 `AddInfoSection.swift` not found (renamed in the dashboard refactor) — relocate the quick-add menu strings.

## Repo-specific gotchas (ranked)

1. **xcodegen silently undoes Xcode-side localization config.** Declare languages via `CFBundleLocalizations` in `project.yml`, never the Xcode UI.
2. **The verbatim boundary** — leaking user data (task names, mood words, renamed sections) into the translator catalog. Mark `Text(verbatim:)` deliberately.
3. **`SeptenaCore` is compiled into 6 targets as source**, not a framework → `Bundle.main` differs per target; shared strings need a catalog in each consuming target (Watch/Widgets).
4. **`String(format:)` is not locale-aware** for decimal separators; prefer `.formatted()`.
5. **No RTL needed** for FR/DE/ES (all LTR). Adding Arabic/Hebrew later is a bigger lift (layout mirroring).

---

## Effort estimate

Big levers are Phase 0 (gets it *right*) and Phase 3 (translation QA, the long pole). Because SwiftUI auto-extracts literals, the refactor concentrates in interpolations, plurals, enums, and the verbatim boundary. Realistic: **~2–3 weeks engineering for FR/DE/ES on phone+Mac**, plus translation/review, *if* the pilot goes first and imperial-units scope stays out.

## Key file references

- `project.yml` — xcodegen source of truth (localization config goes here)
- `Septena/Info.plist`, `Septena/Info-Mac.plist` — generated; `CFBundleLocalizations` via `info.properties`
- `Septena/Sections/Caffeine/EditCaffeineEntrySheet.swift:196` — decimal-parse reference fix
- `Septena/Shell/Dashboard/WelcomeHeader.swift` — AI greeting + hardcoded fallbacks (Phase 2)
- `Septena/App/Intents/` — already localized (`LocalizedStringResource`)
- `SeptenaCore/Models.swift:1410` — latent `AppUnits` (metric/imperial, deferred)
