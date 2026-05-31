# Septena — App Store Submission Copy

> Working document for App Store Connect metadata. Draft v0.1 — 2026-05-31.
> Status: positioning + first-pass copy. Open decisions marked **[DECIDE]**.

---

## 0. The WHY (positioning foundation)

Everything below flows from this. We write the copy once we agree on the why.

### The problem
You track yourself across a dozen apps — one for workouts, one for macros, one
for sleep, one for habits, a notes file for supplements, your head for the rest.
The data never sits in one place, so you never see how it relates. And it all
lives in someone else's database, shaped for their business, not your questions.

### The insight (the name)
**Septena** = seven (heptad). The unit is the **week**, not the day or the month.
A day is too noisy; a month is too late. **A week is where sleep, training, food,
and habits start to relate to each other.** Seven dots in the mark, seven days in
the view. This is the spine of the product — the **Week** tab is the home screen.

> One-liner candidates:
> - "Seven days. One view." *(inherited from the web version — still the best)*
> - "Your whole week, in one place."
> - "Everything you track about yourself, one week at a time."

### What Septena is
One private app for every corner of your life you actually pay attention to —
tasks, training, nutrition, sleep, habits, hydration, mood, supplements, chores,
groceries, body, gut, caffeine, and more. Each domain is a **section** you can
turn on or hide without losing data. The Week dashboard synthesizes them; the
Next view tells you what to do in the next 24 hours; Insights surfaces the
cross-section correlations (does late caffeine cost you sleep?).

### What makes it different (the three pillars)
1. **One week, one view.** Not 12 apps. Not a daily grind or a monthly report —
   the cadence where signals actually connect.
2. **Private by architecture.** Your data lives in *your* iCloud (private
   database), synced across iPhone, iPad, Mac, and Watch. Septena runs no server
   that sees your data. *(Re-frames the web version's "JSON on your machine" for
   the Apple ecosystem.)*
3. **Bring your own agent.** The optional Septena MCP gateway lets Claude (or any
   MCP client) read and write your data with your permission — "plot my protein
   against next-morning HRV," "log this meal from a photo," "summarize my last
   three months of sleep for my doctor." Your data, your AI, your questions.

### What it is NOT
- Not a coach. No meal plans, no prescriptions, no nags.
- Not a social network. One person, their own data.
- Not a cloud product mining your health data. **[DECIDE: how hard to lean on this]**

### Who it's for
**[DECIDE]** The web version was explicitly "for technical users who'll clone a
repo." The App Store can't be that narrow. Candidate framing: *the
quantified-self / self-tracking enthusiast who's tired of app sprawl and wants
ownership* — broad enough for the Store, true to the product. (See Q1.)

---

## 1. App name & subtitle (App Store Connect fields)

| Field | Limit | Draft |
|---|---|---|
| **App Name** | 30 chars | `Septena` |
| **Subtitle** | 30 chars | `Your week, in one view` (21) · alt: `Everything you track, one app` (28) |

> Note: display name in-app is now **Septena** (was "Septena Cloud" — renamed).

---

## 2. Promotional text (170 chars, updatable anytime without review)

Draft:
> One private place for tasks, training, food, sleep, habits, and the rest —
> synced across your devices, one week at a time. Bring your own AI.

---

## 3. Description (4000 chars)

> Draft — long form. Tighten after positioning is locked.

**Septena is one private app for everything you track about yourself.**

Tasks. Training. Nutrition. Sleep. Habits. Hydration. Mood. Supplements. Chores.
Groceries. Body metrics. Caffeine. And more — each one a section you turn on or
hide as you like. No more juggling a dozen apps that never talk to each other.

**Built around the week.**
A day is too noisy and a month is too late. A week is where your sleep, training,
food, and habits start to relate. The Week dashboard brings every section into
one view — bar charts, sparklines, consistency heatmaps, and correlations, your
choice. The Next view tells you what's left in the next 24 hours. Insights shows
you the patterns across sections you'd never spot by eye.

