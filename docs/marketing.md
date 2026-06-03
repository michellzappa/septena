# Septena — Positioning & Messaging

> The source of truth for *what Septena is and how we talk about it.* Every
> piece of outward copy — the App Store listing ([appstore.md](appstore.md)),
> the website, screenshots, the in-app About pane, release notes — should trace
> back to this document. When this conflicts with a shipped feature, the
> **feature wins** and this doc gets corrected. Like [DesignSpec.md](DesignSpec.md),
> this is derived from what the app already does — not aspirational.
>
> **Status:** v1 — 2026-06-03. Positioning locked (see §0 decisions).
> **Audience locked:** quantified-self enthusiast, plain language.
> **Lead hook locked:** *one private app for everything.*
> **Pricing locked:** free (v1).

---

## 0. Decisions that anchor everything below

These were open in early drafts; they're now settled and the rest of the doc
assumes them.

| Decision | Resolution | Consequence |
|---|---|---|
| **Who it's for** | The self-tracker tired of app-sprawl who wants ownership — in plain language, no coding required. "Bring your own AI" is a delighter, not a gate. | Voice is accessible, not technical. We don't lead with MCP/CloudKit jargon. |
| **The #1 hook** | *One private app for everything you track about yourself.* Consolidation and ownership, fused. | Privacy isn't pillar #2 — it's baked into the headline. |
| **Pricing** | Free for v1. | CTA is "Download." No paywall narrative, no onboarding paywall. |
| **Cannabis** | Ships, listed plainly as one logging section. Not featured in hero copy or screenshots. | Affects age rating (answer Apple's questionnaire honestly → likely 17+). |
| **Name story** | Implied, not lectured. "One week at a time" carries it; the full "seven = heptad" story is a reward for the curious, not the headline. | |
| **Domains** | `septena.app` (marketing / support / privacy). `mcp.septena.app` (the agent gateway). | |

---

## 1. The one-liner

**Septena is one private app for everything you track about yourself.**

Elevator (30 seconds):

> You track yourself across a dozen apps — one for workouts, one for macros, one
> for sleep, one for habits, a notes file for supplements, your head for the
> rest. The data never sits in one place, so you never see how it relates. And
> it all lives in someone else's database. Septena puts every corner of your life
> in one app, organized by the week — the cadence where sleep, training, food,
> and habits actually start to relate. Your data lives in *your* iCloud; Septena
> runs no server that can read it. And when you want to ask questions of it, you
> can point your own AI at it — with your permission, and a visible record of
> everything it touched.

Taglines (ranked, pick by surface):

1. **"Everything you track, one private app."** — primary, fuses the two hooks.
2. **"Seven days. One view."** — inherited from the web version; still the most
   memorable. Best for the brand mark / hero where context is already set.
3. **"One app for every corner of your life."** — the shipping in-app tagline.
4. **"A weekly view of everything you're paying attention to."** — benefit-led.
5. **"Your data is yours."** — the trust line; use as a closer, not an opener.

---

## 2. The problem (why Septena exists)

Three problems, in priority order:

1. **App sprawl.** A workout app, a macro app, a sleep tracker, a habit app, a
   notes file. None of them talk. You can't see your week as one thing.
2. **No ownership.** Your most personal data — what you eat, how you sleep, your
   moods, your body — lives in a dozen companies' databases, shaped for *their*
   business, not your questions. You can't easily get it out, and you can't ask
   it anything they didn't build a screen for.
3. **The wrong cadence.** Daily trackers are noisy and guilt-inducing; monthly
   reports come too late to change anything. The unit where signals connect —
   *did late caffeine cost me sleep? do heavy leg days move the scale?* — is the
   **week**, and almost nothing is built around it.

Septena answers all three: **one app**, **your data**, **one week at a time.**

---

## 3. Who it's for (and who it's not)

### For
- The **quantified-self / self-tracking enthusiast** who's outgrown five apps and
  wants one place — but doesn't want to run a server or edit JSON to get it.
- People who care **where their health data lives** and are uneasy that it's
  scattered across cloud products.
- People who already live in the **Apple ecosystem** (iPhone + Watch, maybe Mac
  and iPad) and want something native and synced, not a web app in a wrapper.
- The curious — people who want to **ask questions of their own data**, including
  with AI, on their own terms.

### Not for
- People who want a **coach**. Septena has no meal plans, no prescriptions, no
  programs. It's a mirror, not a trainer.
- People who want a **social/competitive** layer. One person, their own data.
- People outside Apple's platforms. v1 is iPhone / iPad / Mac / Watch only.
- People who want a **turnkey, do-it-for-me** wellness app. Septena rewards
  attention; it doesn't manufacture it.

> **Voice note:** "plain language" doesn't mean dumbed-down. This person is
> smart and intentional. We respect their intelligence and their time. We just
> don't make them learn our plumbing to feel welcome.

---

## 4. The core idea — the week

**Septena = seven** (Latin *septem* / *heptad*). The unit is the **week**.

> A day is too noisy and a month is too late. A week is where sleep, training,
> food, and habits start to relate to each other.

This is the spine of the product, not a tagline flourish:
- Seven dots in the mark, seven days in the view.
- The **Week** tab is the home screen — a synthesizing dashboard across every
  enabled section.
- Most charts span seven days.

Use the week story when you have room to tell it. In tight copy, *"one week at a
time"* does the work and lets the name reward the curious.

---

## 5. What makes it unique — the five pillars

Ordered by how hard we lean on each. Pillars 1–2 are the headline; 3–5 are the
proof and the delight.

### Pillar 1 — One app for everything *(the consolidation)*
Tasks, training, nutrition, sleep, habits, hydration, mood, supplements, chores,
groceries, body, gut, caffeine, cannabis, activity, goals — each a **section** you
turn on or hide without losing data. The Week dashboard synthesizes them; the
**Next** view tells you what's left in the next 24 hours. Not twelve apps. One.

### Pillar 2 — Private by architecture *(the ownership)*
Your data lives in **your own iCloud** (the CloudKit *private* database), synced
across iPhone, iPad, Mac, and Watch. **Septena runs no server that can read your
life.** This isn't a privacy *policy* — it's the *architecture*. There's no
company database to breach, subpoena, sell, or shut down. Even the personalized
greeting is generated **on-device** (Apple Intelligence), not in a cloud.

> This is the modern, Apple-native re-frame of the web version's "JSON in a
> folder on your machine." Same principle — *your data is yours* — fit to the
> ecosystem people actually live in.

### Pillar 3 — Bring your own AI *(modern MCP)* — see §9
Connect the optional **Septena MCP gateway** and point Claude (or any MCP client)
at your data, with your permission. Your data, your AI, your questions — and a
**visible record of everything the agent touched.**

### Pillar 4 — Built around the week *(the insight)* — see §4, §6
The cadence where signals connect. The dashboard's **Correlations** view does the
math you'd never do by eye — *does caffeine after 2pm cost you sleep?* — with
honest statistics, not vibes.

### Pillar 5 — Honest by design *(the trust) — see §7
Streaks are computed from real events: **no grace days, no fudging.** The app
confirms what you log with a small, fitting celebration — and never nags you to
do the thing. It's a calm mirror, not a guilt machine.

---

## 6. How it helps you build better habits

Septena's habit philosophy is **"nudge to mark, don't nag to do."** It doesn't
push you to exercise; it makes *noticing and recording* your life frictionless and
quietly satisfying, and lets the pattern motivate you.

The mechanics that actually ship:

- **Honest streaks.** Each habit and supplement tracks a real consecutive-day
  streak, walked back from today over actual logged events. No grace days. A
  streak you can trust is a streak worth protecting. *(`ChecklistMirror.habitStreak`.)*
- **Milestone celebrations.** Crossing **7 / 30 / 100 / 365 days** fires a one-time
  "ignition" — radiating rings and the streak number springing in. It celebrates
  *once per crossing*, the day it's earned, so it stays meaningful.
- **A confirmation language that matches what you logged.** Every log gets a small
  flourish whose *character fits the data* — caffeine a warm ripple, hydration a
  drop, training a burst. The reward for logging is immediate and tactile, which
  is what makes the habit of logging stick. *(`LogCommit.swift`, `CommitMotion`.)*
- **The Next view.** A single checklist of what's left in the next 24 hours —
  habits, supplements, chores, open tasks — mirrored to your Watch. Plus **learned
  timing nudges**: it notices you usually log coffee around 7:45 and surfaces the
  card near then. (Learned median timing — honest about what it is; not a
  predictive coach.)
- **"Today is a verb."** Scheduled-for-today tasks land in a *review* block, not
  auto-promoted onto your plate. You decide what today is.
- **Calm by default.** Celebrations and motion are **gated for Reduce Motion**
  centrally; nothing flashes or loops. Notifications nudge you to *mark* what you
  already did, at times learned from your own rhythm — they don't badger you to
  perform.

> The throughline: Septena makes the *small act of paying attention* feel good and
> cost nothing, then shows you the week that attention adds up to.

---

## 7. Accountability — to yourself, and from your agent

Two kinds of accountability, both grounded in *honesty about what really happened.*

**To yourself.** Streaks and history come from real logged events, not optimistic
defaults. *"Streaks are computed from actual events. No grace days, no fudging."*
The app won't pretend you took a supplement you skipped. That honesty is the whole
point — a flattering tracker is useless.

**From your agent (provenance).** When you let an AI write to your data, Septena
keeps a visible record:
- Anything an agent creates is **stamped with its origin** (`source = "mcp"`,
  e.g. "Claude") — a permanent, immutable part of the record.
- New agent-created items wear a **calm freshness cue** — a small accent marker
  (deliberately *not* sparkles) that says *"you haven't seen this yet."* It
  **clears the moment you engage** (open, edit, complete, or "mark seen") and
  **auto-decays after 7 days** if you never do. The provenance stays forever; only
  the glow expires.
- The cue syncs — dismiss it on your phone, it's cleared on your Mac.

This is what makes "bring your own AI" *trustworthy* rather than spooky: your agent
can help, but you always know what it touched, and nothing it does hides in your
history.

> **Maturity (be honest in copy):** MCP source-stamping ships today for nutrition
> and tasks; the visible cue ships for tasks. Rolling out: the cue across all
> sections, and an accept/triage queue for higher-stakes agent *edits/deletes*.
> Market the *principle* ("you can always see what your agent touched") — it's
> real and shipping — not a feature checklist that outruns the build.

---

## 8. Private data access — the trust story in full

The cleanest privacy story we could ask for, because it's structural:

- **Your data is in your iCloud, not our cloud.** CloudKit *private* database,
  custom zone `septena-v1`. Septena-the-company has no server that stores or reads
  your entries. Nothing to breach, sell, subpoena, or sunset.
- **Local-first.** Every write lands in a local SwiftData mirror first, then syncs.
  The app works offline; the cloud is just sync, not the brain.
- **Health data stays close.** Apple Health metrics (steps, exercise, VO₂ max, HRV,
  resting heart rate) are read **on-device**. The few things Septena writes back
  (Mood, Nutrition) are opt-in.
- **Third-party imports are user-authorized.** Oura and Withings connect via *your*
  OAuth; you can disconnect anytime. They're read-only — Septena puts that data
  *next to* the rest, it doesn't take it over.
- **On-device intelligence.** The personalized welcome greeting is generated by
  Apple Intelligence **on your device** — even the "smart" touch doesn't phone home.
- **The agent gateway is opt-in and authenticated.** It does nothing until *you*
  connect it (Sign in with Apple), and what it can touch is scoped and logged
  (see §7, §9).
- **Analytics, if any, are anonymous and aggregate** (Plausible), and consented.

One line for the public: **"Your life, in your iCloud. We run no server that can
read it."**

---

## 9. Bring your own AI — modern MCP

The most novel pillar, and the one that ages best. Frame it as *capability +
control*, never as "we built an AI."

**What it is.** The hosted **Septena MCP gateway** (`mcp.septena.app`) exposes your
data to any [Model Context Protocol](https://modelcontextprotocol.io) client —
Claude today — through tools that can **read and write** your sections (tasks,
nutrition, training, habits, supplements, chores, caffeine, cannabis, gut, mood,
hydration, groceries, goals). You connect it; you authorize it; you can revoke it.

**What you can do with it.**
- *"Log this meal from a photo."*
- *"Plot my protein against next-morning HRV for the last month."*
- *"What did I eat the last three times my gut acted up?"*
- *"Summarize my last three months of sleep for my doctor."*
- *"Add these six tasks from the email I just forwarded."*

**Why it's different from every app with a chatbot.**
- **It's your AI, not ours.** Septena doesn't ship a model or a chat box. It
  exposes your data in a shape your agent can use. *(Evolution of the web version's
  "Septena does not ship an agent. It stores your data in a shape yours can use.")*
- **You see what it touched** (§7). Provenance is built in, not bolted on.
- **It writes to the same private store you do.** The agent goes through the
  gateway into *your* iCloud — there's no second, AI-owned copy of your life.

**Positioning line:** *"Your data, your AI, your questions — with a record of
everything it touched."*

> Keep the acronym out of the headline for the QS-plain audience. Lead with
> *"connect your own AI"* / *"ask your data anything"*; introduce "MCP" once, for
> the people who'll perk up at it.

---

## 10. The surface area (grounded — what actually ships)

> Keep this list honest. If a feature isn't here, don't put it in copy. Verified
> against code 2026-06-03.

### Sections (16)
**On by default:** Tasks · Training · Nutrition · Sleep · Habits · Hydration
**Optional (off until you turn them on):** Supplements · Chores · Groceries ·
Caffeine · Cannabis · Body · Gut · Mood · Activity
**Ambient:** Goals (intentions tagged to sections; surfaces inside them)

Every section can be enabled or hidden **without deleting data.**

### What the Week dashboard shows — four reconfigurable layouts
The dashboard isn't one fixed view. You **choose how your week renders**
(Settings → Homepage layout); all four show the same sections in the same order —
only the presentation changes:

- **Histogram** — card grid, a 7-day bar chart + day progress ring per section. The
  glanceable default.
- **Sparkline** — one dense row per section: today's value + a trend sparkline.
  "What are my numbers."
- **Heatmap** — one row per section with a 90-day consistency grid. "Am I being
  consistent?"
- **Correlations** — real cross-section relationships (Pearson r, lag-aware,
  permutation p-values), trusted predictor→target pairs sorted by strength; tap a
  pair for the full detail. A weak or noisy signal is *shown as* weak, not dressed up.

Sections also carry their own visualizations in their detail views — Mood's 30-day
heatmap, Training's volume bars + intensity sparkline, the Caffeine/Cannabis/Gut
activity heatmaps. *(That a user can reshape the whole dashboard between glance,
numbers, consistency, and cause-and-effect is itself a selling point — lead with it.)*

### Integrations
| Source | What comes in | Direction |
|---|---|---|
| **Apple Health** | Steps, active energy, exercise minutes, VO₂ max, HRV, resting HR | Read; writes Mood + Nutrition (opt-in) |
| **Oura** | Sleep score, stages, readiness, HRV, resting HR, bed/wake | Read-only |
| **Withings** | Weight, body fat, body composition | Read-only |
| **Apple Reminders** | A nominated list, imported into Tasks | Read + import |
| **Apple Calendar** | Upcoming events on the dashboard / Next | Read-only |

### Apple platform surface — *full device compatibility is a headline feature*
Septena is native on **every Apple device you own — iPhone, iPad, Mac, and Apple
Watch** — from one SwiftUI codebase, synced through your own iCloud. Most trackers
are iPhone-only or iPhone+Watch; "start a log on your phone, check it off on your
wrist, review the week on your Mac" is a real, ownable differentiator. *Say it loud.*

- **iPhone & iPad** — the full app, adaptive layouts (inspector on iPad, sheet on iPhone).
- **Mac** — native app with sidebar/detail, keyboard commands, **and a menu-bar
  quick-add**: a status-bar item shows today's open items and captures a new to-do
  (⌘N) without opening the window.
- **Apple Watch** — the Next list on your wrist, plus complications.
- **Siri & Shortcuts** — log by voice; 17 App Intents, 10 with built-in phrases
  ("Add to Septena," "Log a supplement," …), the rest assignable in Shortcuts. (App
  Intents also surface in Spotlight.)
- **Home Screen widget** — the Next checklist.
- **Live Activity** — live training session on the Lock Screen / Dynamic Island.
- **8 alternate app icons.**

**Not yet shipping (don't claim):** a Rings/stats widget (only the Next widget ships
today) and explicit Spotlight *indexing* of your entries (App Intents surface in
Spotlight, but logged data isn't indexed).

---

## 11. Voice & tone

The Septena voice is already established in the app and the web copy. Keep it.

**It is:** calm · direct · honest · specific · lightly editorial · confident
without hype.
**It is not:** breathless · clinical/sterile · gamified-cute · jargon-forward ·
guilt-tripping · "your best self" wellness-speak.

Principles:
1. **Specific beats abstract.** *"Espresso at 08:45, filter at 14:00"* and *"the
   dishwasher filter isn't a Tuesday thing"* — concrete, real, a little wry. Not
   *"track your wellness journey."*
2. **First person is allowed and good.** The web copy's *"I did not want five
   apps. I did not want my data sitting in anyone else's database"* is the founder
   talking like a person. Use it where a human voice fits.
3. **Honest about limits.** *"Still early. Correlations get trustworthy around
   ninety days of data."* Underclaiming builds the trust the product is selling.
4. **Short sentences. Real words.** Say "your data is yours," not "data sovereignty."
5. **Name what it's *not*.** *"Today is a verb, not a deadline." "Septena does not
   ship an agent."* Negative space defines the product.
6. **Numbers are mono.** In the *app*, numerics are SF Mono and tabular; in copy,
   respect the same precision — exact, never rounded-up marketing math.

Typographic brand (from [DesignSpec.md](DesignSpec.md)): **Fraunces** (serif, the
single editorial accent — the welcome greeting only) + **SF Mono** (every number) +
**SF Pro** (everything else). *Fraunces-as-accent plus mono-for-numbers is what
carries the brand.* Marketing design should echo that restraint: editorial serif
moment, monospaced figures, calm system sans for the rest.

---

## 12. Messaging bank (by surface & audience)

**Hero / headline candidates**
- Everything you track, one private app.
- Seven days. One view.
- One app for every corner of your life.

**Sub-headlines**
- Tasks, training, food, sleep, habits, and the rest — in your own iCloud, synced
  across your devices, one week at a time.
- The small signals of a whole life, gathered in one calm place — and yours alone.

**The three proof beats (use in this order)**
1. *One app, not twelve.* — "Every corner of your life is a section. Turn on what
   you track; hide the rest without losing a thing."
2. *Your iCloud, not our cloud.* — "Septena runs no server that can read your life."
3. *Your data, your AI.* — "Point your own AI at it — and see everything it touched."

**Platform breadth angle** *(full Apple-ecosystem compatibility — a real differentiator)*
- On every Apple device you own — iPhone, iPad, Mac, and Apple Watch.
- Capture from the Mac menu bar, check it off on your wrist, review the week on your
  iPad. One app, all your screens, synced through your own iCloud.

**Habit / accountability angle**
- Honest streaks — computed from what you actually did. No grace days, no fudging.
- A small, fitting celebration every time you log. Nudges to mark what you did —
  never nagging to do it.

**The "why a week" angle**
- A day is too noisy. A month is too late. A week is where it all connects.
- Does late caffeine cost you sleep? The point of having it all in one place.

**Closers / trust**
- Your data is yours.
- Delete the app and it's still your data, in your iCloud.

---

## 13. What Septena is NOT (say it plainly)

- **Not a coach.** No meal plans, no prescriptions, no programs.
- **Not a social network.** One person, their own data. No feed, no leaderboard.
- **Not a cloud product mining your health data.** There is no Septena server that
  reads your life.
- **Not an AI app.** It doesn't ship a model. It lets *your* AI reach *your* data.
- **Not a single-metric tracker.** It's the *whole* week, related — not just steps,
  or just macros.

---

## 14. Competitive landscape (how we frame the alternatives)

We rarely name competitors in copy; this is internal framing.

- **vs. app sprawl (Strong, MacroFactor, a sleep app, a habit app, Things…):** each
  is good at one thing and blind to the rest. Septena's bet is the *seam between
  them* — the week where they relate. We don't out-feature any single tracker; we
  out-*integrate* them.
- **vs. cloud wellness platforms:** they own your data and shape it for their
  business. Our wedge is **ownership + privacy by architecture.**
- **vs. spreadsheets / Notion / Apple Health itself:** flexible but inert — you do
  all the work and get no synthesis, no streak math, no correlations, no agent
  surface. Septena is structured *and* yours.
- **vs. apps with a bolted-on chatbot:** they give you *their* AI on *their* terms.
  Septena gives you a clean, authorized, provenance-tracked door for *your* AI.

Our durable moats: **breadth × privacy × the agent door.** Any one is copyable;
together, fit to the Apple ecosystem and a coherent design language, they're the
product.

---

## 15. Open questions / to decide

- **Category:** Health & Fitness (primary) vs. Productivity. Recommend **Health &
  Fitness primary, Productivity secondary** — most sections are health/wellness,
  and it's where this buyer browses. *(Confirm in [appstore.md](appstore.md) §8.)*
- **Age rating:** Cannabis + caffeine *logging* (neutral tools, not promotion) still
  has to be declared honestly on Apple's questionnaire → likely **17+.** Decide
  whether that's acceptable or whether Cannabis ships disabled at launch.
- **How loud is the agent story at launch?** It's the most novel pillar but the
  least mature (tasks/nutrition today). Lead with it, or hold it as the "and one
  more thing"? Current call: **third beat, not the headline.**
- **Visual proof of correlations** in screenshots — powerful, but needs ~90 days of
  real data to look honest. Decide whether to show a real account or a curated one.
- **Website scope** for `septena.app` — single landing page (reuse web-version
  copy) vs. per-section pages. The web repo's `marketing-sections.ts` is a ready
  source if we go granular.
```
