// Ambient declaration so TypeScript accepts `import md from "../skill.md"`.
// The wrangler text-import rule in wrangler.toml resolves these to string
// literals at bundle time.
declare module "*.md" {
  const content: string;
  export default content;
}
