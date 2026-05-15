import SwiftUI

// Septena visual tokens. Mirrors app/globals.css and lib/section-colors.ts.
// Single source of truth: any color/font/radius the UI uses lives here.

enum Theme {

  // MARK: - Accent

  /// Primary accent. Inherits from the asset catalog's AccentColor (currently
  /// a neutral blue) — keeps a single source of truth and avoids baking a
  /// section hue into code.
  static let tasksAccent = Color.accentColor
  static let tasksAccentSoft = Color.accentColor.opacity(0.14)
  static let tasksAccentStrong = Color.accentColor

  // MARK: - Surfaces (near-neutral off-white light, warm charcoal dark)

  /// App canvas. Near-neutral off-white in light, Claude-range warm charcoal in dark.
  /// Matches DESIGN.md: trace of warmth, very low chroma — modern/clean, not cream.
  static let paperBackground = Color("PaperBackground", bundle: nil, fallback: dynamic(
    light: Color(red: 0.980, green: 0.980, blue: 0.972),   // #FAFAF8 ≈ oklch(0.98 0.002 100)
    dark:  Color(red: 0.149, green: 0.149, blue: 0.141)    // #262624 ≈ oklch(0.22 0.003 70)
  ))

  /// Sidebar surface. Slightly darker than the canvas on macOS so the column
  /// reads as a distinct sidebar (compact). Identical to paper on iOS,
  /// where the sidebar IS the homepage.
  static let sidebarBackground: Color = {
    #if os(macOS)
    return dynamic(
      light: Color(red: 0.940, green: 0.937, blue: 0.929),  // ≈ #F0EFEC
      dark:  Color(red: 0.122, green: 0.122, blue: 0.114)   // a touch darker than paper
    )
    #else
    return paperBackground
    #endif
  }()

  /// Selection pill background for sidebar rows and keyboard-focused list rows.
  /// Distinct from both paperBackground and sidebarBackground so it stays
  /// visible on either surface. Tuned to read as "active" without shouting.
  static let rowSelection = dynamic(
    light: Color(red: 0.878, green: 0.874, blue: 0.859),   // ≈ #E0DFDB
    dark:  Color.white.opacity(0.10)
  )

  /// Primary contained surface (cards, sheets, inline rows).
  /// Pure white in light so cards pop off the canvas; one step lighter than
  /// canvas in dark, carrying the same warm tint.
  static let cardSurface = dynamic(
    light: Color.white,                                     // #FFFFFF ≈ oklch(1 0 0)
    dark:  Color(red: 0.184, green: 0.184, blue: 0.176)    // #2F2F2D ≈ oklch(0.27 0.003 70)
  )

  /// Soft secondary surface (chips, muted backgrounds).
  static let mutedSurface = dynamic(
    light: Color(red: 0.941, green: 0.941, blue: 0.929),   // #F0F0ED ≈ oklch(0.95 0.002 100)
    dark:  Color(red: 0.216, green: 0.216, blue: 0.208)    // #373735 ≈ oklch(0.31 0.003 70)
  )

  // MARK: - Foregrounds

  /// Warm ink — primary text. Not pure black.
  static let inkPrimary = dynamic(
    light: Color(red: 0.220, green: 0.196, blue: 0.169),   // ≈ oklch(0.22 0.018 60)
    dark:  Color(red: 0.976, green: 0.976, blue: 0.976)    // ≈ oklch(0.985 0 0)
  )

  /// Muted text (meta, captions, sublabels).
  static let inkSecondary = dynamic(
    light: Color(red: 0.541, green: 0.514, blue: 0.471),   // ≈ oklch(0.54 0.014 65)
    dark:  Color(red: 0.620, green: 0.620, blue: 0.620)    // ≈ oklch(0.708 0 0)
  )

  /// Light gray for sidebar/list icons — softer than inkSecondary so glyphs
  /// recede behind row text (which itself sits at inkPrimary, much darker).
  static let iconMuted = dynamic(
    light: Color(red: 0.706, green: 0.682, blue: 0.643),   // ≈ oklch(0.72 0.012 70)
    dark:  Color(red: 0.510, green: 0.510, blue: 0.510)    // ≈ oklch(0.60 0 0)
  )

  // MARK: - Lines & selection

  static let border = dynamic(
    light: Color(red: 0.898, green: 0.898, blue: 0.886),   // #E5E5E2 ≈ oklch(0.91 0.002 100)
    dark:  Color.white.opacity(0.10)
  )

  static let divider = border

  /// Selection / hover highlight — soft accent tint.
  static let rowSelected = tasksAccentSoft

  // MARK: - Semantic

  /// Destructive (overdue, delete) — Septena brand-1 / red-500.
  static let overdueRed = Color(red: 0.937, green: 0.267, blue: 0.267)   // #ef4444

  // MARK: - Filter accents (subordinate to section accent — used only as
  // small icon tints in lists, not as fills)

  static let inboxAccent    = inkSecondary
  static let todayAccent    = tasksAccent              // today is the verb
  static let upcomingAccent = inkSecondary
  static let anytimeAccent  = inkSecondary
  static let logbookAccent  = inkSecondary

  // MARK: - Shape & spacing

  /// Major surface radius — cards, sheets, prominent containers.
  /// Bumped to match iOS 26 Liquid Glass aesthetic.
  static let cornerRadius: CGFloat = 18
  /// Minor radius — selection pills, chips, inline highlights.
  /// Tight enough to read as a tag, not a capsule.
  static let cornerRadiusSmall: CGFloat = 8

