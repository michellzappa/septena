#!/usr/bin/env node
// Headless Chrome renderer for Septena Bento Studio studies.
// Reuses appstore/chrome.mjs (zero npm dependencies) and registry/tokens.json.
//
// Usage:
//   node tools/bento-studio/render.mjs
//
// Outputs PNGs and a self-contained showcase.html into tools/bento-studio/renders/ (gitignored).

import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { openChrome } from "../../appstore/chrome.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, "../..");
const OUT_DIR = join(HERE, "renders");
mkdirSync(OUT_DIR, { recursive: true });

const tokens = JSON.parse(readFileSync(join(REPO, "registry/tokens.json"), "utf8"));
const PERSIMMON = tokens.fruitAccents.find((f) => f.id === "persimmon");
const HASKAP = tokens.fruitAccents.find((f) => f.id === "haskap");

const DEVICES_PHOTO = `data:image/png;base64,${readFileSync(join(REPO, "appstore/art/photo-devices.png")).toString("base64")}`;

const UI_FONT = `-apple-system, "SF Pro Display", "SF Pro Text", "Helvetica Neue", sans-serif`;
const ROUNDED_FONT = `ui-rounded, "SF Pro Rounded", -apple-system, sans-serif`;
const MONO_FONT = `"SF Mono", ui-monospace, Menlo, monospace`;

function topoSvg(stroke = "rgba(255,255,255,0.20)") {
  const paths = [];
  for (let i = 0; i < 16; i++) {
    const y = -60 + i * 42;
    const d = `M -40 ${y} C 160 ${y - 34 + (i % 3) * 16}, 360 ${y + 38 - (i % 4) * 12}, 580 ${y - 14} S 880 ${y + 30}, 1100 ${y - 10}`;
    paths.push(`<path d="${d}" fill="none" stroke="${stroke}" stroke-width="2.4"/>`);
  }
  return `<svg viewBox="0 0 1000 560" preserveAspectRatio="none" style="position:absolute;inset:0;width:100%;height:100%;pointer-events:none;">${paths.join("")}</svg>`;
}

function fieldMatrixSvg(color = "rgba(255,255,255,0.28)") {
  const dots = [];
  for (let r = 0; r < 9; r++) {
    for (let c = 0; c < 11; c++) {
      const rad = 1.6 + ((r * 3 + c * 5) % 4) * 0.6;
      dots.push(`<circle cx="${16 + c * 22}" cy="${16 + r * 22}" r="${rad}" fill="${color}"/>`);
    }
  }
  return `<svg viewBox="0 0 260 210" preserveAspectRatio="xMidYMid slice" style="position:absolute;inset:0;width:100%;height:100%;pointer-events:none;">${dots.join("")}</svg>`;
}

function ridgeMiniSvg(stroke = "rgba(255,255,255,0.28)") {
  const paths = [];
  for (let i = 0; i < 10; i++) {
    const y = 14 + i * 22;
    paths.push(`<path d="M -10 ${y} Q 80 ${y - 14}, 150 ${y + 8} T 280 ${y - 6}" fill="none" stroke="${stroke}" stroke-width="2"/>`);
  }
  return `<svg viewBox="0 0 260 220" preserveAspectRatio="none" style="position:absolute;inset:0;width:100%;height:100%;pointer-events:none;">${paths.join("")}</svg>`;
}

function stippleMiniSvg(color = "rgba(255,255,255,0.32)") {
  const dots = [];
  for (let i = 0; i < 95; i++) {
    const x = (i * 73) % 260;
    const y = (i * 41) % 210;
    const r = 1 + (i % 3) * 0.7;
    dots.push(`<circle cx="${x}" cy="${y}" r="${r}" fill="${color}"/>`);
  }
  return `<svg viewBox="0 0 260 210" preserveAspectRatio="none" style="position:absolute;inset:0;width:100%;height:100%;pointer-events:none;">${dots.join("")}</svg>`;
}

function ridgeBgSvg(stroke = "rgba(255,255,255,0.16)") {
  const paths = [];
  for (let i = 0; i < 24; i++) {
    const y = 30 + i * 54;
    const amp = 16 + (i % 5) * 4;
    const d = `M -40 ${y} Q 340 ${y - amp}, 680 ${y + amp * 0.5} T 1360 ${y - amp * 0.3}`;
    paths.push(`<path d="${d}" fill="none" stroke="${stroke}" stroke-width="2.3"/>`);
  }
  return `<svg viewBox="0 0 1320 1200" preserveAspectRatio="none" style="position:absolute;inset:0;width:100%;height:48%;pointer-events:none;mask-image:linear-gradient(180deg,#000 40%,transparent 100%);-webkit-mask-image:linear-gradient(180deg,#000 40%,transparent 100%);">${paths.join("")}</svg>`;
}

function agentAvatar(color, size = 56) {
  return `<svg width="${size}" height="${size}" viewBox="0 0 64 64" style="flex:none;filter:drop-shadow(0 6px 14px rgba(224,82,18,0.32));">
    <circle cx="32" cy="32" r="30" fill="${color}"/>
    <rect x="21.5" y="24" width="6" height="12.5" rx="3" fill="#fff"/>
    <rect x="36.5" y="24" width="6" height="12.5" rx="3" fill="#fff"/>
  </svg>`;
}

