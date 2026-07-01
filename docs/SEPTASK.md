# Septask — standalone Tasks app plan

**Status:** planning / not started. Working codename: *Septask*.

A plan for extracting Septena's Tasks surface into a **second App Store app that
shares Septena's data backend** — same CloudKit container, same source files, a
clear seam, runnable in parallel with the full app on the same device. This is
deliberately **not** a fork/clone; it is a second composition root over shared
sources.

---

## 1. Why (and why not a clone)

The pull is real: Tasks is Septena's most *legible* surface. "A private,
local-first task manager an AI can drive" is understood in five seconds;
"a life operating system that correlates your domains" is not. Tasks has an
instant comparison set (Things, Todoist, Reminders, TickTick), real ASO
keywords, and near-zero onboarding friction ("open it and type"). A focused
Tasks app is a plausible distribution wedge and funnel into Septena.

The trap is doing it by **cloning the codebase**. That fights us twice:

- **Architecture** — "just clone tasks" is really an *extraction*; the tasks
  feature rides on `SeptenaCore` (mutators, `DayClock`, `SeptenaServices`,
  CloudKit zone `septena-v1`). A clone drags most of the core plus a shell into
  a second repo, then every fix lands in two places — re-creating exactly the
  branch-divergence disease `CLAUDE.md` spends a whole section preventing.
- **Thesis** — the manifesto is *"one private app for everything."* A separate
  data island contradicts it and amputates the cross-domain correlation that is
  the actual moat.

**Resolution:** keep it one repo. Ship a second *target*, not a second
codebase. Tasks logic/UI lives once, in shared source folders; both apps
compile the same files. The full app is one composition root; Septask is a
thinner one. Data is shared through CloudKit, so the two run in parallel over
the same tasks.

### Naming (open)

`Septask` (Sept‑ + task) is clever — it encodes lineage + category in seven
letters — but it reads a register *below* the parent brand (utility, not
instrument), and only signals to people who already know Septena. Decision
still open, and it follows from strategy:

- **Funnel-first** (bait for Septena, siblings are obvious) → `Septask` is
  sharp; ship it.
- **Standalone-first** (earns the upsell later, stands in the Tasks category on
  its own) → prefer a name that says something *true* to a stranger. Current
  front-runner: **Tend** (matches the "nudge, don't nag" cadence philosophy;
  you *tend* tasks/chores/habits over time), with "by Septena" as subtitle.

Codename `Septask` is used throughout this doc regardless.

---

## 2. The governing model: source-inclusion, not modules

In this repo, sharing is **not** SPM/frameworks — it's *source-file inclusion*.
Targets list `- path: SeptenaCore` (full apps compile the whole folder) or
cherry-pick individual files (`SeptenaWidgets` pulls `Shell/UI/Theme.swift`,
`SectionGlyph.swift`, …). `project.yml` line ~366 says so explicitly:
*"SeptenaCore is NOT a package."*

So the sharing primitive is: **one copy of each file on disk, compiled into
multiple targets.** Edit `TaskListView.swift` once → both apps rebuild with the
change. That *is* the elegant no-duplication seam, and we already trust it for
the watch and widgets.

### Structure — three shared rings + one thin shell

```
SeptenaCore/          data, mutators, CKEngine, DayClock, services, models   ← shared whole
Septena/Shell/UI/     design system: Theme, SectionDrawer, scaffolds, rows   ← shared (partly already)
Septena/Shell/Tasks/  the feature: list, detail, composer, triage, import    ← the island to share
   ↑ both targets include these ↑
Septena/        (full app shell)         SeptenaTasks/   (standalone shell)
  mounts every plugin/section              NO section system — navigates
                                           straight into the task views
```

`project.yml` sketch for the new target (near-copy of `Septena`, narrower
sources, no watch/widgets/live-activity deps):

```yaml
SeptenaTasks:
  type: application
  platform: iOS
  sources:
    - path: SeptenaCore          # same files → schema literally cannot diverge
    - path: Septena/Shell/UI
    - path: Septena/Shell/Tasks
      excludes:
        - TasksDestinationView.swift   # section-drawer adapter — full-app only
    # + the task-home view (pin exact file in P1) and any minimal primitives
    - path: SeptenaTasks         # NEW thin shell: entry, root scene, Settings subset, assets
```

### The seam enforces itself

Point the new target at those folders and build. **Every compile error is the
seam telling you the truth** — a tendril from `Shell/Tasks` into the rest of the
shell (Dashboard/Coach/Goals/Intelligence). Resolve each exactly three ways:

1. **Relocate** — actually a shared primitive → move into `Shell/UI` (both apps
   gain it).
