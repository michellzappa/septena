# Septena Android

The Android client is being built around the canonical contracts in `../registry/`.
Regenerate Kotlin registry bindings from the repository root with:

```sh
node scripts/gen-registries.mjs
```

| Module | Responsibility | Platform reach |
|---|---|---|
| `core` | Registry validation, task and conversation mutators, view rules, sync protocol and engine | Kotlin/JVM |
| `store` | SQLDelight records, shadows, local turns and persistent outbox | Kotlin/JVM; Android driver in the app |
| `transport` | Authenticated HTTP adapter for sync push and pull | JVM APIs available on Android and Windows |
| `ui` | Shared Compose task-list surface | Android |
| `app` | Android lifecycle, SQLite driver, and app composition root | Android |

User-visible action IDs, destination IDs, labels, settings, capabilities and
domain rules come from generated registry data. Native hosts bind those IDs to
the portable mutators and may provide their own surrounding navigation and
system integrations.

The first app surface is an offline Today list with quick add and completion.
It writes through `TaskMutator` into SQLite and the durable outbox. Account
approval and email sign-in still depend on the separate A0 backend work in
`docs/ANDROID_CLIENT_SPEC.md`; the app does not show placeholder sign-in flows.

Android CI follows the Bipe build pattern: `.github/workflows/android.yml`
uses Temurin JDK 17 and the checked-in Gradle wrapper on `ubuntu-latest`, then
publishes a short-lived `septena-android-debug-apk` artifact. Download that APK
to the host connected to the phone and install it with `adb install -r`.
The CI job compiles the app but does not run tests or launch it on a device.