// ============================================================================
// Landscape Bento (16:10, 2400 x 1500) — Light & Dark
// ============================================================================
function renderLandscapeBento(mode) {
  const dark = mode === "dark";
  const accent = dark ? PERSIMMON.dark : PERSIMMON.light;
  const accentSolid = PERSIMMON.light;

  const bg = dark ? "#070709" : "#EFEFF3";
  const tileBg = dark ? "#141418" : "#FFFFFF";
  const tileBorder = dark ? "1px solid rgba(255,255,255,0.09)" : "1px solid rgba(0,0,0,0.05)";
  const tileShadow = dark
    ? "0 28px 70px rgba(0,0,0,0.65), inset 0 1px 0 rgba(255,255,255,0.10)"
    : "0 20px 50px rgba(15,15,25,0.07), 0 1px 2px rgba(0,0,0,0.04)";
  const ink = dark ? "#F7F7FA" : "#111216";
  const inkMuted = dark ? "rgba(245,245,250,0.60)" : "#63636A";

  const discussBg = dark
    ? "radial-gradient(110% 85% at 25% 105%, rgba(224,82,18,0.24) 0%, #141418 58%)"
    : "radial-gradient(110% 80% at 25% 105%, rgba(224,82,18,0.11) 0%, #FFFFFF 60%)";
  const discussCardBg = dark ? "#1B1B22" : "#FFFFFF";
  const discussCardBorder = dark ? "rgba(255,119,56,0.34)" : "rgba(224,82,18,0.22)";

  const deckCards = [
    { name: "Persimmon", tex: "Topography", bg: "linear-gradient(145deg,#F16523,#BD3A08)", rot: -9, x: 4, y: 24, z: 1, svg: topoSvg("rgba(255,255,255,0.26)") },
    { name: "Yuzu", tex: "Field Matrix", bg: "linear-gradient(145deg,#DDA00D,#A87000)", rot: -4, x: 146, y: 12, z: 2, svg: fieldMatrixSvg("rgba(255,255,255,0.32)") },
    { name: "Carambola", tex: "Stipple", bg: "linear-gradient(145deg,#74AD08,#476E00)", rot: 1, x: 288, y: 4, z: 3, svg: stippleMiniSvg("rgba(255,255,255,0.35)") },
    { name: "Haskap", tex: "Ridges", bg: "linear-gradient(145deg,#2F78F2,#144AA8)", rot: 6, x: 430, y: 12, z: 4, svg: ridgeMiniSvg("rgba(255,255,255,0.28)") },
    { name: "Pitaya", tex: "Washi", bg: "linear-gradient(145deg,#EA3A82,#AD1854)", rot: 11, x: 568, y: 24, z: 5, svg: topoSvg("rgba(255,255,255,0.22)") },
  ];

  return `<!doctype html><html><head><meta charset="utf-8"><style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    html, body {
      width: 2400px; height: 1500px; overflow: hidden;
      background: ${bg}; color: ${ink};
      font-family: ${UI_FONT};
      -webkit-font-smoothing: antialiased;
    }
    .canvas {
      width: 100%; height: 100%;
      padding: 54px 64px 62px;
      display: flex; flex-direction: column; gap: 30px;
    }
    .header {
      display: flex; align-items: baseline; justify-content: space-between;
      padding: 0 6px;
    }
    .header h1 {
      font-size: 58px; font-weight: 750; letter-spacing: -0.035em; line-height: 1;
      color: ${ink};
    }
    .header h1 span { color: ${inkMuted}; font-weight: 500; }
    .header .tag {
      font-size: 21px; font-weight: 650; letter-spacing: -0.01em;
      color: ${accent};
      background: ${dark ? "rgba(255,119,56,0.16)" : "rgba(224,82,18,0.11)"};
      border: 1px solid ${dark ? "rgba(255,119,56,0.25)" : "rgba(224,82,18,0.18)"};
      padding: 10px 22px; border-radius: 999px;
    }
    /* Interlocking 12-col x 3-row grid: 5|4|3, 5|3|4, 3|4|5 */
    .grid {
      flex: 1;
      display: grid;
      grid-template-columns: repeat(12, 1fr);
      grid-template-rows: 1.04fr 0.94fr 1.02fr;
      gap: 22px;
    }
    .tile {
      position: relative;
      border-radius: 38px;
      background: ${tileBg};
      border: ${tileBorder};
      box-shadow: ${tileShadow};
      overflow: hidden;
      padding: 36px 40px;
      display: flex; flex-direction: column;
    }
    .kicker { font-size: 19px; font-weight: 650; letter-spacing: 0.01em; color: ${inkMuted}; }
    .title { font-size: 38px; font-weight: 750; letter-spacing: -0.03em; line-height: 1.06; color: ${ink}; }
    .sub { font-size: 22px; font-weight: 450; line-height: 1.28; color: ${inkMuted}; margin-top: 8px; }

    /* Tile 1 (5x2): Discuss UI macro */
    .t-discuss {
      grid-column: 1 / 6; grid-row: 1 / 3;
      background: ${discussBg};
      padding: 42px 0 0 44px;
      justify-content: space-between;
    }
    .t-discuss-head { padding-right: 44px; }
    .t-discuss .title { font-size: 56px; letter-spacing: -0.035em; }
    .t-discuss .sub { font-size: 25px; margin-top: 10px; }
    .discuss-stage {
      position: relative; margin-top: 26px; margin-right: -36px;
      background: ${dark ? "rgba(255,255,255,0.04)" : "rgba(242,242,247,0.88)"};
      border: 1px solid ${dark ? "rgba(255,255,255,0.10)" : "rgba(0,0,0,0.06)"};
      border-right: none; border-bottom: none;
      border-radius: 36px 0 0 0;
      padding: 34px 56px 46px 36px;
      box-shadow: ${dark ? "0 -20px 60px rgba(0,0,0,0.45)" : "0 -14px 40px rgba(0,0,0,0.05)"};
    }
    .d-task { display: flex; align-items: center; gap: 18px; margin-bottom: 24px; }
    .d-check { width: 32px; height: 32px; border-radius: 10px; border: 3px solid ${dark ? "rgba(255,255,255,0.34)" : "#C7C7CC"}; flex: none; }
    .d-task-name { font-size: 32px; font-weight: 700; letter-spacing: -0.025em; color: ${ink}; }
    .d-card {
      background: ${discussCardBg}; border: 2px solid ${discussCardBorder};
      border-radius: 30px; padding: 34px 36px 32px;
      box-shadow: ${dark
        ? "0 28px 64px rgba(0,0,0,0.65), 0 0 60px rgba(224,82,18,0.18)"
        : "0 24px 54px rgba(224,82,18,0.12), 0 4px 14px rgba(0,0,0,0.05)"};
    }
    .d-head { display: flex; align-items: center; justify-content: space-between; margin-bottom: 22px; }
    .d-who { display: flex; align-items: center; gap: 16px; }
    .d-who-t { font-size: 23px; font-weight: 700; color: ${ink}; }
    .d-who-s { font-size: 19px; color: ${inkMuted}; }
    .d-pill-live {
      display: inline-flex; align-items: center; gap: 10px;
      padding: 9px 18px; border-radius: 999px;
      background: ${dark ? "rgba(255,119,56,0.16)" : "rgba(224,82,18,0.10)"};
      color: ${accent}; font-size: 18px; font-weight: 650;
    }
    .d-pill-live i {
      width: 10px; height: 10px; border-radius: 50%; background: ${accent};
      box-shadow: 0 0 0 5px ${dark ? "rgba(255,119,56,0.28)" : "rgba(224,82,18,0.22)"};
    }
    .d-q { font-size: 40px; font-weight: 750; letter-spacing: -0.03em; line-height: 1.12; color: ${ink}; margin-bottom: 28px; }
    .d-chips { display: flex; flex-wrap: nowrap; gap: 14px; }
    .d-chip {
      padding: 18px 28px; border-radius: 999px;
      font-size: 24px; font-weight: 650; letter-spacing: -0.015em;
      white-space: nowrap; display: inline-flex; align-items: center; gap: 10px;
    }
    .d-chip.on {
      background: linear-gradient(180deg, #F0621F 0%, ${PERSIMMON.light} 100%);
      color: #fff;
      box-shadow: 0 14px 30px rgba(224,82,18,0.40), inset 0 1px 0 rgba(255,255,255,0.32);
    }
    .d-chip.opt { background: ${dark ? "rgba(255,119,56,0.14)" : "rgba(224,82,18,0.10)"}; color: ${accent}; }
    .d-foot {
      margin-top: 26px; padding-top: 22px;
      border-top: 1px solid ${dark ? "rgba(255,255,255,0.09)" : "rgba(0,0,0,0.07)"};
      display: flex; align-items: center; justify-content: space-between;
    }
    .d-foot-meta { font-size: 20px; font-weight: 500; color: ${inkMuted}; }
    .d-stop { padding: 10px 26px; border-radius: 999px; background: rgba(255,59,48,0.14); color: #FF453A; font-size: 20px; font-weight: 700; }

    /* Tile 2 (4x1): Review obsidian hero */
    .t-review {
      grid-column: 6 / 10; grid-row: 1 / 2;
      background: radial-gradient(95% 110% at 30% 115%, rgba(224,82,18,0.32) 0%, #111216 58%);
      border: 1px solid rgba(255,255,255,0.11);
      color: #FFFFFF; padding: 34px 38px 0; justify-content: space-between;
    }
    .t-review .title { color: #FFFFFF; font-size: 40px; }
    .t-review .kicker { color: rgba(255,255,255,0.56); }
    .rev-card {
      margin-top: 18px;
      background: linear-gradient(180deg, rgba(255,255,255,0.10) 0%, rgba(255,255,255,0.05) 100%);
      border: 1px solid rgba(255,255,255,0.14); border-bottom: none;
      border-radius: 30px 30px 0 0; padding: 26px 28px 34px;
      display: flex; flex-direction: column; gap: 20px;
      box-shadow: 0 -10px 36px rgba(0,0,0,0.45);
    }
    .rev-top { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
    .rev-name { font-size: 27px; font-weight: 700; color: #fff; letter-spacing: -0.02em; }
    .rev-sub { font-size: 18px; color: rgba(255,255,255,0.56); margin-top: 2px; }
    .rev-badge {
      padding: 8px 16px; border-radius: 999px;
      background: rgba(48,209,88,0.18); border: 1px solid rgba(48,209,88,0.34);
      color: #4CE073; font-size: 17px; font-weight: 700; white-space: nowrap;
    }
    .rev-btns { display: flex; gap: 14px; }
    .rev-accept {
      flex: 1.3; padding: 18px 24px; border-radius: 999px;
      background: linear-gradient(180deg, #F46723 0%, ${PERSIMMON.light} 100%);
      color: #fff; font-size: 24px; font-weight: 700;
      display: flex; align-items: center; justify-content: center; gap: 10px;
      box-shadow: 0 14px 32px rgba(224,82,18,0.46), inset 0 1px 0 rgba(255,255,255,0.34);
    }
    .rev-back {
      flex: 1; padding: 18px 20px; border-radius: 999px;
      background: rgba(255,255,255,0.11); color: rgba(255,255,255,0.9);
      font-size: 22px; font-weight: 600; display: flex; align-items: center; justify-content: center;
    }

    /* Tile 3 (3x1): 100% Open Source hero figure */
    .t-stat {
      grid-column: 10 / 13; grid-row: 1 / 2;
      background: linear-gradient(155deg, #F56925 0%, ${accentSolid} 48%, #9C2F04 100%);
      border: 1px solid rgba(255,255,255,0.22);
      color: #FFFFFF; padding: 32px 36px 34px; justify-content: space-between;
    }
    .t-stat .kicker { color: rgba(255,255,255,0.88); position: relative; z-index: 2; }
    .stat-hero { position: relative; z-index: 2; display: flex; align-items: baseline; gap: 2px; margin: -4px 0 -4px -8px; }
    .stat-num {
      font-family: ${ROUNDED_FONT}; font-size: 162px; font-weight: 850; line-height: 1.0; letter-spacing: -0.06em;
      padding: 6px 4px;
      background: linear-gradient(180deg, #FFFFFF 35%, rgba(255,232,216,0.80) 100%);
      -webkit-background-clip: text; -webkit-text-fill-color: transparent;
      filter: drop-shadow(0 16px 32px rgba(95,24,0,0.34));
    }
    .stat-unit {
      font-family: ${ROUNDED_FONT}; font-size: 86px; font-weight: 800; letter-spacing: -0.03em;
      background: linear-gradient(180deg, rgba(255,255,255,0.95) 20%, rgba(255,222,200,0.72) 100%);
      -webkit-background-clip: text; -webkit-text-fill-color: transparent;
    }
    .t-stat .sub { position: relative; z-index: 2; margin-top: 0; color: rgba(255,255,255,0.94); font-size: 22px; font-weight: 500; }

    /* Tile 4 (3x1): Macro anodized keyboard crop */
    .t-keys {
      grid-column: 6 / 9; grid-row: 2 / 3;
      background: ${dark ? "linear-gradient(160deg, #1E1F25 0%, #111216 100%)" : "linear-gradient(160deg, #FFFFFF 0%, #E7E7EC 100%)"};
      padding: 34px 36px 0; justify-content: space-between;
    }
    .kb-deck {
      position: relative; margin: 16px -44px -24px -18px; padding: 18px 20px 28px;
      background: ${dark ? "#0B0B0E" : "#CFCFD6"};
      border-radius: 26px 0 0 0;
      border-top: 2px solid ${dark ? "rgba(255,255,255,0.08)" : "rgba(255,255,255,0.8)"};
      display: grid; grid-template-columns: 112px 136px 136px 112px; grid-template-rows: 96px 116px; gap: 14px;
      transform: perspective(900px) rotateX(12deg) rotateZ(-3deg); transform-origin: bottom center;
      box-shadow: ${dark ? "inset 0 8px 20px rgba(0,0,0,0.8)" : "inset 0 6px 14px rgba(0,0,0,0.15)"};
    }
    .kcap {
      border-radius: 18px; display: flex; align-items: center; justify-content: center; font-size: 38px; font-weight: 500;
      background: ${dark ? "linear-gradient(180deg, #27282F 0%, #1A1B20 100%)" : "linear-gradient(180deg, #FFFFFF 0%, #F2F2F6 100%)"};
      color: ${dark ? "rgba(255,255,255,0.28)" : "rgba(0,0,0,0.24)"};
      border: 1px solid ${dark ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.08)"};
      box-shadow: ${dark
        ? "0 6px 0 #0A0A0D, 0 10px 18px rgba(0,0,0,0.6), inset 0 1px 0 rgba(255,255,255,0.12)"
        : "0 6px 0 #BDBDC6, 0 10px 16px rgba(0,0,0,0.10), inset 0 1px 0 #FFFFFF"};
    }
    .kcap.hero {
      font-size: 54px; font-weight: 600; color: ${dark ? "#FFFFFF" : "#111216"};
      background: ${dark ? "linear-gradient(180deg, #32333C 0%, #202128 100%)" : "linear-gradient(180deg, #FFFFFF 0%, #F6F6FA 100%)"};
      border-color: ${dark ? "rgba(255,255,255,0.20)" : "rgba(0,0,0,0.12)"};
    }
    .kcap.lit {
      font-size: 56px; font-weight: 700; color: #FFFFFF;
      background: linear-gradient(180deg, #F46723 0%, ${PERSIMMON.light} 100%);
      border-color: rgba(255,255,255,0.34);
      box-shadow: 0 6px 0 #9E3004, 0 16px 36px rgba(224,82,18,0.55), inset 0 1px 0 rgba(255,255,255,0.42);
    }

    /* Tile 5 (4x1): Fanned textured fruit cards */
    .t-looks { grid-column: 9 / 13; grid-row: 2 / 3; padding: 34px 38px 0; justify-content: space-between; }
    .looks-head { display: flex; justify-content: space-between; align-items: baseline; }
    .fan-stage { position: relative; height: 245px; margin: 12px -38px 0; }
    .fan-card {
      position: absolute; width: 210px; height: 245px; border-radius: 26px; padding: 20px 18px;
      color: #fff; overflow: hidden; display: flex; flex-direction: column; justify-content: space-between;
      border: 1.5px solid rgba(255,255,255,0.28);
      box-shadow: -12px 18px 36px rgba(0,0,0,0.28), inset 0 1px 0 rgba(255,255,255,0.34);
    }
    .fan-name { position: relative; z-index: 2; font-size: 21px; font-weight: 750; letter-spacing: -0.02em; }
    .fan-tex { position: relative; z-index: 2; font-size: 16px; font-weight: 600; opacity: 0.85; margin-top: 2px; }
    .fan-dot { position: relative; z-index: 2; width: 34px; height: 34px; border-radius: 10px; border: 2.5px solid rgba(255,255,255,0.85); }

    /* Tile 6 (3x1): Inbox macro */
    .t-inbox { grid-column: 1 / 4; grid-row: 3 / 4; padding: 34px 0 0 36px; justify-content: space-between; }
    .t-inbox-head { padding-right: 32px; }
    .inbox-macro {
      margin-top: 18px; margin-right: -40px;
      background: ${dark ? "#1C1C23" : "#F3F3F7"};
      border: 1px solid ${dark ? "rgba(255,255,255,0.10)" : "rgba(0,0,0,0.06)"};
      border-right: none; border-bottom: none; border-radius: 28px 0 0 0;
      padding: 20px 44px 28px 22px; display: flex; flex-direction: column; gap: 14px;
    }
    .inb-bar {
      background: linear-gradient(90deg, ${dark ? "rgba(224,82,18,0.26)" : "rgba(224,82,18,0.13)"} 0%, ${dark ? "rgba(224,82,18,0.12)" : "rgba(224,82,18,0.05)"} 100%);
      border: 1.5px solid ${dark ? "rgba(255,119,56,0.40)" : "rgba(224,82,18,0.24)"};
      border-radius: 20px; padding: 16px 20px; display: flex; align-items: center; justify-content: space-between;
    }
    .inb-lbl { display: flex; align-items: center; gap: 12px; font-size: 26px; font-weight: 750; letter-spacing: -0.02em; color: ${accent}; }
    .inb-cnt {
      font-family: ${ROUNDED_FONT}; font-size: 24px; font-weight: 800; background: ${PERSIMMON.light}; color: #fff;
      min-width: 44px; height: 40px; padding: 0 14px; border-radius: 999px;
      display: flex; align-items: center; justify-content: center; box-shadow: 0 8px 18px rgba(224,82,18,0.38);
    }
    .inb-row {
      display: flex; align-items: center; gap: 14px; padding: 16px 18px; border-radius: 18px;
      background: ${dark ? "rgba(255,255,255,0.05)" : "#FFFFFF"};
      box-shadow: ${dark ? "none" : "0 4px 12px rgba(0,0,0,0.04)"};
      font-size: 22px; font-weight: 600; color: ${ink}; white-space: nowrap;
    }
    .inb-box { width: 24px; height: 24px; border-radius: 7px; border: 2.5px solid ${dark ? "rgba(255,255,255,0.30)" : "#C7C7CC"}; flex: none; }

    /* Tile 7 (4x1): Bring any agent (MCP) */
    .t-mcp {
      grid-column: 4 / 8; grid-row: 3 / 4;
      background: linear-gradient(140deg, #1E63DE 0%, #1140A3 62%, #0B2A72 100%);
      border: 1px solid rgba(255,255,255,0.18);
      color: #FFFFFF; padding: 34px 0 34px 38px; flex-direction: row; align-items: center; gap: 22px;
    }
    .mcp-ghost {
      position: absolute; left: 26px; bottom: -28px;
      font-family: ${ROUNDED_FONT}; font-size: 195px; font-weight: 900;
      letter-spacing: -0.06em; line-height: 1; color: rgba(255,255,255,0.09); pointer-events: none;
    }
    .mcp-copy { position: relative; z-index: 2; flex: 1; display: flex; flex-direction: column; gap: 10px; }
    .mcp-copy .title { color: #FFFFFF; font-size: 38px; }
    .mcp-copy .sub { color: rgba(255,255,255,0.82); font-size: 21px; }
    .mcp-pill {
      display: inline-flex; align-self: flex-start;
      font-family: ${MONO_FONT}; font-size: 18px; font-weight: 700;
      color: #FFFFFF; background: rgba(255,255,255,0.18); border: 1px solid rgba(255,255,255,0.28);
      padding: 8px 16px; border-radius: 999px;
    }
    .mcp-code {
      position: relative; z-index: 2; width: 340px; flex: none; margin-right: -18px;
      background: #0D0E12; border: 1px solid rgba(255,255,255,0.14); border-radius: 26px 0 0 26px;
      padding: 24px 26px; font-family: ${MONO_FONT}; font-size: 18px; line-height: 1.55;
      color: rgba(255,255,255,0.78); transform: rotate(-2deg);
      box-shadow: -16px 24px 50px rgba(0,0,0,0.45);
    }
    .mcp-code .bar {
      display: flex; align-items: center; gap: 7px; margin-bottom: 14px; padding-bottom: 12px;
      border-bottom: 1px solid rgba(255,255,255,0.08); font-size: 14px; color: rgba(255,255,255,0.45);
    }
    .mcp-code .bar i { width: 10px; height: 10px; border-radius: 50%; display: inline-block; }
    .jk { color: #9EE034; } .js { color: #FF9F6E; } .jn { color: #64B5FF; }

    /* Tile 8 (5x1): Every device — framed 4-device 3D Studio render */
    .t-devices {
      grid-column: 8 / 13; grid-row: 3 / 4;
      background: radial-gradient(70% 100% at 75% 88%, rgba(224,82,18,0.16) 0%, #09090B 65%);
      border: 1px solid rgba(255,255,255,0.12); padding: 0; overflow: hidden;
    }
    .dev-photo-wrap {
      position: absolute; right: 12px; top: 0; bottom: 0; width: 468px; overflow: hidden;
      mask-image: linear-gradient(90deg, transparent 0%, rgba(0,0,0,0.6) 14%, #000 30%, #000 100%);
      -webkit-mask-image: linear-gradient(90deg, transparent 0%, rgba(0,0,0,0.6) 14%, #000 30%, #000 100%);
    }
    .dev-photo { position: absolute; left: 0; top: -214px; width: 468px; height: auto; display: block; }
    .dev-copy {
      position: relative; z-index: 2; height: 100%; padding: 36px 0 36px 40px;
      display: flex; flex-direction: column; justify-content: space-between; max-width: 46%;
    }
    .dev-copy .title { color: #FFFFFF; font-size: 40px; }
    .dev-copy .sub { color: rgba(255,255,255,0.72); font-size: 20px; margin-top: 10px; }
    .dev-chips { display: flex; flex-wrap: wrap; gap: 8px; }
    .dev-chip {
      font-size: 16px; font-weight: 650; color: rgba(255,255,255,0.92);
      background: rgba(255,255,255,0.11); border: 1px solid rgba(255,255,255,0.15);
      padding: 7px 14px; border-radius: 999px;
    }
  </style></head><body>
    <div class="canvas">
      <div class="header">
        <h1>Septena. <span>Tasks that think with you.</span></h1>
        <div class="tag">Open Source · Native · MCP</div>
      </div>

      <div class="grid">
        <div class="tile t-discuss">
          <div class="t-discuss-head">
            <div class="title">Asks before it acts.</div>
            <div class="sub">Tap an answer. Your agent handles the rest.</div>
          </div>
          <div class="discuss-stage">
            <div class="d-task">
              <div class="d-check"></div>
              <div class="d-task-name">Send the launch update</div>
            </div>
            <div class="d-card">
              <div class="d-head">
                <div class="d-who">
                  ${agentAvatar(PERSIMMON.light, 56)}
                  <div>
                    <div class="d-who-t">Discuss</div>
                    <div class="d-who-s">Your agent</div>
                  </div>
                </div>
                <span class="d-pill-live"><i></i>Working</span>
              </div>
              <div class="d-q">What should the update focus on?</div>
              <div class="d-chips">
                <span class="d-chip on">
                  <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>
                  What’s new
                </span>
                <span class="d-chip opt">Launch timing</span>
                <span class="d-chip opt">Next steps</span>
              </div>
              <div class="d-foot">
                <span class="d-foot-meta">On-device first · Never closes tasks</span>
                <span class="d-stop">Stop</span>
              </div>
            </div>
          </div>
        </div>

        <div class="tile t-review">
          <div>
            <div class="kicker">Human in the loop</div>
            <div class="title" style="margin-top:6px;">You decide when it’s done.</div>
          </div>
          <div class="rev-card">
            <div class="rev-top">
              <div>
                <div class="rev-name">Draft the launch brief</div>
                <div class="rev-sub">Waiting in Review</div>
              </div>
              <span class="rev-badge">Ready</span>
            </div>
            <div class="rev-btns">
              <span class="rev-accept">
                <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>
                Accept
              </span>
              <span class="rev-back">Send back</span>
            </div>
          </div>
        </div>

        <div class="tile t-stat">
          ${topoSvg("rgba(255,255,255,0.20)")}
          <div class="kicker">Open source · MIT</div>
          <div class="stat-hero">
            <span class="stat-num">100</span>
            <span class="stat-unit">%</span>
          </div>
          <div class="sub">Apps and sync server. Every line public.</div>
        </div>

        <div class="tile t-keys">
          <div>
            <div class="kicker">Native AppKit on Mac</div>
            <div class="title" style="font-size:36px;margin-top:6px;">Keyboard-first.</div>
          </div>
          <div class="kb-deck">
            <div class="kcap">U</div>
            <div class="kcap">I</div>
            <div class="kcap">O</div>
            <div class="kcap">P</div>
            <div class="kcap">⌥</div>
            <div class="kcap hero">⌘</div>
            <div class="kcap lit">K</div>
            <div class="kcap">L</div>
          </div>
        </div>

        <div class="tile t-looks">
          <div class="looks-head">
            <div class="title" style="font-size:36px;">Make it yours.</div>
            <div class="kicker">8 fruits · 5 textures</div>
          </div>
          <div class="fan-stage">
            ${deckCards.map((c) => `
              <div class="fan-card" style="left:${c.x}px; top:${c.y}px; z-index:${c.z}; background:${c.bg}; transform:rotate(${c.rot}deg);">
                ${c.svg}
                <div>
                  <div class="fan-name">${c.name}</div>
                  <div class="fan-tex">${c.tex}</div>
                </div>
                <div class="fan-dot"></div>
              </div>
            `).join("")}
          </div>
        </div>

        <div class="tile t-inbox">
          <div class="t-inbox-head">
            <div class="title" style="font-size:36px;">Today is your call.</div>
            <div class="sub" style="font-size:20px;">Inbox waits above Today.</div>
          </div>
          <div class="inbox-macro">
            <div class="inb-bar">
              <span class="inb-lbl">
                <svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><polyline points="22 12 16 12 14 15 10 15 8 12 2 12"/><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/></svg>
                Inbox
              </span>
              <span class="inb-cnt">2</span>
            </div>
            <div class="inb-row"><span class="inb-box"></span>Check download links</div>
            <div class="inb-row" style="opacity:0.55;"><span class="inb-box"></span>Review product notes</div>
          </div>
        </div>

        <div class="tile t-mcp">
          <div class="mcp-ghost">MCP</div>
          <div class="mcp-copy">
            <span class="mcp-pill">OPEN PROTOCOL</span>
            <div class="title">Bring any agent.</div>
            <div class="sub">Connect any agent that speaks MCP.</div>
          </div>
          <div class="mcp-code">
            <div class="bar">
              <i style="background:#FF5F56;"></i>
              <i style="background:#FFBD2E;"></i>
              <i style="background:#27C93F;"></i>
              <span style="margin-left:6px;">septena-mcp</span>
            </div>
            <div><span class="jk">tasks_claim</span>(<span class="js">"brief"</span>)</div>
            <div><span class="jk">tasks_thread_append</span>(…)</div>
            <div><span class="jk">tasks_set_handoff</span>(<span class="jn">true</span>)</div>
            <div style="color:rgba(255,255,255,0.42);">// waits in Review</div>
          </div>
        </div>

        <div class="tile t-devices">
          <div class="dev-photo-wrap">
            <img class="dev-photo" src="${DEVICES_PHOTO}" alt="Septena on Mac, iPad, iPhone, and Apple Watch" />
          </div>
          <div class="dev-copy">
            <div>
              <div class="kicker" style="color:rgba(255,255,255,0.62);">Native &amp; synced</div>
              <div class="title" style="margin-top:6px;">One list,<br>every device.</div>
              <div class="sub">Private sync across all four.</div>
            </div>
            <div class="dev-chips">
              <span class="dev-chip">iPhone</span>
              <span class="dev-chip">iPad</span>
              <span class="dev-chip">Mac</span>
              <span class="dev-chip">Watch</span>
            </div>
          </div>
        </div>
      </div>
    </div>
  </body></html>`;
}

