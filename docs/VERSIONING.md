# Versioning & changelog

How Septena numbers its releases and how the changelog flows from one source to
the app and the website. The short version lives in `CLAUDE.md`; this is the
full reference.

## The two numbers

Apple builds carry two independent version strings, and we give each a single
clear owner:

| Number | Info.plist key | Lives in | Who sets it | When |
| --- | --- | --- | --- | --- |
| **Marketing version** | `CFBundleShortVersionString` | `project.yml` (`MARKETING_VERSION`) | a human, by hand | only when cutting a release |
| **Build number** | `CFBundleVersion` | `Config/Base.xcconfig` (`CURRENT_PROJECT_VERSION`) | `scripts/changelog-stamp.sh` (cron) and `scripts/stamp-version.sh` (archive) | live, every time work lands |

**Why the build number is in the xcconfig, not project.yml:** with 3–5 parallel
sessions and an hourly commit-cron, a hand-edited build number in the
`project.yml` hotspot would conflict constantly. Deriving it from
`git rev-list --count HEAD` makes it monotonic and conflict-free — nobody edits
it, it just counts commits. An xcconfig is the base build-settings layer, so a
project-level `CURRENT_PROJECT_VERSION` would *override* it — that's why it must
**not** appear in `project.yml`. Every embedded target (the two apps, the watch
app, the widgets, the complication, and the live-activity extension) reads
`$(CURRENT_PROJECT_VERSION)` for its `CFBundleVersion`, so stamping the one
xcconfig keeps the whole bundle's build numbers identical — App Store validation
rejects archives whose extensions disagree with the parent.

This only works because each target's hand-maintained `Info.plist` sets its two
version keys to the build-setting *references*, not literals:
`CFBundleShortVersionString` → `$(MARKETING_VERSION)` and `CFBundleVersion` →
`$(CURRENT_PROJECT_VERSION)`. A plist that hardcodes a literal (the old `1.0` /
`1`) silently ships the wrong version no matter what the config says — Settings ▸
About reads these keys at runtime. `scripts/check-version-wiring.sh` enforces the
wiring across all six plists; `scripts/stamp-version.sh` runs it before stamping
so a mis-wired archive can't ship. **Add a new bundle target's plist to that
script's `PLISTS` list.**

**The build number is now stamped live, not just at archive.** The committer-cron
runs `scripts/changelog-stamp.sh` after it lands real work, which stamps
`CURRENT_PROJECT_VERSION` to the commit count (see *The in-development entry*
below). `scripts/stamp-version.sh` remains the belt-and-suspenders re-stamp run
right before an archive — idempotent, it produces the same number on the same
commit.

### Marketing version (SemVer, pre-1.0)

