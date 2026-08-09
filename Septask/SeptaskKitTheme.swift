#if os(macOS)
import AppKit
import SwiftUI

// AppKit access point for the design system's tokens — the ONE place kit
// code reads fonts/colors from, so nothing else in the AppKit shell hardcodes
// a literal (mirror of the "Theme is the access point" rule on the SwiftUI
// side; see docs/DesignSpec.md).
//
// Fonts come from the shared type ladder (`SeptenaTypeScale`), which honors
// the user's text-size setting — AppKit text scales with the rest of the app.
// Colors: the Theme tokens' macOS branches are already system semantic
// NSColors (see Theme.swift), so this bridge names the same semantic color
// each token wraps rather than round-tripping through SwiftUI.Color — each
// line says which token it mirrors, and a token change means one edit here.
@MainActor
enum SeptaskKitTheme {

  // MARK: - Type (mirrors Theme.septena* fonts)

  /// Theme.septenaTaskTitle — body rung, +1 for the AppKit shell's row
  /// density (its rows have more air than the SwiftUI list's, so the same
  /// size read small in an early pass).
  static var taskTitle: NSFont { .systemFont(ofSize: SeptenaTypeScale.size(.body) + 1) }

  /// Sidebar navigation labels — one shared semibold weight for smart lists,
  /// areas, and projects. This keeps structure legible without the heavy bold
  /// treatment areas previously used on their own.
  static var sidebarTitle: NSFont {
    .systemFont(ofSize: SeptenaTypeScale.size(.body) + 1, weight: .semibold)
  }

  /// Theme.septenaMeta — footnote rung, monospaced digits (dates align).
  static var meta: NSFont {
    .monospacedDigitSystemFont(ofSize: SeptenaTypeScale.size(.footnote), weight: .regular)
  }

  /// Project-heading rows — caption rung, semibold (matches the SwiftUI
  /// heading treatment in project lists).
  static var heading: NSFont {
    .systemFont(ofSize: SeptenaTypeScale.size(.caption1), weight: .semibold)
  }

  /// Theme.septenaCardTitle — the group header above a run of rows.
  static var groupTitle: NSFont {
    .systemFont(ofSize: Theme.groupHeaderFontSize * FontScale.shared.factor,
                weight: .semibold)
  }

  /// Theme.septenaBadge — the row's list-membership chip.
  static var chip: NSFont {
    .systemFont(ofSize: SeptenaTypeScale.size(.caption2), weight: .semibold)
  }

  /// Single-line row height derived from the body rung so rows grow with the
  /// user's text-size setting instead of clipping. Titles truncate; they do
  /// not wrap and grow the row.
  static var rowHeight: CGFloat { SeptenaTypeScale.size(.body) + 21 }

  // MARK: - Color

  /// Theme.checkboxStroke (open box).
  static let checkboxStroke: NSColor = .secondaryLabelColor
  /// Theme.checkboxFill (done box) — same family, slightly heavier.
  static let checkboxFill: NSColor = .labelColor.withAlphaComponent(0.78)
  /// Theme.todayAccent — the gold "promoted to Today" cue on the checkbox.
  static let todayAccent = NSColor(Theme.todayAccent)
  /// Theme.overdueRed — late deadlines, platform red.
  static let overdueRed: NSColor = .systemRed
  /// Theme.inkSecondary.
  static let inkSecondary: NSColor = .secondaryLabelColor
  /// Theme.iconMuted — receding glyphs/meta (Reminders' non-tinted metadata).
  static let iconMuted: NSColor = .tertiaryLabelColor

  // Surfaces. These Theme tokens are hand-built Colors (not straight system
  // semantics), so they bridge rather than name an NSColor — one source of
  // truth stays `Theme`.

  /// Theme.groupedBackground — the page behind the cards (`listCanvasFill` in
  /// the SwiftUI list). NOT `Theme.paperBackground` — paper is near-white and
  /// reads the same as the cards, so cards stop reading as lifted.
  static let pageBackground = NSColor(Theme.groupedBackground)
  /// Theme.cardSurface — the card a run of rows sits on.
  static let cardSurface = NSColor(Theme.cardSurface)
  /// Theme.mutedSurface — the row's list-membership chip fill.
  static let chipFill = NSColor(Theme.mutedSurface)
  /// Theme.sidebarBackground — the source list's backing.
  static let sidebarBackground = NSColor(Theme.sidebarBackground)

  /// Theme.listSelectionFill — the app's ONE selection fill, on every
  /// surface, in both focus states. NOT the emphasized system color: that
  /// follows the accent, which here is adaptive ink, so it would paint
  /// selected rows solid black in light mode.
  ///
  /// One SHAPE and one HUE always (never a second selection language — see
  /// `docs/DesignSpec.md` §4.5) — but `emphasized` (mirrors
  /// `NSTableRowView.isEmphasized`, AppKit's own "this row's table is the
  /// window's first responder AND the window is key" signal, no manual
  /// tracking needed) fades the SAME fill rather than swapping it, so a
  /// selection that lost keyboard focus — Tab moved to the other pane, or the
  /// window went inactive — reads as "still selected, not what you'd act on
  /// right now" instead of looking identical to the live one.
  ///
  /// Bumped noticeably lighter than the raw system
  /// `.unemphasizedSelectedContentBackgroundColor` after visual review — it
  /// read too heavy next to the shell's light gray page and white cards. This
  /// intentionally diverges from `Theme.listSelectionFill`'s SwiftUI value
  /// (same raw system token); worth raising upstream if it holds up.
  static func listSelectionFill(emphasized: Bool) -> NSColor {
    NSColor(name: nil) { appearance in
      let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
      let white: CGFloat = isDark ? 0.24 : 0.93
      return NSColor(white: white, alpha: emphasized ? 1 : 0.5)
    }
  }
}

/// Content column geometry — Things-style: rows don't stretch edge-to-edge on
/// a wide window, they float in a centered column with proportional gutters
/// rather than a fixed pixel cap. The margin is ~`marginFraction` of the
/// container's width on each side, clamped to `[minInset, maxInset]` — narrow
/// windows keep a small fixed gutter (the fraction alone would be too tight
/// to read), very wide windows stop the column from thinning out forever.
@MainActor
enum SeptaskKitLayout {
  static let marginFraction: CGFloat = 0.10
  static let minInset: CGFloat = 10
  static let maxInset: CGFloat = 220

  /// The left/right margin for a row or header at the given container width.
  static func inset(for width: CGFloat) -> CGFloat {
    min(maxInset, max(minInset, width * marginFraction))
  }
}
#endif