  #if os(macOS)
  // Tighter chrome on Mac — compact compact sidebar rows.
  static let hPadding: CGFloat = 12
  static let rowHeight: CGFloat = 24
  /// Total tap-target height for task rows. Larger than `rowHeight` because
  /// the row's selection pill fills this full band, making "gaps" between
  /// rows part of each row's own clickable area.
  static let rowTapHeight: CGFloat = 40
  static let sidebarRowHeight: CGFloat = 32
  static let sidebarSmartRowHeight: CGFloat = 30
  static let sidebarProjectRowHeight: CGFloat = 28
  static let sectionSpacing: CGFloat = 16
  static let sidebarIconSize: CGFloat = 17
  static let sidebarRowSpacing: CGFloat = 10
  static let sidebarTitleSize: CGFloat = 14
  static let sidebarTitleWeight: Font.Weight = .regular
  static let sidebarAreaTitleSize: CGFloat = 14
  /// Extra left whitespace on detail-column lists (compact breathing room).
  static let listLeadingInset: CGFloat = 32
  /// Inline edit/new-task card — match the closed row's vertical padding
  /// exactly so the title doesn't jump when entering / leaving edit mode.
  /// The card's *visual* breathing room comes from the action-row padding
  /// at the bottom + the rounded chrome, not extra top padding.
  static let cardVerticalPadding: CGFloat = 7
  /// Bottom-bar action icons (repeat / move / deadline) inside the inline card.
  static let cardActionIconSize: CGFloat = 14
  /// Inline section header (project / area title above a cluster of tasks).
  static let groupHeaderFontSize: CGFloat = 14
  #else
  static let hPadding: CGFloat = 20
  static let rowHeight: CGFloat = 36
  static let rowTapHeight: CGFloat = 52
  static let sidebarRowHeight: CGFloat = 48
  static let sidebarSmartRowHeight: CGFloat = 38
  static let sidebarProjectRowHeight: CGFloat = 36
  static let sectionSpacing: CGFloat = 24
  static let sidebarIconSize: CGFloat = 22
  static let sidebarRowSpacing: CGFloat = 14
  static let sidebarTitleSize: CGFloat = 17
  static let sidebarTitleWeight: Font.Weight = .medium
  static let sidebarAreaTitleSize: CGFloat = 17
  /// No extra inset on iOS — already in a single-column NavigationStack.
  static let listLeadingInset: CGFloat = 0
  static let cardVerticalPadding: CGFloat = 12
  static let cardActionIconSize: CGFloat = 18
  static let groupHeaderFontSize: CGFloat = 19
  #endif

  // MARK: - Helpers

  /// Wraps a (light, dark) pair in a UIKit-backed dynamic Color so SwiftUI
  /// honors the system trait collection without us threading colorScheme in.
  private static func dynamic(light: Color, dark: Color) -> Color {
    #if canImport(UIKit)
    return Color(UIColor { trait in
      trait.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
    })
    #else
    return light
    #endif
  }
}

// MARK: - Bundle-backed asset color with code fallback

private extension Color {
  init(_ name: String, bundle: Bundle?, fallback: Color) {
    #if canImport(UIKit)
    if UIColor(named: name, in: bundle, compatibleWith: nil) != nil {
      self = Color(name, bundle: bundle)
    } else {
      self = fallback
    }
    #else
    self = fallback
    #endif
  }
}

// MARK: - Typography

extension Font {
  #if os(macOS)
  // Mac runs a touch tighter — denser screens, mouse-pointer precision means
  // we don't need iOS-grade tap targets, and tighter type matches the reference design.
  static let septenaScreenTitle  = Font.system(size: 22, weight: .bold)
  static let septenaSectionTitle = Font.system(size: 16, weight: .bold)
  static let septenaCardTitle    = Font.system(size: 14, weight: .bold)
  static let septenaSidebarRow   = Font.system(size: 14, weight: .medium)
  static let septenaTaskTitle    = Font.system(size: 14, weight: .regular)
  static let septenaNotes        = Font.system(size: 14, weight: .regular)
  static let septenaButton       = Font.system(size: 13, weight: .semibold)
  static let septenaLabel        = Font.system(size: 11, weight: .medium)
  static let septenaMeta         = Font.system(size: 11, weight: .regular)
  static let septenaMetaStrong   = Font.system(size: 11, weight: .semibold)
  static let septenaBadge        = Font.system(size: 10, weight: .semibold)
  #else
  /// Titles use the system sans (SF Pro on iOS) — neutral and platform-native.
  static let septenaScreenTitle  = Font.system(size: 28, weight: .bold)
  static let septenaSectionTitle = Font.system(size: 20, weight: .bold)
  static let septenaCardTitle    = Font.system(size: 17, weight: .bold)

  /// Sans for UI controls and body.
  static let septenaSidebarRow   = Font.system(size: 16, weight: .medium)
  static let septenaTaskTitle    = Font.system(size: 17, weight: .regular)
  static let septenaNotes        = Font.system(size: 16, weight: .regular)
  static let septenaButton       = Font.system(size: 15, weight: .semibold)
  static let septenaLabel        = Font.system(size: 13, weight: .medium)

  /// Proportional sans for metadata, dates, counts, IDs — no monospace
  /// anywhere in the app per design preference.
  static let septenaMeta         = Font.system(size: 12, weight: .regular)
  static let septenaMetaStrong   = Font.system(size: 12, weight: .semibold)
  static let septenaBadge        = Font.system(size: 11, weight: .semibold)
  #endif
}
