# Architecture decision records

One file per decision: `NNNN-short-title.md`, numbered in order. An ADR is
short and does not change after it is accepted. To change a decision, write
a new ADR and set the old one to `superseded by NNNN`.

| # | Decision | Status |
|---|---|---|
| [0001](0001-record-decisions.md) | Record decisions as ADRs; plan with specs, roadmap, issues | accepted |
| [0002](0002-own-backend-replaces-icloud.md) | Own backend replaces iCloud | accepted |
| [0003](0003-external-links-run-server-side.md) | External links run on the server; the remote owns mapped fields | accepted |
| [0004](0004-shared-projects-own-store.md) | A shared project lives in its own store | accepted |
| [0005](0005-tasks-as-factory-intake.md) | Tasks are factory intake; agents ask in the app | accepted |
| [0006](0006-tasks-fade-by-default.md) | Tasks fade by default; the list asks why a task is stuck | accepted |
| [0007](0007-septena-is-the-task-app.md) | Septena is the task app; the life OS becomes Septena Life | accepted |
| [0008](0008-agent-loop-rules-live-in-the-store.md) | Agent loop rules live in the store; the human holds the stop | accepted |
| [0009](0009-trustable-private-ai.md) | Run AI on tasks with checkable privacy guarantees | proposed |
| [0010](0010-free-server-tier-with-limits.md) | Offer a free server tier with limits; paid lifts them | accepted |
| [0011](0011-self-hostable-backend.md) | Keep the backend self-hostable on the user's own Cloudflare account | accepted |
| [0012](0012-project-notes-are-agent-context.md) | Project notes are the context agents read first | accepted |
| [0013](0013-native-windows-app-on-the-android-code.md) | Build the Windows app on the Android client's Kotlin code | accepted |
| [0014](0014-today-rollover-review-or-clean-slate.md) | Today rolls over by Ask (renamed from Review) or by Clean slate; it never carries over silently | accepted |
| [0015](0015-shared-registries-for-cross-platform-clients.md) | Keep cross-platform task-app contracts in shared JSON registries | accepted |
| [0016](0016-sign-in-beyond-apple.md) | Sign in beyond Apple: approve a new device, or use an email code | accepted |
| [0017](0017-move-septena-life-out-of-repo.md) | Move Septena Life out of the Septena repo | accepted |
| [0018](0018-septena-on-its-own-cloudflare-account.md) | Run Septena on its own Cloudflare account | accepted |
| [0019](0019-generative-textures-and-fruit-accents.md) | Use procedural canvas textures and exotic-fruit accents over a Colorful default | accepted |
| [0020](0020-registry-owns-copy-and-translations.md) | The registry owns shared copy and its translations; shells render it | accepted |
| [0021](0021-one-import-engine-with-source-adapters.md) | One import engine, with source adapters behind a versioned bundle | accepted |

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
