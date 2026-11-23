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
const VISUAL = {
  hook:           { fruit: "haskap", texture: "topography" },
  thinking:       { fruit: "yuzu", texture: "fieldMatrix" },
  "agent-work":   { fruit: "acai", texture: "ridges" },
  "agent-result": { fruit: "jabuticaba", texture: "stippleDrift" },
  inbox:          { fruit: "carambola", texture: "washiPaper" },
  dates:          { fruit: "persimmon", texture: "ridges" },
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
    background: { style: "texture", fill, tint, texture: textureId(v.texture ?? theme.app.textures[i % theme.app.textures.length]), seed: 42 + i, intensity: 70, fade: 1 },
    headline: row.title,
    // The first panel's title stands alone and larger; the others carry a
    // one-sentence sub (docs/APPSTORE-SEPTASK.md, ## Screenshots).
    sub: row.sub || undefined,
    align: "center",
    headlineSize: i === 0 ? 200 : 140,
    shot: {
      scene: row.scene,
      src: row.scene,
      callout: row.callout && row.callout !== "-" ? { element: row.callout, ...(v.callout ?? {}) } : null,
      // The phone starts below the text: the first panel's large title, or
      // the title and its sub on the others.
      width: 0.78, rotate: 0, offsetY: i === 0 ? 0.03 : row.sub ? 0.01 : -0.07,
      ...(v.shot ?? {}),
    },
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
