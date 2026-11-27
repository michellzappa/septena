# Septena

Tasks that think with you. Your agents do the work. You decide when it's done.

Septena is a task app for you and your agents. You capture tasks, your agents add theirs, and everything lands in one list in your own account. An agent can pick up a task you assign it, ask its questions inside that task, and hand the result back for you to check. Only you mark it done.

[septena.app](https://septena.app) · [Download](https://septena.app/download) · [Connect an agent](https://septena.app/agents) · [Roadmap](https://septena.app/roadmap) · [Changelog](https://septena.app/changelog) · [Support](https://septena.app/support)

## Connect an agent

In Claude Code, add this repository as a plugin marketplace and install the Septena plugin:

```
/plugin marketplace add septena/septena
/plugin install septena@septena
```

Then type `/mcp`, pick septena and sign in. The plugin adds the tasks connector and a skill that teaches Claude how to work a task. For other agents, see [septena.app/agents](https://septena.app/agents).

## How agents work with your tasks

An agent connects over MCP at `api.septena.app/mcp`. It reads the tasks, areas and projects you can see in the app, and it changes them the way you would.

When you assign a task to an agent, the agent claims it, writes each step into the task's conversation, and asks you when it needs a decision. When it finishes, it sends the task to Review with a note on what to check. You accept the work or send it back.

Stop ends one agent's work on a task. Pause stops every agent at once. The sync server enforces both, so an agent cannot carry on past them. The rules are in [ADR 0008](docs/adr/0008-agent-loop-rules-live-in-the-store.md).

The same tasks are also available over a REST API. The contract is generated from the server code: [`api.septena.app/openapi.json`](https://api.septena.app/openapi.json) and [`docs/agent-spec/spec.md`](docs/agent-spec/spec.md). The procedures an agent follows are in [`skills/`](skills/).

## How it works

Each app keeps your tasks in a local store and writes every change there first, so the app works offline. A sync engine sends the changes to Septena's own server at `api.septena.app`, which runs on Cloudflare Workers ([ADR 0002](docs/adr/0002-own-backend-replaces-icloud.md)).

Rules that must behave the same in every app, such as repeating tasks and list order, live once in a shared Rust core ([ADR 0025](docs/adr/0025-shared-rust-core.md)). The apps call it instead of re-implementing it. Copy, menu actions, shortcuts and settings live in JSON files under [`registry/`](registry/), and a generator turns them into constants for each app.

## Build it

| Part | Folder | Toolchain |
| --- | --- | --- |
| Apple apps | `Septena/`, `SeptenaCore/`, `Septask*/` | Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) |
| Android app | `android/` | Gradle, JDK 17 |
| Web app | `web/` | Node, pnpm |
| Windows app | `windows/` | Gradle |
| Sync server and MCP | `backend/` | Node, pnpm, Wrangler |
| Shared core | `core/` | Rust (CI builds it) |

For the Apple apps, `project.yml` is the source of truth. Generate the Xcode project, then open it:

```bash
git clone https://github.com/septena/septena.git
cd septena
brew install xcodegen
xcodegen generate
open Septena.xcodeproj
```

The code targets keep the working name Septask. `Septask` builds the phone and tablet app with its watch app, widgets and share extension. `SeptaskMac` builds the desktop app. `SeptenaCoreTests` runs the unit tests for the task logic.

To sign a build with your own developer account, copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` and set `SEPTENA_DEVELOPMENT_TEAM`. [`docs/BUILDING_YOUR_OWN.md`](docs/BUILDING_YOUR_OWN.md) has the details. The other parts build in CI; the workflows are in [`.github/workflows/`](.github/workflows/).

## Repository map

| Folder | What it holds |
| --- | --- |
| `SeptenaCore/` | models, local store, sync, import, the mutators that every write goes through |
| `Septena/Shell/` | the shared task screens, sidebar and settings |
| `Septask/` | app entry, launch and the desktop window shell |
| `SeptaskWatch/`, `SeptaskWidgets/`, `ShareExtension/` | watch app, widgets and share extension |
| `android/`, `web/`, `windows/` | the other apps |
| `backend/` | the sync server, REST API and MCP server |
| `core/` | the shared Rust core |
| `registry/` | copy, actions, settings and design tokens shared by every app |
| `skills/` | agent procedures, also served at `septena.app/skills` |
| `docs/` | specs, plans and decision records; start at [`docs/README.md`](docs/README.md) |

## Contributing

Bug reports, ideas and focused pull requests are welcome. Open an [issue](https://github.com/septena/septena/issues) first for anything large. People and coding agents follow the same rules, and they are in [`AGENTS.md`](AGENTS.md). [`CONTRIBUTING.md`](CONTRIBUTING.md) covers the checks a pull request must pass. To report a vulnerability, follow [`SECURITY.md`](SECURITY.md).

Michell Zappa makes Septena on his own, with AI as his pair programmer, mostly Claude.

## License

The code is MIT licensed. See [`LICENSE`](LICENSE). Copyright (c) 2026 Michell Zappa.

The license covers the code, not the brand. The name "Septena", the wordmark and the app icon are reserved trademarks, as [`NOTICE`](NOTICE) explains. Fork and build all you like, but ship your version under your own name and icon. The bundled Claude name and logo belong to Anthropic and are there only to identify the Claude integration.
