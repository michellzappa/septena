# Glass data dots on the day-wheel — spec

**Status:** ready to build · **Target file:** `Septena/Shell/UI/TimeOfDayWheel.swift`
(hero composition in `Septena/Shell/Dashboard/DayDialHero.swift`)

## Goal

Render the day-wheel's **data dots** as real Liquid Glass (`.glassEffect`)
beads instead of flat Canvas-filled circles, on the hero dial. The section
color, recency fade, and density sizing all stay — the dots just become glass.

This **deliberately reverses** the decision recorded in the comment at
`TimeOfDayWheel.swift:438` ("Real `.glassEffect` beads were tried … read as
muddy smudges … data stays solid and crisp"). That comment must be rewritten to
describe the new approach — do not leave it contradicting the code.

## Why this is now feasible

The original attempt failed for two reasons, both of which we now accept or
design around:

1. **Glass can't render through a `rotationEffect`** (same reason the donut is
   held static, see `TimeOfDayWheel.swift:295`). The dots currently live in the
   Canvas marks layer, which *is* rotated (`.rotationEffect(.degrees(displayedRotation))`
   at line 472). **Resolution:** the product owner has accepted that glass dots
   may hide/show across reorientations. We render them in a *separate, untransformed*
   overlay and bake the rotation into their positions (math, not a view transform),
   and fade the whole overlay with `marksOpacity` so they disappear during a
   day-swipe and reappear at the new angle — identical to how the marks already
   behave (line 467–473).
2. **Muddy glass-on-glass smudges** over the donut. This is the real risk and
   the acceptance bar (see "Known failure mode" below). It must be visually
   verified, not assumed solved.

## Hard constraints (do not violate)

- **Canvas cannot host glass.** `ctx.fill(Path(ellipseIn:))` at
  `TimeOfDayWheel.swift:447` is immediate-mode 2D drawing; `.glassEffect` is a
  SwiftUI view material. Glass dots must be real `Circle` views in a SwiftUI
  overlay, not Canvas fills.
- **`dotMarks(side:)` stays the single source of dot geometry.** It already
  computes per-event `center`, `diameter`, `color`, `opacity` (struct `DotMark`
  at line 215). The new overlay consumes the *same* `dotMarks(side:)` output —
  do not duplicate the sizing/density math.
- **Widgets keep the flat path.** Glass cannot render in a widget snapshot; the
  dial already falls back via `flatGlass` (`SeptenaWidgets/RhythmWidget.swift:154`,
  `flatGlass` var at `TimeOfDayWheel.swift:109`). When `flatGlass == true`, dots
  must continue to render exactly as today (the in-Canvas solid fill).
- **Compact thumbnails keep the flat path.** The per-section mini wheels
  (`compact == true`) are too small for glass to read — leave them on the Canvas
  fill.
- **Read-only / presentation change.** No model, mutator, DayClock, or CloudKit
  changes. Pure rendering.

## Approach

Mirror exactly how the donut already toggles between real glass and the flat
fallback (`TimeOfDayWheel.swift:283` for flat, `:301` for live glass).

1. **Gate the Canvas dot loop.** The existing loop at lines 443–448 should only
   run when the glass overlay is *not* active — i.e. keep it for `compact`,
   section dials, and `flatGlass` widgets; skip it when the hero glass overlay
   will draw the dots. (Net: never draw a dot twice.)

2. **Add a glass overlay layer** as a sibling of the Canvas inside the same
   `ZStack`, rendered only when `!compact && heroDate != nil && !flatGlass`.
   It must **not** be inside the rotated Canvas layer and must **not** carry a
   `.rotationEffect`.

   For each `DotMark m` from `dotMarks(side:)`:
   - Compute the **rotated** center: rotate `m.center` about the dial center by
     `displayedRotation` in code (so no view transform is needed). The dial
     center is `(side/2, side/2)`; reuse the same trig as the Canvas.
   - Render `Circle().frame(width: m.diameter, height: m.diameter)` with a
     `.glassEffect(...)` (flavor below), `.position(rotatedCenter)`, and
     `.opacity(m.opacity)` for the recency fade.
   - Wrap all dots in a single `GlassEffectContainer(spacing: …)` so same-slot
     stacks blend/merge fluidly (this reinforces the density story and is the
     recommended perf path for many small glass shapes). Consider
     `glassEffectUnion(id:in:)` keyed by 30-min slot so a cluster reads as one
     bead rather than N overlapping ones.

3. **Fade with the marks.** Apply `.opacity(marksOpacity)` to the whole overlay
   (in addition to per-dot `m.opacity`) so the dots fade out during a day-swipe
   reorientation and fade back in — matching the marks layer. This is the
   "hide/show as needed" behavior the owner approved.

