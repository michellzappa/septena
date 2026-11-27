# Docs — index and rules

This file is the entry point to `docs/`. Read it before you add or change a
doc. Code always wins over any doc (`AGENTS.md`, "Where truth lives").

## How we plan

Four kinds of record. Each has one job.

| Kind | Where | Job | Changes after it is accepted? |
|---|---|---|---|
| **ADR** | `docs/adr/NNNN-title.md` | Records one decision and why. Short. | No. A new ADR supersedes it. |
| **Spec** | `docs/<NAME>_SPEC.md` | Describes how one feature works: data, rules, surfaces, phases. | Yes, until the feature ships. Then it is frozen as *historical*. |
| **Roadmap** | `docs/ROADMAP.md` | Order of the work: tracks and milestones. | Yes, every time the plan changes. |
| **Issue** | GitHub `septena/septena` | One unit of work an agent or mz can pick up. Links its spec and milestone. | Closed when done. |

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
The backend source is the Cloudflare Worker in `../backend/` (it also serves
MCP at `api.septena.app/mcp`).
New specs design for the backend only. Docs that assume CloudKit is the
product are stale on that point, even when the rest still holds.

This repo is the task app, **Septena** (working name Septask), with a paid sync
subscription. The life OS left on 2026-11-21 ([ADR 0017](adr/0017-move-septena-life-out-of-repo.md)).
See [ADR 0007](adr/0007-septena-is-the-task-app.md).

## Index

### Planning

- [ROADMAP.md](ROADMAP.md) — tracks, milestones, order.
- [ENGINEERING_PLAN.md](ENGINEERING_PLAN.md) — engineering order of work, the code audit, who owns what.
- [adr/](adr/README.md) — architecture decision records.
- [agents/factory.md](agents/factory.md) — the unattended factory playbook (`factory-day` skill, target `septena`).

### Platform and data

