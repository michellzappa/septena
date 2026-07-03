// The two apps this repo ships to the App Store: Septena (the life OS) and
// Septask (the focused tasks app over the same task data). There will not be a
// third, so this is a small explicit registry, not an N-app framework.
//
// One app is selected per pipeline run via the SEPTENA_APP env var (default
// "septena"), so capture.sh / metadata.mjs / devices.mjs / panels.config.mjs
// all resolve to the same app without threading an arg through every script.
// Every output path is app-scoped so the two apps' raw captures, rendered
// panels, and metadata never collide.
//
//   node metadata.mjs                       # Septena
//   SEPTENA_APP=septask node metadata.mjs   # Septask
//   npm run all           /  npm run all:septask
//
// Bundle ids are verified against project.yml (Septask = com.septena.tasks,
// mac = com.septena.tasks.mac — NOT com.septask.*). Each app is its own pair of
// App Store Connect apps (iOS + a separate macOS record), so shipping is four
// `fastlane deliver` runs total. Device `active` flags gate rendering/validation
// per app: a class stays inactive until its real captures exist, so `npm run
// all` never ships a placeholder (the same discipline Septena's mac/watch use).

export const APPS = {
  septena: {
    key: "septena",
    name: "Septena",
    metadataDoc: "docs/APPSTORE.md",
    rawRoot: "raw",
    screenshotsDir: "screenshots",
    screenshotsMacDir: "screenshots-mac",
    metadataDir: "metadata",
    metadataMacDir: "metadata-mac",
    bundleIds: { ios: "com.septena.cloud", mac: "com.septena.cloud.mac" },
    devices: {
      iphone69: { active: true },
      ipad13: { active: true },
      mac: { active: false }, // flip on once a real Mac capture lands
      watch: { active: false }, // MZ captures the single Next screen
    },
    capture: {
      iphone69: { scheme: "Septena", sim: "iPhone 16 Pro Max", test: "SeptenaUITests" },
      ipad13: { scheme: "Septena", sim: "iPad Pro 13-inch (M4)", test: "SeptenaUITests" },
      mac: { scheme: "SeptenaMac", sim: "", test: "SeptenaMacUITests" },
    },
  },

  septask: {
    key: "septask",
    name: "Septask",
    metadataDoc: "docs/APPSTORE-SEPTASK.md",
    rawRoot: "raw-septask",
    screenshotsDir: "screenshots-septask",
    screenshotsMacDir: "screenshots-septask-mac",
    metadataDir: "metadata-septask",
    metadataMacDir: "metadata-septask-mac",
    bundleIds: { ios: "com.septena.tasks", mac: "com.septena.tasks.mac" },
    devices: {
      // Inactive until Septask captures exist; flip each on once its raw shots
      // land so validate.mjs's parity guard never lets a placeholder ship.
      iphone69: { active: false },
      ipad13: { active: false },
      mac: { active: false },
    },
    capture: {
      iphone69: { scheme: "Septask", sim: "iPhone 16 Pro Max", test: "SeptaskUITests" },
      ipad13: { scheme: "Septask", sim: "iPad Pro 13-inch (M4)", test: "SeptaskUITests" },
      mac: { scheme: "SeptaskMac", sim: "", test: "SeptaskMacUITests" },
    },
  },
};

/** The app selected for this run (SEPTENA_APP env var; defaults to Septena). */
export const currentApp = () => APPS[process.env.SEPTENA_APP ?? "septena"] ?? APPS.septena;
