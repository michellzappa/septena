# Attachments Mac parity & paid sync gating — spec

**Status:** proposal (2026-11-21). Defaults in §6 stand unless mz overrules.
**Decisions:** [ADR 0002](adr/0002-own-backend-replaces-icloud.md), [ADR 0007](adr/0007-septena-is-the-task-app.md), [ADR 0010](adr/0010-free-server-tier-with-limits.md), [ADR 0015](adr/0015-shared-registries-for-cross-platform-clients.md).
**Builds on:** `docs/SYNC_SUBSCRIPTION_SPEC.md`, `SeptenaCore/TaskAttachments.swift`, `Septena/Shell/Tasks/TaskAttachmentsPanel.swift`, `Septask/SeptaskKitRowViews.swift`, `Septask/SeptaskKitComposer.swift`, `Septask/SeptaskKitInspector.swift`.
**Tracking issue:** [#131](https://github.com/septena/septena/issues/131).
**Owner of decisions:** mz. Defaults chosen by the author are marked *(default)*.

## 1. Goal

Close the macOS parity gap for task file attachments — Septena's clearest day-one advantage over Things 3 — while honoring the Free vs. Paid attachment sync boundary from ADR 0010 and `docs/SYNC_SUBSCRIPTION_SPEC.md` (local-only on the device that added them on Free; 10 GB R2 sync across devices on Paid).

**UX / IA ideal (progressive disclosure):** Tasks without attachments show zero paperclip/icon clutter. Rows with attachments show a quiet paperclip + count indicator; adding files works via drag-and-drop onto a task/composer/inspector, paste (`⌘V` with file/image on clipboard), or the Attach button.

## 2. Paid sync gating (plan-table driven, never plan-name checks)

Per `docs/SYNC_SUBSCRIPTION_SPEC.md` §3.2 and `docs/adr/0010-free-server-tier-with-limits.md`:
- Client reads the server's synced entitlement limits (`attachmentsSyncEnabled: Bool`, `attachmentsQuotaBytes: Int64`) — **never hardcodes plan names**.
- **Free / no-account:**
  - Users can still attach files locally on the device they're using ("the device is free").
  - Attachment metadata row syncs (or stays marked `localOnlyDeviceName`) without uploading bytes to R2, so another device sees a calm, one-line placeholder: `"1 file on your iPhone — Plus syncs files everywhere"` with a single non-nagging upgrade action.
- **Paid (Plus / reverse trial):**
  - Automatic background R2 upload on attach + lazy on-demand download + local cache on other devices, enforcing the 25 MB per-file and 10 GB per-account limits with clear inline error copy if exceeded.

## 3. Mac UI parity (`Septask/SeptaskKit*.swift`)

1. **Task rows (`SeptaskKitRowViews.swift`):**
   - Trailing quiet paperclip glyph (plus count when > 1) only when `attachmentCount > 0`.
2. **Composer & Inspector (`SeptaskKitComposer.swift`, `SeptaskKitInspector.swift`):**
   - Attach button (`NSOpenPanel`), paste image/file from `NSPasteboard`, drag-and-drop file(s) directly onto a task row, open composer, or inspector.
   - Compact thumbnail / file-chip strip with **Quick Look** (`QLPreviewPanel` via click / Space on focused chip), Reveal/Save Copy, and Delete (recorded on `TaskUndo` so `⌘Z` restores the attachment metadata + file before purge!).

## 4. Phases

| Phase | Scope | Depends on |
|---|---|---|
| **AT0 — Plan-table attachment sync gate & cross-device placeholder** | Wire client-side check against server limits (`attachmentsSyncEnabled` / `attachmentsQuotaBytes`), keep local-only attachments working signed-out and on Free, and render the calm `"N files on <device>"` placeholder when remote bytes are not synced. | `#44` (backend entitlement row) |
| **AT1 — Mac task-row, composer, inspector & Quick Look parity** | Add trailing paperclip indicator on `SeptaskKitRowViews`, drag-and-drop / paste / file-picker attach + Quick Look + undoable delete in `SeptaskKitComposer` and `SeptaskKitInspector`. | None (can ship UI ahead of AT0 gate enforcement) |

## 5. Verification

- `scripts/build.sh SeptenaMac 'platform=macOS'` and `scripts/build.sh SeptaskMac 'platform=macOS'` both green.
- Manual test by mz on Mac: drag a PDF and a screenshot onto a task row, press Space for Quick Look, delete and `⌘Z` undo, verify file syncs on Paid and shows local-only placeholder on Free.

## 6. Open questions

| Question | Default |
|---|---|
| Local attachments on Free | Allowed locally on the device that added them; zero R2 upload *(default, ADR 0010)* |
| Max single file size | 25 MB (matches `registry/entities.json` `maxAttachmentBytes`) *(default)* |
| Undo on attachment delete | Keep file in temp/trash dir until session exit so `⌘Z` restores it cleanly *(default)* |
