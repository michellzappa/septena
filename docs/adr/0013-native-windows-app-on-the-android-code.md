# 0013. Build the Windows app on the Android client's Kotlin code

- Status: accepted (2026-11-21)
- Date: 2026-11-21
- Deciders: mz

## Context

- septena.app now has a Windows page with a waitlist and a parity table
  (`septena-site`, `/apps/windows`). Issue #136 tracks the app. No Windows
  code exists.
- After ADR 0002 every client is an ordinary client of `api.septena.app`
  over the push/pull protocol. The task logic that matters for sync lives in
  the backend (`backend/src/shadow/`). The agent loop also runs on the server
  (ADR 0008), so a new client gets agents by showing conversations and
  answering option pills. It does not need its own agent code.
- The Apple apps cannot be reused on Windows. They are SwiftUI, AppKit and
  SwiftData. Swift builds on Windows, but SwiftUI and SwiftData do not.
- Two other clients are planned: the web client (#21, M3) and the Android
  client (#20, M4). The web client reaches Windows browsers first. The
  Android plan (`docs/SEPTASK_ANDROID_PLAN.md`) is Kotlin and Compose, and it
  is being rewritten for the backend.
- Sign-in is Sign in with Apple only. A Windows user may have no Apple ID.
  The Android rewrite needs a second sign-in method for the same reason.
- Bipe (`bipe-chat/bipe-app`, public) built a native Windows app on the same
  pattern, and its path gives evidence:
  - Bipe chose Compose for Desktop that shares the Kotlin code of its Android
    app (`android/desktop-app`, `android/desktop-runtime`). It rejected a web
    wrapper because the complaints it targets are about desktop apps that act
    like wrapped web pages.
  - Bipe built the Mac app first and started Windows only after the Mac
    spike had recorded evidence. Each platform began with a spike that
    signs in and syncs, with a named fallback if the spike failed.
  - Bipe has no Windows hardware. It tests each build on a Windows 365 Cloud
    PC against a written check list, with a Windows CI job as the build gate.
    A feature moves from "built" to "testing" only after that check. Device
    acceptance waited on Cloud PC sign-in more than once.
  - Bipe keeps a parity ledger with one field per platform per capability,
    in a shared registry, and moves a field only with evidence.
  - Windows needed its own public OAuth client record, with no fallback to
    the Mac client id. Secrets use Windows DPAPI with per-account isolation.
  - Distribution needs a code-signing certificate and a Microsoft Store
    account. Both are mz steps.
  - The Windows backlog grew to more than a dozen parity issues once the
    app worked. Full parity was the goal, so the first usable build kept
    moving.

## Decision

Accepted by mz on 2026-11-21 with all defaults below.

Septena for Windows is a native Compose for Desktop app that shares the
Kotlin code of the Android client: the sync client, the local store, the
models and most of the UI. It is not the web client in a desktop shell.
Windows starts after the Android client has a sync spike that passes, and
it uses the same second sign-in method as Android.

The first Windows release has a fixed, small scope (phase W2 below). Parity
beyond that scope is tracked in a ledger and does not block the release.

## Phases

| Phase | Done when | Depends on |
|---|---|---|
| W0 Shared Kotlin core | The Android rewrite puts the sync client, outbox, local store and models in a module with no Android imports. | #20 rewrite |
| W1 Spike | A Compose Desktop build on Windows x64 signs in, pulls one account, creates a task offline and pushes it after reconnect. Tested on a Windows 365 Cloud PC against a written check list. | W0, second sign-in method |
| W2 First release scope | Inbox, Today, Upcoming, Anytime, areas, projects, sections, When and Deadline, repeat, notes, Quick Find, undo, conversations with option pills, Stop and Pause all agents. Keyboard-first, with Windows shortcuts. | W1 |
| W3 Distribution | Signed installer and Microsoft Store listing. Per-account secrets in DPAPI. In-app updates. | W2, mz: certificate and Store account |
| W4 Parity ledger | Each capability in the site's parity table has a Windows status backed by evidence. Gaps have open issues. | W2 |

Out of the first release: attachments, calendar events, imports, a global
Quick Entry hotkey and system notifications. Each gets an issue when W2
ships.

## Consequences

- Windows reuses most of the Android work, so the two clients cannot drift
  on sync rules. The cost is that Windows waits for Android.
- Until then, Windows users have the web client (#21).
- The repo gains a Kotlin codebase and a Windows CI job. Agents build and
  test Windows in CI. No agent needs a Windows machine.
- mz owns the Cloud PC sign-in, the code-signing certificate and the
  Microsoft Store account.
- If W1 fails (Compose Desktop cannot meet the bar on Windows), a successor
  ADR picks another path, for example WinUI with a Kotlin core, or the web
  client in a native shell.
- The parity table on the site is the ledger seed. It lives in
  `septena-site/content/platform-parity.json` and is derived from the
  feature map. When the Windows column moves past "planned", each cell needs
  evidence, as in Bipe's ledger.

## Open questions

| Question | Default |
|---|---|
| Stack | Compose for Desktop on the Android Kotlin code *(default)* |
| Order | After the Android spike; the web client covers Windows until then *(default)* |
| Second sign-in method | Same as Android; decided in the #20 rewrite *(default)* |
| Repo | Same repo as Android, as Bipe does *(default)* |
| Store | Microsoft Store plus a signed direct installer *(default)* |
| Device testing | Windows 365 Cloud PC with a written check list *(default)* |

## Links

- #136 Windows client · #20 Android client · #21 web client · #109 platform pages
- ADR 0002 own backend · ADR 0008 agent loop in the store
- `docs/SEPTASK_ANDROID_PLAN.md` (superseded on architecture)
- Bipe: `bipe-chat/bipe-app` `android/desktop-app/README.md` (check list),
  `android/desktop-runtime/README.md` (storage), `windows/README.md` (OAuth)