// ============================================================================
// Portrait App Store Bento (1320 x 2868) — "Built in the open" study
// ============================================================================
function renderPortraitOpenBento() {
  const blue = HASKAP.light;
  return `<!doctype html><html><head><meta charset="utf-8"><style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    html, body {
      width: 1320px; height: 2868px; overflow: hidden;
      background: linear-gradient(180deg, ${blue} 0%, #12429E 100%);
      font-family: ${UI_FONT}; -webkit-font-smoothing: antialiased; position: relative;
    }
    .headline {
      position: relative; z-index: 2; padding: 164px 92px 0; text-align: center;
      font-size: 108px; line-height: 1.07; letter-spacing: -0.028em; color: #FFFFFF;
    }
    .headline strong { font-weight: 750; }
    .headline span { font-weight: 350; opacity: 0.94; }
    .bento {
      position: relative; z-index: 2; margin: 112px 76px 0;
      display: grid; grid-template-columns: 1fr 1fr; grid-template-rows: 560px 690px 710px; gap: 34px;
    }
    .card {
      position: relative; border-radius: 58px; background: #FFFFFF; padding: 50px 46px;
      box-shadow: 0 36px 84px rgba(0,0,0,0.24); overflow: hidden;
      display: flex; flex-direction: column; justify-content: space-between;
    }
    .card.dark {
      background: radial-gradient(95% 120% at 15% 50%, rgba(45,120,255,0.34) 0%, #111318 62%);
      color: #FFFFFF; border: 1.5px solid rgba(255,255,255,0.14);
    }
    .card.cobalt {
      background: radial-gradient(110% 95% at 75% 10%, #2669E8 0%, #0D2966 78%);
      color: #FFFFFF; border: 1.5px solid rgba(255,255,255,0.20);
    }
    .card.wide { grid-column: 1 / -1; flex-direction: row; align-items: center; gap: 50px; padding: 56px 58px; }
    .c-title { font-size: 56px; font-weight: 750; letter-spacing: -0.03em; line-height: 1.05; color: #111216; }
    .c-sub { font-size: 36px; font-weight: 450; line-height: 1.26; color: #63636A; margin-top: 14px; }
    .dark .c-title, .cobalt .c-title { color: #FFFFFF; }
    .dark .c-title { font-size: 68px; }
    .dark .c-sub, .cobalt .c-sub { color: rgba(255,255,255,0.78); }

    .mit-block {
      flex: none; width: 356px; height: 356px; border-radius: 52px;
      background: linear-gradient(145deg, #438BFF 0%, #1B60DB 52%, #0F3FA3 100%);
      display: flex; flex-direction: column; align-items: center; justify-content: center;
      box-shadow: 0 28px 64px rgba(29,99,220,0.62), inset 0 3px 0 rgba(255,255,255,0.42);
      position: relative; overflow: hidden;
    }
    .mit-sheen {
      position: absolute; top: -40%; left: -30%; width: 160%; height: 85%;
      background: linear-gradient(180deg, rgba(255,255,255,0.26) 0%, rgba(255,255,255,0) 100%);
      transform: rotate(-18deg);
    }
    .mit-word { position: relative; z-index: 2; font-family: ${ROUNDED_FONT}; font-size: 136px; font-weight: 850; letter-spacing: -0.05em; color: #FFFFFF; line-height: 0.95; }
    .mit-cap { position: relative; z-index: 2; font-family: ${MONO_FONT}; font-size: 25px; font-weight: 700; letter-spacing: 0.16em; color: rgba(255,255,255,0.88); margin-top: 10px; }

    .local-stage { display: flex; flex-direction: column; gap: 22px; }
    .ios-toggle-row { display: flex; align-items: center; justify-content: space-between; padding: 26px 28px; border-radius: 34px; background: #F2F4F8; box-shadow: inset 0 1px 0 #fff; }
    .ios-toggle-row.off { background: #FFFFFF; border: 2.5px dashed #D0D4DD; }
    .t-lbl { font-size: 34px; font-weight: 700; color: #111216; letter-spacing: -0.02em; }
    .t-lbl.muted { color: #8E8E93; font-weight: 600; }
    .switch { width: 112px; height: 66px; border-radius: 999px; padding: 6px; display: flex; align-items: center; }
    .switch.on { background: #34C759; justify-content: flex-end; box-shadow: 0 10px 24px rgba(52,199,89,0.40); }
    .switch.off { background: #E2E4EA; justify-content: flex-start; }
    .knob { width: 54px; height: 54px; border-radius: 50%; background: #fff; box-shadow: 0 4px 10px rgba(0,0,0,0.18); }

    .zero-hero { display: flex; align-items: baseline; gap: 14px; margin: 0 0 0 -6px; }
    .zero-big {
      font-family: ${ROUNDED_FONT}; font-size: 272px; font-weight: 850; line-height: 1.02; letter-spacing: -0.05em;
      padding: 6px 4px;
      background: linear-gradient(180deg, #FFFFFF 35%, rgba(160,202,255,0.78) 100%);
      -webkit-background-clip: text; -webkit-text-fill-color: transparent;
      filter: drop-shadow(0 18px 36px rgba(0,18,66,0.48));
    }
    .zero-u { font-family: ${ROUNDED_FONT}; font-size: 52px; font-weight: 700; color: rgba(205,228,255,0.88); }

    .json-bleed {
      background: #111318; border: 1.5px solid rgba(255,255,255,0.12); border-radius: 34px;
      padding: 28px 34px 32px; margin: -10px -58px 0 -6px; transform: rotate(-3deg);
      box-shadow: 0 24px 50px rgba(0,0,0,0.22);
      font-family: ${MONO_FONT}; font-size: 29px; line-height: 1.5; color: rgba(255,255,255,0.82);
    }
    .jb-head {
      display: flex; align-items: center; gap: 10px; padding-bottom: 18px; margin-bottom: 16px;
      border-bottom: 1px solid rgba(255,255,255,0.10); font-size: 23px; color: rgba(255,255,255,0.50);
    }
    .jb-head i { width: 15px; height: 15px; border-radius: 50%; display: inline-block; }
    .jk { color: #9EE034; } .js { color: #70B5FF; } .jn { color: #FF9F6E; }

    .sync-box {
      position: relative; padding: 34px 26px; border-radius: 38px;
      background: radial-gradient(80% 120% at 50% 50%, rgba(29,99,220,0.18) 0%, rgba(29,99,220,0.05) 100%);
      border: 1.5px solid rgba(29,99,220,0.18); display: flex; align-items: center; justify-content: space-between;
    }
    .s-dev {
      width: 108px; height: 108px; border-radius: 30px; background: #FFFFFF; color: #111216;
      display: flex; align-items: center; justify-content: center; box-shadow: 0 14px 30px rgba(0,0,0,0.10);
    }
    .s-lock {
      width: 126px; height: 126px; border-radius: 999px;
      background: linear-gradient(155deg, #3A84FF 0%, ${blue} 100%); color: #FFFFFF;
      display: flex; align-items: center; justify-content: center;
      box-shadow: 0 0 0 16px rgba(29,99,220,0.15), 0 18px 40px rgba(29,99,220,0.46);
    }
    .s-line {
      flex: 1; height: 6px; margin: 0 8px; border-radius: 999px;
      background: linear-gradient(90deg, rgba(29,99,220,0.15), rgba(29,99,220,0.75), rgba(29,99,220,0.15));
    }
  </style></head><body>
    ${ridgeBgSvg("rgba(255,255,255,0.16)")}

    <div class="headline">
      <strong>Septena is built in the open.</strong>
      <span>Open source, and your tasks stay yours.</span>
    </div>

    <div class="bento">
      <div class="card dark wide">
        <div class="mit-block">
          <div class="mit-sheen"></div>
          <div class="mit-word">MIT</div>
          <div class="mit-cap">LICENSE</div>
        </div>
        <div style="flex:1;min-width:0;">
          <div class="c-title">Open source.</div>
          <div class="c-sub">Every line of the apps and sync server is public.</div>
        </div>
      </div>

      <div class="card">
        <div class="local-stage">
          <div class="ios-toggle-row">
            <span class="t-lbl">On device</span>
            <div class="switch on"><div class="knob"></div></div>
          </div>
          <div class="ios-toggle-row off">
            <span class="t-lbl muted">Account</span>
            <div class="switch off"><div class="knob"></div></div>
          </div>
        </div>
        <div>
          <div class="c-title">Start without an account.</div>
          <div class="c-sub">Your tasks stay on this device.</div>
        </div>
      </div>

      <div class="card cobalt">
        ${topoSvg("rgba(255,255,255,0.10)")}
        <div class="zero-hero" style="position:relative;z-index:2;">
          <span class="zero-big">0</span>
          <span class="zero-u">bytes</span>
        </div>
        <div style="position:relative;z-index:2;">
          <div class="c-title">Not in analytics.</div>
          <div class="c-sub">Task text stays off our servers.</div>
        </div>
      </div>

      <div class="card">
        <div class="json-bleed">
          <div class="jb-head">
            <i style="background:#FF5F56;"></i>
            <i style="background:#FFBD2E;"></i>
            <i style="background:#27C93F;"></i>
            <span style="margin-left:8px;">backup.json</span>
          </div>
          <div><span class="jk">"app"</span>: <span class="js">"septena"</span>,</div>
          <div><span class="jk">"tasks"</span>: [<span class="jn">…</span>],</div>
          <div><span class="jk">"export"</span>: <span class="js">"full"</span></div>
        </div>
        <div>
          <div class="c-title">Back up as JSON.</div>
          <div class="c-sub">Export every task whenever you want.</div>
        </div>
      </div>

      <div class="card">
        <div class="sync-box">
          <div class="s-dev">
            <svg width="52" height="52" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><rect x="6" y="2" width="12" height="20" rx="3"/><path d="M10.5 18.5h3"/></svg>
          </div>
          <div class="s-line"></div>
          <div class="s-lock">
            <svg width="56" height="56" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="11" width="16" height="10" rx="2.5"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg>
          </div>
          <div class="s-line"></div>
          <div class="s-dev">
            <svg width="52" height="52" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="12" rx="2"/><path d="M1.5 19h21"/></svg>
          </div>
        </div>
        <div>
          <div class="c-title">Sign in to sync.</div>
          <div class="c-sub">Encrypted at rest on our server.</div>
        </div>
      </div>
    </div>
  </body></html>`;
}

