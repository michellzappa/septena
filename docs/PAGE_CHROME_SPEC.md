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

## The `.pageChrome` primitive (built — `Septena/Shell/UI/SeptenaPage.swift`)

Realized as a **View modifier**, not a wrapper struct, so it drops in exactly
where `homeToolbar` was (no re-indenting large bodies) and composes onto the
sidebar/detail of the Tasks split the same way. It replaced
`homeChrome`/`homeToolbar`/`HomeToolbarExtras` (now deleted from
HomeChrome.swift, which keeps only `OverflowMenu`).

```swift
extension View {
  func pageChrome(
    id: String,                                  // page identity (tab/section key)
    title: String,                               // accessibility; content owns visible title
    localActions: @escaping () -> AnyView? = { nil },  // "···" rows; nil → no "···"
    add: PageAdd? = nil                          // "+" ; nil → no "+"
  ) -> some View
}

enum PageAdd {
  case addInfo              // time-views → nav.presentAddInfo() picker
  case action(() -> Void)   // domain-views → create that domain's object
}
```

The constant gear is injected by the modifier (`PageGlobalButton`), never by the
caller. The three slots render in the page's **navigation bar** (its
`NavigationStack` toolbar) on every platform and size class — `.topBarLeading`
(gear) + `.topBarTrailing` (··· then +) on iOS, `.navigation` + `.primaryAction`
on macOS.

> **Chrome lives in the nav bar, NOT the tab bar.** Apple's HIG: "tab bars are
> for moving between major areas of the app, not for triggering one-off actions."
> iPadOS 26 exposes no API to put buttons in the tab bar — its only accessory
> slot is the bottom shelf (`tabViewBottomAccessory`, used for the training pill).
> Two earlier attempts to "lift" the chrome into the iPad tab bar (a
> `PreferenceKey`, then a shared `@Observable` host, both feeding a `.toolbar` on
> the `TabView`) **never rendered on iPad** and were removed. The nav-bar toolbar
> is the supported, on-guidance home for these actions.

**Tasks split (gear de-duplication).** Tasks is a two-column `NavigationSplitView`.
The **sidebar** calls `.pageChrome(id:"tasks", localActions:{…})` (gear + "···").
The **detail** `TaskListView` calls `.pageChrome(id:"tasks", add:.action{…},
showsGlobal:)` — its "+" plus a gear *only when no sidebar is concurrently
showing one*: `showsGlobal = (iOS && regular) ? false : true`. So iPad-regular
shows one gear (sidebar), iPhone-pushed lists show their own gear, and macOS
(whose sidebar toolbar has no gear) shows it on the detail. Navigating the detail
to a Project unmounts its `.pageChrome` (embedded `TaskListView` opts out, keeping
a plain local "+").

Callers (actual):

```swift
// Next (time-view)
NextView()…
  .pageChrome(id: "next", title: "Next",
              localActions: { AnyView(nextSettingsRow) }, add: .addInfo)

// Coach (domain-view)
List {…}…
  .pageChrome(id: "coach", title: "Coach", add: .action { addGoal() })

// Tasks sidebar contributes "···"; detail TaskListView contributes "+"
sidebar… .pageChrome(id: "tasks", title: "Tasks", localActions: { AnyView(tasksMenuExtraRows) })
detail…  .pageChrome(id: "tasks", title: "Tasks", add: .action { nav.shouldStartCreating = true })
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

## Migration plan (status)

1. ✅ **`.pageChrome` built** (`Septena/Shell/UI/SeptenaPage.swift`) — three-slot
   toolbar + self-clearing `PageChromeKey` hoist. Gear → `nav.showSettings`.
2. ✅ **iPad hoist moved** off `HomeToolbarExtras` onto `PageChromeKey`;
   `RootTabView.rootTabView` reads the preference. `HomeToolbarExtras` deleted.
3. ✅ **Home tabs retargeted:** Week/Next/Coach use `.pageChrome`; Settings is the
   gear, not a menu row. `HomeMenu` deleted.
4. ⏳ **Fold `SectionDrawer`'s toolbar into `.pageChrome`** — drawer keeps its
   masonry/columns/scroll body but stops drawing its own title/time-travel/+/···.
   (Not started.)
5. ✅ **Tasks retargeted:** sidebar (`sidebarSplit`/`sidebarPhone`) publishes
   gear + "···"; `TaskListView` publishes gear + contextual "+", merged on iPad
   regular. `phoneMoreMenu`, `homeToolbarTrailing`, and `usesLocalNewTaskToolbar`
   removed; embedded `TaskListView` keeps its plain local "+".
6. ✅ **`OverflowMenu` kept** as the "···" glyph; its Settings coupling (in the old
   `HomeMenu`) is gone.
7. ⏳ **Section sweep + device walk** — apply step 4 across sections, then verify
   on iPhone / iPad-regular / macOS.

## Acceptance (100% coherent end to end)

- [x] Every **tab** shows the same gear in the same leading slot, opening Settings.
      (Sections: pending step 4.)
- [x] No "···" on a migrated surface contains Settings; "···" is hidden when a
      page has no local actions.
- [x] Every tab has a "+" in the same trailing spot; time-views (Today/Next) open
      Add-Info, domain-views (Tasks/Coach) create their domain object.
- [x] Chrome renders in each page's navigation-bar toolbar on all platforms (NOT
      the tab bar — unsupported by the API + off-HIG). Two tab-bar hoist attempts
      (`PreferenceKey`, then a shared `@Observable` host) never rendered on iPad
      and were removed.
- [x] `homeChrome`/`homeToolbar`/`HomeToolbarExtras`/`HomeMenu` deleted.
- [ ] `SectionDrawer`'s private toolbar folded into `.pageChrome` (step 4).
- [ ] Device walk on all three layouts.
