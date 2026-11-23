// App Store panels for Septena, the task app (code name Septask). Kept
// separate from panels.config.mjs (Septena Life's) so each app's visuals
// evolve on their own; consumed by components.mjs via panelsFor().
//
// Copy and order come from the "## Screenshots" tables in
// docs/APPSTORE-SEPTASK.md (one source of truth, like Bipe's appstore.md).
// This file only adds the visuals per slug: background, phone geometry, and
// where the callout card sits. A table row with no VISUAL entry still renders
// with the defaults below. Screens come from the website's scene builder
// (apps.mjs `scenes`), so `shot.scene` is "<scene id>/<step>".

import { readFileSync } from "node:fs";
import { theme } from "./theme.mjs";
import { parseScreenshots } from "./metadata.mjs";

// Per-slug visuals. fruit: the panel's fruit accent id from the app registry
// (registry/tokens.json fruitAccents); the panel fill is its light value, the
// same accent the scene's UI uses, and the texture draws in white on it.
// callout.side: which phone edge the card sticks out of;
// callout.dy: card centre relative to the element centre, in screen points
// (the scene builder's 402-wide space). Put the card in empty screen space,
// never over content; positive dy puts it below the element.
// Every main phone has the same size and sits on the bottom margin, so the
// whole device shows and the phones line up across the set (mz, 2026-11-23:
// no per-panel scaling, no tilt). shot: appearance "light" | "dark".
// shots: smaller phones behind the main one, only on Make it yours, each
// { src, appearance, accent, width, offsetX, alignTop }.
// Every screen is captured in its panel's fruit accent (export-scenes.mjs),
// so the app's accent matches the fill; accent: null keeps the scene's own.
// Neighbouring panels differ in fill, light or dark screen, size or number
// of phones (docs/APPSTORE-SEPTASK.md).
const VISUAL = {
  // A photo panel (experiment 2026-11-23): the title over a dark top band,
  // the photo filling the rest. art/: committed images, no screen capture.
  photo:          { photo: { src: "art/photo-today.png" }, background: { style: "solid", tint: "#0B0B0C", fill: "#0B0B0C" }, leadSize: 124, splitTitle: true },
  // Slide 2: a task arrives from your agent. A message card (your words, the
  // agent's reply by its face) above the phone; the new task, an agent
  // proposal in the Inbox, has a ring. Message text stays here: it is panel
  // art, not store copy, and it matches the proposal on the today scene.
  "from-agent":   {
    fruit: "haskap", texture: "topography",
    shot: { width: 0.62, ring: { element: "task-proposal", color: "#1D63DC" } },
    chat: { top: 730, face: 0, tint: "#1D63DC", you: "Remind me to check the download links before the launch.", agent: "Done. It’s in your Septena Inbox." },
  },
  // Every device, after TickTick's platforms panel: a neutral canvas, the Mac
  // on a MacBook at the back, the iPhone in front at the right, the watch at
  // the left. All upright. The iPad joins when septena-site#17 adds its layout.
  devices:        {
    fruit: null, texture: "topography",
    shot: { width: 0.42, offsetX: 0.22, top: 1440, accent: "tamarillo" },
    shots: [{ src: "today/0", layout: "mac", frame: "laptop", accent: "tamarillo", width: 1.34, offsetX: -0.1, top: 760 }],
    watch: { src: "today/0", from: "tamarillo", accent: "#FF5C67", left: 120, top: 1960, width: 300 },
  },
  thinking:       { fruit: "yuzu", texture: "fieldMatrix" },
  // Agent faces (the site's avatar crew, in our fruit colours) sit on the
  // phone's edge where agents work, over empty screen. Three and two; no more.
  "agent-work":   { fruit: "acai", texture: "ridges", shot: { appearance: "dark", faces: [{ face: 0, side: "right", y: 0.5 }, { face: 1, side: "left", y: 0.64, size: 180 }, { face: 3, side: "right", y: 0.8, size: 160 }] } },
  "agent-result": { fruit: "jabuticaba", texture: "stippleDrift", shot: { faces: [{ face: 2, side: "right", y: 0.7 }, { face: 4, side: "left", y: 0.84, size: 180 }] } },
  inbox:          { fruit: "carambola", texture: "washiPaper" },
  dates:          { fruit: "persimmon", texture: "ridges", shot: { appearance: "dark" } },
  looks:          {
    // Neutral canvas, so the three looks carry the colour: colourful in front,
    // dark and light behind, smaller, on the front phone's midline and a little lower.
    fruit: null, texture: "fieldMatrix",
    shot: { src: "looks/2", appearance: "light", accent: null },
    shots: [
      { src: "looks/1", appearance: "dark", accent: null, width: 0.56, offsetX: -0.22, alignMiddle: 90 },
      { src: "looks/0", appearance: "light", accent: null, width: 0.56, offsetX: 0.22, alignMiddle: 90 },
    ],
  },
};

