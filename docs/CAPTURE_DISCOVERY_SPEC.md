# Capture Discovery & Teaching Spec

How Septena teaches the *ways data gets in* — without a tour, without nagging.
Working doc; pre-implementation. Companion to `FRONT_DOOR_IDENTITY.md` (identity
arc), `QUICK_ADD_CONTRACT.md` (the in-app log surfaces), and
`APP_INTENTS_BACKLOG.md` (the Siri/Shortcuts surface). Voice and budget inherit
`../septena-site/docs/THE_INSTRUMENT_MANIFESTO.md`.

Status: **plan / pre-implementation.**

---

## 0. Premise

A log is a vote. Every capture surface — manual, voice, photo, widget, watch,
MCP — is just a different door to the same vote. The job of this spec is to make
the *faster doors* discoverable to the people ready for them, while keeping the
first-run experience calm enough that the instrument never feels like a tutorial.

Two forces in tension:

- **Anti-nag.** "Nudge to mark, don't nag to do." A six-screen feature carousel
  is the single most off-brand thing the app could ship. The core loop must need
  zero explanation.
- **Discoverability.** Apple's capture surfaces (Siri phrases, App Intents,
  widgets, Live Activities, the menu-bar add, Spotlight) and the MCP gateway have
  near-zero unaided discovery. "Septena meets your Apple life where it already
  is" is a marketing pillar; teach none of it and the pillar is hollow.

Resolution: **tier the teaching to the mode.** One onboarding step, zero tutorial
for the core loop, everything else earned just-in-time or pulled on demand.

---

## 1. The four capture modes

| Mode | Examples | Discovery risk |
|---|---|---|
| **1. By hand** | per-section tile menu + in-section "+", `AddInfo` ⌘K palette | none — it's the primary UI |
| **2. By voice / photo / AI** | Siri phrase, photo→meal, MCP/Claude write | high — invisible until named |
| **3. Other Apple surfaces** | Watch, Home/Lock widget, Live Activity, Mac menu bar, Spotlight | very high — Apple's own discovery is poor |
| **4. Pulled in automatically** | Apple Health, Oura, Withings, GitHub, Readwise, Reminders, Calendar, Photos | medium — a one-time setup decision |

---

## 2. Teaching tiers (mode → mechanism)

| Mode | Mechanism | Rule |
|---|---|---|
| 1. By hand | **Zero tutorial.** Ghost empty states + one-line section hint. | If logging needs a tour, the screen failed. |
| 2. Voice/photo/AI | **Earned just-in-time nudge** in the Next feed, fired on a usage signal. | Never before the user has done the manual version of that action. |
| 3. Apple surfaces | **Earned nudge + a pull reference** ("Ways to capture" in Settings). | Slightly more proactive than mode 2 (discovery is near-zero), still behavior-gated, never at signup. |
| 4. Imports | **One onboarding step**, skippable, re-accessible in Settings. | The only legitimate first-run teaching moment. |

The whole spec is: **one connect-your-data step + earned nudges + a pull-based
reference.** No carousel, ever.

---

## 3. What already exists (ground truth)

- **First-run welcome** — `Septena/Shell/Onboarding/WelcomeView.swift`. Blank-slate
  section picker, gated on `SettingsKey.welcomeCompleted` / synced `onboardedAt`.
  On Continue it enables picked sections and **chains each one's first-enable
  onboarding sheet**, then `openFirstLog` opens the `AddInfo` quick-add for the
  first picked section (`nav.pendingFirstLog → addInfoRequestedSection`). This is
  the spine new pieces hang off — do not replace it.
- **Per-section onboarding scaffold** — `Septena/Shell/Sections/Plugins/SectionOnboarding.swift`.
  The ONE scaffold; explainer bullets + optional starter catalog, with
  `OnboardingChainContext` ("Step N of M", "Skip all"). Capture-mode teaching must
  reuse this chrome, not add a second scaffold.
- **Quick-add contract** — `QUICK_ADD_CONTRACT.md`. Tile context-menu (capped
  suggestions + one escape row) and the in-section "+". Mode 1 is already solved.
