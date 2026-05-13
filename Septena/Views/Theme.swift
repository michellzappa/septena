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

  // MARK: - Smart-list accents (Things-style per-row icon hues)

  static let inboxBlue       = Color(red: 0.20, green: 0.45, blue: 0.95)   // #3373F2
  static let todayYellow     = Color(red: 0.96, green: 0.74, blue: 0.18)   // #F4BD2E
  static let nextPurple      = Color(red: 0.56, green: 0.40, blue: 0.85)   // #8F66D9
  static let upcomingRed     = Color(red: 0.93, green: 0.30, blue: 0.30)   // #ED4D4D
  static let unscheduledTeal = Color(red: 0.16, green: 0.66, blue: 0.62)   // #29A89D
  static let logbookGreen    = Color(red: 0.30, green: 0.70, blue: 0.40)   // #4DB366

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

  static let cornerRadius: CGFloat = 10
  static let cornerRadiusSmall: CGFloat = 6
  static let hPadding: CGFloat = 20
  static let rowHeight: CGFloat = 44
  static let sidebarRowHeight: CGFloat = 48
  static let sectionSpacing: CGFloat = 24

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
  /// Titles use the system sans (SF Pro on iOS) — neutral and platform-native.
  static let septenaScreenTitle  = Font.system(size: 30, weight: .bold)
  static let septenaSectionTitle = Font.system(size: 20, weight: .bold)
  static let septenaCardTitle    = Font.system(size: 17, weight: .bold)

  /// Sans for UI controls and body.
  static let septenaSidebarRow   = Font.system(size: 16, weight: .medium)
  static let septenaTaskTitle    = Font.system(size: 16, weight: .regular)
  static let septenaNotes        = Font.system(size: 14, weight: .regular)
  static let septenaButton       = Font.system(size: 15, weight: .semibold)
  static let septenaLabel        = Font.system(size: 13, weight: .medium)

  /// Mono with tabular figures for numerics, dates, counts, IDs.
  static let septenaMeta         = Font.system(size: 12, weight: .regular, design: .monospaced)
  static let septenaMetaStrong   = Font.system(size: 12, weight: .semibold, design: .monospaced)
  static let septenaBadge        = Font.system(size: 11, weight: .semibold, design: .monospaced)
}