const tokens = JSON.parse(readFileSync(new URL("../registry/tokens.json", import.meta.url), "utf8"));
// Fails closed: a fruit or texture id the registry does not have stops the
// render, so a fruit or texture removed from the app leaves the panels too.
function fruitFill(id) {
  if (!id) return undefined;
  const fruit = tokens.fruitAccents.find((f) => f.id === id);
  if (!fruit) throw new Error(`panels.septask.mjs: fruit "${id}" is not in registry/tokens.json`);
  return fruit.light;
}
function textureId(id) {
  if (!tokens.textures.some((t) => t.id === id)) throw new Error(`panels.septask.mjs: texture "${id}" is not in registry/tokens.json`);
  return id;
}

const rows = parseScreenshots().iPhone ?? [];
const iphone = rows.map((row, i) => {
  const v = VISUAL[row.slug] ?? {};
  // Background: a fruit accent field with one of the app's header textures in
  // white. The callout ring uses the same accent.
  const fill = fruitFill(v.fruit);
  const tint = fill ?? theme.app.accent;
  return {
    id: row.slug,
    // No fruit: the app's light canvas with the texture in a soft grey.
    background: v.background ?? { style: "texture", fill, tint, ...(fill ? {} : { accent: theme.inkSoft }), texture: textureId(v.texture ?? theme.app.textures[i % theme.app.textures.length]), seed: 42 + i, intensity: 70, fade: 1 },
    photo: v.photo,
    leadSize: v.leadSize,
    // splitTitle: the claim at the top, the rest of the title at the bottom.
    splitTitle: v.splitTitle,
    headline: row.title,
    // The first panel's title stands alone and larger; the others carry a
    // one-sentence sub (docs/APPSTORE-SEPTASK.md, ## Screenshots).
    sub: row.sub || undefined,
    align: "center",
    headlineSize: i === 0 ? 190 : 156,
    shot: row.scene === "-" ? null : {
      scene: row.scene,
      src: row.scene,
      callout: row.callout && row.callout !== "-" ? { element: row.callout, ...(v.callout ?? {}) } : null,
      // The phone starts below the text: the first panel's large title, or
      // the title and its sub on the others.
      accent: v.fruit ?? null,
      ...(v.shot ?? {}),
      width: v.shot?.width ?? 0.68, offsetY: 0, rotate: 0, // one size everywhere; the devices panel shares the frame with a Mac
    },
    shots: v.shots,
    watch: v.watch,
    chat: v.chat,
  };
});

// iPad reuses the iPhone narrative; only the geometry shifts (same as Septena).
const ipad = iphone.map((p) =>
  p.shot
    ? { ...p, shot: { ...p.shot, width: Math.min(0.86, (p.shot.width ?? 0.74) + 0.06), offsetY: (p.shot.offsetY ?? 0) + 0.1 } }
    : p,
);

// Mac is landscape (text column + windowed shot). Fewer panels, all with a shot.
// Inactive (apps.mjs). Titles follow the iPhone tentpoles; rebuild from a "### Mac" table
// when the Mac set moves to the scene builder mac layout.
const mac = [
  {
    id: "hook",
    background: { tint: theme.tints[0], dots: true },
    headline: "Tasks that think with you",
    shot: { src: "tasks-today", rotate: 0 },
  },
  {
    id: "project",
    background: { tint: theme.accent },
    headline: "Your agents do the work",
    shot: { src: "tasks-project", rotate: 0 },
  },
  {
    id: "lists",
    background: { tint: theme.tints[2] },
    headline: "You decide when it’s done",
    shot: { src: "tasks-anytime", rotate: 0 },
  },
];

export const septaskPanels = { iphone69: iphone, ipad13: ipad, mac };
