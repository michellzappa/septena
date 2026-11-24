#!/usr/bin/env node
// Exports the phone screens the Septena App Store panels use, from the
// website's scene builder (SEPTENA_SITE, default ../../_/septena-site).
// Each panel's screen is captured in the panel's own fruit accent
// (SCENE_ACCENT), so the app's accent matches the panel fill; a shot with
// `accent: null` keeps the scene's own colours (the looks scene).
//   appstore/scenes/                 scene colours
//   appstore/scenes/accent-<fruit>/  every screen in that accent
// Run after `npx next build` in the site. Fails closed on any capture error.
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

process.env.SEPTENA_APP ??= "septask";
const ROOT = dirname(fileURLToPath(import.meta.url));
const SITE = process.env.SEPTENA_SITE ?? join(ROOT, "../../_/septena-site");
if (!existsSync(join(SITE, "out", "scenes.html"))) throw new Error(`Build the site first: cd ${SITE} && npx next build`);
const { septaskPanels } = await import("./panels.septask.mjs");

const jobs = new Map(); // accent ("" = scene colours) -> { scenes, layouts }
for (const panel of septaskPanels.iphone69) {
  for (const s of [panel.shot, panel.photo?.screen, ...(panel.shots ?? [])].filter(Boolean)) {
    const key = s.accent ?? "";
    if (!jobs.has(key)) jobs.set(key, { scenes: new Set(), layouts: new Set() });
    jobs.get(key).scenes.add(String(s.src).split("/")[0]);
    jobs.get(key).layouts.add(s.layout ?? "phone");
  }
}
for (const [accent, { scenes, layouts }] of jobs) {
  const out = join(ROOT, "scenes", accent ? `accent-${accent}` : "");
  console.log(`· ${accent || "scene colours"}: ${[...scenes].join(", ")}`);
  execFileSync("node", ["scripts/capture-scenes.mjs"], {
    cwd: SITE, stdio: ["ignore", "ignore", "inherit"],
    env: { ...process.env, SCENE_OUTPUT: out, SCENE_SCALE: "3", SCENE_LAYOUTS: [...layouts].join(","), SCENE_IDS: [...scenes].join(","), ...(accent ? { SCENE_ACCENT: accent } : {}) },
  });
}
console.log("✓ scenes exported");
