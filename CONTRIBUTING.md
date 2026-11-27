# Contributing

Septena's apps and server are open source under the MIT License (see `LICENSE`; the Septena name and icon stay reserved under `NOTICE`). Bug reports, ideas and focused pull requests are welcome.

## Ways to contribute

- Open an issue in [GitHub Issues](https://github.com/septena/septena/issues) to report a bug or suggest a feature, comment on an existing roadmap issue or [write to support](https://septena.app/support).
- Send a pull request for an open issue or a clear bug fix. For larger changes, open an issue first so we agree on the shape before you write the code.

## Before changing code

- Read `README.md` for the repository layout and quick start.
- Read `AGENTS.md` for architecture invariants, build commands, CI gates and known traps. People and coding agents follow the same rules.
- Read `docs/BUILDING_YOUR_OWN.md` if you are building a signed copy under your own Apple Developer account.
- When code and an older doc disagree, follow the current code.

## Development and checks

Use XcodeGen as the source of truth for the Apple project:

```bash
xcodegen generate
```

Build through `scripts/build.sh` (it serializes concurrent builds):

```bash
scripts/build.sh SeptaskMac 'platform=macOS'
```

Run the core unit tests before opening a pull request:

```bash
xcodebuild -project Septena.xcodeproj -scheme SeptenaCoreTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

Backend changes live in `backend/` (Cloudflare Worker and MCP server), the shared Rust core lives in `core/` (gated by `.github/workflows/core.yml`), and the Android client lives in `android/` (gated by `.github/workflows/android.yml`).

## Code guidelines

- Route writes through mutators (`TaskMutator`, `AreasMutator`, `ProjectsMutator`) when a mutator exists.
- Keep task behavior local-first: write to the local store first, then sync through `TaskSyncEngine` (`api.septena.app`). Septena does not use iCloud or CloudKit.
- Keep shared business rules in `core/` and shared constants in `registry/` instead of duplicating them across clients.
- Keep user data private by default. Avoid broad network or security exceptions; add narrowly scoped comments when an exception is required.
- Never commit personal signing settings (`Config/Secrets.xcconfig`), API credentials, generated build output or dependency folders.

## Security

Report vulnerabilities privately using `SECURITY.md`. Never open a public issue for leaked credentials, authentication flaws or anything involving private user data.
