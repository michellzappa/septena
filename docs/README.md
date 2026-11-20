# Docs — index and rules

This file is the entry point to `docs/`. Read it before you add or change a
doc. Code always wins over any doc (`CLAUDE.md`, "Where truth lives").

## How we plan

Four kinds of record. Each has one job.

| Kind | Where | Job | Changes after it is accepted? |
|---|---|---|---|
| **ADR** | `docs/adr/NNNN-title.md` | Records one decision and why. Short. | No. A new ADR supersedes it. |
| **Spec** | `docs/<NAME>_SPEC.md` | Describes how one feature works: data, rules, surfaces, phases. | Yes, until the feature ships. Then it is frozen as *historical*. |
| **Roadmap** | `docs/ROADMAP.md` | Order of the work: tracks and milestones. | Yes, every time the plan changes. |
| **Issue** | GitHub `michellzappa/septena` | One unit of work an agent or mz can pick up. Links its spec and milestone. | Closed when done. |

Rules:

1. A decision that is hard to reverse, or that changes how several parts fit
   together, gets an ADR before the spec that depends on it.
2. A spec names the ADRs it rests on, and lists its phases. Each phase becomes
   one or more issues in the milestone of that phase.
3. A spec opens with a status line: `proposal`, `accepted`, `building`,
   `shipped — historical`, or `superseded by <doc>`.
4. A superseded doc stays in place with a header that names its successor.
   Do not delete it and do not move it: other docs and code comments link to
   it.
5. Defaults that the author chose for mz are marked *(default)* and collected
   in an "Open questions" table at the end of the spec. Silence means the
   default stands.
6. Engineering docs only. This repo is public. Strategy, pricing and
   positioning live in the private site repo (`CLAUDE.md`).

GitHub labels: `spec`, `adr`, `ready-for-agent`, `needs-mz`, and one
`track:<name>` label per roadmap track.

## Current platform direction

Septena and Septask leave iCloud. Data moves to the own backend
(`api.septena.app`). See [ADR 0002](adr/0002-own-backend-replaces-icloud.md).
New specs design for the backend only. Docs that assume CloudKit is the
product are stale on that point, even when the rest still holds.

The task app (working name Septask) ships as **Septena** and is the primary
product, with a paid sync subscription. The life OS becomes **Septena Life**.
See [ADR 0007](adr/0007-septena-is-the-task-app.md).

## Index

### Planning

- [ROADMAP.md](ROADMAP.md) — tracks, milestones, order.
- [adr/](adr/README.md) — architecture decision records.
- [agents/factory.md](agents/factory.md) — the unattended factory playbook (`factory-day` skill, target `septena`).

### Platform and data

