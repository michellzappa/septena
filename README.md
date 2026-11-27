# Septena

Septena is a private, local-first task app for you and your agents, on iPhone, iPad, Mac, Apple Watch and Android. Tasks live in a local store and sync through Septena's own backend. Agents reach the same tasks over MCP.

## Connect an agent

In Claude Code, install the Septena plugin. It adds the tasks connector and the agent loop skill:

```
/plugin marketplace add septena/septena
/plugin install septena@septena
```

Then type `/mcp`, pick septena and sign in. Other agents: [septena.app/agents](https://septena.app/agents).

The app was once a life operating system. That product moved to its own repository on 2026-11-21 ([ADR 0017](docs/adr/0017-move-septena-life-out-of-repo.md)); its history is under the tag `septena-life-archive`.

## Stack

- **SwiftUI** on iOS, iPadOS and watchOS, **AppKit** on macOS, **Kotlin / Compose** on Android
- **SwiftData** local store on Apple platforms, first write for every change
- **Cloudflare Worker** task backend and MCP server (`backend/`)
- **Rust** core for shared task rules (`core/`, [ADR 0025](docs/adr/0025-shared-rust-core.md))
- **Registry** files for shared copy, actions and settings (`registry/`)
- **XcodeGen**: `project.yml` is the source of truth for the Xcode project
- Swift 5.10, deployment target 26.0

## Quick start

```bash
git clone https://github.com/septena/septena.git
cd septena
brew install xcodegen
xcodegen generate
open Septena.xcodeproj
```

| Scheme | Target |
| --- | --- |
| `Septask` | iOS and iPadOS app, embeds the watch app, widgets and share extension |
| `SeptaskMac` | macOS app |
| `SeptaskWatch` | watchOS app |
| `SeptenaCoreTests` | unit tests for pure task logic |

The code targets keep the working name Septask; the product is Septena. To build a signed copy on your own account, copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` (gitignored) and set `SEPTENA_DEVELOPMENT_TEAM`. See [`docs/BUILDING_YOUR_OWN.md`](docs/BUILDING_YOUR_OWN.md). Android builds in CI (`.github/workflows/android.yml`).

## Layout

| Folder | What it holds |
| --- | --- |
| `SeptenaCore/` | models, SwiftData, task sync, import, mutators |
| `Septena/Shell/` | shared task UI, sidebar, settings, on-device AI |
| `Septask/` | app entry, launch, settings shell, AppKit shell |
| `SeptaskWatch/`, `SeptaskWatchComplication/`, `SeptaskWidgets/`, `ShareExtension/` | watch app and extensions |
| `android/` | Android app |
| `core/` | shared Rust core |
| `backend/` | task backend and MCP server (`api.septena.app`) |
| `registry/` | shared copy, actions, settings and tokens |
| `docs/` | specs, plans and ADRs; start at [`docs/README.md`](docs/README.md) |

Rules for contributors and coding agents are in [`AGENTS.md`](AGENTS.md). Code wins over any doc.

## License

MIT - see [`LICENSE`](LICENSE). Copyright (c) 2026 Michell Zappa.

The MIT grant covers the **code**, not the **brand** — see [`NOTICE`](NOTICE).
"Septena," the wordmark, and the app icon are reserved trademarks: fork and
build all you like, but ship derivatives under your own name and icon. One
bundled asset is also excluded — the Claude name/logo (an Anthropic trademark,
bundled only to identify the Claude integration).