We use [SemVer](https://semver.org). Until the public App Store launch we stay
on `0.MINOR.PATCH`:

- **MINOR** (`0.1.0` → `0.2.0`) — a batch of user-facing features / a TestFlight
  drop worth announcing.
- **PATCH** (`0.1.0` → `0.1.1`) — fixes and polish only, nothing new to learn.
- **`1.0.0`** — the public App Store launch. After that, MAJOR for breaking
  changes, MINOR for features, PATCH for fixes, as usual.

## Cutting a release

One deliberate act, done in a **single session** (the changelog and `project.yml`
are conflict hotspots — don't spread a release across parallel sessions). Most of
the work is already done for you: the cron keeps an `"Unreleased"` entry curated
from the commits since the last release (see below). Cutting a release is mostly
**promoting** that entry:

```bash
# 1. Promote the auto-maintained "Unreleased" entry in
#    Septena/Resources/changelog.json: change its `version` from "Unreleased" to
#    the real number, set `name`/`summary`, and curate the highlights down to
#    what's worth announcing. (scripts/changelog-draft.sh still prints the raw
#    commit list if you want to cross-check.)

# 2. Pick the new marketing version (SemVer) by hand — it must match step 1.
#    Edit MARKETING_VERSION in project.yml.

# 3. Tag it so the build-delta math has a clean boundary next time.
git tag v0.2.0

# 4. Stamp the build number from the commit count, then archive.
scripts/stamp-version.sh
#    …Product ▸ Archive (or xcodebuild archive) for TestFlight / the App Store.
```

After a release, the next cron run starts a fresh `"Unreleased"` entry from the
commits past the one you just promoted. Picking the *marketing* version is the
only by-hand judgement call — everything else flows from the commit count.

### The in-development entry

The committer-cron maintains a single entry at the top of the changelog with the
sentinel version `"Unreleased"`:

- **`scripts/changelog-stamp.sh`** runs each time the cron lands work. It reads
  the latest *released* entry's `build`, takes the commits since then (the build
  number *is* the commit count, so the range is pure arithmetic — no git tag
  needed), and asks Claude to curate them into user-facing highlights (falling
  back to the raw commit subjects if Claude is unavailable). It rewrites only the
  `"Unreleased"` entry — released entries are never touched.
- It carries the **live build number** and stamps the same number into
  `Config/Base.xcconfig`. To avoid an infinite loop (committing the build number
  changes the count it just recorded), it writes the *predicted* count — current
  count + 1 for the single refresh commit it makes — so the number is exact at
  `HEAD`. A guard skips the whole thing when `HEAD` is already a refresh commit,
  so a quiet tree never churns.
- The app **hides it from the "What's New" launch sheet** (it would re-fire every
  hour) via `Changelog.latestReleased` / the `isUnreleased` flag, but it *does*
  show in the in-app history and on the public `/changelog` page — both surface
  the build number now, so the count is always visible.

This is why "ordinary feature work doesn't touch the changelog" is now only half
true: **you** don't, but the cron keeps the unreleased notes and the build number
current on your behalf. The release-time judgement — the marketing version and
the final curation — stays human.

## The changelog: one source, two surfaces

`Septena/Resources/changelog.json` is the **single source of truth** for release
notes. It is consumed in two places that must never diverge:

1. **In-app** — bundled into the app and read by `SeptenaCore/Changelog.swift`:
   - Settings ▸ About ▸ **What's New** shows the full history (`ChangelogList`).
   - On launch after an update, a **What's New sheet** auto-presents the
     releases newer than the version the user last saw (gated on the welcome
     being done; a fresh install adopts the current version silently). State key:
     `SettingsKey.lastSeenChangelogVersion`.
2. **On the website** — `../septena-site/scripts/sync-changelog.mjs` copies the
   file into `septena-site/content/changelog.json` at build time (wired into
   `predev`/`prebuild`), and `app/changelog/page.tsx` renders it at `/changelog`.
   If the app repo isn't checked out beside the site, the sync keeps the last
   committed copy so the site still builds.

### File format

```jsonc
{
  "schema_version": 1,
  "releases": [
    {
      "version": "Unreleased",       // the cron-maintained in-development entry (pinned on top)
      "build": 1081,                  // live commit count; promoted to a real version at release time
      "date": "2026-06-21",
      "name": "In development",
      "summary": "Changes since 0.7.0, refreshed automatically as work lands.",
      "highlights": [ /* curated from the commits since the last release */ ]
    },
    {
      "version": "0.2.0",            // a shipped release — matches MARKETING_VERSION at the time
      "build": 137,                   // optional; the stamped build number
      "date": "2026-07-01",          // YYYY-MM-DD
      "name": "Some codename",       // optional, shown beside the version
      "summary": "One-line framing.",// optional
      "highlights": [
        {
          "title": "Short headline",
          "detail": "A sentence of context.",   // optional
          "section": "training"                  // optional SectionManifest key → accent color; null = app-wide
        }
      ]
    }
  ]
}
```

Newest release first, with the single `"Unreleased"` entry (if present) pinned
above every shipped release regardless of its sentinel version. `MARKETING_VERSION`
in `project.yml` must always match the newest *released* entry — the `"Unreleased"`
entry is exempt. `section` is an optional section key (e.g. `training`,
`nutrition`, `tasks`) — it drives the accent dot on both the app row and the
website row. Omit it (or use `null`) for app-wide changes.

### Why not generate it from the database?

The runtime database is *life-data* (meals, sets, gut events, tasks). A
changelog is about *app releases*. They're different things — the changelog is
authored from **git history**, never the DB: the cron curates the in-development
entry from commits as work lands, and a human curates the final release entry
when cutting a version. `scripts/changelog-draft.sh` gives you the raw commit
list to cross-check.
