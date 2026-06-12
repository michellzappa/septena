# Front Door & Identity Roadmap

Decisions and build plan from the 2026-06-12 design review ("the app is bland —
I want delightful, subtle, award-worthy"). This is the working doc for the
identity arc; `docs/DesignSpec.md` remains the design system of record and
absorbs each piece as it ships.

## Diagnosis

The design system's discipline (uniform cards, system backgrounds, SF Pro,
accent stripes) produces coherence *and* blandness. Two things were missing:

1. **No signature object** — nothing you can identify from one screenshot.
   The tile-grid dashboard looks like every health app.
2. **No voice** — the app's latent identity (cardinal virtues, Examined Week,
   "acknowledgment vs celebration" motion philosophy) wasn't expressed in
   the product.

What Septena uniquely owns: **the whole day across every domain** (no
competitor holds mood + meals + caffeine + training + sleep + gut in one
place), and a latent **day-arc metaphor** already in the code (DayClock, the
sun glyph for Today, the `.arc` comet, `TimeOfDayWheel`).

## Decisions (locked 2026-06-12)

- **Risk ceiling: Flighty-level confidence.** Native bones; bold bespoke
  surfaces only where the data is the star (the dial, review pages, share
  cards). Not Gentler-Streak-bespoke, not Things-austere.
- **All four directions approved, built in sequence — never simultaneously:**
  1. **A — Day dial as hero** (front door): SHIPPED v1, see below.
  2. **C — Ambient light** (restrained version, front door only): SHIPPED v1
     as the glow behind the dial. No app-wide tinting.
  3. **B — Literary voice** (NEXT): Fraunces + considered microcopy on
     *reflective* surfaces only — weekly review masthead, milestone cards,
     Examined Week as a typeset letter, share cards as typeset artifacts.
     Transactional surfaces stay SF/native.
  4. **E — Sound identity** (LAST): tiny soft sounds paired to the CheckFeel
     haptic rhythms, off-by-default. Only after the visual identity settles.
- **D — the craft layer** runs alongside everything: gauge motion (shipped),
  matched-geometry tile→destination transitions, live idle details, ghost-state
  empty states replacing `ContentUnavailableView`.

## Celebration budget (shipped same session; tightened after device test)

The screen-level flourish vocabulary is reserved for *earned* moments. The
user's calibration (2026-06-12, after testing): everyday logs should be
**quiet** (tick + announce via `SectionLog.quietLog`), with one earned
canvas moment per section where one exists.

- **Nutrition**: only the day's FIRST meal — breaking the overnight fast —
  plays `.bloom`; every later meal is quiet. Policy lives in ONE place:
  `NutritionPlugin.commitMeal(loggedAt:…)`, which all six new-meal call
  sites route through. Water-only rows don't break a fast; past-day
  backfill never celebrates. First-meal check reads the local mirror at
  commit time.
- **Hydration**: every glass is QUIET; the `.fill` flood plays only for the
  glass that crosses the daily target — once a day, both commit sites,
  crossing computed from the local mirror (`HydrationPlugin.waterMl`),
  never display state (the stale-cache misfire bug).
- **Intake**: `.snap` for every tracker log (user pick). Per-kind stored
  `flourish` tokens are dormant — `IntakeKindPageView.motion(for:)` returns
  `.snap` unconditionally. VISIBILITY FIX: on iPhone the kind page is a
  sheet, which covers the root `LogCommitOverlay`, so the page hosts its
  own `CommitFlourish` overlay (`flourishTrigger`) and passes
  `logCommit: nil` — this is the general pattern for any log surface that
  presents as a sheet and doesn't dismiss on commit.
