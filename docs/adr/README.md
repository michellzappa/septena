# Architecture decision records

One file per decision: `NNNN-short-title.md`, numbered in order. An ADR is
short and does not change after it is accepted. To change a decision, write
a new ADR and set the old one to `superseded by NNNN`.

| # | Decision | Status |
|---|---|---|
| [0001](0001-record-decisions.md) | Record decisions as ADRs; plan with specs, roadmap, issues | accepted |
| [0002](0002-own-backend-replaces-icloud.md) | Own backend replaces iCloud | accepted |
| [0003](0003-external-links-run-server-side.md) | External links run on the server; the remote owns mapped fields | accepted; GitHub dropped by 0033, capture feeds by 0038 |
| [0004](0004-shared-projects-own-store.md) | A shared project lives in its own store | accepted |
| [0005](0005-tasks-as-factory-intake.md) | Tasks are factory intake; agents ask in the app | accepted |
| [0006](0006-tasks-fade-by-default.md) | Tasks fade by default; the list asks why a task is stuck | accepted |
| [0007](0007-septena-is-the-task-app.md) | Septena is the task app; the life OS becomes Septena Life | accepted |
| [0008](0008-agent-loop-rules-live-in-the-store.md) | Agent loop rules live in the store; the human holds the stop | accepted |
| [0009](0009-trustable-private-ai.md) | Run AI on tasks with checkable privacy guarantees | accepted; provider, default and pricing per feature |
| [0010](0010-free-server-tier-with-limits.md) | Offer a free server tier with limits; paid lifts them | accepted, amended by 0023 (devices) and 0036 (agents, live sync, Logbook) |
| [0011](0011-self-hostable-backend.md) | Keep the backend self-hostable on the user's own Cloudflare account | accepted |
| [0012](0012-project-notes-are-agent-context.md) | Project notes are the context agents read first | accepted |
| [0013](0013-native-windows-app-on-the-android-code.md) | Build the Windows app on the Android client's Kotlin code | accepted, W0 amended by 0025 |
| [0014](0014-today-rollover-review-or-clean-slate.md) | Today rolls over by Ask (renamed from Review) or by Clean slate; it never carries over silently | accepted |
| [0015](0015-shared-registries-for-cross-platform-clients.md) | Keep cross-platform task-app contracts in shared JSON registries | accepted, pure logic amended by 0025 |
| [0016](0016-sign-in-beyond-apple.md) | Sign in beyond Apple: approve a new device, or use an email code | accepted |
| [0017](0017-move-septena-life-out-of-repo.md) | Move Septena Life out of the Septena repo | accepted |
| [0018](0018-septena-on-its-own-cloudflare-account.md) | Run Septena on its own Cloudflare account | accepted |
| [0019](0019-generative-textures-and-fruit-accents.md) | Use procedural canvas textures and exotic-fruit accents over a Colorful default | accepted |
| [0020](0020-registry-owns-copy-and-translations.md) | The registry owns shared copy and its translations; shells render it | accepted |
| [0021](0021-one-import-engine-with-source-adapters.md) | One import engine, with source adapters behind a versioned bundle | accepted |
| [0022](0022-marketing-scenes-come-from-the-native-app.md) | Marketing scenes come from the native app | rejected |
| [0023](0023-sync-across-devices-is-plus.md) | Make sync across devices the paid line (amends 0010) | accepted, amended by 0036 (agents) |
| [0024](0024-no-iphone-tab-bar.md) | No tab bar on iPhone: the list is the root of one navigation stack | accepted |
| [0025](0025-shared-rust-core.md) | Put task rules and sync decisions in one shared Rust core | accepted (amends 0013 W0, 0015) |
| [0026](0026-plus-on-any-store-stripe-for-web.md) | Sell Plus on any store, one account entitlement, Stripe for web | accepted |
| [0027](0027-task-date-rules-are-core-actions.md) | Task date rules are actions in the shared core | accepted |
| [0028](0028-registry-owns-vocabulary-platforms-own-interaction.md) | The registry owns vocabulary; each platform owns layout and interaction | accepted |
| [0029](0029-one-task-page-two-depths.md) | One task page with two depths; one picker per attribute | accepted |
| [0031](0031-references-are-keyed-pointers.md) | A task reference is a keyed pointer, separate from a link | accepted |
| [0032](0032-github-issues-are-followed-not-mirrored.md) | Follow GitHub issues, do not mirror them | superseded by 0033 |
| [0033](0033-no-github-integration-issue-links-are-references.md) | Drop the GitHub integration; issue links are references | accepted |
| [0034](0034-companion-devices-get-a-limited-session.md) | Give companion devices a limited session and a small verb set | accepted |
| [0035](0035-companion-voice-is-push-to-talk-and-confirmed.md) | Make companion voice push-to-talk, unstored and confirmed | accepted |
| [0036](0036-plan-ladder-one-agent-then-three.md) | Four plan levels: an account adds the server, Plus adds more than one (amends 0010, 0023) | accepted, presentation amended by 0037 |
| [0037](0037-show-free-plus-and-planned-pro.md) | Show three plans: Free, Plus and a planned Pro (amends 0036) | accepted |
| [0038](0038-agents-are-the-integrations.md) | Agents are the integrations; Septena connects to no source (extends 0033, amends 0003) | accepted |
| [0039](0039-unanswered-proposals-expire.md) | An unanswered agent proposal expires to the Faded pile | accepted |
| [0040](0040-sessions-survive-lost-replies-and-end-on-reuse.md) | Sessions survive lost replies and end on reuse | accepted |
| [0041](0041-do-is-one-task-now-on-every-screen.md) | Do is one task now, and every screen shows it (extends 0034) | accepted |
| [0042](0042-members-keep-replicas-of-a-shared-project.md) | Members keep replicas of a shared project (amends 0004) | accepted |
| [0043](0043-plus-links-and-a-counts-only-admin-page.md) | Plus is given by link, and the admin page sees counts only (amends 0016) | accepted |
| [0044](0044-review-is-one-place.md) | Review is the one place for everything that waits on you (amends 0006, 0008) | accepted |
| [0045](0045-pro-is-a-real-plan-that-is-only-given.md) | Pro is a real plan that is only given, never sold yet (amends 0037, 0043) | accepted |
| [0046](0046-agent-work-is-a-review-group.md) | Agent work in progress is a group of Review, not its own list (amends 0044) | accepted |
| [0047](0047-every-way-in-creates-an-account.md) | Every way into Septena creates an account and offers every sign-in method it can (amends 0016) | accepted |

## Template

```markdown
# NNNN. Title in the imperative

- Status: proposed | accepted | superseded by NNNN
- Date: YYYY-MM-DD
- Deciders: mz

## Context
What forces the decision. Facts, not opinions.

## Decision
What we do. One paragraph.

## Consequences
What becomes easier, what becomes harder, what we give up.

## Links
Specs, issues, earlier ADRs.
```
