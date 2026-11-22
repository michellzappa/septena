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

import { theme } from "./theme.mjs";
import { parseScreenshots } from "./metadata.mjs";

// Per-slug visuals. fill: the panel's fruit accent (header-wash-data.ts
// FRUIT_ACCENTS, light value), the same accent the scene's UI uses; the
// texture draws in white on it. callout.side: which phone edge the card sticks out of;
// callout.dy: card centre relative to the element centre, in screen points
// (the scene builder's 402-wide space). Put the card in empty screen space,
// never over content; positive dy puts it below the element.
const VISUAL = {
  hook:           { fill: "#007AFF", texture: "topography" },
  thinking:       { fill: "#C28500", texture: "fieldMatrix" },
  "agent-work":   { fill: "#6544D6", texture: "ridges" },
  "agent-result": { fill: "#27272E", texture: "stippleDrift" },
  inbox:          { fill: "#5B8C00", texture: "washiPaper" },
  dates:          { fill: "#E05212", texture: "ridges" },
};

const rows = parseScreenshots().iPhone ?? [];
const iphone = rows.map((row, i) => {
  const v = VISUAL[row.slug] ?? {};
  // Background: a fruit accent field with one of the app's header textures in
  // white. The callout ring uses the same accent.
  const tint = v.fill ?? theme.app.accent;
  return {
    id: row.slug,
    background: { style: "texture", fill: v.fill, tint, texture: v.texture ?? theme.app.textures[i % theme.app.textures.length], seed: 42 + i, intensity: 70, fade: 1 },
    headline: row.title,
    align: "center",
    headlineSize: 150,
    shot: {
      scene: row.scene,
      src: row.scene,
      callout: row.callout && row.callout !== "-" ? { element: row.callout, ...(v.callout ?? {}) } : null,
      width: 0.78, rotate: 0, offsetY: -0.07,
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