function writeShowcase() {
  const b64 = (file) => `data:image/png;base64,${readFileSync(file).toString("base64")}`;
  const lightImg = b64(join(OUT_DIR, "bento-landscape-light.png"));
  const darkImg = b64(join(OUT_DIR, "bento-landscape-dark.png"));
  const afterImg = b64(join(OUT_DIR, "bento-appstore-open.png"));
  const beforePath = join(REPO, "appstore/screenshots-septask/en-US/6_iphone69_open.png");
  const beforeImg = existsSync(beforePath) ? b64(beforePath) : null;

  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Septena Bento Studio</title>
<style>
  :root { --bg:#0c0c0e; --border:rgba(255,255,255,0.09); --ink:#f5f5f7; --muted:rgba(245,245,247,0.58); --accent:#E05212; }
  * { box-sizing:border-box; margin:0; padding:0; }
  body { background:var(--bg); color:var(--ink); font-family:-apple-system,"SF Pro Display","SF Pro Text",sans-serif; -webkit-font-smoothing:antialiased; min-height:100vh; display:flex; flex-direction:column; }
  header { position:sticky; top:0; z-index:20; backdrop-filter:blur(20px); -webkit-backdrop-filter:blur(20px); background:rgba(12,12,14,0.82); border-bottom:1px solid var(--border); padding:14px 24px; display:flex; align-items:center; justify-content:space-between; gap:16px; flex-wrap:wrap; }
  .brand { display:flex; align-items:center; gap:10px; font-size:15px; font-weight:650; }
  .dot { width:10px; height:10px; border-radius:50%; background:var(--accent); }
  .tabs { display:flex; gap:6px; background:rgba(255,255,255,0.06); padding:4px; border-radius:999px; }
  .tab { border:none; background:transparent; color:var(--muted); font:600 13px/1 -apple-system,sans-serif; padding:8px 15px; border-radius:999px; cursor:pointer; }
  .tab.active { background:#fff; color:#111; }
  main { flex:1; padding:28px 28px 56px; max-width:1520px; width:100%; margin:0 auto; }
  .panel { display:none; flex-direction:column; gap:18px; }
  .panel.active { display:flex; }
  .frame { border-radius:18px; overflow:hidden; border:1px solid var(--border); box-shadow:0 24px 64px rgba(0,0,0,0.5); background:#111; }
  .frame img { display:block; width:100%; height:auto; }
  .compare { display:grid; grid-template-columns:${beforeImg ? "1fr 1fr" : "1fr"}; gap:24px; max-width:${beforeImg ? "920px" : "460px"}; margin:0 auto; width:100%; }
  .col { display:flex; flex-direction:column; gap:10px; }
  .col-label { display:flex; justify-content:space-between; font-size:13px; font-weight:600; color:var(--muted); }
</style></head><body>
  <header>
    <div class="brand"><span class="dot"></span>Septena Bento Studio</div>
    <div class="tabs">
      <button class="tab active" data-tab="light">Landscape Light</button>
      <button class="tab" data-tab="dark">Landscape Dark</button>
      <button class="tab" data-tab="appstore">App Store Portrait</button>
    </div>
  </header>
  <main>
    <section class="panel active" id="panel-light"><div class="frame"><img src="${lightImg}" alt="Light Bento" /></div></section>
    <section class="panel" id="panel-dark"><div class="frame"><img src="${darkImg}" alt="Dark Bento" /></div></section>
    <section class="panel" id="panel-appstore">
      <div class="compare">
        ${beforeImg ? `<div class="col"><div class="col-label"><span>Before (current 6_iphone69_open.png)</span></div><div class="frame"><img src="${beforeImg}" alt="Before" /></div></div>` : ""}
        <div class="col"><div class="col-label"><span>Bento study</span></div><div class="frame"><img src="${afterImg}" alt="After" /></div></div>
      </div>
    </section>
  </main>
  <script>
    const tabs = document.querySelectorAll('.tab'), panels = document.querySelectorAll('.panel');
    tabs.forEach(t => t.addEventListener('click', () => {
      tabs.forEach(x => x.classList.remove('active')); panels.forEach(x => x.classList.remove('active'));
      t.classList.add('active'); document.getElementById('panel-' + t.dataset.tab).classList.add('active');
    }));
  </script>
</body></html>`;
  writeFileSync(join(OUT_DIR, "showcase.html"), html);
}

const chrome = await openChrome();
try {
  const jobs = [
    { name: "bento-landscape-light", html: renderLandscapeBento("light"), width: 2400, height: 1500 },
    { name: "bento-landscape-dark", html: renderLandscapeBento("dark"), width: 2400, height: 1500 },
    { name: "bento-appstore-open", html: renderPortraitOpenBento(), width: 1320, height: 2868 },
  ];
  for (const job of jobs) {
    const htmlPath = join(OUT_DIR, `${job.name}.html`);
    const pngPath = join(OUT_DIR, `${job.name}.png`);
    writeFileSync(htmlPath, job.html);
    await chrome.screenshot(htmlPath, pngPath, { width: job.width, height: job.height });
    console.log(`✓ ${job.name}.png (${job.width}×${job.height})`);
  }
  writeShowcase();
  console.log(`✓ showcase.html`);
} finally {
  await chrome.close();
}
