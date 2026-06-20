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
| **Build number** | `CFBundleVersion` | `Config/Base.xcconfig` (`CURRENT_PROJECT_VERSION`) | `scripts/stamp-version.sh` | at archive time |

**Why the build number is in the xcconfig, not project.yml:** with 3–5 parallel
sessions and an hourly commit-cron, a hand-edited build number in the
`project.yml` hotspot would conflict constantly. Deriving it from
`git rev-list --count HEAD` makes it monotonic and conflict-free — nobody edits
it, it just counts commits. An xcconfig is the base build-settings layer, so a
project-level `CURRENT_PROJECT_VERSION` would *override* it — that's why it must
**not** appear in `project.yml`. The committed default (`1`) is fine for
day-to-day Debug builds; only an archive needs the real, ever-increasing value.

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
are conflict hotspots — don't spread a release across parallel sessions):

```bash
# 1. See what changed since the last release tag.
scripts/changelog-draft.sh                  # or: scripts/changelog-draft.sh v0.1.0

# 2. Curate those commits into user-facing highlights.
#    Edit Septena/Resources/changelog.json — add a new entry at the TOP.

# 3. Pick the new marketing version (SemVer) by hand.
#    Edit MARKETING_VERSION in project.yml.

# 4. Tag it so "since last release" works next time.
git tag v0.2.0

# 5. Stamp the build number from the commit count, then archive.
scripts/stamp-version.sh
#    …Product ▸ Archive (or xcodebuild archive) for TestFlight / the App Store.
```

Ordinary feature work does **not** bump the version or touch the changelog — the
committer-cron lands green units as they come. Versioning is a release-time
decision, made on purpose.

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
      "version": "0.2.0",            // matches MARKETING_VERSION
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

Newest release first. `section` is an optional section key (e.g. `training`,
`nutrition`, `tasks`) — it drives the accent dot on both the app row and the
website row. Omit it (or use `null`) for app-wide changes.

### Why not generate it from the database?

The runtime database is *life-data* (meals, sets, gut events, tasks). A
changelog is about *app releases*. They're different things — the changelog is
authored from git history, by hand, curated down to what's worth announcing.
`scripts/changelog-draft.sh` gives you the raw commit list to start from.
