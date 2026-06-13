# Messaging — the canonical spine

Single source of truth for how Septena talks about itself, across every
surface: the marketing site (`../septena-site`), the App Store listing
(`docs/APPSTORE.md` + `appstore/`), the in-app onboarding, and off-store
channels (Product Hunt, press, social). Copy and visuals on every surface
should *derive from this doc*, the way colors derive from
`SeptenaCore/SectionTheme.swift` and `appstore/theme.mjs`. When a surface says
something this doc doesn't, the surface is wrong.

_Last reconciled against site + store: 2026-06-13. Items marked **(DECIDE)**
are open — see “Open decisions” at the end._

## 1. Positioning line — the one sentence

One idea, two lengths (same meaning, never a third variant):

- **Long form** (site hero H1, press, no limit):
  *Everything you track, one private app.*
- **Short form** (App Store subtitle, ≤30 chars):
  *All your life, one private app.* (30/30)

Every surface opens on this idea. Don't invent surface-specific taglines.

## 2. Audience

Privacy-conscious general users who are tired of juggling a dozen
single-purpose apps and uneasy about where that data lives. Not enterprise, not
hardcore quantified-self only — ordinary people who track a few things and want
one calm, trustworthy home for them.

## 3. Value pillars (canonical order)

The store proves three; the site lists five. Reconciled set of **four** ordered
pillars — every surface uses these names, in this order, and introduces no
others **(DECIDE: is “Bring your own AI” a top-four pillar or a sub-point?)**:

1. **One app, not twelve** — the all-in-one promise. Not "all your apps in one
   folder" — one surface, so the things you track can finally *relate*. Twelve
   siloed apps each tell you a fact; only one place tells you two facts connect.
2. **Built around the week** — the cadence where signals relate (a day is noisy,
   a month is too late). Seven days in the view, seven dots in the mark. The
   Correlations view does the math you'd never do by eye, with honest stats.
3. **Private by architecture** — your data lives in your own iCloud, a private
   database synced across your devices. No server we run can read your life.
   Nothing to breach, sell, or shut down.
4. **Bring your own AI** — Septena ships no AI of its own; it opens an optional
   door so you point *your* AI at your data, with a visible record of what it
   touched.

"Honest by design" (real streaks, gentle nudges, no nagging) is a **voice/
product trait**, woven through copy — not a standalone pillar.

## 4. Proof map (pillar → the screenshot that proves it)

Shots live once in `appstore/raw/<device>/` and are reused by the site. Names
are being unified **(DECIDE: adopt semantic names everywhere?)**:

| Pillar | App Store panel | Capture (proposed canonical name) | Site `AppShot` today |
|---|---|---|---|
| One app, not twelve | hook | `overview` (was `01-Week`) | `overview` |
| Built around the week | week + correlations | `week-heatmap`, `insights` (was `06`/`08`) | `insights` |
| Private by architecture | privacy | — (statement panel) | — |
| Bring your own AI | (add a panel?) | `mcp` / `ai` | — |

## 5. Voice & tone

- First person from the maker where it fits ("I wanted one place…", the founder
  line) — Septena is a personal, opinionated product, not a faceless brand.
- Plain, warm, confident. Short declaratives. Em-dashes over bullets in prose.
- Concrete over abstract: "late caffeine → worse sleep," not "actionable health
  insights."
- Calm, never nagging — the product nudges you to *mark* what you did, never
  guilts you into doing it. The copy mirrors that.

## 6. Brand tokens (one palette, one type system)

The app is the source of truth (`SeptenaCore/SectionTheme.swift`,
`Septena/Resources/Fraunces-Regular.ttf`). `appstore/theme.mjs` already mirrors
it. The **site currently diverges** and must be reconciled **(DECIDE)**:

| Token | App / App Store | Site today | Action |
|---|---|---|---|
| Display type | **Fraunces** SemiBold (opsz 9) | Iowan Old Style / Charter / Georgia | unify on Fraunces |
| Brand accent | **#336bd1** (blue, AccentColor) | `oklch(0.45 0 0)` (neutral gray) | pick one, apply everywhere |
| Section colors | `SectionTheme.defaultPalette` | own ramp in `globals.css` | confirm values match |
| Body / numerics | system / mono tabular | system | aligned |

Goal: a person who sees the site hero and then the App Store hook should see the
*same artifact* — same serif, same accent, same section colors.

## 7. Per-surface translation (same spine, format-appropriate)

- **Site, above the fold:** positioning line (long form) as H1, one-sentence
  sub, one hero shot (`overview`), one CTA (App Store badge). Don't list all
  pillars before the fold.
- **Site, on scroll:** the four pillars in canonical order, each = headline +
  the matching shared capture + 2–3 sentences; privacy as its own section;
  download CTA. (The current site is close — it just has 5 pillars and different
  brand tokens.)
- **App Store:** the six panels in `appstore/panels.config.mjs` (hook + 3
  pillars + privacy + close). Aligned, pending a "Bring your own AI" panel if it
  stays a top pillar.
- **App onboarding:** first screens echo the same pillars in the same order, so
  the promise users clicked is the promise they land in.
- **Off-store (Product Hunt / press / social):** headline = positioning line;
  press kit reuses the rendered `appstore/screenshots/`.

## 8. Audit — drift found 2026-06-13

1. Positioning wording differs (site "Everything you track" vs store "All your
   life"). → §1 reconciles to long/short of one idea.
2. Brand accent: site neutral gray vs app blue `#336bd1`. → **(DECIDE)** §6.
3. Display font: site Iowan serif vs app Fraunces. → **(DECIDE)** §6.
4. Pillar count: site 5 vs store 3. → §3 reconciles to 4; store may need a
   BYO-AI panel.
5. "Bring your own AI" and the "seven days / seven dots" idea are strong on the
   site but missing from the store. → fold "seven" into pillar 2 everywhere;
   decide BYO-AI's rank.
6. Screenshot names diverge (`overview`/`insights` vs `01-Week`/`08`). → unify
   on semantic names so one capture serves both surfaces.

## 9. Resolved decisions (2026-06-13)

- **(D1) Brand accent → blue `#336bd1`** (the app's AccentColor), everywhere.
  Site `--brand-accent` switched from neutral gray to blue.
- **(D2) Fraunces everywhere.** The site already loads Fraunces via `next/font`
  (`fonts/fraunces-latin.woff2` → `--font-heading`); the stale Iowan `:root`
  fallback was removed so nothing can shadow it.
- **(D3) "Bring your own AI" is a top-four pillar** → gets its own App Store
  panel and stays prominent on the site.
- **(D4) Positioning** long form = *Everything you track, one private app.*
  (already the site H1); short form = *All your life, one private app.* (subtitle).
- **(D5) Semantic capture names** (`overview`, `insights`, `sleep`, …) adopted
  across the pipeline so one capture file serves both site and store.
