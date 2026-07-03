// Septask's App Store panels — the focused tasks app. Kept separate from
// panels.config.mjs (Septena's) so each app's marketing visuals evolve on their
// own. Same panel schema (see panels.config.mjs header); consumed by
// components.mjs via panelsFor() when SEPTENA_APP=septask.
//
// Angle (docs/APPSTORE-SEPTASK.md, docs/SEPTASK.md): a real, private, AI-drivable
// task manager for the Things crowd. Each headline names one benefit its shot
// proves; AI can't be depicted in a screenshot (no-server is invisible), so it
// rides the store description, not a panel. Shot `src` names map to
// SeptaskUITests / SeptaskMacUITests basenames. Real, reliably-captured shots:
//   tasks-today   → the populated Today list (inbox tasks + project sections)
//   tasks-anytime → the smart-list home grid (Today/Upcoming/Anytime/Logbook)
//   tasks-project → the "Q3 launch" project board
// Missing captures render a branded placeholder.

import { theme } from "./theme.mjs";
const S = theme.sections;

const iphone = [
  {
    // 1 · HOOK — the focused task app, on a real Today.
    id: "hook",
    background: { tint: S.tasks, dots: true },
    badge: "JUST YOUR TASKS",
    headline: "A real task app, *and nothing else*",
    sub: "Inbox, Today, and projects, calm and fast. A focused app over your own task data.",
    shot: { src: "tasks-today", width: 0.76, rotate: -2.5, offsetY: 0.17 },
  },
  {
    // 2 · SMART LISTS — the home grid shows exactly these buckets.
    id: "lists",
    background: { tint: theme.accent },
    badge: "SMART LISTS",
    headline: "Today, Upcoming, *Anytime*",
    sub: "The lists that fit how work actually shows up, with a count on each.",
    shot: { src: "tasks-anytime", width: 0.74, rotate: 2, offsetY: 0.15 },
  },
  {
    // 3 · PROJECTS — the seeded project board.
    id: "project",
    background: { tint: S.activity },
    badge: "PROJECTS",
    headline: "Projects with *real progress*",
    sub: "Group work under an area and watch the progress ring fill as you finish.",
    shot: { src: "tasks-project", width: 0.74, rotate: -2, offsetY: 0.15 },
  },
  {
    // 4 · OWNERSHIP — same private data as Septena; the calm sign-off.
    id: "private",
    background: { tint: S.sleep, style: "split", dots: true },
    badge: "YOURS, AND OPEN",
    headline: "Your tasks, in *your own iCloud*",
    sub: "No server that can read them. Open source. The same task data as Septena.",
    shot: { src: "tasks-today", width: 0.74, rotate: 2, offsetY: 0.15 },
    footnote: "iPhone · iPad · Mac · free, and open source",
  },
];

// iPad reuses the iPhone narrative; only the geometry shifts (same as Septena).
const ipad = iphone.map((p) =>
  p.shot
    ? { ...p, shot: { ...p.shot, width: Math.min(0.86, (p.shot.width ?? 0.74) + 0.06), offsetY: (p.shot.offsetY ?? 0) + 0.1 } }
    : p,
);

// Mac is landscape (text column + windowed shot). Fewer panels, all with a shot.
// Captures come from raw-septask/mac/ (SeptaskMacUITests), same basenames.
const mac = [
  {
    id: "hook",
    background: { tint: S.tasks, dots: true },
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
    background: { tint: S.activity },
    badge: "SMART LISTS",
    headline: "Today, Upcoming, *Anytime*",
    sub: "The lists that fit how work actually shows up, with a count on each.",
    shot: { src: "tasks-anytime", rotate: 0 },
  },
];

export const septaskPanels = { iphone69: iphone, ipad13: ipad, mac };
