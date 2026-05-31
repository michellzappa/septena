# Bet 1 — The LogCommit Confirmation Language

> A handover for whoever picks this up next. This document is about **intent and
> feel**, not implementation. Read it to understand what we're trying to make the
> app *feel like*, then go build the parts that aren't there yet.

---

## The thesis

Septena's ownable idea — the thing that could make it memorable rather than just
well-built — is already latent in one screen: the **Mood meter**. When you log a
mood, the confirmation animation *changes character based on what you felt*:
confetti for joy, a tension-snap for anger, a slow bloom for calm, a quiet
downward sink for despair. The celebration matches the affect.

That single idea — **"the app responds to the texture of your life"** — is the
whole bet. Right now it's buried in 1 of 16 sections. Bet 1 promotes it into a
**system-wide language**: every meaningful log gets a confirmation whose
character fits what was logged. Logging caffeine should *feel* different from
crossing a 30-day habit streak, which should feel different from finishing a
workout. Same grammar, different words.

The payoff is emotional, not functional. The data already saves correctly. This
is about making the moment of logging feel *alive* — so the app rewards the
ritual, not just records it.

---

## Design principles (hold these the whole way)

1. **The celebration matches the affect.** A warm ripple for coffee. A water
   drop for hydration. A burst for a workout. An "ignition" with the streak
   number popping for a habit milestone. Never one generic confetti for
   everything — that's the opposite of the thesis.

2. **Tasteful, not a party.** Single-tone, accent-colored, short (~1s). It
   should feel like a satisfying *click*, not a Vegas slot machine. When in
   doubt, less.

3. **Confirmation, never a gate.** The animation is a reward layered on top of
   an action that already succeeded. It must never block, delay, or be required
   for the log to happen. If it can't play, the log still works silently.

4. **It must be invisible to those who opt out.** Reduce Motion is a hard
   switch, not a hint. With it on, there is **no** visual — the haptic and a
   spoken VoiceOver confirmation carry the moment instead. (This is also a
   safety requirement: a full-screen flash with Reduce Motion on is
   seizure-adjacent. Never regress this.)

5. **Reward consistency, because that's the headline feature.** The app
   advertises "routines and streaks" but checking a habit currently does
   nothing celebratory. Streaks are computed and then thrown away. The biggest
   emotional win in this bet is making a streak milestone *feel* like an
   achievement.

---

## What's already done (the foundation + the headline)

Two pieces are built, shipped, and verified running in the simulator:

- **The shared celebration layer exists.** There is now one app-wide overlay
  that any screen can ask to "play a celebration of style X." It's mounted once
  at the root, it honors Reduce Motion centrally, and it's the single place new
  celebration styles get added. Think of it as the stage; the rest of the bet is
  writing more performances for it.

- **Habit streak milestones celebrate.** When you complete a habit and your
  streak lands on **7, 30, 100, or 365 days**, an "ignition" fires — radiating
  rings with the streak number springing into view — plus a success haptic and a
  spoken "{n} day streak!" for VoiceOver. It fires **once per milestone** (not
  every day after), and if you break a streak and re-earn it, it celebrates
  again. This works from the habit screen and the Next list.

So the proof-of-concept is live: the Mood idea has been generalized, and the
single most important new moment (streak achievement) pays off.

---

## What's left to build

### Phase 1 — Give the daily logs their own feel
Right now, logging a coffee, water, or a workout is silent (or only haptic).
Each should get a confirmation that fits its domain:

- **Caffeine → a warm ripple.** Concentric rings in the caffeine accent. Should
  feel like warmth spreading.
- **Hydration → a water drop.** A droplet landing + ripple. Cool, clean, light.
- **Training → a burst.** A celebratory upward fan — finishing a workout has
  earned some fanfare. (A confetti-style burst already exists in the app; reuse
  its energy.)
- **Anything else that logs → a tasteful default burst**, so no log ever feels
  completely dead.

The important UX judgment here: **each domain's celebration should be
recognizable with your eyes closed-ish** — distinct enough that a regular user
starts to *feel* which thing they logged. But all within the same restrained,
single-accent family so the app feels coherent, not chaotic.

One thing to respect: some logs happen *inside* a pop-up sheet (e.g. editing a
caffeine entry before saving). The celebration should land on the main screen
**after** the sheet closes — not get hidden behind it. One-tap logs (water, a
habit checkbox) have no sheet and should celebrate immediately.

### Phase 2 (done) — Streak ignition
Already built (see above). Listed here only so the phase numbering matches the
original plan.

### Phase 3 — Make the dashboard feel alive
The dashboard is the app's front door and it's currently inert — tiles don't
react to touch, and they don't react when their numbers change. Two changes,
both small in feel but big in "this app is alive":

- **Tiles respond to touch.** A subtle press-in when you tap a tile. Standard
  modern-app tactility; its absence makes the dashboard feel like a static
  poster.
- **Tiles react when their value changes.** Log a coffee → the caffeine tile's
  number ticks up *and* the tile gives a soft pulse. This closes the loop: you
  log something, the celebration fires, **and** the relevant tile visibly
  acknowledges the new reality. The number-rolling transition is already used in
  one place; spread that feeling.

---

## How to know you've succeeded

You're done with Bet 1 when a person using the app for a normal day feels this:

- Every time they log something, the app *acknowledges* it with a small moment
  that feels right for that thing — coffee feels warm, water feels cool, a
  workout feels earned.
- Crossing a streak milestone feels like a genuine little achievement, not a
  silent database write.
- The dashboard feels responsive and current — it reacts to their touch and to
  their logging.
- A user with Reduce Motion on experiences none of the motion but still feels
  confirmed (haptics + VoiceOver) — and nothing ever flashes.
- Nothing is loud, nothing is slow, nothing blocks. It all feels like polish,
  not gimmick.

If a design-award juror used the app for five minutes and came away saying *"it
responds to you,"* the bet paid off.

---

## Guardrails (don't undo these)

- **Never** let a celebration render under Reduce Motion. Route everything
  through the central gate that already exists; don't hand-roll motion at call
  sites.
- **Never** make the log depend on the celebration. Log first, celebrate second,
  and only if possible.
- Keep it **single-accent and short**. The moment you reach for rainbow or
  multi-second animations, you've left the design language.
- Match the existing restraint. Septena is calm and editorial, not playful-loud.
  The celebrations should feel like they belong to *this* app.

---

## Pointers for the next agent (orientation only — go read the code yourself)

- The mood celebration that started all this is the reference for "affect-matched
  choreography" — study how it varies by quadrant.
- The shared celebration layer (the "stage") is where new styles get added —
  one place, one pattern. Adding caffeine/hydration/training is mostly authoring
  new performances in that file and asking the right screens to fire them.
- The streak logic is the template for "fire once, on a real threshold, reset on
  break" — reuse that discipline for any future milestone-style celebration.
- The dashboard tiles are a single reusable component — change it once, every
  tile benefits.