| Doc | Status |
|---|---|
| [SEPTASK_BACKEND.md](SEPTASK_BACKEND.md) | building (migration track) |
| [REPO_SPLIT_PLAN.md](REPO_SPLIT_PLAN.md) | done (ADR 0017) — historical |
| [SYNC_SUBSCRIPTION_SPEC.md](SYNC_SUBSCRIPTION_SPEC.md) | proposed (launch track) |
| [SIGN_IN_SURFACES_SPEC.md](SIGN_IN_SURFACES_SPEC.md) | accepted (ADR 0047; #137, SI0 to SI6) |
| [SUPPORT_SPEC.md](SUPPORT_SPEC.md) | accepted (ADR 0054; SUP1 to SUP5) |
| [LIST_SORT_SPEC.md](LIST_SORT_SPEC.md) | building (#779) |
| [ADMIN_CONSOLE_SPEC.md](ADMIN_CONSOLE_SPEC.md) | building (ADR 0043, 0058; phase 1 shipped) |
| [IDENTIFIERS.md](IDENTIFIERS.md) | current |
| [CloudKitSchema.md](CloudKitSchema.md) | current until the iCloud exit, then historical |
| [PROD_CUTOVER.md](PROD_CUTOVER.md) | CloudKit-era checklist |
| [VERSIONING.md](VERSIONING.md) | current |
| [OPEN_SOURCE_LIMITATIONS.md](OPEN_SOURCE_LIMITATIONS.md), [BUILDING_YOUR_OWN.md](BUILDING_YOUR_OWN.md) | iCloud-era; review at cutover |

### Septask and tasks

| Doc | Status |
|---|---|
| [SEPTASK.md](SEPTASK.md) | current (P0–P4 landed) |
| [LINKED_PROJECTS_SPEC.md](LINKED_PROJECTS_SPEC.md) | rewrite for Starlings before work (#12) |
| [GITHUB_SPEC.md](GITHUB_SPEC.md) | dropped (ADR 0033) |
| [TASK_REFERENCES_SPEC.md](TASK_REFERENCES_SPEC.md) | building (ADR 0031, ADR 0033; first release #386, #387) |
| [agent-spec/spec.md](agent-spec/spec.md) | v0, unstable until 1.0: the public agent spec (records, IDs, claim lifecycle, refusal codes). Generated from `agent-spec/spec.src.md`; published at septena.app/spec.md |
| [AGENT_SURFACE_SPEC.md](AGENT_SURFACE_SPEC.md) | accepted (ADR 0050): what agents read on septena.app and call on api.septena.app, AS1 to AS14 |
| [RAYCAST_EXTENSION_SPEC.md](RAYCAST_EXTENSION_SPEC.md) | proposal (ADR 0051, #667): Septena from the Raycast launcher, RX0 to RX5 |
| [PROJECT_SHARING_SPEC.md](PROJECT_SHARING_SPEC.md) | MVP built |
| [PUBLIC_LINKS_SPEC.md](PUBLIC_LINKS_SPEC.md) | proposal (#22, phase S4 of project sharing) |
| [TASK_FACTORY_SPEC.md](TASK_FACTORY_SPEC.md) | accepted |
| [AGENT_LOOP_AUDIT.md](AGENT_LOOP_AUDIT.md) | current (#619): every hop of the agent comment loop, its test and its status |
| [DO_SPEC.md](DO_SPEC.md) | building (ADR 0041): Do one task, full on one device, a notice on the others, the orb takes over |
| [REVIEW_SPEC.md](REVIEW_SPEC.md) | accepted (ADR 0044, 0046; store rules built) |
| [DAILY_REVIEW_SPEC.md](DAILY_REVIEW_SPEC.md) | proposal (#618): a short end-of-day review in Review |
| [USER_STATS_SPEC.md](USER_STATS_SPEC.md) | proposal (ADR 0063; #817, #820, #56, #818): content-free daily counts, never streaks |
| [DECISIONS_SPEC.md](DECISIONS_SPEC.md) | proposal (#620, ADR 0048): decisions and open questions as typed log entries |
| [TASK_FADE_SPEC.md](TASK_FADE_SPEC.md) | accepted (§6 amended by ADR 0014, proposals by ADR 0039) |
| [INBOX_ZERO_MOTION_SPEC.md](INBOX_ZERO_MOTION_SPEC.md) | shipped — historical (#298) |
| [PROJECT_NOTES_SPEC.md](PROJECT_NOTES_SPEC.md) | accepted (ADR 0012) |
| [TASK_PAGE_SPEC.md](TASK_PAGE_SPEC.md) | accepted (ADR 0029, #300) |
| [AGENT_PROMPT_SPEC.md](AGENT_PROMPT_SPEC.md) | building (#396; Android Review rows #412) |
| [TIMED_REMINDERS_SPEC.md](TIMED_REMINDERS_SPEC.md) | proposal (#97) |
| [RECURRENCE_V2_SPEC.md](RECURRENCE_V2_SPEC.md) | proposal (#126) |
| [MOVING_IN_SPEC.md](MOVING_IN_SPEC.md) | building (#99, ADR 0021): one import engine, source adapters |
| [TEMPLATES_SPEC.md](TEMPLATES_SPEC.md) | proposal (#621, ADR 0049): shareable templates and a gallery |
| [CHECKLISTS_SPEC.md](CHECKLISTS_SPEC.md) | proposal (#76) |
| [DATA_EXPORT_SPEC.md](DATA_EXPORT_SPEC.md) | proposal (#130) |
| [TASK_ROW_MENU_SPEC.md](TASK_ROW_MENU_SPEC.md) | building (#300): one flat row menu, Repeat in the When picker |
| [IOS_SWIPE_ACTIONS_SPEC.md](IOS_SWIPE_ACTIONS_SPEC.md) | superseded 2026-11-23 (swipes dropped) |
| [MULTI_SELECT_SWIPE_AND_DRAG_SPEC.md](MULTI_SELECT_SWIPE_AND_DRAG_SPEC.md) | partly superseded 2026-11-23 (Select menu item replaces swipe-to-select) |
| [TAGS_SPEC.md](TAGS_SPEC.md) | proposal (#96) |
| [TASK_WIDGETS_SPEC.md](TASK_WIDGETS_SPEC.md) | shipped — historical (#129) |
| [STAR_PRIORITY_SPEC.md](STAR_PRIORITY_SPEC.md) | proposal (#127) |
| [ATTACHMENTS_MAC_PARITY_SPEC.md](ATTACHMENTS_MAC_PARITY_SPEC.md) | proposal (#131) |
| [TASK_TIMES_AND_ICAL_SPEC.md](TASK_TIMES_AND_ICAL_SPEC.md) | proposal (#128) |
| [INLINE_CAPTURE_PARSING_SPEC.md](INLINE_CAPTURE_PARSING_SPEC.md) | proposal (#133) |
| [RAMBLE_MODE_SPEC.md](RAMBLE_MODE_SPEC.md) | proposal (#211, ADR 0035): on-device voice capture and task-notes enrichment with shared confirm step |
| [EMAIL_TO_TASK_SPEC.md](EMAIL_TO_TASK_SPEC.md) | proposal (#134) |
| [NATIVE_PROJECT_SHARING_SPEC.md](NATIVE_PROJECT_SHARING_SPEC.md) | superseded by PROJECT_SHARING_SPEC |
| [COMPANION_DEVICES_SPEC.md](COMPANION_DEVICES_SPEC.md) | building (ADR 0034, ADR 0035): needs-you views, limited session, live nudge, voice for the watch and the desk orb |
| [WEB_CLIENT_SPEC.md](WEB_CLIENT_SPEC.md) | proposal (#21); WB2 uses the Rust core's WASM (ADR 0025) |
| [CLOUDFLARE_ACCOUNT_MOVE.md](CLOUDFLARE_ACCOUNT_MOVE.md) | accepted; ADR 0018 |
| [ANDROID_CLIENT_SPEC.md](ANDROID_CLIENT_SPEC.md) | accepted (#20); shared Kotlin core for Windows; rules move to the Rust core in C1 (ADR 0025) |
| [WINDOWS_IMPLEMENTATION_PLAN.md](WINDOWS_IMPLEMENTATION_PLAN.md) | building (#136); fixture spike, Win365 acceptance and implementation assignments |
| [SHARED_CORE_SPEC.md](SHARED_CORE_SPEC.md) | accepted (ADR 0025); C0 and C5 done, C4 in progress (#250): one Rust core for rules and sync decisions |
| [HAPTICS_SPEC.md](HAPTICS_SPEC.md) | building: H1–H4 done, H5 (device tuning) open |
| [TASK_DATES_SPEC.md](TASK_DATES_SPEC.md) | accepted (ADR 0027): When, deadline, Today and overdue as core actions + one read model |
| [REGISTRY_AUDIT.md](REGISTRY_AUDIT.md) | audit 2026-11-21; hard-coded copy vs registry, l10n proposal (#214–#219) |
| [SEPTASK_ANDROID_PLAN.md](SEPTASK_ANDROID_PLAN.md) | superseded by ANDROID_CLIENT_SPEC.md |
| [TASK_CONVERSATIONS_PLAN.md](TASK_CONVERSATIONS_PLAN.md) | shipped — historical, still the design rationale |
| [TASK_CONVERSATIONS_PHASE0.md](TASK_CONVERSATIONS_PHASE0.md), [PHASE1](TASK_CONVERSATIONS_PHASE1.md), [SEPTASK_CONVERSATIONS_PLAN.md](SEPTASK_CONVERSATIONS_PLAN.md) | shipped — historical |
| [AI_TASKS_EXPLAINER.md](AI_TASKS_EXPLAINER.md) | user copy; iCloud claims change at cutover |
| [TASK_ROW_LANGUAGE_SPEC.md](TASK_ROW_LANGUAGE_SPEC.md), [TRIAGE_BAND_SPEC.md](TRIAGE_BAND_SPEC.md), [QUICK_ADD_CONTRACT.md](QUICK_ADD_CONTRACT.md) | built |
| [ORDERING_AND_HEADINGS_PLAN.md](ORDERING_AND_HEADINGS_PLAN.md), [DRAG_AND_DROP.md](DRAG_AND_DROP.md) | shipped — historical |
| [RECENTLY_DELETED_SPEC.md](RECENTLY_DELETED_SPEC.md), [TASK_LIST_OBSERVATION_PLAN.md](TASK_LIST_OBSERVATION_PLAN.md) | proposal |
| [SEPTASK_APPKIT_PARITY.md](SEPTASK_APPKIT_PARITY.md), [SEPTASK_APPKIT_SURFACES.md](SEPTASK_APPKIT_SURFACES.md), [SEPTASK_APPKIT_LOCALIZATION_HANDOFF.md](SEPTASK_APPKIT_LOCALIZATION_HANDOFF.md) | AppKit shell notes |
| [RELEASING-MAC.md](RELEASING-MAC.md), [RELEASING-ANDROID.md](RELEASING-ANDROID.md); store copy and panels are in the private `septena/studio` repo | current |
| Marketing image skills (photo, composite, 3D, bento) | moved to `septena/studio` on 2026-11-27 |
| [NATIVE_SCENES_SPEC.md](NATIVE_SCENES_SPEC.md) | superseded (ADR 0022 rejected): website scenes draw from the registries |
| [PLATFORM_CHROME.md](PLATFORM_CHROME.md) | draft spec: what each OS draws on a marketing screen (iOS 27, iPadOS 27, macOS 27, Android 17, Windows 11) |

### Registries

| Doc | Status |
|---|---|
| [REGISTRY_PLAN.md](REGISTRY_PLAN.md) | accepted (ADR 0020): P0 translation pipeline → P4 reach |
| [REGISTRY_AUDIT.md](REGISTRY_AUDIT.md) | audit 2026-11-21 |

### AI and MCP

| Doc | Status |
|---|---|
| [CONNECTOR_DIRECTORY_SUBMISSION.md](CONNECTOR_DIRECTORY_SUBMISSION.md) | ready for mz to submit (#85): Claude & ChatGPT directory packet |
| [agent-provenance-spec.md](agent-provenance-spec.md) | superseded in part (permanent provenance shipped 2026-11-24) |
| [agent-provenance-gateway-handoff.md](agent-provenance-gateway-handoff.md) | landed — historical |
| [CORE_AI_iOS27_PREP.md](CORE_AI_iOS27_PREP.md) | research, pre-implementation |
| [SPOTLIGHT_READABILITY_PLAN.md](SPOTLIGHT_READABILITY_PLAN.md) | phases 0–2 built |
| [APP_INTENTS_BACKLOG.md](APP_INTENTS_BACKLOG.md) | historical — open items moved to GitHub issues (2026-11-20) |

### Design system and UI

| Doc | Status |
|---|---|
| [DesignSpec.md](DesignSpec.md) | canonical |
| [PREMIUM_LANGUAGE.md](PREMIUM_LANGUAGE.md) | canonical: plan mark, wordmark, benefit rows for every paid surface |
| [FEATURE_MAP.md](FEATURE_MAP.md) | generated: feature status per platform |
| [PAGE_CHROME_SPEC.md](PAGE_CHROME_SPEC.md), [GLASS_DOTS_SPEC.md](GLASS_DOTS_SPEC.md) | mixed: see each status line |
| [SETTINGS_UX_SPEC.md](SETTINGS_UX_SPEC.md) | proposal (task app Settings IA + `registry/settings.json` v2, S0–S3) |
| [CUSTOMIZATION_SPEC.md](CUSTOMIZATION_SPEC.md) | building (#196, ADR 0019; procedural Header Wash textures + exotic-fruit accents, C0–C4) |
| [SETTINGS_FLATTEN_SPEC.md](SETTINGS_FLATTEN_SPEC.md) | superseded by SETTINGS_UX_SPEC.md |
| [LOCALIZATION_PLAN.md](LOCALIZATION_PLAN.md) | pt-BR pilot done |

### Life OS

The docs that cover only the life OS were removed on 2026-11-24 (an exception to
rule 4, because the product left the repo). They are in
`michellzappa/septena-life` and under the tag `septena-life-archive`.

### Product and identity

[MESSAGING.md](MESSAGING.md) (moved to the Septena Starlings workspace), [MAKER_IDENTITY.md](MAKER_IDENTITY.md),
[feedback.md](feedback.md),
[BACKLOG.md](BACKLOG.md) (historical: open items moved to GitHub issues on
2026-11-20).
