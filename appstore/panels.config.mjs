// Panel compositions per device — THE file to edit for marketing visuals.
// Copy (store listing text) lives in docs/APPSTORE.md; this file owns what
// the screenshot panels look like. Each panel is a plain object consumed by
// components.mjs:
//
//   id          stable slug → output filename ordering
//   background  { tint, style: "wash"|"solid"|"split", pct, dots }
//   badge       small mono pill above the headline
//   headline    *stars* = accent-italic New York span
//   sub         supporting line
//   align       "left" (default) | "center"
//   shot        { src: raw capture basename (no .png), width 0–1, rotate°, offsetY 0–1 }
//   overlays    [{ icon, title, sub, tint, x, y, w, rotate }]  (x/y = panel fractions)
//   chips       { x, y, w, items? }   — defaults to all section colors
//   founder     { quote, name, role }
//   footnote    small print at the bottom
//
// Raw capture names come from SeptenaUITests/ScreenshotTests.swift
// (01-Week … 14-Body). Missing captures render a branded placeholder.

import { theme } from "./theme.mjs";
import { currentApp } from "./apps.mjs";
const S = theme.sections;

// iPhone narrative, defined first so iPad can reuse it (same captures, same
// copy; only the device frame differs). Mac and Watch have their own lists.
// App Store best practice: first 2 panels carry most conversions, each headline
// = one benefit the shot proves. Angle: all-in-one life dashboard, for
// privacy-conscious general users. Must-prove: Week, Correlations, Privacy.
// Shot `src` names map to SeptenaUITests/ScreenshotTests.swift.
// Each panel = a DISTINCT screen whose shot matches its headline (no repeated
// screenshots). Privacy is Septena's #1 differentiator but a screenshot can't
// depict "no servers," so it rides the hook headline ("one private app") + the
// store description rather than a mismatched shot. Shots used once each:
// overview · week-heatmap · insights · coach · nutrition · next.
const iphone = [
    {
      // 1 · HOOK — all-in-one + privacy, on the hero dashboard.
      id: "hook",
      background: { tint: theme.accent, dots: true },
      badge: "ALL IN ONE",
      headline: "Everything you track, *one private app*",
      sub: "Tasks, sleep, training, mood, and more. Every part of your day, in one place.",
      shot: { src: "overview", width: 0.76, rotate: -2.5, offsetY: 0.17 },
    },
    {
      // 2 · THE WEEK — the heatmap layout (visually distinct from the dial).
      id: "week",
      background: { tint: S.habits },
      badge: "THE WEEK",
      headline: "Your last *seven days*, at a glance",
      sub: "Heatmaps and honest streaks across every section, in one view.",
      shot: { src: "week-heatmap-scrolled", width: 0.74, rotate: 2, offsetY: 0.15 },
    },
    {
      // 3 · AI — the Coach screen; bring-your-own-AI rides in the sub.
      id: "ai",
      background: { tint: S.activity },
      badge: "YOUR DATA, YOUR AI",
      headline: "Coaches that *read your own life*",
      sub: "On-device coaches, plus an open door for your own AI. Everything they touch is logged.",
      shot: { src: "coach", width: 0.74, rotate: -2, offsetY: 0.15 },
    },
    {
      // 5 · NUTRITION — quick logging (the food log + macro bars).
      id: "nutrition",
      background: { tint: S.nutrition },
      badge: "LOG IN SECONDS",
      headline: "A meal in *a few taps*",
      sub: "Macros and a photo, by hand or by voice. Enough to see the shape of your week.",
      shot: { src: "nutrition", width: 0.74, rotate: 2, offsetY: 0.15 },
    },
    {
      // 6 · NEXT — the merged daily checklist; the calm sign-off.
      id: "next",
      background: { tint: S.tasks, style: "split", dots: true },
      badge: "EVERY DAY",
      headline: "One list for *what's left today*",
      sub: "Today's tasks, chores, habits, and supplements, together, mirrored to your wrist.",
      shot: { src: "next", width: 0.74, rotate: -2, offsetY: 0.15 },
      footnote: "iPhone · Apple Watch · iPad · Mac · free, and open source",
    },
];

// iPad reuses the iPhone narrative; the pad frame is shorter (aspect 0.75) so
// shots sit a little higher and wider. We adjust only the geometry, not copy.
const ipad = iphone.map((p) =>
  p.shot
    ? { ...p, shot: { ...p.shot, width: Math.min(0.86, (p.shot.width ?? 0.74) + 0.06), offsetY: (p.shot.offsetY ?? 0) + 0.10 } }
    : p,
);

// Mac is landscape (text column + windowed shot). Fewer panels, all with a
// shot. Captures come from raw/mac/ (SeptenaMacUITests), same basenames.
const mac = [
  {
    id: "hook",
    background: { tint: theme.accent, dots: true },
    badge: "ALL IN ONE",
    headline: "Your whole life, *one calm screen*",
    sub: "Every part of your day, together, now on the Mac.",
    shot: { src: "overview", rotate: 0 },
  },
  {
    id: "week",
    background: { tint: theme.accent },
    badge: "THE WEEK",
    headline: "Your last *seven days*, at a glance",
    sub: "Heatmaps and streaks across every section, in one calm window.",
    shot: { src: "week-heatmap", rotate: 0 },
  },
  {
    id: "correlations",
    background: { tint: S.sleep },
    badge: "PATTERNS",
    headline: "See what *actually moves* your sleep",
    sub: "Septena connects the dots across everything you track.",
    shot: { src: "insights", rotate: 0 },
  },
  {
    id: "ai",
    background: { tint: S.activity },
    badge: "YOUR DATA, YOUR AI",
    headline: "Coaches that *read your own life*",
    sub: "On-device coaches, plus an open door for your own AI. Everything they touch is logged.",
    shot: { src: "coach", rotate: 0 },
  },
];

// Watch: single Next screen (MZ captures it). frame "none", minimal chrome.
const watch = [
  {
    id: "next",
    background: { tint: theme.accent, dots: true },
    align: "center",
    badge: "ON YOUR WRIST",
    headline: "What's *next*, now",
    headlineSize: 46,
    shot: { src: "next", width: 0.82, rotate: 0, offsetY: 0.04 },
  },
];

// Septena's panels, keyed by device class.
const septena = { iphone69: iphone, ipad13: ipad, mac, watch };

// Septask's panels live in a sibling file so this file stays Septena's. Loaded
// lazily-by-object here; both are plain data.
import { septaskPanels } from "./panels.septask.mjs";

const BY_APP = { septena, septask: septaskPanels };

export const panels = septena; // back-compat: Septena's set
export const panelsFor = (deviceKey) => (BY_APP[currentApp().key] ?? {})[deviceKey] ?? [];
