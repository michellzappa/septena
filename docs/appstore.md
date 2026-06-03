# Septena — App Store Submission Copy

> Working document for App Store Connect metadata.
> **Draft v0.2 — 2026-06-03.** (v0.1 was 2026-05-31.)
> Positioning now lives in **[marketing.md](marketing.md)** — this file is the
> *application* of it to App Store Connect fields. When the two disagree, fix this
> one. Copy here is verified against shipped features (2026-06-03); claims the app
> doesn't back are removed, not softened.

### What changed from v0.1 (so the diff is legible)
- **Decisions resolved** (were Q1–Q5): audience = *QS enthusiast, plain language*;
  lead hook = *one private app for everything*; pricing = **free**; cannabis =
  *ship, list plainly, don't feature*; name story = *implied*; domains =
  `septena.app` / `mcp.septena.app`.
- **Accuracy:** the one correction vs. v0.1 is that "Insights" is **not a separate
  tab** — it's the **Correlations layout of the Week dashboard**, one of *four*
  homepage layouts (**Histogram / Sparkline / Heatmap / Correlations**). v0.1 was
  right that sparklines, heatmaps, and **Mac menu-bar quick-add** ship — all kept
  and now described properly. (A mid-draft pass had wrongly cut them on a bad code
  search; restored after verifying against `HomepageLayoutMode.swift` +
  `MenuBarMenu.swift`.)
- Reframed the agent pillar honestly (provenance is the differentiator; maturity
  noted). Free CTA throughout.

---

## 0. Positioning in one screen

(Full version in [marketing.md](marketing.md). The essentials, so this file stands alone.)

- **What it is:** one private app for everything you track about yourself — tasks,
  training, nutrition, sleep, habits, hydration, mood, supplements, chores,
  groceries, body, gut, caffeine, cannabis, activity, goals. Each a section you
  turn on or hide without losing data. Organized by the **week**.
- **The hook:** *one private app for everything.* Consolidation + ownership, fused.
- **The three pillars:**
  1. **One app, not twelve.** The Week dashboard synthesizes every section; Next
     tells you what's left today.
  2. **Private by architecture.** Your data lives in *your* iCloud (CloudKit
     private DB), synced across iPhone, iPad, Mac, and Watch. Septena runs no
     server that can read it.
  3. **Bring your own AI.** Optionally point Claude (or any MCP client) at your
     data — with your permission, and a visible record of what it touched.
- **What it's NOT:** not a coach, not a social network, not a cloud product mining
  your health data, not an AI app that ships its own model.
- **Who it's for:** the self-tracker tired of app-sprawl who wants ownership — in
  plain language, no coding required.

---

## 1. App name & subtitle

| Field | Limit | Value |
|---|---|---|
| **App Name** | 30 | `Septena` |
| **Subtitle** | 30 | `Everything you track, one app` (28) · alt: `Your week, in one view` (21) |

> In-app display name is **Septena** (was "Septena Cloud").

---

## 2. Promotional text (170 chars, updatable anytime without review)

> One private place for tasks, training, food, sleep, habits, and the rest — all in
> your own iCloud, synced across your devices, one week at a time. Free.

*(165 chars. The "Bring your own AI" beat lives in the description, not here — too
much to introduce in a promo line for the plain-language audience.)*

---

## 3. Description (4000 chars)

**Septena is one private app for everything you track about yourself.**

Tasks. Training. Nutrition. Sleep. Habits. Hydration. Mood. Supplements. Chores.
Groceries. Body metrics. Caffeine. And more — each one a section you turn on or
hide as you like. No more juggling a dozen apps that never talk to each other.

**Built around the week.**
A day is too noisy and a month is too late. A week is where your sleep, training,
food, and habits start to relate. The Week dashboard brings every section into one
view — and you choose how it renders: a histogram grid, dense sparkline rows, a
90-day consistency heatmap, or a Correlations view that does the math you'd never do
by eye (does late caffeine cost you sleep?). The Next view tells you what's left in
the next 24 hours, learned around your own rhythm.

**Private by design.**
Your data lives in your own iCloud, synced seamlessly across iPhone, iPad, Mac, and
Apple Watch. Septena runs no server that reads your life — there's no company
database to breach or sell. Health metrics from Apple Health are read on your
device. Even the personalized greeting is generated on-device.

**Honest by default.**
Streaks are computed from what you actually did — no grace days, no fudging. Every
time you log something, a small celebration confirms it. Septena nudges you to mark
what you did; it never nags you to do it.

**Bring your own AI.** *(optional)*
Connect the Septena gateway and point Claude — or any AI that speaks the Model
Context Protocol — at your data, with your permission. Ask it to chart protein
against HRV, log a meal from a photo, or draft a health summary for your doctor.
Anything your AI creates is clearly marked, so you always know what it touched.

**Works with what you already use.**
- Apple Health — steps, exercise, VO₂ max, HRV, resting heart rate
- Oura — sleep score, stages, readiness
- Withings — weight and body-composition trends
- Reminders & Calendar — tasks and events on your dashboard
- Siri & Shortcuts — log by voice
- Home Screen widget, Live Activities, and Watch complications

