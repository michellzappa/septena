// Panel compositions per device — THE file to edit for marketing visuals.
// Copy (store listing text) lives in docs/APPSTORE.md; this file owns what
// the screenshot panels look like. Each panel is a plain object consumed by
// components.mjs:
//
//   id          stable slug → output filename ordering
//   background  { tint, style: "wash"|"solid"|"split", pct, dots }
//   badge       small mono pill above the headline
//   headline    *stars* = accent-italic Fraunces span
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
const S = theme.sections;

// iPhone narrative, defined first so iPad can reuse it (same captures, same
// copy; only the device frame differs). Mac and Watch have their own lists.
// App Store best practice: first 2 panels carry most conversions, each headline
// = one benefit the shot proves. Angle: all-in-one life dashboard, for
// privacy-conscious general users. Must-prove: Week, Correlations, Privacy.
// Shot `src` names map to SeptenaUITests/ScreenshotTests.swift.
const iphone = [
    {
      // 1 · HOOK — the all-in-one promise, on the hero Week screen.
      id: "hook",
      background: { tint: theme.accent, dots: true },
      badge: "ALL IN ONE",
      headline: "Your whole life, *one calm screen*",
      sub: "Tasks, sleep, training, mood — every part of your day, together.",
      shot: { src: "01-Week", width: 0.76, rotate: -2.5, offsetY: 0.17 },
    },
    {
      // 2 · THE WEEK — glanceable seven days; proves breadth + streaks.
      id: "week",
      background: { tint: theme.accent },
      badge: "THE WEEK",
      headline: "Your last *seven days*, at a glance",
      sub: "Heatmaps and streaks across every section you care about — no tab-digging.",
      shot: { src: "06-Week-heatmap", width: 0.74, rotate: 2, offsetY: 0.15 },
      overlays: [
        { icon: "spark", title: "Streaks & heatmaps", sub: "per section, per day", tint: S.habits, x: 0.04, y: 0.55, rotate: -2 },
      ],
    },
    {
      // 3 · CORRELATIONS — a sleep-insight story, so it wears sleep indigo.
      id: "correlations",
      background: { tint: S.sleep },
      badge: "PATTERNS",
      headline: "See what *actually moves* your sleep",
      sub: "Septena connects the dots — like late coffee turning up in last night's rest.",
      shot: { src: "08-Correlations", width: 0.74, rotate: 2, offsetY: 0.15 },
    },
    {
      // 4 · SECTIONS — breadth + control; chips name the domains.
      id: "sections",
      background: { tint: S.goals },        // dots reserved for bookends (hook + close)
      align: "center",
      badge: "SIXTEEN SECTIONS",
      headline: "Turn on *only what matters*",
      sub: "Hide a section and it's gone from view. Your data stays exactly where it was.",
      chips: { x: 0.5, y: 0.43, w: 1140 },
      shot: { src: "17-Sections", width: 0.66, rotate: 0, offsetY: 0.44 },
    },
    {
      // 5 · PRIVACY — the trust wedge for a general, privacy-aware audience.
      id: "privacy",
      background: { tint: theme.accent, style: "split" },
      align: "center",
      badge: "PRIVATE BY DESIGN",
      headline: "No servers. No accounts. *No ads.*",
      sub: "Your data lives on your device, synced only through your own iCloud.",
      overlays: [
        { icon: "lock", title: "End-to-end, even from us", sub: "export it all, any time", tint: theme.accent, x: 0.17, y: 0.46, w: 860, rotate: 0 },
      ],
    },
    {
      // 6 · CLOSE — quiet, human sign-off.
      id: "close",
      background: { tint: S.body, style: "split", dots: true },
      align: "center",
      badge: "MADE FOR DAILY USE",
      headline: "A calm place to *run your life*",
      sub: "Not another feed to check. Try it with demo data before committing your own.",
      founder: {
        quote: "I built Septena for my own daily use. Your data is yours — full stop.",
        name: "MZ",
        role: "maker of Septena",
      },
      footnote: "iPhone · Apple Watch · iPad · Mac",
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
    sub: "Every part of your day, together — now on the Mac.",
    shot: { src: "01-Week", rotate: 0 },
  },
  {
    id: "week",
    background: { tint: S.sleep },
    badge: "THE WEEK",
    headline: "Your last *seven days*, at a glance",
    sub: "Heatmaps and streaks across every section, in one calm window.",
    shot: { src: "06-Week-heatmap", rotate: 0 },
  },
  {
    id: "correlations",
    background: { tint: S.nutrition },
    badge: "PATTERNS",
    headline: "See what *actually moves* your sleep",
    sub: "Septena connects the dots across everything you track.",
    shot: { src: "08-Correlations", rotate: 0 },
  },
  {
    id: "sections",
    background: { tint: S.goals, dots: true },
    badge: "SIXTEEN SECTIONS",
    headline: "Turn on *only what matters*",
    sub: "Hide a section and it's gone from view. Your data stays.",
    shot: { src: "05-Goals", rotate: 0 },
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
    shot: { src: "Next", width: 0.82, rotate: 0, offsetY: 0.04 },
  },
];

export const panels = { iphone69: iphone, ipad13: ipad, mac, watch };
export const panelsFor = (deviceKey) => panels[deviceKey] ?? [];
