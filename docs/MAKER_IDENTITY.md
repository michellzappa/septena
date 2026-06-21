# Maker identity & voice

The single source of truth for how Michell ("mz") shows up across Septena — the
app, the website, support, the journal, and any longer-form writing. This is the
`DesignSpec.md` of voice: surfaces don't invent their own maker copy, they pull
the facts and blocks from here so the story stays consistent and **every claim
stays inside what the data supports.**

Referenced from:

- `CLAUDE.md` → Conventions (one pointer line)
- `docs/DesignSpec.md` → a "Voice" note (one pointer line)
- `../septena-site/docs/marketing.md` → the marketing source of truth (one pointer line)

If you change a fact or a copy block here, the surfaces are downstream — grep for
the block and update each, same change. Treat this like a hotspot file.

---

## 1. The facts — never exceed these

Every maker claim must trace to a row here. Numbers are a **snapshot** (git as of
2026-06-21); they're for storytelling, not a live readout — restamp when you cite
fresh ones, don't pretend they're current if they're old.

| Claim you may make | The data behind it |
|---|---|
| Built by one person | Across every repo, every commit is mine. Native: 1,039 mine + 50 from `envisioning-agent`, an automation I wrote. Webapp pilot: 242. No other human contributor. |
| Piloted as a webapp, then rebuilt native | A Next.js + FastAPI pilot ("Setlist", `../septena-app`) ran Apr 19 → May 24, 230 commits. Its final commit exports data to bootstrap the iOS CloudKit build — the pilot fed the rebuild. The shipping app is the native version. |
| Built fast, with AI | ~1,080 commits in the native app + 230 in the pilot (~1,310 app commits; ~1,410 incl. gateway + site), all inside ~11 weeks (Apr 4 → Jun 21 2026) — only possible paired with AI |
| Evenings and weekends | Holds in **both** repos. Native: peaks 8–11pm (9pm = 131), Sat (199) + Sun (207) biggest. Pilot: single biggest day is Sunday (65). |
| **Not** a night owl | **Zero** commits between 1am and 6am — in *either* repo. None. |
| Built in the open | Public repo (`github.com/septena/septena`), MIT-licensed — every line that touches your data is readable |
| Private by design | Local-first, CloudKit private DB, no third-party analytics, no investors, no growth team |
| The numbers are trustworthy | `septena-cloud` has a single root + linear history; going open source rewrote hashes via `filter-repo` (secrets + PII scrub) but **preserved author dates**, so its counts/dates are real. Its ancestor is the private `engage-app` repo (the original Engage code) — `septena-cloud` is its renamed public continuation, so do **not** add engage-app's commits (they already live inside septena-cloud's early history). |

### The build, in three phases (day counts, for the record)

| Phase | What it was | Window | Days | Commits |
|---|---|---|---|---|
| 1 · **Engage** | a focused, Things-3-style **task manager** — its tasks/areas/projects engine *is* Septena's task section today | Apr 4–6 (initial build) | **3** | 53 |
| 2 · **Setlist** | the webapp pilot (Next.js + FastAPI) — proved the broader life-tracking idea on myself | Apr 19 – May 24 | **35** | 230 |
| 3 · **Septena** | the native build: Engage's task engine + Setlist's domain, rebranded onto CloudKit | May 13 – Jun 21 (ongoing) | **39** | ~1,030 |

Engage was **not** a wrong turn — it's the foundation Septena is still built on
(the rebrand `Engage → Septena` literally renames the same codebase). Between the
Engage burst and the pilot the native app paused, but I wasn't idle: ~125 commits
landed across **six other projects** in those ~12 days (day job at Envisioning —
signals / research / .com — plus an Amsterdam event app, an iOS app, and site
work). The "merge" was manual: on **May 13** Engage was rebranded and fused with
what the webapp proved; the FastAPI seam was deleted **May 24**, the same day the
pilot's last commit exported its data to seed CloudKit. Net: ~1,310 app commits
across 78 days (~11 weeks), one person — *3 days to stand up the task engine, 35
to prove the wider idea, 39 to build it for real.*

**Canonical build visual:** a stacked **daily commit-volume** chart over Apr 4 →
Jun 21 (series: Engage, Septena native, Setlist pilot, other projects), with the
① May 13 rebrand and ② May 24 handoff marked. The bars *are* the data — height =
commits that day — so the phases read off the shape. Fully reproducible from git
(`git log --since=2026-04-04 --until=2026-06-22 --date=short --pretty=%ad | sort |
uniq -c` per repo). Use this for the site `/about` and the book lede, not the flat
phase ribbon.

