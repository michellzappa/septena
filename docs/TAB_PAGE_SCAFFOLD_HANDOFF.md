# Handoff: unify the 4 tab pages on one `.septenaTabPage` modifier

## Goal

DRY the **cross-cutting treatment** of the four top-level tab pages (Today, Next,
Tasks, Coach) into a single modifier, so chrome + scroll-surface + the iPad bar
inset are identical by construction and can't drift. Do NOT merge their
containers — Today is a `ScrollView`+grid, Next/Coach are `List`s, Tasks is a
`NavigationSplitView`; those differences are correct.

Read first: `docs/PAGE_CHROME_SPEC.md` (the chrome model — gear-less "···" menu
with Settings-last on the left, "+" on the right, centered glass switcher; iPad
renders the chrome as a window-level overlay bar in `RootTabView.iPadTopBar`,
fed per-tab by `IPadChromeModel`; iPhone/macOS use nav-bar toolbar items). The
chrome itself is already unified via `.pageChrome` in
`Septena/Shell/UI/SeptenaPage.swift`. This task unifies the *rest*.

## Build / verify

- Build ONLY through `scripts/build.sh Septena 'platform=iOS Simulator,id=<an iPad sim UUID>'`
  (it takes the shared lock; concurrent xcodebuild corrupts incremental builds).
  Also build `SeptenaMac 'platform=macOS'` before finishing.
- Verify visually on an iPad simulator. The app needs no iCloud if you launch with
  demo data: `xcrun simctl launch booted com.septena.cloud -SeptenaSeed demo -septena.welcome.completed YES`.
  To check a non-default tab, temporarily set `TabSelection.current` /
  `visitedTabs` in `RootTabView.swift` to that tab, screenshot, then REVERT.
- These files are edited by other concurrent sessions — rebuild right before you
  start and treat a sudden unrelated error as a save-race (rebuild once).

## What's currently duplicated (the drift to remove)

Each of Today/Next/Coach independently applies some subset of:
`navigationTitle("")`, `.navigationBarTitleDisplayMode(.inline)`,
`.scrollContentBackground(.hidden)`, `.homeTabScrollSurface()`,
`.scrollEdgeEffectStyle(.soft, for: .top)`, `.pageChrome(...)`. Tasks applies the
bar inset per column. This inconsistency is what made the bar inset behave
differently per page (we just fixed it case-by-case with `.contentMargins`).

## Step 1 — add the modifier (`Septena/Shell/UI/SeptenaPage.swift`)

```swift
extension View {
  /// Standard treatment for a top-level tab page's scroll view: nav title,
  /// scroll surface, soft top edge, and the unified chrome (`.pageChrome`, which
  /// also reserves the iPad bar inset via contentMargins). Apply to the page's
  /// OWN List/ScrollView so the scroll modifiers land on it. Page-specific bits
  /// (Today's sky background, Next's list selection) stay on the page.
  func septenaTabPage(
    id: String, title: String,
    localActions: @escaping () -> AnyView? = { nil },
    add: PageAdd? = nil,
    showsGlobal: Bool = true
  ) -> some View {
    self
      .scrollContentBackground(.hidden)
      .homeTabScrollSurface()
      #if os(iOS)
      .scrollEdgeEffectStyle(.soft, for: .top)
      #endif
      .navigationTitle("")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .pageChrome(id: id, title: title, localActions: localActions,
                  add: add, showsGlobal: showsGlobal)
  }
}
```

Keep `.pageChrome` as-is (other call sites + the iPad inset live there). Confirm
`homeTabScrollSurface` (in `PlatformShims.swift`) is safe to apply to a
`ScrollView` as well as a `List` — if it isn't, gate it or split it out.

## Step 2 — adopt it, removing the per-page copies

- **Next** (`Septena/Shell/Dashboard/NextDashboardView.swift` → the `NextView`
  List): replace its `scrollContentBackground`/`homeTabScrollSurface`/
  `scrollEdgeEffectStyle`/`navigationTitle`/`pageChrome` stack with one
  `.septenaTabPage(id:"next", title:"Next", localActions: { AnyView(<Next Settings row>) }, add: .addInfo)`.
  Keep `.septenaNeutralListSelection()`, the `List(selection:)`, keyboard-nav,
  and its `.background { … }` — those are Next-specific.
- **Coach** (`CoachView.swift`): same swap on its `List`. Coach has no
  `localActions`, add `add: .action { addGoal() }`.
- **Today** (`WeekDashboardScreen.swift`): swap to `.septenaTabPage(id:"week",
  title:"Today", localActions:{ AnyView(menuExtra()) }, add:.addInfo)`. Today is
  the special one: KEEP its `.background { SkyTopWash … }.ignoresSafeArea()` and
  its separate `ClaudeReconnectCue` toolbar. If `septenaTabPage` double-applies
  `scrollEdgeEffectStyle` it already had, just remove the page's own copy.
- **Tasks** (split view) stays the exception: the **sidebar** (`SidebarView.sidebarSplit`)
  keeps `.pageChrome(id:"tasks", localActions:{…}, add:.action{shouldStartCreating})`;
  the **detail** (`TaskListView` → `TaskListStandaloneChrome`, iPad-regular,
  non-embedded) keeps `.contentMargins(.top, PageChromeMetrics.iPadBarHeight, for: .scrollContent)`.
  Do NOT route Tasks through `septenaTabPage` (it's not a single scroll page).
  Optional: factor the detail's `.contentMargins` line behind a tiny
  `.septenaTabInset()` helper so the magic constant has ONE caller pattern.

## Step 3 — verify parity

On the iPad sim, each of Today / Next / Coach / Tasks must show: the same
overlay bar (round "···" left, glass switcher center, round "+" right, aligned to
`Theme.pageGutter`), and content starting the SAME distance below the bar. Switch
tabs and confirm no drift. Then macOS build green (chrome there is nav-bar items,
unaffected).

## Acceptance

- [ ] `septenaTabPage` exists; Today/Next/Coach each call it once, with their
      page-specific extras layered separately.
- [ ] No tab repeats `scrollContentBackground`/`homeTabScrollSurface`/
      `scrollEdgeEffectStyle`/`navigationTitle`/`pageChrome` outside the modifier.
- [ ] All 4 tabs: identical bar + identical content top-inset (the `74` lives in
      `PageChromeMetrics.iPadBarHeight` only).
- [ ] iOS + macOS build green via `scripts/build.sh`.

## Then (separate follow-up, not this task)

Fold the **section** pages (`SectionDrawer`) onto the same chrome so sections
match the tabs — the long-standing step 4 in `docs/PAGE_CHROME_SPEC.md`.