- **App Intents** — 20 intents across 13 loggable sections, 10 curated "Hey Siri"
  phrases, gated to enabled sections in lockstep with MCP
  (`MCPToolCatalog.manifest(enabledSections:)`). The surface exists; nobody knows
  the phrases.
- **Celebration budget** — `FRONT_DOOR_IDENTITY.md`. Everyday logs are quiet
  (`SectionLog.quietLog`); flourishes are reserved for earned moments. Teaching
  nudges inherit the same discipline (see §6).
- **NextScoring / Next feed** — the surface a teaching nudge rides on, the same
  place the manifesto's "never miss twice" nudge (Ch 8) will live.

Gaps this spec fills: (a) imports have **no** connect step in the welcome chain;
(b) there is **no** just-in-time teaching of any mode-2/3 surface; (c) there is
**no** in-app "ways to capture" reference.

---

## 4. Tier 1 — the one onboarding step (imports)

Add a single **"Connect your data"** step to the `WelcomeView` chain, after the
section picker and before the first-log handoff. It is not a feature tour; it is
the setup decision that is genuinely awkward to discover later and that makes the
dashboard non-empty on day one.

- **Contextual, not exhaustive.** Show only the providers relevant to the sections
  the user just picked: Sleep → Oura; Body → Withings; Activity → Apple Health;
  Tasks → Reminders import; GitHub → token. If they picked none of those sections,
  skip the step entirely.
- **Skippable and reversible.** "Connect later" is a first-class button. Every
  provider is re-connectable from Settings ▸ Integrations. Honor the manifest
  invariant: connecting never deletes, disconnecting never deletes.
- **One screen, grouped.** "Bring your numbers in" — a list of relevant providers
  with a connect toggle each, mirroring the site's `/integrations` "bring your
  data in" group. Reuse `SectionOnboarding`'s scaffold chrome as a chain step.

This is the *only* push-style teaching in the whole spec, and it earns its place
because it is configuration, not education.

---

## 5. Tier 2/3 — earned just-in-time nudges

A teaching nudge is a Next-feed card that surfaces *one faster door* at the moment
a usage signal says the user is ready. It is dismissible-forever, capped hard, and
fired only for surfaces that actually exist for that user (§7 honesty gate).

### Trigger table

| Surface | Eligibility signal | Fire moment | Copy (draft — voice per manifesto) | Cap |
|---|---|---|---|---|
| **Photo → meal** | ≥5 meals logged **by hand**, no photo used | after a manual meal save | "Next time, just snap it. Septena can read a meal from a photo." | once; dismiss = never |
| **Siri phrase** | ≥10 logs in a section that has a phrased intent | start of a high-log day | "You can log this by voice. Try 'Add to Septena.'" | once per phrased section, global cap 1 |
| **Home/Lock widget** | opens app ≥2×/day to check Next, ≥7-day streak | after viewing Next | "Put Next on your Home Screen. Glance, don't open." | once |
| **Live Activity** | logs a training session by hand ≥3× | at session start | "Want this live on your Lock Screen while you train?" | once |
| **Apple Watch** | Watch paired + ≥14 days of use | quiet slot | "Log from your wrist — the Next list is on the watch." | once |
| **Mac menu bar** | Mac app launched | first Mac session | "Septena lives in your menu bar. ⌘N adds without leaving your app." | once |
| **MCP / Claude** | ≥30 days of use, OR has connected ≥1 integration | Settings visit | "Connect Claude — log and ask about your life in plain language." | once; also permanent in Settings |

Signals are all available: per-section log counts (mirror), day streak
(`DayClock`), device capability (Watch paired, running on macOS), connection
state. None require new telemetry.

### The "shrink the vote" cousin

These nudges are mechanically the same surface as the manifesto's mode-2 ideas
("never miss twice", "shrink the vote", learned fire-times). Build the
teaching-nudge plumbing as a **general Next-feed insight card** with a budget and
a dismiss ledger, so all of them share one mechanism rather than each shipping its
own banner.

---

## 6. The teaching budget (so nudges never become nags)

Mirror the celebration budget. Hard rules:

