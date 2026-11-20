// Landing surface for mcp.septena.app:
//   GET /         → HTML page introducing the gateway and embedding the
//                   skill brief so model/human visitors land on the same
//                   docs that ship with the in-app Skills section.
//   GET /skill.md → raw markdown (text/markdown) for copy-paste into any
//                   MCP client's system prompt or Claude Code skill file.
//
// Content source: `skill.md` at the repo root, imported as a text module
// via wrangler's `[[rules]] type = "Text"` config. To update, edit
// skill.md and redeploy; no rebuild step needed.

import skillRaw from "../skill.md";

const PUBLIC_APP_URL = "https://www.septena.app";
const MCP_ENDPOINT   = "https://mcp.septena.app/mcp";

/** Strip YAML frontmatter (the `--- ... ---` block at the top of SKILL.md). */
function stripFrontmatter(md: string): string {
  return md.replace(/^---\n[\s\S]*?\n---\n+/, "");
}

/** The skill markdown, frontmatter removed — what we expose publicly. */
export const SKILL_MARKDOWN: string = stripFrontmatter(skillRaw);

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

const STYLES = `
  :root {
    color-scheme: light dark;
    --bg: #fff;
    --fg: #111;
    --muted: #6b7280;
    --border: #e5e7eb;
    --accent: #5b21b6;
    --code-bg: #f5f5f5;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #0b0b0c;
      --fg: #e5e5e5;
      --muted: #9ca3af;
      --border: #1f2937;
      --accent: #a78bfa;
      --code-bg: #1a1a1d;
    }
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; padding: 0; background: var(--bg); color: var(--fg); }
  body {
    font: 16px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", system-ui, sans-serif;
    -webkit-font-smoothing: antialiased;
  }
  main { max-width: 760px; margin: 0 auto; padding: 48px 24px 96px; }
  header { margin-bottom: 48px; padding-bottom: 32px; border-bottom: 1px solid var(--border); }
  h1 { margin: 0 0 8px; font-size: 32px; font-weight: 600; letter-spacing: -0.02em; }
  .lede { margin: 0 0 24px; font-size: 18px; color: var(--muted); }
  .endpoint {
    display: inline-block; padding: 10px 14px; margin: 0 0 24px;
    background: var(--code-bg); border-radius: 8px;
    font: 14px/1 ui-monospace, "SF Mono", Menlo, monospace;
    user-select: all;
  }
  .endpoint-label { display: block; margin-bottom: 6px; font-size: 12px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.05em; }
  nav { display: flex; flex-wrap: wrap; gap: 16px; font-size: 14px; }
  nav a { color: var(--accent); text-decoration: none; }
  nav a:hover { text-decoration: underline; }
  .primary {
    display: inline-block; padding: 12px 18px; margin-right: 12px;
    background: var(--accent); color: #fff; border-radius: 8px;
    font-weight: 500; text-decoration: none;
  }
  .primary:hover { opacity: 0.9; text-decoration: none; }
  article pre {
    margin: 0; padding: 28px;
    background: var(--code-bg);
    border-radius: 12px;
    font: 13px/1.6 ui-monospace, "SF Mono", Menlo, monospace;
    white-space: pre-wrap;
    overflow-x: auto;
    color: var(--fg);
  }
  article h2 {
    font-size: 14px; font-weight: 600;
    text-transform: uppercase; letter-spacing: 0.05em;
    color: var(--muted); margin: 0 0 12px;
  }
  footer {
    margin-top: 64px; padding-top: 24px;
    border-top: 1px solid var(--border);
    color: var(--muted); font-size: 14px;
    display: flex; justify-content: space-between; flex-wrap: wrap; gap: 12px;
  }
  footer a { color: var(--muted); }
`;

/**
 * Renders the public landing page. Embeds the full skill brief in a
 * styled <pre> block — preserves markdown formatting reliably without
 * pulling in a markdown parser. Models reading the page get the same
 * content as humans, and `/skill.md` gives the raw text for tool prompts.
 */
export function landingHTML(): string {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Septena MCP</title>
  <meta name="description" content="MCP gateway for Septena — connect Claude or another AI assistant to your private CloudKit data: tasks, nutrition, habits, training, and more.">
  <link rel="canonical" href="https://mcp.septena.app/">
  <style>${STYLES}</style>
</head>
<body>
  <main>
    <header>
      <h1>Septena MCP</h1>
      <p class="lede">Connect Claude or another MCP client to your private Septena data — tasks, nutrition, habits, training, and more, straight out of your iCloud CloudKit store.</p>

      <span class="endpoint-label">MCP endpoint</span>
      <code class="endpoint">${escapeHtml(MCP_ENDPOINT)}</code>

      <div>
        <a class="primary" href="${escapeHtml(PUBLIC_APP_URL)}">Get Septena →</a>
      </div>

      <nav style="margin-top: 24px;">
        <a href="/skill.md">skill.md (raw)</a>
        <a href="${escapeHtml(PUBLIC_APP_URL)}">www.septena.app</a>
        <a href="/health">health</a>
      </nav>
    </header>

    <article>
      <h2>Skill brief</h2>
      <pre>${escapeHtml(SKILL_MARKDOWN)}</pre>
    </article>

    <footer>
      <span>Septena · personal data, owned and synced via CloudKit.</span>
      <a href="${escapeHtml(PUBLIC_APP_URL)}">www.septena.app</a>
    </footer>
  </main>
</body>
</html>`;
}
