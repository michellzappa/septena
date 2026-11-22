# 0022. Marketing scenes come from the native app

- Status: rejected (2026-11-22). mz: the website stays programmatic, with no screenshots. The web scene renderer draws from the app's registries instead (septena-site `lib/task-ui/registry.ts`, `scripts/sync-registry.mjs`).
- Date: 2026-11-22
- Deciders: mz

## Context

The website (`septena-site`) explains the task app with "scenes": short loops of app screens with a caption per step. A web copy of the app UI (`septena-site/components/task-ui`) draws these scenes. The copy drifts from the app. On 2026-11-22 it showed the Inbox as a separate list and sidebar row, but the app has no such list: the Inbox is the band at the top of Today (`registry/destinations.json`, `inbox.visibility = "todayBand"`). Every fix to the copy is a second implementation of the app that nobody tests against the app.

mz's requirement: the site must draw the app 1:1, and each concept must appear in context on the real screen.

The app repo already has part of a native path. `SeptaskUITests` and `SeptaskMacUITests` capture screens from a demo-seeded build (`-SeptenaSeed demo`), and `appstore/capture.sh` collects them. Issue #94 records why those captures cannot be trusted yet: navigation is best-effort, so a failed tap still saves a screenshot under the expected name.

## Decision

1. **The native app draws every pixel of a marketing scene.** Scene frames are screenshots that UI tests capture from Septask on iPhone and Mac, from a deterministic marketing fixture, in light and dark.
2. **The website draws only the explanation layer**: a spotlight on one named part of the screen, the dimming around it, and the caption. It never redraws app UI for a scene.
3. **A spotlight targets an accessibility identifier.** The UI test records the frame of each named element with the screenshot. The site positions the spotlight from that frame.
4. **Scene scripts live in the app repo** next to the capture tests, because they depend on app identifiers and fixture data. Captions live in the site, keyed by scene and step, because they are marketing copy.
5. **A capture that cannot prove where it is fails.** Before each screenshot, the test asserts the destination identifier and the fixture state (#94). No silent skips.
6. **The web task UI copy stops serving marketing scenes.** It may stay as the design preview for the planned web app, labeled as such.

## Consequences

- The site cannot show a screen the app does not have. A wrong scene is now a failed capture, not a page that looks right.
- Changing a marketing scene needs a capture run: simulators and a signed Mac build. mz runs it, or clears an agent to run it. No unattended runs (#94).
- The app must name the parts that marketing explains. Today almost nothing carries an accessibility identifier (only task rows, `septena.task.row.<id>`). Adding identifiers also helps VoiceOver, Voice Control and the UI contract tests.
- The demo seed must grow a marketing scenario: the Inbox band, a project with notes, start and deadline dates, a repeating task, attachments, an agent conversation.
- Scenes stop being clickable fake UI. The site keeps step buttons, play and pause.
- Real motion (a checkbox animating) needs screen recordings later; frames with crossfades come first.

## Links

- Spec: [`docs/NATIVE_SCENES_SPEC.md`](../NATIVE_SCENES_SPEC.md)
- #94 (capture hardening), #50 (site rewrite), michellzappa/septena-site#7 (a visual on every footer page)