- **Gut / Medications / Symptoms**: `.sink` retired (read as "nothing
  happening") → `.snap`.
- **Training**: per-set canvas burst REMOVED (haptic + icon bounce remain);
  session-complete is the one moment — `.burst` always, intensity still
  scaled by PRs / volume.
- Tile gauges carry the everyday feedback instead: `Theme.Motion.gauge`
  spring (travel + overshoot), numeric count-up on the same curve, and a
  traveling glint across the newly-added span of the progress bar
  (`ModuleTile.ProgressRow`) — the "glow" re-expressed as motion along a
  6pt bar. Honors Reduce Motion + the logging-animations opt-out; seeds
  unanimated on first mount; only a *grow* glints.

## Front door v1 (shipped, this branch)

- **`DayDialHero`** (`Septena/Shell/Dashboard/DayDialHero.swift`) — today as
  a living 24-hour dial between the greeting and the layout grid. Composes
  the existing `TimeOfDayWheel` (today-focused by default, week overlay one
  tap away) over **`AmbientGlow`**. Self-observes DayClock so the minute
  tick (now-hand) re-renders only the hero. Reloads on `.septenaDataChanged`.
  Hidden in the Wheel layout mode (which already renders this dial as its
  body). Toggle: Settings ▸ Home ▸ "Show Day dial"
  (`SettingsKey.homepageShowDayDial`, default on).
- **`RhythmData`** (extracted in `RhythmHomepageView.swift`) — the one
  cross-section rhythm fetch; both dials (hero + Rhythm mode) load through
  it so they can never disagree (§8 centralization).
- **`AmbientLight`** (`Septena/Shell/UI/AmbientLight.swift`) — ONE definition
  of the time-of-day wash (dawn warm / day near-neutral / dusk ember / night
  indigo), presented as a low-alpha radial glow. Slightly boosted in dark
  mode. 2s cross-fade on phase change; hidden from accessibility.

## Dial polish pass (shipped, same branch)

1. **The comet orbits the dial.** `DayDialHero` publishes its dot-ring circle
   as `DayDialAnchor` on `LogCommitCenter` (global coords, via
   `onGeometryChange`; cleared on disappear). The root `LogCommitOverlay`
   passes it to `.arc` only; `ArcFlourish` then traces one full clockwise
   revolution of the dial — midnight back to midnight, the day's circle
   completed — instead of the screen sweep. Falls back to the screen sweep
   whenever the circle isn't actually on-canvas (other tabs, hero hidden,
   scrolled away, in-sheet flourishes). `TimeOfDayWheel.dotRing(forDiameter:)`
   is the shared geometry so the comet lands exactly on the drawn ring.
2. **Ambient rim instead of sunrise/sunset markers.** True solar times need
   location; instead the dial face wears the `AmbientLight` phases as a faint
   rim wash under the ticks (dawn warm 5–8, day near-silent 8–17, dusk ember
   17–21, night indigo 21–5) — honest, and it unifies direction C with the
   dial. Opt-in via `TimeOfDayWheel.heroDate`; section-detail wheels and
   compact thumbnails are untouched.
