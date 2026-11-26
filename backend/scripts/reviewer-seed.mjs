#!/usr/bin/env node
// Fills the directory reviewer demo account with sample data (ADR 0055,
// docs/CONNECTOR_DIRECTORY_SUBMISSION.md section 5).
//
//   node scripts/reviewer-seed.mjs            # against https://api.septena.app
//   API=https://... node scripts/reviewer-seed.mjs
//
// Needs reviewer mode on (REVIEWER_CODE and REVIEWER_ACCOUNT_ID set as
// secrets) and the ADMIN_TOKEN secret, read from the macOS keychain (service
// septena-cf/ADMIN_TOKEN) and never printed. /v1/admin/reviewer/prepare gives
// the demo account an app session and a Pro grant, and returns a short-lived
// connector token for it. The script writes through the public MCP tools, the
// same path a reviewer's agent uses, then revokes the token.
//
// Idempotent: when the demo account already has the "Studio" area, it writes
// nothing. All content is invented.

import { execFileSync } from "node:child_process";

const API = process.env.API ?? "https://api.septena.app";
const adminToken = () =>
  execFileSync("security", ["find-generic-password", "-s", "septena-cf/ADMIN_TOKEN", "-w"], { encoding: "utf8" }).trim();

const day = (offset) => new Date(Date.now() + offset * 86_400_000).toISOString().slice(0, 10);

async function prepare() {
  const res = await fetch(`${API}/v1/admin/reviewer/prepare`, {
    method: "POST",
    headers: { "X-Admin-Token": adminToken(), "Content-Type": "application/json" },
    body: "{}",
  });
  if (!res.ok) throw new Error(`prepare -> ${res.status} ${(await res.text()).slice(0, 200)}`);
  return res.json();
}

let rpcId = 0;
async function tool(token, name, args) {
  const res = await fetch(`${API}/mcp`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", Accept: "application/json, text/event-stream" },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method: "tools/call", params: { name, arguments: args } }),
  });
  const body = await res.json();
  const result = body.result;
  if (!res.ok || !result || result.isError) {
    throw new Error(`${name} -> ${res.status} ${JSON.stringify(body.error ?? result?.content ?? body).slice(0, 300)}`);
  }
  return JSON.parse(result.content[0].text);
}

async function seed(token) {
  const areas = await tool(token, "tasks_list_areas", {});
  const list = Array.isArray(areas) ? areas : areas.areas ?? [];
  if (list.some((a) => a.title === "Studio")) {
    console.log("The demo account already has sample data. Nothing written.");
    return;
  }
  const brief = (text) => `${text}\n\n## Log\n`;
  const studio = await tool(token, "tasks_area_create", {
    title: "Studio", emoji: "🎨",
    notes: brief("A small design studio run by one person. Client work comes first on weekdays."),
  });
  const home = await tool(token, "tasks_area_create", {
    title: "Home", emoji: "🏡",
    notes: brief("The flat, the garden and the bills."),
  });
  const site = await tool(token, "tasks_project_create", {
    title: "New studio website", area: studio.id,
    notes: brief("Goal: a five-page site that shows recent work.\nCurrent state: copy drafted, photos not chosen.\nDecisions: no blog for now."),
  });
  const garden = await tool(token, "tasks_project_create", {
    title: "Spring garden", area: home.id,
    notes: brief("Goal: the vegetable beds planted by the end of April."),
  });

  const create = (args) => tool(token, "tasks_create", { origin: "user_request", ...args });
  await create({ title: "Reply to the printer about paper samples", today: true, area: studio.id });
  await create({ title: "Choose six photos for the work page", today: true, project: site.id });
  await create({ title: "Water the seedlings", today: true, area: home.id, recurrence: { unit: "day", interval: 2, after_completion: true } });
  await create({ title: "Look into a second monitor", today: true });
  await create({ title: "Send the invoice for the poster job", scheduled: day(3), area: studio.id });
  await create({ title: "Order compost for the beds", scheduled: day(7), project: garden.id });
  await create({ title: "Sketch ideas for the studio logo", area: studio.id });
  await create({ title: "Fix the shed door", area: home.id });
  await create({
    title: "Read the hosting comparison before choosing a host", project: site.id,
    refs: [{ key: "https://septena.app/compare", role: "about", snapshot: { title: "Compare task apps" } }],
  });
  const research = await create({
    title: "Draft the About page text", project: site.id,
    notes: "Two short paragraphs about how the studio works. Friendly, no jargon.",
  });
  await tool(token, "tasks_set_assignee", { id: research.id, assignee: "claude" });
  const review = await create({
    title: "Summarise the three hosting options", project: site.id,
    notes: "Price, speed and how hard each is to set up.",
  });
  await tool(token, "tasks_set_assignee", { id: review.id, assignee: "claude" });
  await tool(token, "tasks_claim", { id: review.id, agent: "sample-data" });
  await tool(token, "tasks_set_endstate", {
    id: review.id, endState: "needs_verify",
    note: "The summary is in the task's conversation. Check the prices before you choose.",
  });
  console.log("Sample data written to the demo account.");
}

const tokens = await prepare();
try {
  await seed(tokens.access_token);
} finally {
  await fetch(`${API}/oauth/revoke`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ token: tokens.refresh_token }),
  });
}
