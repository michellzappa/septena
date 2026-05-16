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
  /// Reminders uses behind insetGrouped lists; on macOS we use the plain
  /// window background so the sidebar's `.regularMaterial` can sit on top.
  static let paperBackground: Color = {
    #if os(macOS)
    return Color(nsColor: .windowBackgroundColor)
    #else
    return Color(.systemGroupedBackground)
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
  static let todayAccent    = Color.blue
  static let upcomingAccent = Color.red
  static let anytimeAccent  = Color.secondary
  static let logbookAccent  = Color.secondary

  // MARK: - Shape & spacing
  //
  // Reminders has near-zero corner radius on list rows and ~10pt on
  // sheets / inline cards. Keeping the old token names; only the major
  // radius drops from 18 → 10.

  static let cornerRadius: CGFloat = 10
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
}

// MARK: - Typography
//
// Every font now resolves to a system text style so Dynamic Type and
// accessibility sizes Just Work. The "screenTitle" is the one place we
// keep a fixed look — Reminders' large list header — using SF Pro Rounded
// Bold at largeTitle. The list-color tint is applied by the call site, not
// here.

extension Font {
  /// Large list title — SF Pro Rounded Bold, tinted in list color by caller.
  static let septenaScreenTitle  = Font.system(.largeTitle, weight: .bold)
  /// Section header inside a list ("Today", "Scheduled") — uppercase footnote
  /// in callers; this is the bare style.
  static let septenaSectionTitle = Font.system(.title2, weight: .bold)
  static let septenaCardTitle    = Font.system(.headline)
  static let septenaSidebarRow   = Font.system(.body)
  static let septenaTaskTitle    = Font.system(.body)
  static let septenaNotes        = Font.system(.subheadline)
  static let septenaButton       = Font.system(.subheadline, weight: .semibold)
  static let septenaLabel        = Font.system(.footnote, weight: .medium)
  static let septenaMeta         = Font.system(.footnote)
  static let septenaMetaStrong   = Font.system(.footnote, weight: .semibold)
  static let septenaBadge        = Font.system(.caption2, weight: .semibold)
}