2. **Cut** — a real cross-section coupling → sever it (shouldn't exist in a
   standalone anyway).
3. **Stub** — full-app-only chrome → the thin shell provides a no-op /
   alternative.

Afterward the seam is permanent and self-checking: couple tasks to the
dashboard by accident and **the standalone target stops compiling.** Free seam
integrity on every build — stronger than a module's `public`/`internal` line.

---

## 3. Data + running both in parallel

Both targets compile the same `SeptenaCore`, so `Persistence.swift`,
`CKEngine.swift`, every mutator, and `SeptenaServices` are shared by
construction. To make them the *same data*:

- **Hand-write `SeptenaTasks.entitlements`** (entitlements are hand-maintained
  here) listing the **same** CloudKit container `iCloud.com.septena.cloud` and
  the **same** App Group; bundle id `com.septena.tasks`. Two App Store apps from
  one team may share a container.
- **Two installs = two local SwiftData mirrors, one CloudKit zone.** They
  converge through `CKSyncEngine` exactly as the iOS and Mac apps do today — a
  solved problem in this codebase, not a new risk.
- **Do NOT share the SQLite file across processes** via the App Group.
  Two-process SwiftData writers is precisely the "needs something clever to
  behave" smell `CLAUDE.md` bans. CloudKit is the convergence point; each app's
  mirror stays private.
- **Snappy same-device updates (optional):** post a Darwin notification
  (`CFNotificationCenterGetDarwinNotifyCenter`) on write to nudge the other app
  into a foreground fetch — leaning on the existing "foreground fetch is the
  reliable refresh path" truth rather than inventing live cross-process sync.
- **Schema can't drift** — both apps compile the identical model files, so the
  auto-managed schema is the same set; Septask just touches a subset
  (Task/Area/Project). Keep schema *deploy* ownership in the full app.

---

## 4. The seam, measured (dependency ledger)

Tasks UI is already a clean island: `Septena/Shell/Tasks/` (12 files) +
`Shell/Sections/Plugins/TasksPlugin.swift` + `Shell/Sidebar/`. The
"surrounding logic" we want to avoid is concentrated in the **adapter** files,
not the feature. `TaskListView` (the real surface) is nearly clean; the
section-ness lives in `TasksDestinationView` (its own header says it *is* the
`SectionDrawer` embedding).

| Dependency | Verdict for Septask | Why |
|---|---|---|
| `TaskMutator`, `LocalCache`, `DayClock`, `SeptenaServices`, `SeptenaTask`/`Area`/`Project` | **Keep** | This *is* tasks data. All in `SeptenaCore`, UI-free, included whole. |
| `TaskListView`, `TaskComponents`/`TaskRow`, `TaskComposer`, `TaskDetailView`, `TaskDraft`, `RemindersInboxSection`, `ThingsImportView` | **Keep** | Strictly tasks UX. The standalone-ready content. |
| `TasksDestinationView`, `TasksPlugin` | **Exclude** | Section-drawer / plugin adapters — pure full-app embedding. Never compiled by Septask. |
| `SectionTheme` (the one real tendril in the content) | **Shim → accent, see §5** | Just an accent provider. Inject a one-section theme seeded from the shared tasks `SectionEntity` color. |
| `LogCommitCenter` (celebration) | **Drop** | Already `Optional`/nil-safe by design — shell just doesn't provide it. |
| `DrawerMode` / Patterns heatmap | **Gate** | Shell choice: Log-only, or keep Patterns. Small enum, no machinery. |
| EventKit calendar agenda, `ConversationEngine`/`ConversationCard` | **Gate** | Tasks-adjacent but optional; shell toggles so v1 can ship lean. |

Environment the task views expect (from `TasksDestinationView`) — the shell's
whole job is to provide these: `TaskMutator`, `DayClock`, a one-section
`SectionTheme`, `modelContext`, the `SettingsKey` AppStorage values, and **nil**
`LogCommitCenter`.

---

## 5. Product decisions (locked)

- **Task-home, not the section system.** Septask does **not** mount
  `SectionRegistry` / `SectionDrawer` / `NextBlocks` / the multi-plugin registry.
  The thin shell navigates straight into `TaskListView` from a task-scoped home
  (areas/projects → list → detail). The section machinery stays a full-app
  concept.
- **Strictly tasks data + UX.** Avoid Septena's surrounding logic wherever
  possible. `SeptenaCore` is compiled whole (it's UI-free and self-contained;
  slicing it is the watch target's pain — don't), but the UI/orchestration layer
  is minimal.
