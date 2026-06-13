// App Store surface registry. One entry per device class Septena ships on.
// `active: true` ⇒ render.mjs produces panels for it. Sizes verified against
// ASC screenshot specs (2026):
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

export const devices = {
  iphone69: {
    active: true,
    label: 'iPhone 6.9"',
    width: 1320,
    height: 2868,
    designWidth: 1320,
    screenAspect: 1320 / 2868,
    platform: "ios",
    frame: "phone",
    rawDir: "raw/iphone69",
    outDir: "screenshots/en-US",
    captureNote: "appstore/capture.sh iphone69 light  (iPhone 16 Pro Max sim)",
  },

  ipad13: {
    active: true,
    label: 'iPad 13"',
    width: 2064,
    height: 2752,
    designWidth: 1320,         // shared portrait coordinate space → same type scale
    screenAspect: 2064 / 2752,
    platform: "ios",
    frame: "pad",
    rawDir: "raw/ipad13",
    outDir: "screenshots/en-US",
    captureNote: 'appstore/capture.sh ipad13 light  (iPad Pro 13" sim)',
  },

  mac: {
    active: true,
    label: "Mac",
    width: 2880,
    height: 1800,
    designWidth: 2880,         // landscape, its own space
    screenAspect: 2880 / 1800,
    landscape: true,
    platform: "osx",           // separate ASC app: com.septena.cloud.mac
    frame: "mac",
    rawDir: "raw/mac",
    outDir: "screenshots-mac/en-US",
    captureNote: "appstore/capture.sh mac light  (SeptenaMacUITests on macOS)",
  },

  watch: {
    active: false,             // MZ captures these (single Next screen); flip when ready
    label: "Apple Watch",
    width: 410,
    height: 502,
    designWidth: 410,
    screenAspect: 410 / 502,
    platform: "ios",           // watch shots ride along under the iOS app
    frame: "none",
    rawDir: "raw/watch",
    outDir: "screenshots/en-US",
    captureNote: "xcrun simctl io <watch-sim> screenshot — single Next screen",
  },
};

export const activeDevices = () =>
  Object.entries(devices).filter(([, d]) => d.active).map(([key, d]) => ({ key, ...d }));
