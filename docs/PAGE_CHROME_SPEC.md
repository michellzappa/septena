# Page Chrome & Tab Bar — Unified Model

Canonical spec for how the 4 tabs, the page chrome (global / page / add slots),
and page construction work across iOS, iPadOS, and macOS. Supersedes the
three-scaffold drift described under "Today" below. When this conflicts with
code, the code is wrong (fix the code) — except where a line is marked
**(target)**, which is not built yet.

## First principles

1. **One page skeleton, everywhere.** Today, Next, Tasks, Coach, and every
   section destination are the *same* primitive (`SeptenaPage`) configured
   differently — not three different scaffolds (`homeChrome`, `SectionDrawer`,
   `ContentView`/`TaskListView`) that happen to look similar.
2. **Each toolbar slot has exactly one meaning, in one place, on every page.**
   A glyph never means two things. The user learns three affordances once.
3. **Two kinds of tab, one skeleton.** *Time-views* (Today, Next) aggregate all
   sections by time and are triage-first. *Domain-views* (Tasks, Coach,
   sections) expand one domain and are management-first. Same slots, different
   fill — so they read as related-but-distinct, not fake peers.

## The three-slot chrome

Every page renders the same toolbar skeleton:

```
[ ⚙ global ]            Title            [ ··· page ] [ + add ]
  LEADING                                 TRAILING cluster
```

| Slot | Glyph | Meaning | Varies by page? | Opens / does |
|------|-------|---------|-----------------|--------------|
| **Global** (leading) | `gearshape` | Configure the app | **No** — identical everywhere | `nav.showSettings = true` (iOS sheet / macOS `settings` window) |
| **Page** (trailing) | `ellipsis` | Act on *this* page | Yes (page-local rows only) | Menu of page actions; **hidden when empty**. Never contains Settings. |
| **Add** (trailing) | `plus` | Add to *this* context | Yes (what it adds) | See "Add semantics" below |

Rules that make it coherent:

- **Global is constant.** The gear is supplied by the scaffold, never by the
  caller, so it can't drift. It is the *only* path to Settings from the chrome.
- **"···" is page-local only.** Settings is gone from it. If a page has no local
  actions, the "···" does not render (no empty menu).
- **"+" is on every page.** Even time-views (resolved below).
- **Order is fixed:** global left; "···" then "+" right, in that order.

## Add semantics (the "+" per page)

| Page | Kind | "+" does |
|------|------|----------|
| **Today** (`.week`) | time-view | Opens **Add-Info picker** (`AppModal.addInfo`) — choose any section to log into |
| **Next** (`.next`) | time-view | Opens **Add-Info picker** (same) |
| **Tasks** (`.tasks`) | domain-view | `nav.shouldStartCreating = true` — inline new task in the current list |
| **Coach** (`.goals`) | domain-view | New goal |
| **Section** (drawer) | domain-view | Section `quickAdd` — new entry of that section's kind |

Time-views share one capture surface (`AddInfoSheet`); domain-views create their
own domain object directly. This is the visible expression of the time/domain
split.

## Page (···) menu contents

Page-local only — **never Settings**. Examples (not exhaustive):

| Page | "···" rows |
|------|-----------|
| **Today** | Dashboard layout switcher, Insights |
| **Next** | (sparse — Next-specific prefs link, if any) |
| **Tasks** | New Area, New Project, Task Settings (deep-links to Settings ▸ Sections ▸ Tasks) |
| **Coach** | Coach-specific actions |
| **Section** | History, Log/Patterns is its *own* toggle (not in menu), section settings deep-link |

"Section Settings" / "Task Settings" rows deep-link *into* the global Settings at
a pane — that's fine; they're page-scoped shortcuts, not the global entry point.

## The `SeptenaPage` primitive (target)

One scaffold replaces `homeChrome`/`homeToolbar` (HomeChrome.swift),
`SectionDrawer`'s toolbar (SectionDrawer.swift), and the bespoke Tasks chrome
(TaskListView.swift toolbar block).

```swift
struct SeptenaPage<Content: View>: View {
  let title: String
  var localActions: () -> AnyView? = { nil }   // "···" rows; nil → menu hidden
  var add: PageAdd? = nil                       // "+" ; nil → no add (rare)
  var timeTravel: Binding<Date>? = nil          // optional calendar slot
  var mode: Binding<DrawerMode>? = nil          // optional Log/Patterns toggle
  let content: () -> Content
  // Global gear slot is injected internally — callers cannot override it.
}

enum PageAdd {
  case domain(() -> Void)   // Tasks/Coach/section create
  case addInfo              // time-views → AppModal.addInfo picker
}
```

Callers:

