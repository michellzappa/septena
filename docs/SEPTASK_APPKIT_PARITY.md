# Septask AppKit shell — parity backlog

What the AppKit shell (`Septask/SeptaskKit*.swift`) still lacks versus the
SwiftUI task surface it replaced on macOS. **This file is only the gap list.**

- Context, the decision, the working rules, and the AppKit hazards that cost a
  session each live in `docs/SEPTASK.md` ("AppKit shell on macOS"). Read that
  first.
- Surface tiers (popover / command panel / alert) are in
  `docs/SEPTASK_APPKIT_SURFACES.md`.
- The port's history — what landed when, and why each thing was built the way
  it was — is in git. `git log --follow docs/SEPTASK_APPKIT_PARITY.md` reaches
  the session-by-session record this file used to carry inline.

Everything below is still *reachable* today: the SwiftUI shell is one menu item
away (Go ▸ Classic Window, ⌥⌘0). It just isn't in the fast shell.

Status legend: **[P2]** real feature loss · **[P3]** polish / rarely reached ·
**[—]** deliberately not porting.

Verified against the code on 2026-08-23.

---

## Open question — row title wrapping

The AppKit row truncates a long title to one line. SwiftUI's canonical row
(`TaskComponents.swift`) uses `.lineLimit(2)`, so a long title wraps and grows
the row there. A prior session removed the matching AppKit implementation
(`taskTitleWidth` / `heightForTask` in `SeptaskKitTheme.swift`); the working
grow-row-on-wrap version, guarded against the pre-layout near-zero-width launch
bug, is in git history around that removal.

Left as-is pending MZ's call — the denser single-line list looks deliberate,
but it diverges from SwiftUI, so one of the two is wrong.

## 1. Task editing

- **[P2] Hero-glide between closed row and open editor**
  (`matchedGeometryEffect` anchors on title + checkbox). Cosmetic, but it is
  what makes inline editing read as continuous rather than modal. The largest
  remaining item.
- **[P3] Notes inline** — the shell has notes in the inspector only.

## 2. Task Conversations

The thread renders in the inspector below Notes, per
`docs/SEPTASK_CONVERSATIONS_PLAN.md`. Two things the plan listed as explicit
v1 non-goals are still open:

- **[P3] `subtasks` (epic decompose)** render as the stored ids, nothing richer.
- **[P3] No human override of assignee** — end state, acceptance and assignee
  are read-only.

## 3. Structure CRUD

Areas, projects and headings are fully manageable from the shell. What's left:

- **[P3] Project detail / notes**, and area attachment (repo / calendar / feed
  context feed).

## 4. Views and routes

- **[P3] Things import** (`ThingsImportView`) — a one-time migration, fine in
  the classic window.
- **[P3] Task patterns section.**
- **[P3] Time travel sheet** (DayClock debug offset). The shell honors
  `SeptenaDate.today` everywhere but cannot *change* it.

## 5. Platform integration

- **[P3] In-list search field.** Quick Find (⇧⌘F) covers global search; there
  is no filter-within-this-list field.
- **[P3] The toolbar carries no items.** The window has an `NSToolbar`, but it
  exists for the title, the material and the drag region — the SwiftUI window's
  search and add buttons have no counterpart.
- **[P3] External drag/drop.** Task drags are `forLocal: true` only: a task
  can't be dragged out to Mail/Finder as text, and dropping text or files into
  the list doesn't create tasks.
- **[P3] Multi-window.** The shell is a single-window singleton
  (`SeptaskKitWindowController.current`); SwiftUI had a `WindowGroup`.
- **[P3] Live text-size refresh** — rows pick up a new text size on the next
  reload, not immediately.
- **[P3] Services / Share / Print menus.**
- **[P3] Accessibility beyond the floor.** VoiceOver roles, labels and the
  shared cue vocabulary are wired; the task rotor, an FKA regression pass and a
  Dynamic Type audit stay on `docs/BACKLOG.md`.

## 6. Smaller behavior gaps

- **[P3] Logbook has no bulk clear/purge.**
- **[P3] Calendar events are inert** — no click-through to Calendar.app.
- **[P3] Keyboard Shortcuts sheet** (⌘/ in SwiftUI). The menu bar is arguably
  the better answer on macOS, so this may really be a **[—]**.

## Deliberately not porting

- **[—] Settings and other form surfaces.** Hosted SwiftUI in an AppKit window
  (⌘, → `SeptaskKitSettingsWindow`). They are not latency surfaces; porting
  them is drift.
- **[—] iOS/iPad task UI.** Unchanged and still SwiftUI.

---

## Working on this

- **Build/verify loop**: `xcodegen generate`, then
  `scripts/build.sh SeptaskMac 'platform=macOS'`. That compile is the ONLY
  green gate — nobody tests by running the app (root `CLAUDE.md`). Run
  `scripts/lint-design.sh` before calling something done.
- **Every `SeptaskKit*.swift` file starts with `#if os(macOS)`** and compiles
  into `SeptaskMac` only — don't expect these types to exist when building the
  `Septask` (iOS) scheme.
- Keep this file current as items land: strike what shipped, and put the
  reasoning in the commit message rather than back into this file.