**Everywhere you are.**
Native on iPhone, iPad, Mac, and Apple Watch — your whole week on every screen you
own, synced through your own iCloud. Capture a to-do from the Mac menu bar, check off
your day from your wrist, glance at the Next widget on your Home Screen, and log by
voice with Siri.

**Free.**

*Sections:* Tasks · Training · Nutrition · Sleep · Habits · Hydration · Mood ·
Supplements · Chores · Groceries · Body · Gut · Caffeine · Cannabis · Activity ·
Goals

> Cannabis is listed plainly as one logging section (per positioning) but kept out
> of the hero copy and screenshots.

---

## 4. Keywords (100 chars, comma-separated, no spaces)

`habit tracker,quantified self,health,nutrition,macros,sleep,training,self tracking,wellness,journal,log`

> Don't repeat the app name or subtitle words. Singular forms (Apple auto-handles
> plurals). Tune against ASO once live. ~96 chars; room to swap one term.

---

## 5. What's New (version notes)

> First release:
> Welcome to Septena. One private place for everything you track about yourself —
> tasks, training, food, sleep, habits, and more — across iPhone, iPad, Mac, and
> Watch. Your data, in your iCloud. Free.

---

## 6. Privacy (App Privacy "nutrition label" + policy)

Our story is unusually clean — it's the architecture, not a promise:

- **Data stored in the user's private iCloud (CloudKit private DB).** Septena the
  company does not collect or have access to it. Most data types map to **"Data Not
  Collected."**
- **HealthKit data** is read on-device; disclose read types (steps, exercise, VO₂
  max, HRV, resting HR) and writes (Mood, Nutrition). HealthKit data is not used for
  tracking/advertising and not sold.
- **Third-party imports** (Oura, Withings) via user-authorized OAuth; read-only.
- **MCP gateway** access is user-initiated, authenticated via Sign in with Apple,
  scoped, and provenance-logged; document exactly what it can touch.
- **Analytics** (if enabled): anonymous, aggregate (Plausible), consented.

Required artifacts:
- HealthKit usage strings — **already in app.**
- **Privacy Policy URL:** `septena.app/privacy` **[create]**
- **Support URL:** `septena.app/support` (or `mailto:mz@envisioning.com` as
  fallback — already the in-app feedback target).

---

## 7. Decisions — RESOLVED (kept for the record)

- **Q1 Audience/tone → QS enthusiast, plain language.** Broad enough for the Store,
  true to the product; "bring your own AI" is a delighter, not a gate.
- **Q2 Privacy emphasis → folded into the #1 hook.** Not a standalone pillar — it's
  *in* "one **private** app for everything."
- **Q3 Cannabis → ship, list plainly, don't feature.** Affects age rating (see §8).
- **Q4 Pricing → free (v1).** CTA "Download." No paywall narrative.
- **Q5 Name story → implied.** "One week at a time" carries it; no "seven = heptad"
  lecture in the listing.
- **Domains → `septena.app`** (marketing/support/privacy), **`mcp.septena.app`**
  (gateway).

---

## 8. Submission checklist

**Copy (above):** name · subtitle · promo · description · keywords · what's new ✅ drafted

**Categorization**
- [ ] **Primary category: Health & Fitness.** Secondary: **Productivity.**
      (Most sections are health/wellness; it's where this buyer browses.)
- [ ] **Age rating:** answer the questionnaire honestly — Cannabis + caffeine
      *logging* likely lands at **17+** (Infrequent/Mild–to–Frequent drug
      references). **[DECIDE: accept 17+, or ship Cannabis disabled at launch.]**

**Assets**
- [ ] App icon (1024×1024) — 8 alternates already in app
- [ ] Screenshots: iPhone 6.9" & 6.5", iPad 13", Mac, (Watch optional) — **lead with
      the Week dashboard + Next; do not feature Cannabis**
- [ ] App preview video (optional)
- [ ] Privacy Policy URL + Support URL (`septena.app/...`)

**Screenshot guidance**
- [ ] Demo all four dashboard layouts (Histogram / Sparkline / Heatmap /
      Correlations) — reconfigurability shows well.
- [ ] Mac shots *should* feature the **menu-bar quick-add** — it's a real
      differentiator; show the full device spread (iPhone + iPad + Mac + Watch).
- [ ] Correlations shots need a real ~90-day account to look honest.
- [ ] Don't imply a Rings/stats widget — only the Next widget ships today.

---

## 9. Source notes
- Positioning, voice, full pillar/feature reasoning, messaging bank: **[marketing.md](marketing.md)**.
- Feature ground-truth verified against code 2026-06-03 (sections, integrations,
  Apple surface, correlations engine, streaks/celebrations, agent provenance).
- Inherited web copy worth reusing on `septena.app`: `../septena-app`
  (`components/marketing-page.tsx`, `lib/marketing-sections.ts`).