- **At most one teaching nudge live at a time**, app-wide.
- **At most one new teaching nudge per ~7 days.**
- **None in the first 3 days** of use (let the core loop settle first).
- **Every nudge is dismiss-forever**, recorded in a synced dismiss ledger (same
  shape as the `onboardedAt` marker) so it never returns on another device.
- **A nudge that's been shown but not acted on retires after one appearance** —
  it does not re-surface to "try again." The reference page (§8) is where a
  curious user goes back.
- **Skip is data, not shame** — declining a nudge is silent; no follow-up, no
  badge, no "you're missing out."

If the budget and the "never miss twice" nudge ever contend for the one slot,
**identity protection wins** — teaching is always lower priority than the vote.

---

## 7. Honesty gate

Never teach a door that isn't there for this user. Before any nudge or reference
row renders, assert:

- The surface is **shipped and enabled** for the section (e.g. only the 10 phrased
  intents advertise a Siri phrase; only Nutrition advertises photo→meal).
- The **capability exists on the device** (Watch paired; macOS for the menu bar).
- The section is **enabled** (a disabled section advertises nothing — same gate as
  MCP/App Intents, `SeptenaServices.isSectionEnabled(_:)`).

Same rule as the manifesto's: never assert ahead of the code. A nudge for a
surface that's mid-rollout (voice, Health write) waits for the surface to land.

---

## 8. The pull reference — "Ways to capture" (Settings)

One discoverable page for the user who goes looking, the in-app twin of the
marketing capture explainer. Lives in Settings (slot it in the
`SETTINGS_REORG_PROPOSAL.md` structure). Four sections matching §1, each row:
what it is, one line of how, a connect/enable affordance where relevant.

- This is **pull, never push** — nothing links to it unbidden except a single
  quiet "see every way to log" footer on the Next feed.
- It doubles as the **escape hatch** for any nudge the user dismissed: the door is
  always here even if the just-in-time card retired.
- Keep it data-driven off the same capture catalog (§10) so it can't drift from
  what the app actually ships.

---

## 9. Anti-patterns (explicitly out of scope)

- A multi-screen feature carousel at first launch.
- Any modal listing surfaces the user hasn't earned context for.
- Coach-mark / tooltip-tour overlays — the opposite of calm.
- Teaching mode 2/3 before the user has done the manual version.
- Re-surfacing a dismissed nudge to "remind" them.
- A red badge or count on the "Ways to capture" entry.

---

## 10. One catalog, shared

Define the capture surfaces once — `{ mode, surface, sectionScope, eligibility,
copy, shippedFlag }` — and read it from three places: the nudge engine (§5), the
Settings reference (§8), and (mirrored, by hand for now) the site's capture page.
Same lockstep discipline as the MCP / App Intents catalog: a surface that ships
updates the catalog, the Settings page, and the marketing copy in one change.

---

## 11. Open questions

- **Connect-your-data step placement** — inside the welcome chain (one more "Step
  N of M") vs. a distinct screen after it? Leaning inside the chain for chrome
  consistency.
- **MCP nudge threshold** — is "30 days of use" the right power-user gate, or
  should connecting any integration alone qualify? Probably the latter is the
  stronger intent signal.
- **Does the teaching-nudge engine ship before or after "never miss twice"?**
  They share plumbing; building the general insight-card budget first unblocks
  both. Recommend the engine first, "never miss twice" as its first consumer,
  teaching nudges second.
- **Voice nudge gating** — hold until the Siri/voice path is verified shipped per
  section (currently 🟡 in the site's catalog).

---

## 12. Build sequencing

1. **General Next-feed insight card + budget + synced dismiss ledger** (§6). The
   shared mechanism. Unblocks teaching nudges *and* "never miss twice".
2. **Connect-your-data welcome step** (§4). Highest-leverage single addition;
   makes day-one dashboards non-empty.
3. **"Ways to capture" Settings reference** (§8) + the shared catalog (§10).
4. **Teaching nudges**, cheapest first: photo→meal and Siri phrase (signals and
   surfaces already exist), then widget / Live Activity / menu bar.

Nothing here needs a CloudKit schema change beyond the dismiss ledger marker.
