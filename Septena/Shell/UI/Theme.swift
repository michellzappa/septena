import SwiftUI

// Septena visual tokens.
//
// Phase 1 of the Reminders-style redesign: every color is now a system color
// and every font is a Dynamic-Type-aware system text style. Spacing tokens
// stay (they're shape, not paint). Symbol names are preserved so call sites
// elsewhere keep compiling — later phases will retire the ones that no
// longer make sense (e.g. cardSurface once rows stop being cards).

enum Theme {

  // MARK: - Accent
  //
  // Reminders draws its per-list color from the system palette. We surface
  // the *current* tint via `Color.accentColor` so any view inside a
  // `.tint(listColor)` scope picks it up automatically. The "Soft" variant
  // is the same color at a fixed alpha for selection pills / chips.

  static let tasksAccent = Color.accentColor
  static let tasksAccentSoft = Color.accentColor.opacity(0.18)
  static let tasksAccentStrong = Color.accentColor

  // MARK: - Surfaces

  /// App canvas. System grouped background on iOS gives the soft gray that
  /// Reminders uses behind insetGrouped lists; on macOS we use the text
  /// background (white in light, near-black in dark) so the content pane
  /// reads as paper next to the translucent sidebar — matching Reminders.
  static let paperBackground: Color = {
    #if os(macOS)
    return Color(nsColor: .textBackgroundColor)
    #else
    return Color(.systemBackground)
    #endif
  }()

  /// Sidebar surface — translucent material on macOS (the Reminders look),
  /// system grouped background on iOS where the sidebar is just another
  /// view in the stack.
  static let sidebarBackground: Color = {
    #if os(macOS)
    return Color(nsColor: .underPageBackgroundColor)
    #else
    return Color(.systemGroupedBackground)
    #endif
  }()

  /// Selection pill background. Uses the system selection color so it
  /// honors highlight contrast and accent inheritance.
  static let rowSelection: Color = {
    #if os(macOS)
    return Color(nsColor: .selectedContentBackgroundColor).opacity(0.25)
    #else
    return Color.accentColor.opacity(0.15)
    #endif
  }()

  /// Card surface. Used for sheets and any container that needs to lift
  /// off the canvas. Plain rows should NOT use this — they sit on the
  /// list background directly, Reminders-style.
  static let cardSurface: Color = {
    #if os(macOS)
    return Color(nsColor: .controlBackgroundColor)
    #else
    return Color(.secondarySystemGroupedBackground)
    #endif
  }()

  /// Cross-platform analogue of `UIColor.systemGroupedBackground` — the soft
  /// gray under insetGrouped lists / dashboard canvases on iOS.
  /// macOS uses a hand-mixed dynamic gray: lighter than
  /// `.underPageBackgroundColor` (too dark) but distinct from
  /// `.windowBackgroundColor` (reads as white against tiles). Targets the
  /// iOS systemGroupedBackground tone (~#F2F2F7) on both appearances.
  static let groupedBackground: Color = {
    #if os(macOS)
    return Color(nsColor: NSColor(name: nil) { appearance in
      let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
      return isDark
        ? NSColor(white: 0.13, alpha: 1)   // ~iOS dark systemGroupedBackground
        : NSColor(white: 0.95, alpha: 1)   // ~iOS light systemGroupedBackground
    })
    #else
    return Color(.systemGroupedBackground)
    #endif
  }()

  /// Cross-platform analogue of `UIColor.secondarySystemGroupedBackground` —
  /// the elevated surface that sits on top of `groupedBackground` (tiles,
  /// inset cards). Same swatch as `cardSurface`; kept as a distinct name so
  /// call sites that migrate from the iOS-only token read clearly.
  static let secondaryGroupedBackground: Color = cardSurface

  /// Muted secondary surface — chips, search fields, inline pills.
  static let mutedSurface: Color = {
    #if os(macOS)
    return Color(nsColor: .quaternaryLabelColor).opacity(0.5)
    #else
    return Color(.tertiarySystemGroupedBackground)
    #endif
  }()

  // MARK: - Foregrounds

  /// Primary text. `Color.primary` adapts to light/dark and high contrast.
  static let inkPrimary = Color.primary

  /// Muted text (meta, captions, sublabels).
  static let inkSecondary = Color.secondary

  /// Icon color when an icon should recede behind row text. `.tertiary`
  /// matches what Reminders uses for non-tinted glyphs (calendar, bell,
  /// flag-outline) in row metadata.
  static let iconMuted: Color = {
    #if os(macOS)
    return Color(nsColor: .tertiaryLabelColor)
    #else
    return Color(uiColor: .tertiaryLabel)
    #endif
  }()

  // MARK: - Lines & selection

  static let border: Color = {
    #if os(macOS)
    return Color(nsColor: .separatorColor)
    #else
    return Color(uiColor: .separator)
    #endif
  }()
  static let divider = border
  static let rowSelected = tasksAccentSoft

