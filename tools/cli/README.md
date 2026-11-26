# septena CLI

Your Septena tasks from the terminal (#653). A thin MCP client: each command is
one `tools/call` on `https://api.septena.app/mcp` with an agent key (#86), so
Stop, Pause, claims and the duplicate rule apply as for any agent. No
dependencies beyond Node 20.

    npx septena login          # paste a key from Settings > AI & Agents > Agents > New Agent Key
    septena add "Fix the flaky test" --today
    git log -5 --format=%s | septena add -
    septena today
    septena done <id>

The key lives in the macOS Keychain or the Linux Secret Service, never in a
dotfile. `SEPTENA_KEY` overrides it for CI. Inside a git worktree, `add` puts
the repository and branch on the task as an `about` reference; `--no-ref`
turns it off. Septena itself connects to no repository (ADR 0038).

Tasks the CLI adds are `origin: user_request`: they land where you said, not
as proposals.

Tests: `node --test test/*.test.mjs`. Publishing to npm is mz's call.