> **Canonical origin story — DECIDED (2026-06-21): the pilot → rebuild arc.**
> Lead with it everywhere. The literal git arc is *a 3-day task-manager
> foundation (Apr 4–6, "Engage") → webapp pilot (Apr 19–May 24, Next.js +
> FastAPI) → native rebuild on CloudKit (May 13 → Jun 21)*, but the **story we
> tell** is "I piloted it as a webapp on my own life, then rebuilt it native."
> Engage is a good origin detail for the book — Septena grew out of a task
> manager I built first, not a blank page — but the headline stays the pilot →
> rebuild arc. That's honest (the pilot's last commit
> really does export data to seed the native build) and it's the strongest indie
> framing: validate first, build for real second. The graph reflects this (two
> chapters). Honest nuance to preserve: the *dead zone* (1–6am) and the weekend
> skew hold in both repos, but the peak hour shifted — pilot skewed mornings,
> native skews evenings. Don't claim "always evenings"; claim "always waking
> hours, never the night."

### Block G — the origin line (canonical, for site /about, book lede, press)

> For five weeks Septena was a scrappy Next.js webapp I tested on my own life.
> When it proved itself, I rebuilt it native for Apple — and the pilot's last act
> was exporting my data to seed it.

For Phase 2, weave Block G into Block B (the long maker's note) — the website is
where the arc gets told in full.

### Banned claims (untrue or off-voice)

- ❌ "late nights", "3am", "midnight", "all-nighters", "burning the candle" — **the data says he sleeps.** This is the one the user called out by name.
- ❌ "fueled by coffee/caffeine" as a grind trope (the caffeine data is real, but it's "two cups, never past three" — a *restraint* story, not a hustle one; see the journal post of that name)
- ❌ "team", "we", "our engineers" — it's one person; "I" or "Septena"
- ❌ hype: "revolutionary", "game-changing", "the only app you'll ever need"
- ❌ fake scarcity / fake urgency / countdown timers
- ❌ guilt or manipulation around patronage — it gates nothing (see block C)

---

## 2. The voice

Codify what the existing journal already does well (see
`../septena-site/content/journal/`). Hold every surface to it.

- **First person, signed.** "I built this." Sign maker moments `— mz` or
  `— Michell`. Never corporate third-person about myself.
- **Dry and understated.** Let the facts carry it. "The wins weren't the big
  weeks. They were the un-skipped Tuesdays." Under-claim, never over-claim.
- **Honest, including the unflattering part.** The journal admits the protein
  miss. Maker copy can admit rough edges. Honesty *is* the brand.
- **Data-named, not vibes.** When you reach for a number, use a real one from §1
  (or the app's own data). No round-number theater.
- **Solo + AI stated plainly,** never apologized for and never bragged about.
  It's just how it's made.
- **Sentence case. Two weights. No emoji in product chrome.** (matches DesignSpec)

---

## 3. Reusable copy blocks

Canonical wording. Reuse verbatim where it fits; adapt length, not meaning.

### Block A — Maker's note (short, for the in-app About pane)

> **Made by one person.**
> Hi, I'm Michell. Septena is built by me alone, with AI as my pair-programmer.
> No team, no investors, no analytics watching you. If something's rough, that's
> on me; if something's thoughtful, it's probably the part I use every day too.
> — mz

### Block B — Maker's note (long, for the website /about and /ownership)

> I built Septena in about eleven weeks of evenings and weekends — a thousand-odd
> commits, one person, with AI doing the parts of the typing I'd otherwise still
> be doing. I'm not a night owl about it; the work happens after dinner and on
> Saturdays, and the repo is public so you can check. I made it because I wanted
> one private place for everything I track, and nothing on the market was mine
> enough. It still is — local-first, open, no investors to answer to but you.
> — Michell Zappa

### Block C — Patronage / the AI-bill joke (Support / Septena+)

> Septena is free and stays free. If you want to chip in: I build this with a lot
> of AI help, and the AI bill is the one part that was never free. Patronage keeps
> the tokens flowing. You get a badge. That's the whole deal — no features held
> hostage, nothing unlocked, nothing nagged.

This is funny **because it's literally true**: the real cost of building this way
is API spend, not server farms or salaries. Keep it dry; don't oversell it.

### Block D — Built in the open (trust pillar, reusable one-liner)

> A thousand-plus commits, all public. You can read every line that touches your
> data — `github.com/septena/septena`.

### Block E — Changelog & journal sign-off voice

First-person highlights, not release-bot. "I finally killed the iPad freeze that
was driving me nuts." The changelog is authored from git, by a person — let it
sound like one. (See `docs/VERSIONING.md`; changelog lives in
`Septena/Resources/changelog.json`.)

### Block F — Support identity (decision needed)

Today the maintainer role renders as **"Septena"**
(`SupportSettingsPane.swift` → `roleLabel`). Options:
- keep "Septena" (clean, scales if there's ever help), or
- show **"Michell"** (more personal, matches "you're emailing the guy who made it").

Recommendation: keep the role label "Septena" in the thread UI, but add one line
to the support intro — *"You're reaching me directly — I'm the only person here."*
— so it's personal without pretending the support desk is a brand.

---

## 4. Surface map

Where the identity appears, which block, which repo/file, current state.

| Surface | Repo · file | Block | Status |
|---|---|---|---|
| About pane (maker's note) | cloud · `AboutAdvancedSettingsPanes.swift` ("From the maker" section) | A | **done** (iOS+Mac green 2026-06-21) |
| Patronage / Septena+ | cloud · `SettingsPanes.swift` (`SeptenaPlus.reasons` → "Pays the AI bill") | C | **done** (iOS+Mac green 2026-06-21) |
| Support intro line | cloud · `SupportSettingsPane.swift` (ticket footer + email fallback) | F | **done** (iOS+Mac green 2026-06-21) |
| Changelog voice | cloud · `Septena/Resources/changelog.json` | E | ongoing, tighten |
| Website /about | site · `app/about/page.tsx` | B + D | review vs. this doc |
| Website /ownership | site · `app/ownership/page.tsx` | B + D | review vs. this doc |
| Website /support | site · `app/support/page.tsx` | C + F | reframe |
| Website /supporters | site · `app/supporters/page.tsx` | C | review |
| Journal | site · `content/journal/*.md` | E + §2 | **live, on-voice — keep cadence** |
| Marketing source of truth | site · `docs/marketing.md` | all | add pointer to this doc |
| Book proposition | see §6 | B + §2 | proposal only |

---

## 5. Rollout plan (phased)

Each phase is independently shippable. Land green; don't batch across repos.

**Phase 1 — In-app (cloud repo).** Highest signal, lowest risk.
1. Add a `MakersNote` section (Block A + Block D link) to the About pane.
   Wire into `SettingsView` / `AboutAdvancedSettingsPanes`. The Source-code link
   already exists — sit the human next to it.
2. Reframe the patronage copy to Block C in the support/Septena+ pane.
3. Add the Block F intro line to support.
4. One verifying build (`scripts/build.sh`, then Mac scheme). Leave green.

**Phase 2 — Website identity (site repo).** Bring /about, /ownership, /support,
/supporters into line with Blocks B/C/D/F. Add the pointer line to
`marketing.md`. The more-prominent "me" the user wants lives here, not in the app.

**Phase 3 — Journal cadence.** Already live and on-voice. Formalize: a post per
release or per genuine inflection, always data-named, always honest about the
miss. Reuse the `cards` mechanism (charts from real series). The journal is the
engine of build-in-public; everything else points back to it.

**Phase 4 — Book proposition.** §6. Proposal first, no writing committed.

**Coordination, every phase:** if you touch a block here, update §4's status
column and the downstream surface in the same change. This doc is the spine.

---

## 6. Book proposition (sketch — for discussion, not yet a commitment)

**Working angle:** *not* a hustle-porn "I shipped in a weekend" story. The honest
craft version: one person, a clear personal need, AI as a real collaborator, and
what it's actually like to build software this way in 2026.

**Working title candidates:** *A Life, Logged* · *One Private App* · *Built in
Evenings* (lean on the data — the title can be true to the 8pm-not-3am reality).

**Why it's credible:** the whole thing is on the record. 1,080 public commits, a
running journal, a real app people use, real personal data driving the decisions.
The book doesn't have to invent a narrative — it can be *read off the repo and the
logs*, which is itself the interesting argument: that a single person plus AI plus
honest measurement is now enough to make a real thing.

**Spine (maps to the data we already have):**
1. The itch — wanting one private place for everything (ties to §1 "private by design")
2. The method — log first, change nothing, "steer what you can see" (the journal's own thesis)
3. The pace — evenings and weekends, not all-nighters (the hour/weekday graph *is* a chapter)
4. The collaborator — what AI actually did and didn't do across 1,080 commits
5. The openness — why it's MIT and public, and what that costs and buys
6. The economics — free app, patronage, the AI bill (Block C, told straight)

**Smallest viable first step:** the journal already *is* the book in serial form.
A "proposition" can be one essay — "Building in the open, one evening at a time" —
that doubles as a journal post and a proposal sample. Reuse the graph from this
session as its lede image.

---

## 7. Coordination hooks (the pointer lines to add)

Keep each to one line so the hotspot files don't bloat.

- **`CLAUDE.md`** (Conventions): `Maker voice & identity (the "made by mz" story across app/site/support/journal) is specified in docs/MAKER_IDENTITY.md — pull facts and copy blocks from there, never invent maker claims.`
- **`docs/DesignSpec.md`** (a short Voice note): `For maker/first-person voice and the data-backed claims behind it, see docs/MAKER_IDENTITY.md.`
- **`../septena-site/docs/marketing.md`**: `Maker identity & the data-supported claims are canonical in the app repo at docs/MAKER_IDENTITY.md — marketing copy about "made by one person" derives from there.`