  // MARK: - Semantic

  /// Destructive / overdue. System red — matches Apple Reminders' overdue
  /// date text. The previous orange read as "warning, but soft"; red is the
  /// platform convention for "this is late".
  static let overdueRed = Color.red

  // MARK: - Filter accents

  static let inboxAccent    = Color.secondary
  /// Slightly darker than `Color.yellow` so the white sun glyph keeps
  /// contrast against it in light mode (system yellow is so bright the
  /// icon almost disappears). Same swatch in both modes — dark mode reads
  /// it as a warm gold, light mode as a saturated amber.
  static let todayAccent    = Color(red: 0.96, green: 0.78, blue: 0.13)
  /// Muted moonlight indigo — marks "Someday" tasks in mixed lists.
  static let somedayAccent  = Color(red: 0.50, green: 0.50, blue: 0.75)
  static let upcomingAccent = Color.red
  static let anytimeAccent  = Color.secondary
  static let logbookAccent  = Color.secondary

  // MARK: - Shape & spacing
  //
  // Section drawer cards (and the goal strip's row) use a larger
  // continuous corner radius — the iOS 26 "soft tile" feel rather than
  // the tighter 10pt Reminders look. Small radius stays modest for
  // chips and pills.

  static let cornerRadius: CGFloat = 22
  static let cornerRadiusSmall: CGFloat = 6

  /// Tap-target width of the row checkbox. Reused by group-header icon
  /// columns and inline-new placeholder so the icon column lines up
  /// across every list row and section header — one X for icons, one X
  /// for text.
  #if os(macOS)
  static let checkboxTap: CGFloat = 22
  #else
  static let checkboxTap: CGFloat = 28
  #endif
  /// Diameter of the progress ring shown on the area page's project rows.
  /// Sized to match the `TaskCheckbox` glyph that appears in task rows
  /// below, so the icon column reads as one consistent dot size.
  #if os(macOS)
  static let areaRowRingDiameter: CGFloat = 16
  #else
  static let areaRowRingDiameter: CGFloat = 22
  #endif
  /// HStack spacing between the icon column and the text column, shared
  /// across closed task rows, the editor row, the new-task placeholder
  /// row, and group headers — so text always starts at the same X.
  static let iconTextGap: CGFloat = 12

  #if os(macOS)
  static let hPadding: CGFloat = 12
  static let rowHeight: CGFloat = 24
  static let rowTapHeight: CGFloat = 32
  static let sidebarRowHeight: CGFloat = 28
  static let sidebarSmartRowHeight: CGFloat = 26
  static let sidebarProjectRowHeight: CGFloat = 30
  static let sectionSpacing: CGFloat = 16
  static let sidebarIconSize: CGFloat = 17
  static let sidebarRowSpacing: CGFloat = 10
  static let sidebarTitleSize: CGFloat = 13
  static let sidebarTitleWeight: Font.Weight = .regular
  static let sidebarAreaTitleSize: CGFloat = 13
  static let listLeadingInset: CGFloat = 20
  static let cardVerticalPadding: CGFloat = 6
  static let cardActionIconSize: CGFloat = 14
  static let groupHeaderFontSize: CGFloat = 13
  #else
  static let hPadding: CGFloat = 20
  static let rowHeight: CGFloat = 36
  static let rowTapHeight: CGFloat = 44
  static let sidebarRowHeight: CGFloat = 44
  static let sidebarSmartRowHeight: CGFloat = 38
  static let sidebarProjectRowHeight: CGFloat = 45
  static let sectionSpacing: CGFloat = 24
  static let sidebarIconSize: CGFloat = 22
  static let sidebarRowSpacing: CGFloat = 14
  static let sidebarTitleSize: CGFloat = 17
  static let sidebarTitleWeight: Font.Weight = .regular
  static let sidebarAreaTitleSize: CGFloat = 17
  static let listLeadingInset: CGFloat = 0
  static let cardVerticalPadding: CGFloat = 10
  static let cardActionIconSize: CGFloat = 18
  static let groupHeaderFontSize: CGFloat = 17
  #endif

  /// Vertical padding inside a task / log row. Single source of truth so
  /// row density stays coherent across platforms. iOS 26 drawer cards
  /// want noticeably more air than the old Reminders-tight rows —
  /// bumped from 3pt so LogRow / TaskRow / ChoreRow all settle into a
  /// taller, easier-to-tap rhythm inside DrawerSection.
  static let rowVPadding: CGFloat = 8

