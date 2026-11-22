# 0024. No tab bar on iPhone: the list is the root of one navigation stack

- Status: accepted (2026-11-22)
- Date: 2026-11-22
- Deciders: mz

## Context

Septena on iPhone had a three-tab `TabView`: Tasks, Today and Upcoming. The
Tasks tab held the full list (smart lists, areas, projects). That list also
linked to Today and Upcoming, so two of the three tabs were a second route to
places the list already reached.

Problems this caused:

- **Two routes to one place.** `SeptaskRootView` kept the selected tab and
  `NavigationState.path` in step, decided which tab owned a project or area
  route, and translated routes across the iPhone Duo fold. A route to Today
  had to switch tabs and then clear itself from the shared path, or Back led
  to a duplicate Today.
- **A crowded bottom edge.** The tab bar, the Magic Plus orb and toasts all
  sat at the bottom. The orb had to hide while a toast showed, so Undo stayed
  tappable.
- **An incomplete top level.** Areas and projects cannot be tabs, so the tab
  bar could never be the whole top level. The list could.
- **Different from the other platforms.** iPad and Mac already use a sidebar
  as the only switcher.

Things and Reminders both ship on iPhone without a tab bar: a list you push
into, with a floating add button.

## Decision

On iPhone (compact width), Septena has **no tab bar**.

- The sidebar list (Today, Upcoming, smart lists, areas, projects) is the
  root of ONE `NavigationStack` (`ContentView`'s compact layout). Every list
  pushes onto it.
- The app opens on Today, with the list one Back away.
- iPhone and iPad/Mac share the same `NavigationState.path`. A fold or a
  resize keeps the user on the same list with no route translation.
- The Magic Plus orb owns the bottom-right corner.
- Designs, mocks, scene builders, App Store screens and marketing copy show
  no iPhone tab bar.

## Consequences

- Today ↔ Upcoming costs two taps (Back, then tap) instead of one. Things
  makes the same trade. Back swipe and opening on Today soften it.
- `SeptaskTab`, the tab-to-path sync and the fold route translation are
  deleted (`Septask/SeptaskRootView.swift`).
- Septena Life's `RootTabView` is a different app and is not affected.
- The site's task mock (`septena-site` `components/task-ui`) draws no
  `task-tabbar`, and the App Store iPhone set renders from it.
- `SeptaskUITests/ScreenshotTests` navigates through the list, not tabs.
