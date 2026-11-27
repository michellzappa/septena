# One-click data export — spec

**Status:** proposal (2026-11-21). Defaults in §8 stand unless mz overrules.
**Decisions:** [ADR 0002](adr/0002-own-backend-replaces-icloud.md), [ADR 0007](adr/0007-septena-is-the-task-app.md), [ADR 0010](adr/0010-free-server-tier-with-limits.md), [ADR 0015](adr/0015-shared-registries-for-cross-platform-clients.md).
**Builds on:** `Septask/SeptaskDataTransfer.swift` (`TaskJSONTransfer`, `septena_export_version: 1`), `Septask/SeptaskSettingsView.swift`, `backend/src/store/TaskStore.ts`, `registry/entities.json`.
**Tracking issue:** [#130](https://github.com/septena/septena/issues/130).
**Owner of decisions:** mz. Defaults chosen by the author are marked *(default)*.

## 1. Goal

Turn Septena's existing local JSON export (`Septask/SeptaskDataTransfer.swift`) into a complete, trustworthy, one-click export across **JSON (lossless archive)**, **Markdown (human-readable)**, and **CSV (spreadsheet/importer-compatible)** — always **free on every level** (no account, free account, paid) per ADR 0010.

**UX / IA ideal (progressive disclosure):** One primary `"Export Backup"` button (lossless JSON) upfront in Settings ▸ Privacy / Data, with a compact format picker (`JSON Backup` · `Markdown` · `CSV`) and an optional `"Include attachments"` toggle revealed cleanly rather than a wizard.

## 2. What exists and what is missing

**Exists (`Septask/SeptaskDataTransfer.swift`):**
- `TaskJSONTransfer.exportJSON(context:)` exports `area`, `project`, `task`, and inline base64 `task_attachment` rows in the `septena_export_version: 1` envelope (compatible with Septena Life backups).
- Works 100% locally and offline with no account.

**Missing:**
1. **Complete task-app coverage in JSON:** conversations (`conversationJSON` / turns), checklists (`#76`), tags (`#96`), timed reminders (`#97`), star (`#127`), start/end times (`#128`), and soft-deleted / history metadata.
2. **Markdown export** (single `.md` file or folder hierarchy: Area → Project → Section → `- [ ]` / `- [x]` tasks + indented checklist items + notes + dates/tags).
3. **CSV export** (RFC 4180 UTF-8 with BOM for Excel compatibility; flat columns for title, status, area, project, section, when, deadline, repeat, tags, starred, notes, completedAt, created).
4. **Large attachment bundle option (`.zip`)** so accounts with hundreds of MB of photos don't explode RAM with base64-encoded JSON *(default: inline base64 in `.json` when total attachment bytes ≤ 25 MB, or `.zip` archive containing `septena-tasks.json` + `attachments/<id>-<filename>` when "Include attachments" is toggled and files exist)*.
5. **Optional server-side full-history export (`GET /v1/export`)** on `api.septena.app` so signed-in users (and future Web/Android clients) can export full change history + synced R2 attachments from the backend too.

## 3. Format contracts

### 3.1 Canonical JSON (`septena_export_version: 1`)
- Keep `septena_export_version: 1` backward-compatible by adding optional keys and new tables (`checklist_item`, `tag`, `task_tag`, `task_convo`, `change_log` when exported from server) — older readers ignore unknown keys/tables.
- Every task column defined in `registry/entities.json` MUST be serialized in `TaskJSONTransfer.taskDict` and restored in `upsertTask` (enforced by a unit test comparing exported keys against `registry/entities.json`).
- Table `task_ref` (`TASK_REFERENCES_SPEC.md` §9): `id`, `taskID`, `key`, `kind`, `role`, `snapshot` (object), `position`, `createdBy`, `lastSeenAt`, `createdAt`. An absent value is an absent key, as in `checklist_item`. The app's exporter reads the local store, so it writes this table from R1 on (#387), when that store has references. `GET /v1/export` (EX2) writes the same rows.
- Round-trip invariant: exporting a local store to JSON and importing into a fresh store via `TaskJSONTransfer.apply` (and later `#99`) produces an identical task dataset with zero lost fields.

### 3.2 Markdown (`septena-tasks-YYYY-MM-DD.md`)
- Ordered cleanly: **Inbox**, then **Areas** (with their **Projects** and **Sections**), then **Standalone Projects**, then **Logbook (Completed)**.
- Task line: `- [ ] Title` (or `- [x] Title`), followed by subtle inline metadata (`(when: 2026-11-22, deadline: 2026-11-30, repeat: Weekdays, ★)`), indented notes block, and indented `- [ ]` / `- [x]` checklist items (`#76`), then one indented line per reference: its title, then its URL if there is one (`#387`).
- Deterministic ordering by `position` so diffs are clean if a user commits exports to git or drops them in Obsidian.

### 3.3 CSV (`septena-tasks-YYYY-MM-DD.csv`)
- Columns: `id,title,status,area,project,section,today,scheduled,deadline,reminder_at,recurrence,starred,tags,checklist,notes,created,completed_at,references`. `references` holds the reference keys, separated by a space (`#387`).
- Strictly RFC 4180 escaped (quotes, embedded newlines, commas), UTF-8 with optional BOM (`\uFEFF`) so Excel/Numbers open Unicode cleanly.

## 4. UX & Settings placement

- Surface in `SeptaskSettingsView.swift` under **Privacy** (and linked from Account / Data), on Mac, iPhone, and iPad:
  - Primary button: **Export Backup (JSON)** → native save panel (`NSSavePanel` on Mac, Share Sheet / `fileExporter` on iOS).
  - Compact secondary row (progressive disclosure): Format (`JSON` / `Markdown` / `CSV`) + `Include completed tasks` (on by default) + `Include attachments` (off by default for Markdown/CSV, optional for JSON/ZIP).
  - One-line honest privacy note: `"Exports are unencrypted files stored where you choose."`
  - Progress + Cancel button for large exports (> 100 tasks or attachments).

## 5. Backend export endpoint (signed-in & future Web/Android)

- `GET /v1/export?format=json|markdown|csv` on `api.septena.app` (authenticated with user's session token; free on every plan per ADR 0010).
- Streams the user's `TaskStore` snapshot (areas, projects, tasks, checklists, tags, convos, turns, change history). Attachment binaries are listed by pointer/download URL in JSON or bundled client-side to stay within Worker memory limits.

## 6. Phases

| Phase | Scope | Depends on |
|---|---|---|
| **EX0 — Lossless JSON parity + Markdown & CSV generators** | Extract pure formatters (`TaskExportMarkdown`, `TaskExportCSV`) into `SeptenaCore`, add missing `TaskEntity` fields (conversations, fade fields, recurrence v2, future hooks) to `SeptaskDataTransfer.swift`, and add round-trip + RFC 4180 unit tests. | None |
| **EX1 — Progressive-disclosure Export UI (Mac & iOS) + ZIP attachment archive** | Wire format selector, `Include completed` / `Include attachments` toggles, `.zip` archive support when attachments exceed 25 MB, progress/cancel, and Settings placement in `SeptaskSettingsView.swift`. | EX0 |
| **EX2 — Backend `GET /v1/export` endpoint** | Add free authenticated export endpoint on `api.septena.app` serving JSON/Markdown/CSV from `TaskStore` (unblocks Web `#21` and Android `#20`). | EX0 |

## 7. Verification

- Round-trip test: export → import in empty in-memory SwiftData container preserves 100% of fields.
- RFC 4180 CSV test (commas, quotes, newlines, emoji, non-ASCII).
- `scripts/build.sh SeptenaMac 'platform=macOS'` and `scripts/build.sh SeptaskMac 'platform=macOS'` both green.

## 8. Open questions

| Question | Default |
|---|---|
| Default export format | Lossless JSON (`septena_export_version: 1`) *(default)* |
| Attachments in JSON export | Inline base64 up to 25 MB total; `.zip` bundle above 25 MB or when user picks archive *(default)* |
| Include completed & Recently Deleted by default | Completed included; Recently Deleted included in JSON backup (flagged with `deletedAt`) and excluded from Markdown/CSV *(default)* |
| Plan gating | Always free on every tier (no account, free account, paid) per ADR 0010 *(default)* |
