// Design tokens for App Store marketing panels.
// Mirrors the app's real brand sources:
//   - section accents → SeptenaCore/SectionTheme.swift `defaultPalette`
//   - app accent      → Assets AccentColor (rgb 0.20, 0.42, 0.82)
//   - typography      → docs/DesignSpec.md §5 (SF Pro for titles and UI, mono numerics)
// Edit freely — everything downstream (components, panels) reads from here.

export const theme = {
  // ----- color -----
  ink: "#000000",          // iOS label
  inkSecondary: "rgb(60 60 67 / 0.6)", // iOS secondaryLabel
  inkSoft: "#8a8378",      // secondary text (SectionTheme fallback gray)
  paper: "#faf9f7",        // warm off-white card/page base
  white: "#ffffff",
  accent: "#336bd1",       // app AccentColor — default marketing accent

  // Per-section accents, straight from SectionTheme.defaultPalette.
  sections: {
    tasks: "#ef4444",
    habits: "#22c55e",
    training: "#f97316",
    chores: "#a855f7",
    supplements: "#3b82f6",
    sleep: "#6366f1",
    nutrition: "#f59e0b",
    groceries: "#84cc16",
    body: "#ec4899",
    gut: "#b45309",
    activity: "#06b6d4",
    goals: "#8b5cf6",
  },

  // Task-app panel backgrounds, in panel order. Neutral hues around the
  // platform accent; the task app has no section colors.
  tints: ["#336bd1", "#5b5bd6", "#0f9d8f", "#c2410c", "#7c3aed", "#0369a1"],

  // The task app's own canvas and header textures (Settings > Appearance).
  // Canvas is iOS systemGroupedBackground; accent is the platform accent
  // (AGENTS.md, decided 2026-11-19). The textures draw with the site's port of
  // SeptenaCore/HeaderWashEngine.swift (render.mjs loads it).
  app: {
    canvas: "#f2f2f7",
    accent: "#007AFF",
    textures: ["topography", "fieldMatrix", "stippleDrift", "causticGlass", "ridges", "washiPaper"],
  },

  // ----- typography -----
  // SF Pro everywhere, as in the app: titles use the screen-title weight
  // (DesignSpec §5 .septenaScreenTitle, semibold). New York is not app chrome.
  fonts: {
    display: `-apple-system, "SF Pro Display", "Helvetica Neue", sans-serif`,
    ui: `-apple-system, "SF Pro Text", "Helvetica Neue", Inter, sans-serif`,
    mono: `"SF Mono", ui-monospace, Menlo, monospace`,
  },

  // ----- shape & depth (panel-space px, designed at 1320 wide) -----
  radius: { card: 40, device: 120, badge: 999 },
  // The site's 3D-ish phone bezel (same file), instead of a flat black frame.
  bezel: "linear-gradient(145deg,#747479,#202023 28%,#303034 80%,#737379)",
  shadow: {
    device: "0 60px 120px -30px rgb(0 0 0 / 0.35)",
    // septena-site components/scenes/scenes.css .scene-frame--phone, scaled.
    phone: (k) => `0 ${20 * k}px ${50 * k}px ${-20 * k}px rgb(0 0 0 / 0.3), inset 0 0 0 ${k}px rgb(255 255 255 / 0.3)`,
    card: "0 24px 60px -12px rgb(0 0 0 / 0.18)",
  },

  // Background wash recipe: tint mixed into white/paper. Components use
  // CSS color-mix so any hex works without precomputed light variants.
  wash: (tint, pct = 14) => `color-mix(in oklab, ${tint} ${pct}%, white)`,
};
