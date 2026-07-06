# Septena Backlog

Tracked work, not urgent. Ordered loosely by appeal, not priority.

## Interactions

- **Magic Plus drag-to-file** — drag the floating button onto Today / Upcoming targets to schedule on creation. Tap-to-create is enough for now.

## Lists

- **Logbook grouped by completion date** — Today / Yesterday / This Week / Earlier headers in the Logbook view.
- **Project headings** — manual section dividers inside a project (not a sort; preserves manual order). Requires a `Heading` model alongside tasks in the project's ordered children. Defer until a real project asks for it.

## Data model (deferred)

- **Checklists / subtasks** — nested checkable items on a task. Not yet, but likely needed.

## Tasks — today logic (tech debt)

Found during the `due`→`deadline` vocab cleanup (2026-06-14); not vocabulary, so left untouched. Retiring the `today` flag (already seamed in `TaskEntity.isOnToday`, "Step 4 of the due/when simplification") dissolves the first two outright.

- **Sticky `today` pins never expire** — `isOnToday` short-circuits on `if today { return true }`, so a task pinned Monday stays in Today indefinitely until completed or explicitly removed. Either intended (Things-style) → then the next item is pure dead weight; or pins should age out → then rollover logic is missing.
- **`todaySetOn` is write-only dead weight** — stamped on every pin and carried through SwiftData + CloudKit + the wire + MCP output + migration, but read by nothing. Someone planned pin-expiry via this date and never wired it. Delete it (or wire it).
- **Today-membership union is copy-pasted in 3+ places** — the `today || scheduled≤today || deadline≤today` rule is re-implemented in `SidebarView` counts, `TaskReads`, and `LocalCache.convert`, despite the "everyone reads `isOnToday`" intent. They agree today; they'll drift when the rule changes (e.g. the flag retirement). Collapse onto the single `isOnToday`.
- **`SeptenaDate.today` ignores time-travel** — it calls naked `Date()`, so `isOnToday`/`isOverdue` don't follow `DayClock.debugDayOffset` while views (reading `clock.today`) do. Tasks' today/overdue state diverges in time-travel and across a midnight while the app's open. Fix = consumers read `DayClock`, not change `SeptenaDate` (which seeds the clock).

## Multi-platform

- **iPad** — the open platform gap. `NavigationSplitView` 3-column when `horizontalSizeClass == .regular`, pointer hover, cross-list drag-and-drop, iPad keyboard shortcuts. Today iPad rides incidental size-class branches only — no top-level split view. macOS is already native (`.commands`, menu-bar extra, ⌘ shortcuts, context menus — shipped).

## Supporters

- **Supporter early-access to TestFlight builds (Path A)** — wire the actual "Join
  the beta" affordance: a button in the supporter section that opens a **public
  TestFlight link**, shown only when `plusUnlocked` (the StoreKit entitlement the
  app already tracks via `SupportStore.isSupporter`). Perk copy already ships
  (`SeptenaPlus.perks` → "Get new versions first"); this backlog item is just the
  join button + the pasted-in public link. **No email field, no server, no
  Cloudflare** — that was the whole reason to pick Path A: it keeps the "no data
  collected / nothing sold" promise the supporter pitch makes. Caveats: the public
  link is a bearer token (a supporter can reshare it; someone who cancels keeps it
  — acceptable for a free beta, cap the tester count); an *external* TestFlight
  group needs Beta App Review on the first build; internal-tester slots don't apply
  (supporters aren't on the ASC team). Rejected **Path B** (collect email → add as
  external testers, automated via an App Store Connect API Worker) — more
  machinery plus a PII store that contradicts the supporter promise; only worth it
  if per-person revocable invites ever become a hard requirement.

## Claude / MCP

- **Agent deletion of entries** — let Claude delete via MCP, phased and gated (asymmetry: a wrongful delete loses data silently). Phase 1: delete only Claude-authored rows (`source="mcp"` provenance) — ~zero risk, no toggle. Phase 2: delete any data behind a per-connection access level (Read-only / Read-write / Full), because local (your Claude Code) and hosted (Claude chat on mobile) have different trust. Surface in a unified "Claude Access" settings pane — hosted card iOS+Mac, local card Mac-only. Not yet.

## Explicitly out of scope

- Tags
- "This Evening" bucket
- Manual sort controls (rely on opinionated defaults + manual drag-reorder)
