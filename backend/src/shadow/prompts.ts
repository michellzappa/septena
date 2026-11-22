import ONBOARD_MARKDOWN from "../../onboard.md";
import type { Prompt } from "../rpc.js";

// MCP prompts served by the api.septena.app connector (#124,
// docs/PROJECT_NOTES_SPEC.md §7). The prompt text lives in `backend/onboard.md`
// so `GET /onboard.md` and the MCP prompt `onboard_septena` never diverge.

export { ONBOARD_MARKDOWN };

export interface PromptMessage {
  role: "user" | "assistant";
  content: { type: "text"; text: string };
}

export interface PromptResult {
  description: string;
  messages: PromptMessage[];
}

export const ONBOARD_PROMPT_NAME = "onboard_septena";

export const PROMPTS: Prompt[] = [
  {
    name: ONBOARD_PROMPT_NAME,
    title: "Set up Septena",
    description:
      "Populate your Septena account with real areas (with context and emoji), projects (with briefs), and tasks, " +
      "starting from what your agent already knows about you, or a short conversation if starting fresh.",
    arguments: [
      {
        name: "focus",
        description: "Optional starting context, areas to focus on, or a pasted list of tasks.",
        required: false,
      },
    ],
  },
];

/// Strip YAML frontmatter when delivering the skill body inside a prompt turn.
function stripFrontmatter(md: string): string {
  return md.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n+/, "").trim();
}

export function getPrompt(name: string, args?: Record<string, unknown>): PromptResult | null {
  if (name !== ONBOARD_PROMPT_NAME) return null;
  const focus = typeof args?.focus === "string" ? args.focus.trim() : "";
  const body = stripFrontmatter(ONBOARD_MARKDOWN);
  const text = focus
    ? `${body}\n\n## Starting context from the user\n\n${focus}`
    : body;
  return {
    description: PROMPTS[0].description,
    messages: [{ role: "user", content: { type: "text", text } }],
  };
}
