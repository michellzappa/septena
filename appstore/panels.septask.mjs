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

// Per-slug visuals. callout.side: which phone edge the card sticks out of;
// callout.dy: card centre relative to the element centre, in screen points
// (the scene builder's 402-wide space). Put the card in empty screen space,
// never over content; positive dy puts it below the element.
const VISUAL = {
  hook:           {},
  inbox:          { callout: { side: "right", dy: 150 } },
  plan:           { callout: { side: "right", dy: 340 } },
  "agent-asks":   { callout: { side: "left", dy: 200 } },
  "agent-result": { callout: { side: "left", dy: 330 } },
  notes:          {},
};

const rows = parseScreenshots().iPhone ?? [];
const iphone = rows.map((row, i) => {
  const v = VISUAL[row.slug] ?? {};
  // Background: the app's canvas with its header textures, one per panel in
  // the order Settings lists them. Accent: the platform accent the app uses.
  const tint = theme.app.accent;
  return {
    id: row.slug,
    background: { style: "texture", tint, texture: theme.app.textures[i % theme.app.textures.length], seed: 42 + i, ...(v.background ?? {}) },
    headline: row.title,
    sub: row.sub,
    align: "center",
    headlineSize: 150,
    shot: {
      scene: row.scene,
      src: row.scene,
      callout: row.callout && row.callout !== "-" ? { element: row.callout, ...(v.callout ?? {}) } : null,
      width: 0.74, rotate: 0, offsetY: 0,
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
// Inactive (apps.mjs). Still the July story; rebuild from a "### Mac" table
// when the Mac set moves to the scene builder mac layout.
const mac = [
  {
    id: "hook",
    background: { tint: theme.tints[0], dots: true },
    badge: "JUST YOUR TASKS",
    headline: "A real task app, *now on the Mac*",
    sub: "Keyboard flow, calm density, fast import. Built to stand next to Things.",
    shot: { src: "tasks-today", rotate: 0 },
  },
  {
    id: "project",
    background: { tint: theme.accent },
    badge: "PROJECTS",
    headline: "Projects with *real progress*",
    sub: "Group work under an area, watch the progress ring fill as you finish.",
    shot: { src: "tasks-project", rotate: 0 },
  },
  {
    id: "lists",
    background: { tint: theme.tints[2] },
    badge: "SMART LISTS",
    headline: "Today, Upcoming, *Anytime*",
    sub: "The lists that fit how work actually shows up, with a count on each.",
    shot: { src: "tasks-anytime", rotate: 0 },
  },
];

export const septaskPanels = { iphone69: iphone, ipad13: ipad, mac };
