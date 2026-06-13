// Tiny static server for the App Store viz (no dependencies).
//   node serve.mjs   → http://127.0.0.1:4477/viz/
import { createServer } from "node:http";
import { readFileSync, existsSync, statSync } from "node:fs";
import { join, dirname, extname, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { exec } from "node:child_process";

const ROOT = dirname(fileURLToPath(import.meta.url));
const MIME = { ".html": "text/html", ".json": "application/json", ".png": "image/png",
  ".jpg": "image/jpeg", ".css": "text/css", ".mjs": "text/javascript", ".js": "text/javascript",
  ".ttf": "font/ttf", ".svg": "image/svg+xml" };

createServer((req, res) => {
  let p = normalize(decodeURIComponent(new URL(req.url, "http://x").pathname));
  if (p.includes("..")) { res.writeHead(403).end(); return; }
  // Alias the repo's variable Fraunces so the viz uses the real brand serif.
  let file = p === "/fraunces.ttf"
    ? join(ROOT, "..", "Septena", "Resources", "Fraunces-Regular.ttf")
    : join(ROOT, p);
  if (existsSync(file) && statSync(file).isDirectory()) file = join(file, "index.html");
  if (!existsSync(file)) { res.writeHead(404); res.end("not found"); return; }
  res.writeHead(200, { "content-type": MIME[extname(file)] ?? "application/octet-stream", "cache-control": "no-store" });
  res.end(readFileSync(file));
}).listen(4477, "127.0.0.1", () => {
  const url = "http://127.0.0.1:4477/viz/";
  console.log(`appstore viz → ${url}`);
  exec(`open ${url}`, () => {}); // macOS convenience; harmless elsewhere
});