| Doc | Status |
|---|---|
| [SEPTASK_BACKEND.md](SEPTASK_BACKEND.md) | building (migration track) |
| [REPO_SPLIT_PLAN.md](REPO_SPLIT_PLAN.md) | proposal (#84): Septena Life moves to `septena-life` |
| [SYNC_SUBSCRIPTION_SPEC.md](SYNC_SUBSCRIPTION_SPEC.md) | proposed (launch track) |
| [IDENTIFIERS.md](IDENTIFIERS.md) | current |
| [CloudKitSchema.md](CloudKitSchema.md) | current until the iCloud exit, then historical |
| [PROD_CUTOVER.md](PROD_CUTOVER.md) | CloudKit-era checklist |
| [VERSIONING.md](VERSIONING.md) | current |
| [OPEN_SOURCE_LIMITATIONS.md](OPEN_SOURCE_LIMITATIONS.md), [BUILDING_YOUR_OWN.md](BUILDING_YOUR_OWN.md) | iCloud-era; review at cutover |

### Septask and tasks

| Doc | Status |
|---|---|
| [SEPTASK.md](SEPTASK.md) | current (P0–P4 landed) |
| [LINKED_PROJECTS_SPEC.md](LINKED_PROJECTS_SPEC.md) | accepted |
| [PROJECT_SHARING_SPEC.md](PROJECT_SHARING_SPEC.md) | accepted |
| [TASK_FACTORY_SPEC.md](TASK_FACTORY_SPEC.md) | accepted |
| [TASK_FADE_SPEC.md](TASK_FADE_SPEC.md) | accepted |
| [NATIVE_PROJECT_SHARING_SPEC.md](NATIVE_PROJECT_SHARING_SPEC.md) | superseded by PROJECT_SHARING_SPEC |
| [SEPTASK_ANDROID_PLAN.md](SEPTASK_ANDROID_PLAN.md) | superseded on architecture (ADR 0002) |
| [TASK_CONVERSATIONS_PLAN.md](TASK_CONVERSATIONS_PLAN.md) | shipped — historical, still the design rationale |
| [TASK_CONVERSATIONS_PHASE0.md](TASK_CONVERSATIONS_PHASE0.md), [PHASE1](TASK_CONVERSATIONS_PHASE1.md), [SEPTASK_CONVERSATIONS_PLAN.md](SEPTASK_CONVERSATIONS_PLAN.md) | shipped — historical |
| [AI_TASKS_EXPLAINER.md](AI_TASKS_EXPLAINER.md) | user copy; iCloud claims change at cutover |
| [TASK_ROW_LANGUAGE_SPEC.md](TASK_ROW_LANGUAGE_SPEC.md), [TRIAGE_BAND_SPEC.md](TRIAGE_BAND_SPEC.md), [QUICK_ADD_CONTRACT.md](QUICK_ADD_CONTRACT.md) | built |
| [ORDERING_AND_HEADINGS_PLAN.md](ORDERING_AND_HEADINGS_PLAN.md), [DRAG_AND_DROP.md](DRAG_AND_DROP.md) | shipped — historical |
| [RECENTLY_DELETED_SPEC.md](RECENTLY_DELETED_SPEC.md), [TASK_LIST_OBSERVATION_PLAN.md](TASK_LIST_OBSERVATION_PLAN.md) | proposal |
| [SEPTASK_APPKIT_PARITY.md](SEPTASK_APPKIT_PARITY.md), [SEPTASK_APPKIT_SURFACES.md](SEPTASK_APPKIT_SURFACES.md), [SEPTASK_APPKIT_LOCALIZATION_HANDOFF.md](SEPTASK_APPKIT_LOCALIZATION_HANDOFF.md) | AppKit shell notes |
| [APPSTORE-SEPTASK.md](APPSTORE-SEPTASK.md), [RELEASING-MAC.md](RELEASING-MAC.md) | current |

### AI and MCP

| Doc | Status |
|---|---|
| [agent-provenance-spec.md](agent-provenance-spec.md) | draft |
| [agent-provenance-gateway-handoff.md](agent-provenance-gateway-handoff.md) | landed — historical |
| [CORE_AI_iOS27_PREP.md](CORE_AI_iOS27_PREP.md) | research, pre-implementation |
| [SPOTLIGHT_READABILITY_PLAN.md](SPOTLIGHT_READABILITY_PLAN.md) | phases 0–2 built |
| [APP_INTENTS_BACKLOG.md](APP_INTENTS_BACKLOG.md) | historical — open items moved to GitHub issues (2026-11-20) |

### Design system and UI

| Doc | Status |
|---|---|
| [DesignSpec.md](DesignSpec.md) | canonical |
| [PAGE_CHROME_SPEC.md](PAGE_CHROME_SPEC.md), [DRAWER_MODES_SPEC.md](DRAWER_MODES_SPEC.md), [GLASS_DOTS_SPEC.md](GLASS_DOTS_SPEC.md), [WAKING_DAY_WHEEL.md](WAKING_DAY_WHEEL.md) | mixed: see each status line |
| [SETTINGS_FLATTEN_SPEC.md](SETTINGS_FLATTEN_SPEC.md) | building (task app settings) |
| [SETTINGS_REORG_PROPOSAL.md](SETTINGS_REORG_PROPOSAL.md) | life app; mostly built |
| [FRONT_DOOR_IDENTITY.md](FRONT_DOOR_IDENTITY.md) | roadmap |
| [LOCALIZATION_PLAN.md](LOCALIZATION_PLAN.md) | pt-BR pilot done |

### Septena sections (life OS)

[ADDING_A_SECTION.md](ADDING_A_SECTION.md) (checklist, current),
[SECTION_DRY_AUDIT.md](SECTION_DRY_AUDIT.md),
[BUCKET_CONSISTENCY_SPEC.md](BUCKET_CONSISTENCY_SPEC.md),
[ACTIVITY_CLOUD_HISTORY_PLAN.md](ACTIVITY_CLOUD_HISTORY_PLAN.md),
[CONSUMABLES_PLAN.md](CONSUMABLES_PLAN.md) / [study](CONSUMABLES_GENERALIZATION_STUDY.md) (historical),
[GOAL_MILESTONES_PLAN.md](GOAL_MILESTONES_PLAN.md) (shipped),
[PINNED_GOALS_PLAN.md](PINNED_GOALS_PLAN.md),
[MARKERS_PLAN.md](MARKERS_PLAN.md),
[CAPTURE_DISCOVERY_SPEC.md](CAPTURE_DISCOVERY_SPEC.md),
[SELF_DISCOVERY_PLAN.md](SELF_DISCOVERY_PLAN.md),
[PRACTITIONER_REPORTS_SPEC.md](PRACTITIONER_REPORTS_SPEC.md) / [prototype](PRACTITIONER_REPORTS_PROTOTYPE.md),
[PER_SET_LOGGING_SPEC.md](PER_SET_LOGGING_SPEC.md),
[TRAINING_PT_SPEC.md](TRAINING_PT_SPEC.md),
[MUSCLE_TAXONOMY_16.md](MUSCLE_TAXONOMY_16.md),
[GUT_SYMPTOMS_MIGRATION_PLAN.md](GUT_SYMPTOMS_MIGRATION_PLAN.md),
[NUTRITION_MIGRATION_HANDOFF.md](NUTRITION_MIGRATION_HANDOFF.md),
[TRAINING_MIGRATION_HANDOFF.md](TRAINING_MIGRATION_HANDOFF.md) (historical).

### Product and identity

[MESSAGING.md](MESSAGING.md) (moved to the Septena Starlings workspace), [MAKER_IDENTITY.md](MAKER_IDENTITY.md),
[APPSTORE.md](APPSTORE.md), [feedback.md](feedback.md),
[BACKLOG.md](BACKLOG.md) (historical: open items moved to GitHub issues on
2026-11-20).
