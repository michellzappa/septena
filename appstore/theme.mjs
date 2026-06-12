// Design tokens for App Store marketing panels.
// Mirrors the app's real brand sources:
//   - section accents → SeptenaCore/SectionTheme.swift `defaultPalette`
//   - app accent      → Assets AccentColor (rgb 0.20, 0.42, 0.82)
//   - typography      → docs/DesignSpec.md §5 (Fraunces display, SF Pro UI, mono numerics)
// Edit freely — everything downstream (components, panels) reads from here.

export const theme = {
  // ----- color -----
  ink: "#1c1917",          // primary text on light washes
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

  // ----- typography -----
  // Fraunces is the app's single editorial face (Dashboard welcome) and is
  // bundled in the repo; render.mjs inlines it via @font-face so panels use
  // the genuine brand serif. UI/meta text uses the system stack (SF on Mac).
  fonts: {
    display: `"Fraunces", Georgia, serif`,
    ui: `-apple-system, "SF Pro Text", "Helvetica Neue", Inter, sans-serif`,
    mono: `"SF Mono", ui-monospace, Menlo, monospace`,
  },

  // ----- shape & depth (panel-space px, designed at 1320 wide) -----
  radius: { card: 40, device: 120, badge: 999 },
  shadow: {
    device: "0 60px 120px -30px rgb(0 0 0 / 0.35)",
    card: "0 24px 60px -12px rgb(0 0 0 / 0.18)",
  },

  // Background wash recipe: tint mixed into white/paper. Components use
  // CSS color-mix so any hex works without precomputed light variants.
  wash: (tint, pct = 14) => `color-mix(in oklab, ${tint} ${pct}%, white)`,
};
