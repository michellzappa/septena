# Production Cutover — Go-to-Prod Checklist

**Goal for this pass:** ship the first **Production** build to TestFlight.
**Decided 2026-07-03:** ship with an **empty Production DB** (correct for new
testers). Migrating **your own** personal data (Development → Production) is a
**separate follow-on**, NOT on this critical path — it needs code that doesn't
exist yet (see [§ Follow-on](#follow-on-your-personal-data-migration-not-tomorrow)).

Tick top-to-bottom. Phases 1–6 are tomorrow. Phase 7 + the follow-on come later.

---

## The one trap to keep in mind

Development and Production are **separate CloudKit environments with separate
data.** The Console's "Deploy Schema Changes to Production" promotes **record
types / fields / indexes only — never records.** So after deploy, Production's
private DB is **empty**. That is expected and fine here — new testers start
blank, and your data stays safe in Development until you migrate it deliberately.

**Consequence of shipping empty-Prod:** keep daily-driving your **Development**
build (Xcode debug install) for your real data. The Prod TestFlight build is for
release verification + new testers. The **MCP gateway stays on Development** too
(don't flip it — see Phase 7) so your consumer/chat data keeps resolving.

---

## Phase 0 — Preflight (green gate)

- [ ] All schemes build green via `scripts/build.sh` (serialize; don't run
      concurrent with the cron): `Septena`, `SeptenaMac`, `Septask`, `SeptaskMac`,
      `SeptenaWatch`.
- [ ] `SeptenaCoreTests` pass.
- [ ] Working tree clean / cron caught up (no half-landed work).
- [ ] Confirm version: `MARKETING_VERSION 0.7.0` (project.yml), build number is
      git-count (`Base.xcconfig`, currently 1336). **TestFlight ships at 0.7.0;**
      promote to `1.0.0` only when cutting the public App Store release.

## Phase 1 — Register the missing schema fields in Development

Production is stricter than Dev: fields the debug build never *wrote* were never
auto-registered in the Dev schema, and Prod won't auto-create them → silent write
failures. `SchemaSeedRegistrar` (committed, wired at `App.swift:394`, `#if DEBUG`)
seeds them into a throwaway temp zone so the fields register without polluting
`septena-v1`.

- [ ] Run a **DEBUG** build once on device/sim. On first launch it runs
      `SchemaSeedRegistrar.runIfNeeded()` (gate key `schema.seedMissingFields.v1`),
      seeding the **12 previously-unwritten optional fields**:
      `Area.context`; `Project.completedAt / context / githubRepo`;
      `SessionType.kind`; `NutritionEntry.{mealType, sugarG, saturatedFatG,
      alcoholG, sodiumMg, cholesterolMg, potassiumMg}`; `NutritionDaySum.{same
      seven macros}`.
- [ ] In CloudKit Console (Development schema) confirm all 12 fields now exist on
      their record types. If any are missing, the seed didn't run — check the
      UserDefaults gate didn't pre-set, re-run.

### Optional orphan cleanup (cheapest moment is the first deploy)

Deleting from the **Dev Console** (record-type/field delete — NOT an
environment reset, which nukes live data) keeps them out of Prod permanently.
Recommended but not blocking; harmless if you skip and just let them deploy.

- [ ] Delete dead type `AirReading` (no writer).
- [ ] Delete `Area.slug`, `Area.previousSlugs`, `Project.slug`,
      `Project.previousSlugs` (no `*Record.swift` encodes them; gateway ignores).
- [ ] **Do NOT** delete the event `time` string yet — it's still the canonical
      write source (`occurredAt` derives from it) and the gateway filters on it.
      That's a post-cutover Phase 3 consolidation, not a launch step.

## Phase 2 — Deploy schema to Production

- [ ] CloudKit Console → **Deploy Schema Changes to Production**. This carries the
      pending changelog in `docs/CloudKitSchema.md` § Production deploy — new types
      (`MoodEvent`, `GoalMilestone`, `ActivityDaySum`, `Symptom*`, `Medication*`,
      `CoachVoice`/`CoachMessage`, `Quote`) + new fields (`occurredAt` ×5 event
      types, `SupplementDefinition.bucket`, `Section.showInSpotlight`,
      `*.reservedString1`, the intake `emoji` fields). Additive, one-way, no zone
      reset.

## Phase 3 — Verify Production schema

- [ ] In the Console's **Production** schema, eyeball that every record type/field
      from `docs/CloudKitSchema.md` is present (Prod must be a **superset-match** of
      the manifest). Spot-check the 12 Phase-1 fields + all new types made it.

## Phase 4 — Archive-time entitlement flips ⚠️ cron hazard

These three are **release-only** and must **not persist in main** — the hourly
commit-cron auto-commits green `main`, so a committed `production` entitlement
would break every dev session's push and point local Mac builds at the empty Prod
DB. **Flip → archive → revert, in one sitting**, and confirm the revert before the
next cron tick (or pause the cron for the window).

- [ ] `Septena/Septena.entitlements` → `aps-environment` = `production`.
- [ ] `Septena/SeptenaMac.entitlements` → `aps-environment` = `production`.
- [ ] `Septena/SeptenaMac.entitlements` → `com.apple.developer.icloud-container-environment`
      = `Production` (or remove the key; the iOS app correctly omits it).
- [ ] `xcodegen generate` if the project needs regen.
- [ ] `scripts/stamp-version.sh` to stamp the build number for the archive.

## Phase 5 — Archive + upload to TestFlight

- [ ] Archive the `Septena` scheme (iOS; embeds Watch + widgets + live activity).
- [ ] Validate + upload to App Store Connect → TestFlight (`ITSAppUsesNonExemptEncryption`
      is already `false`, so no per-upload encryption prompt).
- [ ] **Revert the Phase-4 entitlement edits** and confirm `main` is back to
      `development` before leaving the tree / before the cron runs.
- [ ] (Mac is a separate ASC app + separate archive — do it the same way if you're
      shipping Mac this pass, else defer.)

## Phase 6 — Verify Production on a clean install

You **cannot** peek Prod data from a debug/dev build — verify on a real Prod build.

- [ ] Install the TestFlight build on a **second device / fresh install** (not over
      your Dev build).
- [ ] Cold-start + **empty-state pass**: onboarding, section picker, dashboards,
      Next feed all render cleanly against a blank Prod DB (no crashes, no "looks
      broken because empty").
- [ ] Create a few records on the Prod build; confirm they sync (second device or
      relaunch). Confirm no `serverRecordChanged` retry storms in logs.

## Phase 7 — Gateway flip (DEFER until your data is in Prod)

- [ ] **Leave `CK_ENVIRONMENT = "development"`** in
      `../septena-mcp-gateway/wrangler.toml` for now. Flipping to `production`
      would point your consumer/chat MCP at the empty Prod DB. Flip only as part of
      the follow-on below (after your data is migrated), which also requires a
      **re-auth** pass (stored `ckWebAuthToken`s are Dev-minted) and a valid
      Production `CK_API_TOKEN`.

---

## Follow-on — your personal data migration (NOT tomorrow)

This is the decoupled piece. Do it when you're ready to move your own history to
Production and switch your daily driver to the Prod build.

1. **Build the full-entity Dev→Prod re-push routine (new code).** Today's
   `Migration.swift` (`replaceLocalMirrorFromCloudKit`, `syncRepair`) is
   **task-graph-only** (Task/Area/Project/Settings/Section). A cutover re-push must
   cover **every** entity — the `noteXChange` primitives already exist for all ~20
   types (`CKEngine.swift:197+`). The routine, `#if DEBUG`, one-shot:
   - clear **every** entity's `cloudKitSystemFields` (stale Dev etags are the #1
     re-push failure — `serverRecordChanged` loops),
   - `engine.discardLocalSyncState()`,
   - call the matching `noteXChange` for **every row of every type**,
   - `sendChanges()`, then verify counts against the Console.
   - Do **not** use `exportToJSON`/`importFromJSON` — that snapshot is task-graph
     only and would silently drop health data.
2. Run it once from your device (whose SwiftData mirror holds ALL data and
   survives the same-bundle-ID dev→prod build swap).
3. Verify record counts in the Prod Console.
4. **Then** Phase 7: flip the gateway to `production`, `wrangler deploy`, re-auth.
5. Switch your daily driver to the Prod/TestFlight build.
6. Keep the Development zone as a backup until Prod is confirmed healthy — **don't
   delete it.**

## Independent (any time)

- [ ] Community worker deploy — `wrangler d1 migrate` + `wrangler deploy` for the
      supporter badge + Apple sign-in (separate `septena-community` worker; not
      part of the CloudKit cutover).

---

## Rollback / safety

- Schema deploy is **additive and cannot be un-deployed** — but it can't hurt
  existing data either (Prod was empty). No rollback needed; a wrong/extra field
  is inert.
- Your real data never moves in this pass — it stays in Development. Lowest-risk
  possible cutover.
- If TestFlight sync misbehaves, you have lost nothing: keep using the Dev build,
  fix, re-archive.
