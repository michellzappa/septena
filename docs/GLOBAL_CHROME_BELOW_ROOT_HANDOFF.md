# Handoff: hide the iPad global chrome bar below the tab roots

## Goal

On iPad, the window-level chrome overlay (`RootTabView.iPadTopBar` — the `···` /
sidebar-toggle / centered switcher / reconnect / `+` glass circles) currently
floats over EVERYTHING, including pushed section/detail screens. So a pushed
section shows two stacked bars: the global tab bar on top + its own
`SectionDrawer` chrome (title, time-travel, Log/Patterns, +) below.

**Decision (made): HIDE the global bar when the active tab is below its root**
(a section/detail is pushed). The pushed screen is then a normal push: its own
nav bar (back button + `SectionDrawer`/detail chrome). Backing out re-shows the
global bar. Do NOT route section chrome into the global bar (sections are too
chrome-rich — title + time-travel calendar + Log/Patterns + add — to fit two
circles).

**Hard constraint: never lose the nav.** Hiding the bar must always leave a back
button (the pushed screen's own `NavigationStack` back). The user trades the tab
switcher for a back button while deep, and backing out restores the bar — but
must never be stranded with no way back. Verify every push path has a working
back affordance after the bar hides.

**Also decided — do NOT add a collapse-on-scroll / minimize-to-pill to the iPad
bar.** It stays full-size at root (and simply hides below root, per above). iPhone
collapses its tab bar via the free system `.tabBarMinimizeBehavior` on a real
`TabView`; iPad has no TabView (we removed it) so matching that would mean
hand-rolling scroll-offset tracking + animation on the custom overlay — bespoke
and fragile, against this codebase's "standard SwiftUI, never get creative" rule.
The form factor justifies the asymmetry (iPad has the vertical space iPhone
doesn't), the switcher is the primary nav and should stay one tap away, and
content already scrolls UNDER the glass bar so it reads as responsive without
moving. Keep it static.

Read first: `docs/PAGE_CHROME_SPEC.md` and
`memory: project_page_chrome_unification` for how the overlay + `IPadChromeModel`
+ `usesPushNavigation` gating work.

## Build / verify

- Build via `scripts/build.sh Septena 'platform=iOS Simulator,id=<iPad sim UUID>'`
  and `SeptenaMac 'platform=macOS'`. Launch demo data:
  `xcrun simctl launch booted com.septena.cloud -SeptenaSeed demo -septena.welcome.completed YES`.
  To screenshot a non-default tab, temporarily set `TabSelection.current` /
  `visitedTabs` in RootTabView, then REVERT.
- These chrome files are edited by other concurrent sessions — rebuild right
  before starting; a sudden unrelated error is usually a save-race (rebuild once).

## The mechanism

1. Add a shared signal of "the active tab is at its root" that the overlay reads.
   Simplest robust shape: an `@Observable` (or an entry on the existing
   `IPadChromeModel`) holding `atRoot: [SeptenaTab: Bool]` (or just the active
   tab's depth). `RootTabView.iPadTabless` shows `iPadTopBar` only when the active
   tab reports `atRoot == true` (animate the show/hide).

2. Each scrolling tab reports its nav depth:
   - **Today** (`WeekDashboardView`/`WeekDashboardScreen`), **Next**
     (`NextDashboardView`→`NextView`), **Coach** (`CoachView`): these push via
     `.navigationDestination` (Coach pushes `CoachDomain`; Next/Today push
     sections). Give each an explicit `NavigationStack(path:)` binding (or observe
     depth via the pushed destination's `.onAppear`/`.onDisappear`) and set
     `atRoot = path.isEmpty`.
   - **Tasks** (`ContentView`): a `NavigationSplitView` — selecting a
     project/area SWAPS the detail (`nav.path = [route]`), it is NOT a deeper
     push. **Tasks is always at root → its overlay never hides.** Do not treat
     `nav.path` depth as "below root" for Tasks. (Tasks editors are
     inspectors/sheets, which are still "root".)

3. When hidden: the pushed section's own `NavigationStack` nav bar (back +
   `SectionDrawer` toolbar) shows normally. Pushed sections do NOT use
   `.pageChrome`, so they carry no `contentMargins(.top, iPadBarHeight)` inset —
   nothing to undo. Confirm the section's own top spacing reads correctly with no
   global bar above it.

4. The switcher disappears with the bar (expected — back out to switch tabs).
   Verify the transition animates and back-nav restores the bar cleanly.

## Sub-task (same chrome layer): un-fuse the trailing glass circles

On device (NOT the simulator — sim renders them separate) the reconnect circle
and `+` fuse into one Liquid-Glass blob; widening the gap to 22pt did NOT fix it,
so it's iOS 26 unioning sibling `.glass` buttons, not proximity. Fix by isolating
each circle's glass: wrap each in its own `GlassEffectContainer`, or replace
`.buttonStyle(.glass)` with the codebase's manual `glassCircle()` per circle
(note: `glassCircle()` swallowed a *Menu*'s tap earlier, so keep `···` on
`.buttonStyle(.glass)` and only switch the plain Buttons, or use separate
containers throughout). Verify on a physical iPad — the simulator can't show it.

## Acceptance

- [ ] On iPad, Today/Next/Coach show the global bar at root; pushing a section /
      coach hub hides it, leaving the pushed screen's own back + chrome. Backing
      out restores the bar (animated).
- [ ] Tasks ALWAYS shows the global bar (sidebar selection never hides it).
- [ ] No double top bar anywhere; pushed sections' top spacing looks right.
- [ ] iPhone/macOS unchanged (no overlay there; this is iPad-regular only).
- [ ] (Sub-task) reconnect + `+` render as two distinct circles on a physical iPad.
- [ ] iOS + macOS build green via `scripts/build.sh`.
```