4. **Rewrite the comment** at lines 438–442 to describe the glass overlay and
   the rotation/visibility tradeoff, replacing the "data stays solid and crisp"
   rationale.

## Glass flavor & legibility (decisions — defaults chosen, change if wanted)

- **Flavor:** default `.clear.tint(m.color).interactive()`. `.clear` is more
  transparent/lensy and carries less of the frosted elevation shadow that
  caused the original muddy look; `.interactive()` gives the press/tilt
  parallax that makes it read as glass. (Alternative: `.regular.tint(...)` if
  `.clear` reads too faint over the donut.)
- **Color carrier:** the dot must still read as its section color. Tint the
  glass with `m.color`; if tint alone is too washed out at small size, the agent
  may underlay a thin solid color core or a subtle inner color fill — but keep
  the glass material as the dominant surface.
- **Size floor:** the current sizing (`dotMarks`: min 4.4pt, max 8pt diameter)
  may be too small for glass to read. The agent may raise the **glass-only**
  floor (e.g. ~7pt min, keep/raise max to ~9–10pt) — but only for the glass
  overlay; do **not** change the flat-fallback / widget sizing, and do not alter
  the `dotMarks` density math itself (scale at the overlay if needed). Tune on
  device and report the final numbers.

## Known failure mode (acceptance bar)

The prior attempt produced "muddy smudges" because glass beads sitting on the
glass donut carried the material's built-in elevation shadow (glass-on-content,
which Apple's HIG warns against). The dots sit on the outer ring
(`dotRing = ringR * 0.82`), which is on the donut annulus, so this risk is live.

**The build is only acceptable if the glass dots read as clean, distinct,
section-colored beads over the donut — not muddy blurs.** Mitigations to try, in
order: `.clear` flavor, `GlassEffectContainer` (normalizes/merges), per-slot
`glassEffectUnion`, reducing/removing the material shadow, raising the size
floor. **If a clean result cannot be achieved, stop and report back with a
screenshot rather than shipping a muddy dial.**

## Scope

- **In:** the hero day-wheel (`heroDate != nil`) in `DayDialHero`, both Today
  and Week views.
- **Out:** compact per-section mini wheels, section-detail dials, the widget
  (all keep the flat Canvas fill), and the `dotMarks` density/sizing formula.

## Acceptance criteria

1. Hero dial dots render as real Liquid Glass on iOS 26 and macOS 26 (follow the
   donut's cross-platform `.glassEffect` usage at line 301 — no platform shim
   needed; it already works on both).
2. Section color, recency fade, and density sizing are all preserved/legible.
3. Dots read clean over the glass donut (see acceptance bar) — verified by
   screenshot, not assumed.
4. During a day-swipe, dots fade out, the dial reorients, dots fade back at the
   new angle — no rotation glitch, no stuck/ghost glass.
5. Widget (`flatGlass`) and compact thumbnails are visually unchanged.
6. All three schemes build green:
   ```
   xcodebuild -scheme Septena      -destination 'generic/platform=iOS'     -configuration Debug build
   xcodebuild -scheme SeptenaMac   -destination 'platform=macOS'           -configuration Debug build
   xcodebuild -scheme SeptenaWatch -destination 'generic/platform=watchOS' -configuration Debug build
   ```
   (Watch doesn't render the hero dial but must still compile.)
7. The contradicting comment at `TimeOfDayWheel.swift:438` is rewritten.

## Verification

This is a visual change — a green build is necessary but **not sufficient**.
Run the app (iOS simulator and/or macOS) and screenshot the hero dial in both
Today and Week views to confirm the glass reads clean and the section colors
survive. Use the `run` / `verify` skills or boot a simulator and capture the
front-door dashboard. Attach before/after screenshots in the handoff.

## Reference points in the current code

- `dotMarks(side:)` — geometry source — `TimeOfDayWheel.swift:226`
- `DotMark` struct — `:215`
- Current flat dot loop (to gate) — `:443`
- Comment to rewrite — `:438`
- Donut: flat fallback `:283`, live glass `:301` — copy this gating pattern
- Rotation + marks fade — `:472` (`displayedRotation`, `marksOpacity`)
- `flatGlass` flag — `:109`; widget sets it `RhythmWidget.swift:154`
- Existing glass idioms in the app: `GlassEffectContainer` + `glassEffectID`
  in `Septena/Shell/Tasks/TaskComposer.swift:375`; `.glassEffect` tint/interactive
  in `Septena/Shell/Goals/Discovery/DiscoveryFlowChrome.swift`

## Project conventions (from CLAUDE.md)

- Match surrounding comment density / naming / idiom.
- `project.yml` + `xcodegen generate` is the source of truth if any file is
  added (none expected for this change).
- Leave the tree green and build-verified; a committer-cron commits green work
  on `main` — do not create branches, do not `git push`.
