// App Store surface registry. One entry per device class Septena ships on.
// `active: true` ⇒ render.mjs produces panels for it. Inactive entries are
// pre-wired slots (sizes verified against ASC screenshot specs, 2026):
//   iPhone 6.9" 1320×2868 — ASC auto-scales smaller iPhone shelves from it
//   iPad 13"    2064×2752 — required if the app runs on iPad
//   Mac         must be 16:10 (2880×1800 preferred) — separate ASC app
//   Watch       410×502 (Ultra) / 416×496 (S10) — uploads under the iOS app
// Rules: PNG/JPEG, RGB (no alpha), exact pixels, 1–10 shots per class.

export const devices = {
  iphone69: {
    active: true,
    label: 'iPhone 6.9"',
    width: 1320,
    height: 2868,
    platform: "ios",
    frame: "phone",            // device-frame style in components.mjs
    designWidth: 1320,         // panel coordinate system; zoom = width/designWidth
    rawDir: "raw/iphone69",    // sync-shots.sh fills <rawDir>/<light|dark>/
    outDir: "screenshots/en-US",
    captureNote: "scripts/screenshots.sh (iPhone 16 Pro Max simulator)",
  },

  ipad13: {
    active: false,
    label: 'iPad 13"',
    width: 2064,
    height: 2752,
    platform: "ios",
    frame: "pad",
    designWidth: 2064,
    rawDir: "raw/ipad13",
    outDir: "screenshots/en-US",
    captureNote: "needs an iPad pass in ScreenshotTests (iPad Pro 13\" sim)",
  },

  mac: {
    active: false,
    label: "Mac",
    width: 2880,
    height: 1800,
    platform: "osx",           // separate ASC app: com.septena.cloud.mac
    frame: "mac",
    designWidth: 2880,
    landscape: true,           // panels need the landscape layout variant
    rawDir: "raw/mac",
    outDir: "screenshots-mac/en-US",
    captureNote: "SeptenaMac scheme + screencapture, or an XCUITest pass",
  },

  watch: {
    active: false,
    label: "Apple Watch",
    width: 410,
    height: 502,
    platform: "ios",           // watch shots ride along under the iOS app
    frame: "none",             // too small for marketing chrome; raw-ish
    designWidth: 410,
    rawDir: "raw/watch",
    outDir: "screenshots/en-US",
    captureNote: "no watch ScreenshotTests target yet",
  },
};

export const activeDevices = () =>
  Object.entries(devices).filter(([, d]) => d.active).map(([key, d]) => ({ key, ...d }));
