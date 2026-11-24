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
  // the photo filling the rest. `screen` replaces the generated phone screen
  // in art/photo-today.png with the real Persimmon Today scene via
  // tools/3d-studio/replace_photo_screen.py.
  photo:          { photo: { src: "art/photo-today.png", screen: { src: "today/0", appearance: "light", accent: "persimmon" } }, background: { style: "solid", tint: "#0B0B0C", fill: "#0B0B0C" }, leadSize: 124, splitTitle: true },
  // Slide 2: a task arrives from your agent. A message card (your words, the
  // agent's reply by its face) above the phone; the new task, an agent
  // proposal in the Inbox, has a ring. Message text stays here: it is panel
  // art, not store copy, and it matches the proposal on the today scene.
  "from-agent":   {
    // Persimmon, the photo's glow on panel 1, so the first two panels match
    // (mz, 2026-11-23); blue stays for the open panel.
    fruit: "persimmon", texture: "topography",
    shot: { width: 0.62, ring: { element: "task-proposal" } },
    chat: { top: 730, you: "Remind me to check the download links before the launch.", agent: "Done. It’s in your Septena Inbox." },
  },
  // Every device: a render of the Mac, iPad, iPhone and Apple Watch on a desk
  // (mz, 2026-11-24, tools/3d-studio iso_vertical_4dev). Its dark top holds the title.
  // The focus keeps the iPhone whole at the right edge; the Mac runs off the left.
  // The render at the panel's full width, from the top; under it, on the
  // dark fill, the four devices by symbol and name (mz, 2026-11-24).
  devices:        {
    photo: { src: "art/photo-devices.png", fit: "width", offsetY: 90, bottomFade: 460, shade: 0.55, fade: 700 },
    background: { style: "solid", tint: "#0B0B0C", fill: "#0B0B0C" },
    badges: [
      { icon: "smartphone", label: "iPhone" }, { icon: "tablet", label: "iPad" },
      { icon: "laptop", label: "Mac" }, { icon: "watch", label: "Apple Watch" },
    ],
  },
  // Slides 3 and 4 in one (mz, 2026-11-24): the task page (ADR 0029). The
  // Discuss card holds both moments: the question you answered with a tap,
  // and the agent at work with Stop.
  asks:           {
    fruit: "yuzu", texture: "fieldMatrix",
    shot: { ring: { element: "discuss" } },
    card: { kind: "page", top: 2110 },
  },
  // Slide 5: agent work waits in Review until you accept it.
  "agent-result": {
    fruit: "carambola", texture: "stippleDrift",
    shot: { ring: { element: "task-review-1" } },
    card: { kind: "review", element: "task-review-1", top: 2110 },
  },
  // Slide 6: the list that lets go (T4). The Faded list, and the weekly
  // notice from the registry, counted from the screen.
  "lets-go":      {
    fruit: "pitaya", texture: "washiPaper",
    // The notice in the accent, with its symbol and Review button, so it reads
    // as the app's notice, not an agent card (mz, 2026-11-24).
    card: { kind: "notice", notice: "weeklySweep", style: "accent", top: 1800 },
  },
  // Slide 7: bring your tasks with you. Anytime with areas and projects, and
  // the app's own "Move from another app" words from registry/settings.json.
  // No other app is named on the panel (mz, 2026-11-23).
  "move-in":      {
    fruit: "tamarillo", texture: "topography",
    // Symbols for the tasks arriving from your other app (mz, 2026-11-24):
    // each symbol once, no two overlapping, some over the phone and some
    // under it. render.mjs and incoming() check both rules.
    shot: {
      incomingStyle: "icons",
      incoming: [
        // Left: an inner column across the phone edge, an outer column of smaller tiles.
        { icon: "bell", y: 140, side: "left", out: 25, size: 150, over: true },
        { icon: "mail", y: 235, side: "left", out: 30, size: 150, over: false },
        { icon: "receipt", y: 350, side: "left", out: 25, size: 150, over: true },
        { icon: "image", y: 465, side: "left", out: 30, size: 150, over: false },
        { icon: "plane", y: 178, side: "left", out: 176, size: 92 },
        { icon: "gift", y: 293, side: "left", out: 176, size: 92 },
        { icon: "dumbbell", y: 408, side: "left", out: 176, size: 92 },
        // Right: the same, offset by half a step.
        { icon: "repeat", y: 175, side: "right", out: 30, size: 150, over: false },
        { icon: "calendar", y: 290, side: "right", out: 25, size: 150, over: true },
        { icon: "file-text", y: 405, side: "right", out: 30, size: 150, over: false },
        { icon: "tag", y: 520, side: "right", out: 25, size: 150, over: true },
        { icon: "shopping-cart", y: 232, side: "right", out: 176, size: 92 },
        { icon: "book-open", y: 347, side: "right", out: 176, size: 92 },
        { icon: "phone", y: 462, side: "right", out: 176, size: 92 },
      ],
    },
    card: { kind: "section", page: "import_export", section: "move_in", top: 2160 },
  },
  // Slide 8: yours, built in the open. No screen: one symbol per claim
  // (mz, 2026-11-23). Every claim is in the store description (YOURS, BUILT
  // IN THE OPEN) and the Privacy & Data page; icons are Lucide names.
  open:           {
    fruit: "haskap", texture: "ridges",
    // Each promise traces to the store description (YOURS, BUILT IN THE OPEN)
    // or the Privacy & Data page (registry/settings.json). Sync needs an
    // account, so "no account" is said as "start without one".
    claims: [
      { icon: "code", title: "Open source, MIT License", body: "Every line of the apps and the sync server is public.", wide: true, dark: true },
      { icon: "smartphone", title: "Start without an account", body: "Your tasks stay on this device." },
      { icon: "refresh-cw", title: "Sign in to sync", body: "Through Septena’s own server, encrypted at rest." },
      { icon: "file-braces", title: "Back up as JSON", body: "Take all your tasks with you, anytime." },
      { icon: "eye-off", title: "Not in analytics", body: "Your task titles and text are never sent." },
    ],
  },
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
    background: v.background ?? { style: "texture", fill, tint, ...(fill ? {} : { accent: theme.inkSoft }), texture: textureId(v.texture ?? theme.app.textures[i % theme.app.textures.length]), seed: 42 + i, intensity: 70, fade: 0.5 },
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
      ...(v.shot?.ring ? { ring: { ...v.shot.ring, color: fill } } : {}),
      width: v.shot?.width ?? 0.68, offsetY: 0, rotate: 0, // one size everywhere; the devices panel shares the frame with a Mac
    },
    shots: v.shots,
    claims: v.claims,
    badges: v.badges,
    // The watch title in the fruit's dark-appearance colour (a watch face is dark).
    watch: v.watch && { ...v.watch, accent: tokens.fruitAccents.find((f) => f.id === v.watch.accentFruit)?.dark ?? (() => { throw new Error(`panels.septask.mjs: watch fruit ${v.watch.accentFruit} is not in registry/tokens.json`); })() },
    // Cards, chat and rings take the panel's fruit accent (registry), never a hand-typed hex.
    chat: v.chat && { ...v.chat, tint: fill },
    card: v.card && { ...v.card, tint: fill },
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