```swift
// Today
SeptenaPage(title: "Today",
            localActions: { AnyView(layoutSwitcher; insightsRow) },
            add: .addInfo) { weekContent }

// Tasks list
SeptenaPage(title: filter.title,
            localActions: { AnyView(newArea; newProject; taskSettings) },
            add: .domain { nav.shouldStartCreating = true }) { list }

// A section
SeptenaPage(title: section.label,
            localActions: { AnyView(history; sectionSettings) },
            add: .domain { quickAdd() },
            timeTravel: $date, mode: $mode) { sectionBody }
```

## Platform handling (one path, not per-tab)

The hard part today is iPad-regular: per-tab `NavigationStack` toolbars render one
row *below* the tab bar, so chrome must be hoisted to the `TabView` toolbar. This
is currently done **imperatively and fragilely** by `HomeToolbarExtras`
(HomeChrome.swift:22–46) — each tab calls `setContent` on `.onAppear` and
`clearContent` on `.onDisappear`; a tab that forgets to clear leaves stale chrome.

**Target:** `SeptenaPage` owns the hoist in one place. Resolve by size class:

- **iPhone compact / macOS:** chrome lives in the page's own `NavigationStack`
  toolbar (leading gear, trailing ··· + +).
- **iPad regular:** the page publishes its chrome **declaratively via a
  `PreferenceKey`** that bubbles to `RootTabView`, which renders it in the
  `TabView` toolbar. A `PreferenceKey` self-clears when the page disappears — no
  manual `clearContent`, so the stale-chrome failure mode is gone. This replaces
  `HomeToolbarExtras` entirely.

`usesPushNavigation` (SectionDrawer.swift:102–160) stays the single source for
push-vs-sheet; `SeptenaPage` reads it from the environment, never recomputes.

## The 4 tabs (unchanged identity, clarified roles)

| Tab | enum | View | Kind | Always shown? |
|-----|------|------|------|---------------|
| **Today** | `.week` | `WeekDashboardView` | time-view | yes |
| **Next** | `.next` | `NextDashboardView` | time-view | yes |
| **Tasks** | `.tasks` | `ContentView` | domain-view | gated on `tasks` section enabled |
| **Coach** | `.goals` | `CoachView` | domain-view | yes (goals = `.appFunction`, only reachable via this tab) |

Tab set and gating logic (RootTabView.swift:69–81, 220–233) are **kept as-is**.
The cleanup is chrome, not tab membership.

## Migration plan (file by file)

1. **Add `SeptenaPage`** (new file, `Septena/Shell/UI/SeptenaPage.swift`) with the
   three-slot toolbar + the `PreferenceKey` hoist. Gear → `nav.showSettings`.
2. **Move the iPad hoist** off `HomeToolbarExtras` onto the `PreferenceKey`;
   `RootTabView.rootTabView` (RootTabView.swift:235–258) reads the preference
   instead of `homeToolbarExtras.content` / `.trailingContent` / `.hasTrailing`.
   Delete `HomeToolbarExtras` (HomeChrome.swift:22–46) once no caller remains.
3. **Retarget the home tabs:** Week/Next/Coach drop `.homeChrome` / `.homeToolbar`
   and wrap their body in `SeptenaPage(...)`. Remove the Settings row from the old
   `HomeMenu` (HomeChrome.swift:84–86) — Settings is now the gear only.
4. **Fold `SectionDrawer`'s toolbar into `SeptenaPage`:** the drawer keeps its
   masonry/columns/scroll body but stops drawing its own title/time-travel/+/···;
   it renders inside `SeptenaPage`. (SectionDrawer.swift toolbar block.)
5. **Retarget Tasks:** `TaskListView` toolbar block (TaskListView.swift:480–493,
   2726–2741) and the phone `phoneMoreMenu` (SidebarView.swift:387–429) move into
   `SeptenaPage` slots — gear (global), ··· (New Area/Project/Task Settings), +
   (`shouldStartCreating`). Delete the bespoke `TaskListNewTaskButton` placement
   logic and `TopLevelChromeModifier` shim where `SeptenaPage` subsumes it.
6. **Delete `OverflowMenu`/`HomeMenu`'s Settings coupling** and keep `OverflowMenu`
   purely as the "···" glyph for page-local menus.
7. **Verify**: one `scripts/build.sh` per platform; check the gear opens Settings
   on every tab and section, "···" never shows Settings, "+" matches the table
   above on all 4 tabs and a sample section, on iPhone / iPad-regular / macOS.

## Acceptance (100% coherent end to end)

- [ ] Every page (4 tabs + every section) shows the **same gear** in the **same
      leading slot**, opening Settings.
- [ ] No "···" anywhere contains Settings; "···" is hidden when a page has no
      local actions.
- [ ] Every page has a "+" in the same trailing spot; time-views open Add-Info,
      domain-views create their domain object.
- [ ] iPad-regular chrome is hoisted by the scaffold's `PreferenceKey`, not
      per-tab `onAppear`/`clearContent`; no stale-chrome path remains.
- [ ] `homeChrome`, `HomeToolbarExtras`, and `SectionDrawer`'s private toolbar are
      gone or reduced to `SeptenaPage` call sites.
