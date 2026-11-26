# Septena Agent Packages (Issue #88)

Draft installable packages for AI coding/CLI agents pointing at the Septena tasks MCP connector (`https://api.septena.app/mcp`), plus the draft `llms.txt` for `septena.app`.

The Claude Code plugin is published. This repo is its marketplace (`.claude-plugin/marketplace.json` at the repo root):

```
/plugin install septena --marketplace michellzappa/septena
```

The Gemini CLI extension and `llms.txt` are still drafts.

## Single source of truth

The agent loop rules from [`https://septena.app/agents.md`](https://septena.app/agents.md) live in one file:

- [`loop-rules.md`](./loop-rules.md)

Both packages are generated from that single file by [`sync.mjs`](./sync.mjs):

- `gemini-extension/GEMINI.md` — context file referenced by `gemini-extension/gemini-extension.json`
- `claude-plugin/skills/septena/SKILL.md` — Claude Code skill (YAML frontmatter + exact loop rules)

After editing `loop-rules.md`, regenerate and verify zero drift:

```bash
node tools/agent-packages/sync.mjs
node tools/agent-packages/sync.mjs --check
```

## What is included

| Path | Target | Auth today |
|---|---|---|
| [`gemini-extension/`](./gemini-extension/gemini-extension.json) | Gemini CLI extension (`gemini-extension.json` + `GEMINI.md`) | Streamable HTTP (`httpUrl`) + OAuth PKCE with RFC 9728/8414 discovery + loopback redirect |
| [`claude-plugin/`](./claude-plugin/.claude-plugin/plugin.json) | Claude Code plugin (`.claude-plugin/plugin.json` + `.mcp.json` + `skills/septena/SKILL.md`) | Streamable HTTP (`type: "http"`) + OAuth PKCE with loopback redirect |
| [`llms.txt`](./llms.txt) | Draft `https://septena.app/llms.txt` pointing at `/agents.md` | N/A (copy to `septena-site/public/llms.txt` when shipping) |

## What waits on agent keys (#86) or external repos

- **OpenClaw / ClawHub skill & Hermes Agent skill** — wait on **agent keys (#86)** because those clients cannot hold an interactive OAuth sign-in and need `Authorization: Bearer <key>` on `/mcp`.
- **Headless / CI / cron runs of Gemini CLI or Claude Code** — interactive local sessions can complete the OAuth PKCE + pairing-code flow on loopback today; non-interactive/headless runners without a browser wait on **agent keys (#86)**.
- **Gemini CLI extension repo** — not created. `gemini extensions install` wants the extension at a repo root, so it needs its own repo. The Claude Code plugin needs none: this repo is its marketplace.
- **"Add to Cursor" deep link on `/agents` and serving `llms.txt` on `septena.app`** — live in the private `septena-site` repository.
