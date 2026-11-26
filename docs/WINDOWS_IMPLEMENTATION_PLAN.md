# Septena for Windows

Status: building (ADR 0013, #136)

## What carries over from Bipe

Bipe separated the work into a standalone JVM proof, a real account runtime, a Compose desktop shell, then distribution. Its Windows CI proved the native libraries and SQLite path with synthetic sessions. Its Windows 365 checks recorded separate evidence for account restore, keyboard behavior and packaging. That sequence fits Septena. Bipe's Matrix SDK, MAS registration and encrypted Matrix store are specific to its messaging stack.

Septena already has the components that ADR 0013 called W0. `android/core` owns mutators and the sync engine, `android/store` owns the SQLDelight schema and durable outbox, and `android/transport` owns the HTTP and live-sync clients. Decisions delegated to Rust come from the same released core used by the other clients. The pin in `core/release/release.json` includes a Windows x64 JNA library. Both clients compile the portable task rows and list content in `android/ui/src/commonMain`. The Windows Gradle build consumes that source set directly to stay independent of the Android SDK.

The existing backend and `SeptenaAuthClient` already support device approval and email codes. Device approval supplies both the QR modules and manual code. Email availability comes from `/v1/auth/methods`. The Android Keystore, account adoption, runtime wiring and Compose activity belong to the Android host. `JsonHttp.kt` and `SyncLiveSocket.kt` currently hard-code the Android client label, which the live Windows host must supply explicitly.

Source checkpoints are Septena [ADR 0013](https://github.com/michellzappa/septena/blob/main/docs/adr/0013-native-windows-app-on-the-android-code.md), [ADR 0025](https://github.com/michellzappa/septena/blob/main/docs/adr/0025-shared-rust-core.md) and [#136](https://github.com/michellzappa/septena/issues/136), plus Bipe's [JVM spike](https://github.com/bipe-chat/bipe-app/tree/main/android/desktop-spike), [Windows account runtime](https://github.com/bipe-chat/bipe-app/tree/main/android/desktop-runtime), and [desktop evidence](https://github.com/bipe-chat/bipe-app/tree/main/android/desktop-app).

## Checkpoint 1 — fixture spike

The standalone `windows/` build uses the Android Gradle wrapper and version catalogue, the existing Kotlin mutator and SQLDelight store, and the checksum-verified released Rust core. It runs without the Android SDK. The Compose window uses an in-process fixture with a sample task and an online/offline control. The headless check proves initial pull, offline creation, a failed send, SQLite close/reopen, outbox retry after reconnect, a second database pulling the new task, and file cleanup. The fixture database is temporary and the window resets it on exit.

Windows x64 CI runs the shared core/store conformance vectors and the spike's headless smoke check. It packages a Windows app image with its runtime. The artifact is `septena-windows-spike-x64`. Extract the entire artifact on Win365 and open `SeptenaSpike.exe`. Choose **Go offline**, add a task with **New Task**, then choose **Sync** and check that the offline error leaves the task visible. Choose **Go online** and **Sync** twice. The first sync should send one write and the second zero. This is the first manual check of the bundle and window. The next checkpoint uses a dedicated test account and the real backend. [Compose app-image documentation](https://kotlinlang.org/docs/multiplatform/compose-native-distribution.html#basic-tasks)

## Task parity while device testing is pending

The first fixture slice uses the shared task rows for Today with its Inbox band, Upcoming and Anytime (`lists.today`, `lists.inbox`, `lists.upcoming`, `lists.anytime`). The released core decides membership and Upcoming dates. The desktop shell provides navigation and sends create, rename and complete through the existing mutator. Windows CI checks those actions and the resulting fixture sync. Win365 acceptance covers layout, input, accessibility and launch from the bundle.

The second fixture slice adds areas, projects and project sections (`places.areas`, `places.projects`, `places.sections`). The desktop sidebar shows the hierarchy, including empty sections. A project displays unsectioned tasks and groups the rest by section. Create and rename locations, create tasks directly inside them, and file an existing task with its **Move** action. The fixture check covers offline creation and filing, rejects a section that belongs to another project, and confirms that a second database sees the hierarchy after reconnect. Win365 acceptance covers navigation, the move picker, and keyboard and screen-reader behavior.

The third fixture slice adds the task editor for title, notes, When, Deadline and the basic Repeat controls. When and Deadline use the released date rules through the shared mutator. Repeat supports day, week, month and year with a fixed schedule or after completion, pause and removal. Rescheduling a fixed occurrence offers the existing one-task and series choices. Editor Undo uses the same Kotlin history as Android. The fixture check covers separate dates, repeat changes, undo, offline reopen and a peer pull.

Next add Quick Find against SQLite, then conversations and agent actions. Advanced repeat-pattern editing, broader undo coverage for task actions and keyboard behavior stay in the parity backlog. These slices can use fixture workspaces until live W1 is ready. A feature's fixture and CI evidence stays separate from its Win365 result.

## Checkpoint 2 — live W1 on Win365

Wire the existing account approval and sync clients to a minimal Inbox in the desktop shell. Keep all database access serialized for a given workspace, serialize refresh and sync, and retire and join in-flight work before closing the driver or changing accounts. Put the account database under the current user's application data with a separate path per backend account. Protect session material with current-user DPAPI before real-account persistence. Windows tests must cover wrong-user/account scope, a missing or corrupt envelope, overlapping owners and stale callbacks. Keep the paired account's outbox across disconnect and restart. When a different account is adopted, open its own database and handle the prior account's pending work using the product's account-switch behavior.

Once the live x64 build is green, run the Win365 checklist with a sync-enabled test account and a second signed-in Septena client:

1. Record the exact commit, CI run/artifact, Windows version and architecture, and the counterpart build. Open the app from the extracted image and approve it with a manual code or QR from the second client. Pull one known task. Check cancellation, expiry and retry with a fresh code.
2. Take the Cloud PC offline, add a uniquely named test task, close and relaunch while offline, and confirm that the task remains visible. Restore connectivity. Verify the task appears once on the other device and that a second sync sends no duplicate.
3. Change the task on the other device. Verify the PC receives the edit. Restart online and confirm it restores the same account. Verify that sign-out or server revocation requires approval again and that a second test account cannot read the first account's rows or credentials.
4. Record pass/fail for each step and the action that reproduced a failure. Keep task contents, email addresses, approval codes and tokens out of evidence. Remove the test task using the app after the run.

A green CI run closes the fixture checkpoint. W1 closes after the live Win365 run passes, with the exact tested artifact recorded.

## Implementation assignments

Use GPT-6 Luna at x-high for each implementation lane. Give each worker its row, the accepted spike commit, the shared interfaces, and the relevant verification commands. Use one worktree and a `wt/windows-*` branch per lane so pushes trigger the Windows workflow. The coordinator owns the integration branch, reviews boundaries, queues CI, and records Win365 acceptance. The Windows source packages in the table are relative to `windows/src/main/kotlin/app/septena/windows/`.

| Lane | Owns | Delivers and verifies |
| --- | --- | --- |
| A · Account and credentials | `account/`; device/refresh portions of `android/transport` | Device approval state machine and QR data, serialized refresh, revocation, DPAPI current-user account vault, failure and cancellation tests. Route email support through the existing methods response when adding the fallback. Tests cover corruption, identity mismatch and stale refresh. |
| B · Workspace and sync | `workspace/`; sync polling/live and app wiring shared with Android | Account SQLite paths, driver lifecycle, single-flight sync, HTTP client identity and offline/reconnect state. Reuse portable pieces from `SyncController` and `SyncLiveCoordinator` where the interface fits. Tests cover persistent outbox, 401 and 402, lost acknowledgement, cross-account teardown and reconnect. |
| C · Desktop shell and tasks | `ui/`, shared `android/ui` build and task surfaces | First connect the shell to the account and workspace contracts using fixtures. Then implement Inbox, Today, Upcoming, Anytime, areas/projects, project headings, date/deadline/repeat/notes editors, Quick Find and undo. Compile the shared Compose sources for desktop with one source of truth and keep the Windows build independent of the Android SDK. Prove keyboard navigation, context menus, focus on edit, scale and accessibility on Win365. |
| D · Conversations and agents | `agents/`, shared conversation and settings bindings where needed | Show synced task conversations, send replies, answer option pills, stop the current agent and pause/resume agents account-wide. Use `ConversationMutator`, `SyncedSettingsMutator` and existing task backend calls. Check pending/rejected actions, remote updates and the actual agent state on a second client. |
| E · Packaging and evidence | Windows workflow, image and release configuration, tester instructions and parity evidence | Publish an exact-head tester image with commit and core version. Later take ownership of signed direct distribution, updates, and Microsoft Store submission with mz's signing and Store access. Keep an evidence row per canonical capability, including distinct CI and Win365 results. |

**First integration slice.** The coordinator lands shared contracts for session/account state, workspace lifecycle and sync state as one small commit. B makes client identity configurable in the shared HTTP and live socket code, and A consumes it for auth. A and B can implement against each other's fixtures once those interfaces are agreed. C builds the small shell on the same fixtures. E owns the CI files throughout. D can develop against fixture conversations once B's read/write interface is fixed. The coordinator owns the top-level desktop build and entry point and assigns individual file handoffs as needed.

**Second integration slice.** Integrate A, B, then the first C slice and run W1. C and D can continue in parallel after the live checkpoint. Keep each review scoped to its lane, rebase onto the integration head before testing, and run Windows x64 CI and Android CI for changes to shared Kotlin. Verify mutators, queues and retry semantics with existing conformance fixtures and targeted tests. Each task-surface PR should name its capability IDs and the evidence still needed.

Use this handoff for each worker:

> Implement lane [letter] from this plan in [worktree], based on [integration commit]. Use [contract commit] for the account and workspace interfaces. Keep changes within your assigned files and ask the coordinator to land cross-lane interface changes. Reuse the generated registry, released Rust core and shared Kotlin modules. Run the checks for your lane and report the commit, CI link, tests passed and remaining acceptance. The coordinator owns integration and the user's Win365 test handoff.

**First release.** Ship the W2 task and agent scope in the table after W1. The project organization feature is project headings, using the current task model. Attachments, calendar events, imports, global Quick Entry and system notifications are tracked parity follow-ups. Key the evidence to `registry/capabilities.json`, which supplies the Windows statuses for the site's parity table. Record each capability's device results before promoting its registry status. Keep Windows ARM64, signed upgrade/uninstall and Store submission explicit in the distribution work. If x64 live testing exposes a Compose constraint that prevents W1, record the repro and decide the fallback in a successor to ADR 0013 before changing stacks.