- **Accent — selectable in Septask, identical to Septena tasks.** Reuse the
  existing section-color write boundary (`SettingsMirror.swift` ~L391–402,
  `entity.color = hex`), scoped to key `"tasks"`, surfaced as a picker in
  Septask Settings.
  - The accent **is** the shared tasks `SectionEntity.color`. Editing it in
    Septask writes the same CloudKit field → propagates **both ways** and across
    devices. That's why the UX comes out identical for free: both apps'
    `SectionTheme` read the same row.
  - Footnote: this means changing it in Septask *also* recolors the Tasks tile in
    Septena/watch/widgets — desired here. A truly *private* Septask accent would
    need a new local field (more logic); not building that unless divergence is
    later wanted.

### Open / to pin during P1

- **Task-home view file.** The `SidebarRootView` name in prior notes is stale
  (no such file today). Pin the actual task-scoped home view; the compiler pass
  confirms it's task-scoped the moment Septask includes it.
- **Naming** — funnel-first (`Septask`) vs standalone-first (`Tend`); see §1.
- **v1 scope of the gated features** (Patterns, calendar agenda, task
  conversations, MCP tasks-subset, a watch app — likely *not* v1).

---

## 6. Workflow — phased, build-gated, on `main`

Each phase lands green; the **full Septena app must build and behave
identically throughout** (extraction is pure relocation + a new target, never a
behavior change to the existing app). Build through `scripts/build.sh` (shared
lock). No branches unless asked.

- **P0 — Prove the premise, move no feature code.**
  Add an empty `SeptenaTasks` target (sources: `SeptenaCore` only) +
  `SeptenaTasks.entitlements` (same container + App Group) + a ~30-line
  `SeptenaTasks/App.swift` that runs `await SeptenaServices.shared.start()` and
  shows one raw task list. `xcodegen generate`, build, install next to Septena
  on a device, confirm it reads/writes the **same** tasks. This de-risks the
  entire "two apps, one backend, parallel" claim before anything else moves.
  *Additive — touches no existing file except a `project.yml` append.*

- **P1 — Make `Shell/Tasks` independently includable (mostly file moves).**
  Relocate any shared primitives the tasks folder reaches into `Shell/UI`. Pin
  the task-home view. End state: full Septena builds and behaves identically
  (only file locations changed). Low-risk by design.

- **P2 — Mount tasks in the standalone shell (compiler-driven).**
  Point `SeptenaTasks` at `SeptenaCore + Shell/UI + Shell/Tasks` (excluding the
  adapters) + the task-home view + the thin shell. Build; let the compiler
  enumerate the seam; relocate/cut/stub each tendril. Provide the required
  environment objects. Green both apps.

- **P3 — Thin-shell polish.**
  Septask root scene + task-scoped navigation, a Settings *subset* (incl. the
  accent picker), onboarding, app icon/assets, the Darwin fetch-nudge, and a
  tasks-only MCP tool subset if wanted.

- **P4 — Divergence policy (write it down, §7).**

---

## 7. Governing invariant (keep this true)

> **Shells own composition; shared folders own behavior; CloudKit owns data.**
> The `SeptenaTasks/` target may contain *only*: app entry, scene/navigation
> chrome, its Settings subset, onboarding, assets, and the choice of which
> folders to mount. Any task *logic or view* written inside `SeptenaTasks/` is a
> bug — it belongs in `Shell/Tasks` so both apps get it. Same rule for the full
> app's shell.

That single rule is what makes "improve once, both improve" hold, while keeping
intentional divergence (simpler home, fewer settings) visible and confined to
the thin shells — the exact opposite of the clone trap. Maintenance cost is one
`project.yml` block, not a second codebase; the existing worktree/cron
discipline already handles N targets.

---

## Appendix — key file references

- Feature: `Septena/Shell/Tasks/*` (`TaskListView`, `TaskComponents`,
  `TaskComposer`, `TaskDetailView`, `TaskDraft`, `TasksQuickAddMenu`,
  `RemindersInboxSection`, `ThingsImportView`, `ConversationEngine`/`Card`).
- Adapters to exclude: `Septena/Shell/Tasks/TasksDestinationView.swift`,
  `Septena/Shell/Sections/Plugins/TasksPlugin.swift`.
- Accent write boundary: `SeptenaCore/SettingsMirror.swift` (~L391–402).
- Sharing model / target defs: `project.yml` (see the `Septena`,
  `SeptenaWatch`, `SeptenaWidgets` targets for the source-inclusion pattern).
- Data/sync: `SeptenaCore/Persistence.swift`, `SeptenaCore/CloudKit/CKEngine.swift`.
- App Intents (task-only, optional in Septask): `Septena/App/TaskIntents.swift`,
  `Septena/App/AddTaskIntent.swift`, `Septena/App/Intents/*`.
