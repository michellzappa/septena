// App Store surface registry. Device GEOMETRY (pixel sizes, frame, platform) is
// shared across both apps — only which classes are active and where their files
// land differ per app, and those come from apps.mjs. Sizes verified against ASC
// screenshot specs (2026):
//   iPhone 6.9" 1320×2868 — ASC auto-scales smaller iPhone shelves from it
//   iPad 13"    2064×2752 — required if the app runs on iPad
//   Mac         must be 16:10 (2880×1800 preferred) — separate ASC app
//   Watch       410×502 (Ultra) / 416×496 (S10) — uploads under the iOS app
// Rules: PNG/JPEG, RGB (no alpha), exact pixels, 1–10 shots per class.
//
// Layout model: portrait devices share designWidth 1320 so the type scale is
// identical across iPhone/iPad (render scales to real px via zoom). Mac is
// landscape and authored in its own 2880-wide space. `screenAspect` (w/h of the
// raw capture) keeps frames and placeholders correctly proportioned.
//
// rawDir / outDir are computed per selected app (apps.mjs) so Septena and
// Septask never overwrite each other's captures or renders.

import { currentApp } from "./apps.mjs";

const GEOMETRY = {
  iphone69: {
    label: 'iPhone 6.9"',
    width: 1320,
    height: 2868,
    designWidth: 1320,
    screenAspect: 1320 / 2868,
    platform: "ios",
    frame: "phone",
  },
  ipad13: {
    label: 'iPad 13"',
    width: 2064,
    height: 2752,
    designWidth: 1320, // shared portrait coordinate space → same type scale
    screenAspect: 2064 / 2752,
    platform: "ios",
    frame: "pad",
  },
  mac: {
    label: "Mac",
    width: 2880,
    height: 1800,
    designWidth: 2880, // landscape, its own space
    screenAspect: 2880 / 1800,
    landscape: true,
    platform: "osx", // separate ASC app
    frame: "mac",
  },
  watch: {
    label: "Apple Watch",
    width: 410,
    height: 502,
    designWidth: 410,
    screenAspect: 410 / 502,
    platform: "ios", // watch shots ride along under the iOS app
    frame: "none",
  },
};

/**
 * Every device class the selected app ships, with app-scoped paths + active
 * flags folded in. render.mjs and validate.mjs read this (never GEOMETRY
 * directly), so switching SEPTENA_APP reroutes the whole pipeline.
 */
export function allDevices() {
  const app = currentApp();
  const out = {};
  for (const [key, g] of Object.entries(GEOMETRY)) {
    const cfg = app.devices[key];
    if (!cfg) continue; // this app doesn't ship this device class
    const isMac = g.platform === "osx";
    out[key] = {
      ...g,
      active: !!cfg.active,
      rawDir: `${app.rawRoot}/${key}`,
      outDir: `${isMac ? app.screenshotsMacDir : app.screenshotsDir}/en-US`,
      captureNote: `SEPTENA_APP=${app.key} appstore/capture.sh ${key} light`,
    };
  }
  return out;
}

export const activeDevices = () =>
  Object.entries(allDevices())
    .filter(([, d]) => d.active)
    .map(([key, d]) => ({ key, ...d }));