**Private by design.**
Your data lives in your own iCloud, synced seamlessly across iPhone, iPad, Mac,
and Apple Watch. Septena runs no server that reads your life. Health and recovery
metrics from Apple Health stay on your device.

**Bring your own AI.** *(optional)*
Connect the Septena MCP gateway and point Claude — or any MCP client — at your
data, with your permission. Ask it to chart protein against HRV, log a meal from
a photo, or draft a health summary for your doctor. Your data answers your
questions.

**Works with what you already use.**
- Apple Health — steps, exercise, VO₂ max, HRV, resting heart rate
- Oura — sleep score, stages, readiness, stress
- Withings — weight and body composition trends
- Reminders & Calendar — tasks and events on your dashboard
- Siri Shortcuts — log anything by voice
- Live Activities, Home Screen widgets, and Watch complications

**Everywhere you are.**
Native on iPhone, iPad, Mac, and Apple Watch. Quick-add from the Mac menu bar,
check off your day from your wrist, log on the go.

*Sections included:* Tasks · Training · Nutrition · Sleep · Habits · Hydration ·
Mood · Supplements · Chores · Groceries · Body · Gut · Caffeine · Activity ·
Goals · Insights **[DECIDE: list Cannabis? see Q3]**

---

## 4. Keywords (100 chars, comma-separated, no spaces)

Draft pool (pick ≤100 chars):
`habit tracker,quantified self,health,nutrition,macros,sleep,training,journal,self tracking,wellness,log`

> Notes: don't repeat the app name or subtitle words. Singular forms; Apple
> auto-handles plurals. Tune against ASO once positioning is set.

---

## 5. What's New (version notes)

> First release. Draft:
> Welcome to Septena. One private place for everything you track about yourself —
> tasks, training, food, sleep, habits, and more — across iPhone, iPad, Mac, and
> Watch.

---

## 6. Privacy (App Privacy "nutrition label" + policy)

App Store Connect requires a per-data-type privacy disclosure and a privacy
policy URL. Our story is unusually clean:

- **Data stored in user's private iCloud (CloudKit private DB).** Septena the
  company does not collect or have access to it.
- **HealthKit data** is read on-device; disclose read types (steps, exercise,
  VO₂ max, HRV, resting HR) and any writes (Mood).
- **Third-party imports** (Oura, Withings) via user-authorized OAuth.
- **MCP gateway** access is user-initiated and authenticated via Sign in with
  Apple; document exactly what it can touch. **[DECIDE: privacy-policy URL]**

Required: HealthKit usage strings (already in app), a public **Privacy Policy
URL** and **Support URL**. **[DECIDE: which domain — septena.app?]**

---

## 7. Open decisions

- **Q1 — Audience/tone:** power-user/quantified-self vs. broader wellness?
- **Q2 — Privacy emphasis:** lead with it as the #1 pillar, or keep it as one of
  three?
- **Q3 — Cannabis section:** Apple scrutinizes drug-related content. Include it in
  the marketing copy / screenshots, ship it but don't market it, or gate/omit for
  v1?
- **Q4 — Pricing/model:** free, one-time, or subscription? (Changes CTA + "what's
  new" framing and whether we need an onboarding paywall.)
- **Q5 — Name origin in copy:** do we explicitly tell the "seven = week" story in
  the description, or just let "one week at a time" imply it?
- **Domains:** marketing/support/privacy URLs (septena.app? mcp.septena.app is
  the gateway).

---

## 8. Assets checklist (not copy, but needed for submission)

- [ ] App icon (1024×1024)
- [ ] Screenshots: iPhone 6.9" & 6.5", iPad 13", Mac, (Watch optional)
- [ ] App preview videos (optional)
- [ ] Promotional text, description, keywords (above)
- [ ] Privacy policy URL + support URL
- [ ] Age rating questionnaire **[Cannabis/caffeine answers affect this]**
- [ ] Category: primary **Health & Fitness**? or **Productivity**? **[DECIDE]**