  /// Spacing scale shared across drawer chrome (SectionDrawer,
  /// DrawerSection, ChartCard, StatTile, StatStrip). Replaces the
  /// magic-number sprinkle of 4 / 8 / 12 / 14 / 16 / 28 with named
  /// tokens. Tune one place; the whole drawer system shifts in step.
  enum Spacing {
    /// 4pt — between adjacent rows inside a DrawerSection.
    static let xs: CGFloat = 4
    /// 8pt — between a section's header text and its card.
    static let sm: CGFloat = 8
    /// 12pt — vertical padding inside a DrawerSection card (.standard).
    static let md: CGFloat = 12
    /// 14pt — horizontal padding inside a DrawerSection card (.standard).
    static let lg: CGFloat = 14
    /// 16pt — horizontal indent of a section header text from screen edge.
    static let xl: CGFloat = 16
    /// 28pt — between adjacent DrawerSections in the drawer's LazyVStack.
    static let xxl: CGFloat = 28
  }

  /// Motion tokens — named animation curves so timings live in one place
  /// instead of being hand-typed per view. Reach for one of these rather
  /// than inlining a `.spring(...)` / `.easeOut(duration:)` literal at a
  /// call site; tune the curve here and the whole app shifts in step.
  ///
  /// These are *curves*, not gated animations — always apply them through
  /// `.a11yAnimation(_:value:)` or `A11yMotion.run` so Reduce Motion still
  /// suppresses the motion. (Decorative celebrations gate themselves; see
  /// `ConfettiBurst` / `MoodCommitAnimation`.)
  enum Motion {
    /// Default UI transition — selection, content swaps, value tweens.
    /// SwiftUI's `.snappy`: responsive with a touch of give.
    static let standard: Animation = .snappy
    /// Quick fade / dismiss / toggle — short and crisp.
    static let quick: Animation = .easeOut(duration: 0.2)
    /// Row expand / collapse. Snappy enough to feel responsive on tap,
    /// soft enough to read as an expand rather than a snap. Symmetric on
    /// insert and dismiss.
    static let expand: Animation = .spring(response: 0.32, dampingFraction: 0.84)
    /// Settle: a checked item fades out of the open list after lingering
    /// (see `SettleStore`). Gentle enough to read as "drifting away", not a
    /// snap. Paired with `.transition(.opacity)` on the open-list rows.
    static let settle: Animation = .easeInOut(duration: 0.35)
  }
}

// MARK: - Typography
//
// Three-family system (see docs/DesignSpec.md §5):
//   - SF Pro (system)  → UI body, controls, labels, buttons, most titles
//   - Fraunces (serif) → screen-level H1 only (septenaScreenTitle); rare by design
//   - System mono      → numerics / metrics (tabular)
//
// Fraunces is registered via Info.plist `UIAppFonts` (iOS) and
// `ATSApplicationFontsPath` (Mac). If the file isn't bundled, Font.custom
// silently falls back to system — so the app stays buildable either way.
//
// Use `Font.custom(_, size:, relativeTo:)` so Dynamic Type still scales.

extension Font {
  // Fraunces PostScript names registered by the bundled variable font.
  // We address weights by name rather than via `.weight(...)` on a single
  // base, because SwiftUI's weight modifier can't navigate this font's
  // multi-axis design (opsz/SOFT/wght/WONK) and silently fails.
  private static let frauncesRegular  = "Fraunces-9ptRegular"
  private static let frauncesSemiBold = "Fraunces-9ptSemiBold"
  private static let frauncesBold     = "Fraunces-9ptBold"

  // MARK: Titles
  // Fraunces is reserved for the screen-level H1 only — destination headers,
  // homepage welcome, Tasks H1. Everything else (section, card, tile titles)
  // uses SF Pro so the editorial face stays rare and meaningful.
  /// Destination header — Fraunces SemiBold at largeTitle. The one Fraunces user.
  static let septenaScreenTitle  = Font.custom(frauncesSemiBold, size: 34, relativeTo: .largeTitle)
  /// Section header within a screen — SF Pro semibold at title2.
  static let septenaSectionTitle = Font.system(.title2, weight: .semibold)
  /// Card header — SF Pro at headline (already semibold by default).
  static let septenaCardTitle    = Font.system(.headline)
  /// Dashboard tile header — slightly larger on iOS so it reads at a glance
  /// in the Histogram layout; macOS keeps the denser headline size.
  #if os(iOS)
  static let septenaTileTitle    = Font.system(.title3, weight: .semibold)
  #else
  static let septenaTileTitle    = Font.system(.headline)
  #endif

  // MARK: UI body (SF Pro)
  static let septenaSidebarRow   = Font.system(.body)
  static let septenaTaskTitle    = Font.system(.body)
  static let septenaNotes        = Font.system(.subheadline)
  static let septenaButton       = Font.system(.subheadline, weight: .semibold)
  static let septenaLabel        = Font.system(.footnote, weight: .medium)
  static let septenaBadge        = Font.system(.caption2, weight: .semibold)

  // MARK: Metrics (mono, tabular)
  static let septenaMeta         = Font.system(.footnote).monospacedDigit()
  static let septenaMetaStrong   = Font.system(.footnote, weight: .semibold).monospacedDigit()
  static let septenaMetric       = Font.system(.body, design: .monospaced).monospacedDigit()
}
