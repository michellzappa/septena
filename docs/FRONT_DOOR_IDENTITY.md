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

## Celebration budget (shipped same session)

The screen-level flourish vocabulary is now reserved for *earned* moments:

- Nutrition + hydration demoted from per-log full-page `.fill` to calm
  `.bloom` (the celebration-budget rule in `TaskComponents` applied to logs).
- The `.fill` flood is **reserved for the glass that crosses the daily
  hydration target** — once a day, both commit sites (destination +
  dashboard quick-add). The hydration sibling of the tasks `.arc` rule.
- Nutrition gets no crossing payoff on purpose: no single target to cross
  (multi-axis range goals; kcal often unknown at log time).
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