3. **Dots bloom in.** The hero diffs today's event ids between reloads; new
   dots get a one-shot expanding ring (`DotBloomRing`) at their dial position
   — capped at 4 per reload (bulk syncs can't ring the whole dial), seeded
   silently on first load, gated by Reduce Motion + the logging-animations
   opt-out.
4. **Center shows the date.** In hero today-focus the scope chip gives way to
   weekday-over-day-number (watch-face style); the week overlay keeps the
   "7 days" chip so the toggled state stays labeled.

### Round 2 (user feedback, same day)

- **Sun + moon landmarks** (hero, today view only): the midnight and noon
  numerals become `moon.fill` (top — midnight is at the top of this dial)
  and `sun.max.fill` (bottom), tinted from the AmbientLight palette. Week
  overlay keeps all four numerals.
- **Date hub**: a 30pt card-surface disc under the date but over the
  now-hand, so the hand reads as truncated at the hub — a watch's center
  cap. (The small 6pt hub in non-hero center was added by a parallel
  session; same chrome.)
- **Sleep bands thin** (4pt, like calendar pills) — a night is context,
  not a headline.
- **`DayViewStyle` setting** (Settings ▸ Home): Dial / Timeline / Hidden
  picker (`homepageDayView` key) replaced the two independent
  show-dial/show-timeline toggles — circular and linear are two shapes of
  the same information, so it's one choice now. Linear = the existing
  `DayTimelineView` strip.

### Round 3 (user feedback, same day)

- **Solar ring replaces the phase arcs**: the user disliked the 4-segment
  colored rim → now one Watch-Solar-style conic band
  (`AmbientLight.solarRing`, stop locations = day fractions, stroked at
  -90° so midnight lands top): near-black night, sky-blue day, dawn/dusk
  gradient transitions "indicating" morning and evening.
- **`AmbientHalo`**: a two-ring blurred glow hugging the disc edge, phase-
  tinted, *stronger in dark mode* (the flat-in-dark complaint) — composes
  with the wide `AmbientGlow` backwash behind the hero.
- **Sun/moon moved to wake/bedtime**: markers now ride the solar ring at
  today's Oura `wakeTime` (sun) and `bedtime` (moon) — the same night the
  linear `DayTimelineView` uses for its markers; quadrant numerals
  restored at 0/6/12/18. Card-surface "pucks" lift the glyphs off the
  band. No night synced → no markers (honest, like the timeline).

### Round 5d — glow A/B on the window tap (user feedback, same day)

- `AmbientHalo` gained `Style`: `.sky` (full solar-band gradient around the
  circle) vs `.now` (uniform glow in the current hour's sampled light).
  The hero keys it off the dial's today⇄week window (shared
  `TimeOfDayWheel.windowDefaultsKey` @AppStorage), so TAPPING THE DIAL
  compares the two glow treatments live — today = sky band, week = now
  light. Once a winner is picked, collapse Style back to one case.
- The center hub disc now draws in EVERY full-dial window (week + non-hero
  included), holding the scope chip — the now-hand is capped everywhere.

### Round 5c — face cleaned, tap restored (user feedback, same day)

- Solar ring stroke REMOVED from inside the face — the sky band now lives
  only in the blurred `AmbientHalo` behind the dial ("just bg is nice").
  The wheel no longer takes `solarTimes`; SolarClock feeds the halo alone.
- The "…" window menu (added by a parallel session) replaced with the
  original tap-on-dial toggle (today ⇄ 7 days); `todayOnly` stays
  @AppStorage so the choice persists and all dials flip together. The
  center scope chip returns on non-hero dials / hero-week so the current
  window is visible again without the menu naming it.

### Round 5b — halo wears the whole gradient (user feedback, same day)

- `AmbientHalo` now strokes the solar ring's OWN gradient (AngularGradient,
  same -90° start) blurred — the night side glows indigo, day side blue,
  dawn edge orange, in the same angular positions as the band. Not a
  single sampled color anymore (that was the misread of "merge the blur
  with the sky"); the wide `AmbientGlow` backwash keeps the sampled
  sky-at-now color as the room light.

### Round 5 — markers dropped (user feedback, same day)

- Sun/moon wake/bedtime markers (and their pucks) REMOVED: redundant once
  the sleep arc shows the night and the solar ring shows the sky. The
  `sunFraction`/`moonFraction` wheel params and the hero's Oura-night
  lookup went with them; `RhythmData.frac` is private again. The linear
  `DayTimelineView` keeps its own sun/moon — different geometry, still
  earns them.

### Round 4 — one sky model (user feedback, same day)

- **The glow IS the sky now.** `AmbientLight` keeps ONE stop table
  (night/dawn/day/dusk colors at hours anchored to sunrise/sunset);
  `solarRing(times:)` strokes it, `sky(at:)` *samples* it at the current
  minute — and `AmbientGlow` + `AmbientHalo` wear that sampled color. At
  07:00 the blur behind the dial is dawn-orange, at noon sky-blue, at
  23:00 night-indigo, drifting continuously through the transitions. The
  old four-phase tint pairs are gone from the glow path (the `Phase` enum
  survives only for the sun/moon marker tints).
- **Real sunrise/sunset, ZERO permission** (`SolarClock`,
  `Septena/Shell/UI/SolarClock.swift`): the device TIME ZONE maps to a
  representative city coordinate via a ~150-zone built-in table
  (zone1970-style points), then the NOAA approximation runs on-device.
  Within a zone solar times vary by minutes — invisible inside the
  2-hour gradient transitions — and the zone follows travel
  automatically. Always on, nothing asked, nothing stored, no Settings
  toggle. Unknown zone / polar edge → the fixed design day (up 6:30,
  down 19:00). [History: round 4 first shipped this as an opt-in
  CoreLocation one-shot fix + Settings toggle + usage strings; round 6
  deleted all of it — `SolarLocationFetcher`, `septena.solar.*` keys,
  `NSLocationWhenInUseUsageDescription` in project.yml/xcstrings — after
  realizing timezone geography is sufficient for ambient light. "Never
  asks for location" is itself a feature for this app.]

## Next steps (in order)

1. **Device pass on the dial** — glow strength, rim alphas (0.07–0.20 in
   `TimeOfDayWheel`), bloom timing, comet-orbit feel; then commit.
2. **B — literary voice**: weekly review masthead in Fraunces, Examined Week
   typeset pass, milestone share cards (also the planned viral loop).
3. **D continued**: `.navigationTransition(.zoom)` tile→destination,
   ghost-state empties (render the section's viz primitive faintly with one
   inviting cell instead of `ContentUnavailableView`), live fasting-timer
   breathing.
4. **E — sound**: design alongside the CheckFeel rhythms; off by default.

## Traps

- Don't read `clock.now` in `WeekDashboardView`'s body — it invalidates the
  tile grid every minute. Hero and glow self-observe instead (same pattern
  as `WelcomeHeaderSection`).
- The hero passes section-key-level colors; the Rhythm mode colors intake
  dots with the first kind's adaptive color. Minor, acceptable divergence.
- `RhythmFmt` formatters are file-private to `RhythmHomepageView.swift`;
  `RhythmData` lives in the same file on purpose.
