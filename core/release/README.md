# Shared core releases (C5, #251)

Apps link a **released** shared core, never a local Rust build (ADR 0025).

## Cut a release

1. Set `version` in `core/Cargo.toml` and the two workspace entries in
   `core/Cargo.lock` (`septena-core`, `septena-core-wasm`) to the new version.
   Land that on `main` through a PR with a green `core` run.
2. Tag `main`: `git tag core-vX.Y.Z && git push origin core-vX.Y.Z`.
3. `.github/workflows/core-release.yml` checks that the tag matches the
   crate version, runs every `core.yml` job (vectors and budgets), and
   publishes the release.

## Assets of a release

| Asset | For |
|---|---|
| `SeptenaSharedCoreFFI-X.Y.Z.xcframework.zip` | iOS, iOS simulator and macOS (SwiftPM `binaryTarget`) |
| `SeptenaSharedCore-X.Y.Z.swift` | The Swift bindings |
| `septena-core-kotlin-X.Y.Z.zip` | The Kotlin bindings (Android and the JVM) |
| `septena-core-android-jnilibs-X.Y.Z.zip` | `arm64-v8a`, `armeabi-v7a`, `x86_64` in Gradle's `jniLibs` layout |
| `septena-core-jvm-natives-X.Y.Z.jar` | Linux and Windows natives in JNA's resource layout (Windows app) |
| `septena-core-wasm-web-X.Y.Z.tgz` | The `wasm-bindgen --target web` package (web client) |
| `release.json` | Every asset with its URL and SHA-256 |

## Pin a release

`scripts/core-pin.sh X.Y.Z` writes this directory:

- `release.json`: the pinned manifest. Android (C1) and the web client (C2)
  read their asset URLs and checksums from it.
- `swift/`: a local Swift package. Its `binaryTarget` names the XCFramework
  zip by URL and checksum, so Xcode downloads the prebuilt core. C4 (#250)
  adds it to `project.yml`.

Commit the result. Never edit `swift/` by hand.
