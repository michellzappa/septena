# 0025. Put task rules and sync decisions in one shared Rust core

- Status: accepted (2026-11-22)
- Date: 2026-11-22
- Deciders: mz
- Amends: [ADR 0013](0013-native-windows-app-on-the-android-code.md) (phase
  W0) and [ADR 0015](0015-shared-registries-for-cross-platform-clients.md)
  (how pure logic is shared)

## Context

- Septena has five client platforms on the roadmap: iOS, macOS, web (#21),
  Android (#20) and Windows (#136). They use three languages: Swift,
  TypeScript and Kotlin. The backend is a fourth codebase in TypeScript.
- After ADR 0002 every client speaks one push/pull protocol to
  `api.septena.app`. The agent loop and the write rules run on the server
  (ADR 0008). The client core is therefore small: wire codecs, domain rules
  and the sync engine.
- On 2026-11-22 these copies exist:
  - Swift, about 5,400 lines: `SeptenaCore/TaskBackend/*` (sync engine,
    outbox, shadows, apply, mapping), `TaskFade`, `DayBucket`, `DateParser`
    recurrence, `ConvoDerived`, `TaskListOrder`.
  - Kotlin, about 1,700 hand-written lines: `android/core` (A1, #173, in
    progress). Rules, codec, mutator, engine, and the pull merge in
    `android/store`.
  - TypeScript: `backend/src/tools/taskShared.ts`, `backend/src/recurrence.ts`
    and `backend/src/reminders.ts`, about 500 lines. The web client spec plans
    a fourth copy (`packages/task-rules`, WB2).
- ADR 0015 keeps the copies aligned with registries and 5 conformance vector
  files. Vectors catch drift in pure functions. They catch drift in a
  stateful engine (merge, cursor, retry, reject) much less well, and every
  new rule still costs one implementation per language.
- Bipe faced the same five platforms and accepted a shared Rust core on
  2026-11-07 (Bipe ADR 0267). Its spike passed size and time budgets on iOS,
  macOS, Android, the JVM on Windows and WASM. Bipe's core is pure logic: no
  network, files, clock or secrets. Septena can reuse that build route.
- The Apple apps store tasks in SwiftData, and mutators, views, widgets and
  App Intents read it. A core that owns the store would force a rewrite of
  the shipping app's data layer.
- Rust's watchOS targets are tier 3 (nightly only). The Septask watch
  compiles `DateParser.swift` for recurrence.
- No machine of mz's has a Rust toolchain. CI runners do.

## Decision

Septena builds one shared Rust core, `septena-core`, in `core/`. It holds
the task domain rules and the sync decisions. It does no I/O: no network,
no storage, no clock, no secrets. Hosts pass in the current time and the
rows. The core returns values and plans that the host applies.

- **In the core:** wire constants generated from `registry/` (rules, limits,
  enums), task view membership, fade, recurrence and occurrence ids,
  reminders, conversation projection, and the sync engine's decisions: pull
  page checks, the pull-row merge ("local wins while its op is queued"),
  push-response handling (bisect on 400, reject one) and server rejection
  reasons.
- **Native per platform:** UI, navigation, undo, the store engine
  (SwiftData, SQLDelight, IndexedDB), HTTP and WebSocket transport, sign-in
  and secret storage, notifications, EventKit, imports.
- **Bindings:** UniFFI for Swift (XCFramework) and Kotlin (Android AAR and a
  JVM library for Windows). `wasm-bindgen` for the web client and, later,
  the Worker.
- **Registries stay the authority.** `scripts/gen-registries.mjs` gains a
  Rust target. The conformance vectors stay language-neutral and gain a
  sync file (`registry/conformance/sync-engine.json`).
- **CI is the build gate.** `.github/workflows/core.yml` builds and tests the
  core and every packaged artifact. Agents do not install Rust.

### Order *(defaults chosen; mz can overrule)*

1. **C0 spike.** The crate, the Rust codegen target and the CI workflow.
   All conformance vectors pass in `cargo test` and through each packaged
   artifact: macOS (Swift), the JVM on Linux and Windows (Kotlin), and
   WASM in Node. Android and iOS slices build and report their size.
2. **Android A1 continues in Kotlin until C0 passes.** The Kotlin store,
   transport and UI do not change with the core. Only the Kotlin rule
   files and the store's merge decisions move to the core (C1).
3. New shared logic after C0 lands in the core first, not in three
   languages.
4. Each move deletes the hand-written copy in the same change. The vectors
   stay.

### Gates for C0 *(defaults, taken from Bipe ADR 0267)*

| Gate | Budget |
|---|---|
| Conformance | Every vector passes in each packaged artifact |
| Native slice size (stripped static library or cdylib) | ≤ 1 MiB |
| WASM size, Brotli | ≤ 300 KiB |
| Time per call | p95 ≤ 5 ms |

If C0 fails a gate, a new ADR records the numbers. The fallback is the
plan of ADR 0013 and ADR 0015: Kotlin and TypeScript copies kept aligned
by the vectors.

## Consequences

- One implementation of each rule and each sync decision for five clients
  and, later, the server. The sync engine cannot drift between platforms.
- The repo gains a fifth language, a Cargo lockfile, and a release pipeline
  for an XCFramework, an AAR, a JVM library and a WASM package.
- One bug in the core reaches every client. The independent vectors matter
  more than they did with separate copies.
- Debugging crosses a language boundary. The core's API uses plain values
  and JSON strings for row fields, so a host can log every call.
- The Apple apps move to the core piece by piece (C4), rules first. SwiftData
  stays.
- Agents cannot compile the core locally. A core change waits for CI.
- The watch keeps its Swift recurrence until C4 decides how a wrist
  completion reaches the core (default: the phone runs it).

## Open questions

| Question | Default |
|---|---|
| Language | Rust, with UniFFI and wasm-bindgen *(default)* |
| Scope | Rules and sync decisions, no I/O, the store stays native *(default)* |
| Home | `core/` in this repo *(default)* |
| Toolchain | CI only; no local Rust on the laptop or mz-mini *(default)* |
| Kotlin A1 | Continues; C1 swaps its rules for the core after C0 *(default)* |
| Web client | WB2 uses the core's WASM, not `packages/task-rules` *(default)* |
| Backend | Keeps TypeScript; C3 measures the core's WASM in the Worker *(default)* |
| Watch | Keeps Swift recurrence until C4 *(default)* |
| Licence | MIT, as the rest of the repo; Cargo dependencies reviewed in CI *(default)* |

## Links

- Spec: `docs/SHARED_CORE_SPEC.md`
- ADR 0002 own backend · ADR 0008 agent loop in the store · ADR 0013 Windows
  on the Android code · ADR 0015 shared registries
- Issues: #246 C0 spike · #247 C1 Android and Windows · #248 C2 web · #249 C3 backend · #250 C4 Apple · #251 C5 releases · #20 Android · #21 web · #136 Windows · #173 Android A1
- Bipe: `bipe-chat/bipe` ADR 0267, `bipe-chat/bipe-app` `core/` and
  `.github/workflows/core.yml`
