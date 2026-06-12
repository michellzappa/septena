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

export const panels = {
  iphone69: [
    {
      id: "hook",
      background: { tint: theme.accent, dots: true },
      badge: "PRIVATE · LOCAL-FIRST",
      headline: "Your whole life, *one private app*",
      sub: "Sixteen life sections. One Week. Zero servers.",
      shot: { src: "01-Week", width: 0.76, rotate: -2.5, offsetY: 0.16 },
    },
    {
      id: "week",
      background: { tint: S.sleep },
      headline: "Start your day with *the Week*",
      sub: "The trailing seven days — tasks, training, sleep, mood — in one glance.",
      shot: { src: "06-Week-heatmap", width: 0.74, rotate: 2, offsetY: 0.14 },
      overlays: [
        { icon: "✓", title: "Streaks & heatmaps", sub: "per section, per day", tint: S.habits, x: 0.04, y: 0.56, rotate: -2 },
      ],
    },
    {
      id: "next",
      background: { tint: S.habits },
      headline: "Always know *what's next*",
      sub: "One Next feed, identical on iPhone, Apple Watch, and widgets.",
      shot: { src: "03-Next", width: 0.74, rotate: -2, offsetY: 0.14 },
      overlays: [
        { icon: "⌚", title: "Same feed on your wrist", sub: "watch app + complications", tint: S.sleep, x: 0.36, y: 0.6, rotate: 2 },
      ],
    },
    {
      id: "correlations",
      background: { tint: S.nutrition },
      headline: "See what *actually moves* your sleep",
      sub: "Septena correlates across sections — caffeine, training, mood — once the data means something.",
      shot: { src: "08-Correlations", width: 0.74, rotate: 2, offsetY: 0.14 },
    },
    {
      id: "sections",
      background: { tint: S.goals, dots: true },
      align: "center",
      headline: "Sections, *not silos*",
      sub: "Enable what fits. Hide the rest — your data stays.",
      chips: { x: 0.5, y: 0.42, w: 1140 },
      shot: { src: "10-Nutrition", width: 0.66, rotate: 0, offsetY: 0.42 },
    },
    {
      id: "privacy",
      background: { tint: theme.accent, style: "split" },
      align: "center",
      headline: "No servers. No accounts. *No ads.*",
      sub: "Local-first, synced end-to-end through your own iCloud.",
      founder: {
        quote: "I built Septena for my own daily use. Your data is yours — full stop.",
        name: "MZ",
        role: "maker of Septena",
      },
      footnote: "Export everything, any time · iOS · macOS · watchOS",
    },
  ],

  // Pre-wired slots — fill when the device goes active in devices.mjs.
  // iPad can usually reuse the iPhone list with wider shots; Mac needs the
  // landscape layout variant (components.mjs doesn't have one yet); Watch
  // panels are raw-ish captures with at most a one-line headline.
  ipad13: [],
  mac: [],
  watch: [],
};

export const panelsFor = (deviceKey) => panels[deviceKey] ?? [];
