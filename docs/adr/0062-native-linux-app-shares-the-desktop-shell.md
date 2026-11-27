# 0062. Build the native Linux app on the shared Compose desktop shell

- Status: accepted (2026-11-27)
- Date: 2026-11-27
- Deciders: mz
- Extends: [ADR 0013](0013-native-windows-app-on-the-android-code.md) (Windows on the Android client's Kotlin code) and [ADR 0025](0025-shared-rust-core.md) (shared Rust core)

## Context

- Septena already ships a `linux-x86-64/libseptena_core.so` build of the shared Rust core inside `septena-core-jvm-natives-<version>.jar` (`.github/workflows/core.yml`, `.github/workflows/core-release.yml`) and runs every conformance vector on `ubuntu-latest` through JNA.
- The Windows client (#136, ADR 0013) is a Compose Multiplatform Desktop app in `windows/` sharing `android/core`, `android/store`, `android/transport`, and `android/ui/src/commonMain` with zero Android SDK dependencies.
- As of Checkpoint 1 (the fixture spike), `windows/` contains no Windows-specific APIs and uses `Ctrl` shortcuts that match Linux desktop conventions. Checkpoint 2 (live W1) is about to introduce per-account SQLite paths (`%LOCALAPPDATA%`), secret storage (DPAPI), and an explicit client identity label.
- Building a separate Linux GUI in another toolkit (such as GTK4/Rust or a web wrapper) would create a fourth independent client shell to keep in parity or violate ADR 0013's decision against wrapped web apps on desktop.

## Decision

Septena for Linux (#773) is a native Compose Multiplatform Desktop app that shares the same desktop shell, Kotlin store/sync/account modules, shared `android/ui` task surfaces, and released Rust core as the Windows client.

Before Windows live persistence (W1) lands, the desktop shell isolates OS-specific behavior behind one small `DesktopHost` boundary:

- **`DesktopPaths`**: per-account SQLite database and cache directories (`%LOCALAPPDATA%\Septena` on Windows; XDG Base Directory `$XDG_DATA_HOME/septena` / `~/.local/share/septena` on Linux).
- **`SecretVault`**: per-account session storage (current-user DPAPI on Windows; freedesktop Secret Service / `libsecret` over D-Bus on Linux, with explicit error handling when no keyring daemon is unlocked).
- **`ClientIdentity`**: platform identifier (`"windows"` vs `"linux"`), user-agent, and device label supplied to `android/transport` (`JsonHttp`, `SyncLiveSocket`).
- **`SystemBridge`**: external URL opening (`Desktop.browse` / `xdg-open`) and later desktop integrations (notifications, desktop metadata).

No Windows-only API (DPAPI, Win32 JNA, Windows paths) is imported outside `platform/windows/`. The desktop CI workflow (`.github/workflows/windows-spike.yml`) compiles and smoke-tests the shared desktop build on both `windows-2025` and `ubuntu-latest` on every PR so shared code cannot drift away from Linux.

Linux is added as a first-class platform (`"linux"`) across `registry/capabilities.json`, `registry/sign-in.json`, `registry/settings.json`, and `registry/actions.json`, and on `septena.app` (`/apps/linux`, `/features/parity`, `/compare`, `/roadmap`).

## Phases

| Phase | Done when | Depends on |
|---|---|---|
| L0 Shared host seam | `DesktopHost` isolates paths, secret storage, client identity, and system bridge; desktop CI compiles and smoke-tests on both `windows-2025` and `ubuntu-latest`. | #136 spike |
| L1 Spike | A Linux x64 build signs in (device approval / email code), stores secrets in `libsecret`, stores SQLite under XDG, creates a task offline, and pushes after reconnect. Tested on a real Linux desktop against a written checklist. | L0, W1 account/workspace contracts |
| L2 First release scope | Matches Windows W2 scope: Inbox, Today, Upcoming, Anytime, areas, projects, sections, When and Deadline, repeat, notes, Quick Find, undo, conversations with option pills, Stop and Pause all agents. Keyboard-first with `Ctrl` shortcuts. | L1 |
| L3 Distribution | `.deb`, `.rpm`, and distro-agnostic bundle (AppImage or Flatpak) with `.desktop` metadata; Wayland + X11 checks; optional Linux ARM64 Rust core slice (`aarch64-unknown-linux-gnu`). | L2 |
| L4 Parity ledger | Every capability in the site's parity table has a Linux status backed by evidence; gaps have open issues. | L2 |

## Consequences

- Windows and Linux share ~95% of their code (UI, sync, SQLite store, account state machine, agent conversations), so every feature built for Windows immediately compiles and runs on Linux.
- The Windows worker only needs to keep DPAPI, `%LOCALAPPDATA%`, and Windows packaging behind `DesktopHost` — no extra Linux work during W1/W2.
- The upcoming Linux worker only needs to implement `platform/linux/` (`XdgPaths`, `LibsecretVault`, `LinuxClientIdentity`), Linux packaging, and Linux desktop acceptance.
- Trade-off: the Linux app ships a bundled JRE and Skia/Material 3 rendering (same as Windows), rather than native GTK4/Libadwaita or Qt widgets.
- Directory rename (`windows/` to `desktop/`) can happen in one mechanical commit once active Windows W1 work settles; keeping the Gradle directory path stable during W1 avoids unnecessary merge churn.

## Links

- #773 Linux client · #136 Windows client · #20 Android client · #21 web client
- [ADR 0013](0013-native-windows-app-on-the-android-code.md) · [ADR 0025](0025-shared-rust-core.md)
- `docs/WINDOWS_IMPLEMENTATION_PLAN.md`
