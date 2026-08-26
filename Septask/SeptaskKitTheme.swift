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

  /// Project section headings — semibold at SwiftUI's
  /// `sectionGroupHeaderTitleStyle()` rung (`Theme.groupHeaderFontSize`).
  /// READ FROM THE TOKEN, never hardcoded: this said `17` while the token is
  /// 15 on macOS, so AppKit headers outran the SwiftUI ones and sat 3pt above
  /// the 14pt task title — the token's own comment is "keep them visually
  /// subordinate to the task text", which 17 was not.
  static var heading: NSFont {
    .systemFont(ofSize: Theme.groupHeaderFontSize * FontScale.shared.factor,
                weight: .semibold)
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

  /// Task notes body — two rungs above the old subheadline notes face so
  /// prose matches `TaskMarkdownNotesEditor` (SwiftUI) at the body size.
  static var notesFontSize: CGFloat { SeptenaTypeScale.size(.body) }

  /// Single-line row height derived from the body rung so rows grow with the
  /// user's text-size setting instead of clipping. Titles truncate; they do
  /// not wrap and grow the row.
  static var rowHeight: CGFloat { SeptenaTypeScale.size(.body) + 21 }

  // MARK: - Color

  /// Theme.checkboxStroke (open box).
  static let checkboxStroke: NSColor = .secondaryLabelColor
  /// Theme.checkboxFill (done box) — same family, slightly heavier.
  static let checkboxFill: NSColor = .labelColor.withAlphaComponent(0.78)
  /// Theme.checkboxCheck — the check glyph inside a done box. NOT white:
  /// `checkboxFill` is label ink, which is near-white in dark mode, so a white
  /// check vanished the instant you ticked a row. This flips with the
  /// appearance alongside the fill.
  static let checkboxCheck: NSColor = .textBackgroundColor
  /// Theme.todayAccent — the gold "promoted to Today" cue on the checkbox.
  static let todayAccent = NSColor(Theme.todayAccent)
  /// Theme.overdueRed — late deadlines, platform red.
  static let overdueRed: NSColor = .systemRed
  /// Theme.inkPrimary.
  static let inkPrimary: NSColor = .labelColor
  /// Theme.inkSecondary.
  static let inkSecondary: NSColor = .secondaryLabelColor
  /// Theme.iconMuted — receding glyphs/meta (Reminders' non-tinted metadata).
  static let iconMuted: NSColor = .tertiaryLabelColor
  /// Color.claudeAccent — the ONE place Claude's own color appears in the
  /// shell (the reconnect row). A brand color, not a semantic one, so it
  /// bridges the shared token rather than naming a system color.
  static let claudeAccent = NSColor(Color.claudeAccent)

  // Surfaces. These Theme tokens are hand-built Colors (not straight system
  // semantics), so they bridge rather than name an NSColor — one source of
  // truth stays `Theme`.

  /// Theme.groupedBackground — the page behind the cards (`listCanvasFill` in
  /// the SwiftUI list). NOT `Theme.paperBackground` — paper is near-white and
  /// reads the same as the cards, so cards stop reading as lifted.
  static let pageBackground = NSColor(Theme.groupedBackground)
  /// Theme.cardSurface — the card a run of rows sits on.
  static let cardSurface = NSColor(Theme.cardSurface)
  /// Theme.mutedSurface — the row's list-membership chip fill, and the
  /// unset elective-pill fill on the composer rail.
  static let chipFill = NSColor(Theme.mutedSurface)
  /// Theme.inkPrimary.opacity(0.10) — filled/active elective pill. Matches
  /// SwiftUI's neutral `AttributePill` (a gray wash, never a black slab).
  static let pillOnFill = NSColor.labelColor.withAlphaComponent(0.10)
  /// Theme.sidebarBackground — the source list's backing.
  static let sidebarBackground = NSColor(Theme.sidebarBackground)

  /// Selection fill for AppKit rows. Same SHAPE everywhere (full-bleed card /
  /// inset sidebar pill — never a second language), but the *active*
  /// (`emphasized`) state follows the user's macOS System Settings accent as
  /// a wash — Finder/Mail/Notes idiom — while unemphasized stays the neutral
  /// gray so a selection that lost keyboard focus (Tab to the other pane, or
  /// the window went inactive) still reads as selected without looking live.
  ///
  /// Cannot use `.selectedContentBackgroundColor` / `NSColor.controlAccentColor`:
  /// both follow the **app** AccentColor, which here is adaptive INK (black in
  /// light / white in dark), so the "standard" treatment paints a solid black
  /// bar. We resolve the System Settings preference via `AppleAccentColor`
  /// instead and paint a low-opacity wash so row text can stay normal ink
  /// (`interiorBackgroundStyle = .normal`) — same wash-plus-ink pattern as
  /// `SelectableChip`. Unemphasized still diverges lighter than the raw
  /// `.unemphasizedSelectedContentBackgroundColor` so it doesn't fight the
  /// shell's light gray page / white cards.
  static func listSelectionFill(emphasized: Bool) -> NSColor {
    NSColor(name: nil) { appearance in
      let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
      if emphasized {
        // Wash opacity calibrated so the accent reads clearly on white cards
        // (light) and dark surfaces without needing white text.
        let alpha: CGFloat = isDark ? 0.34 : 0.22
        return systemAccentColor.withAlphaComponent(alpha)
      }
      let white: CGFloat = isDark ? 0.24 : 0.93
      return NSColor(white: white, alpha: 0.5)
    }
  }

  /// User's System Settings accent, bypassing the app's AccentColor asset
  /// (adaptive ink). `AppleAccentColor` is the documented preference key;
  /// `nil` means Blue (the system default). Do NOT call
  /// `NSColor.controlAccentColor` here — with a Global Accent Color Name set
  /// it returns the asset ink, and reading it can also break SwiftUI's
  /// accent resolution (FB13688723).
  private static var systemAccentColor: NSColor {
    switch UserDefaults.standard.object(forKey: "AppleAccentColor") as? Int {
    case -1: return .systemGray      // Graphite
    case 0:  return .systemRed
    case 1:  return .systemOrange
    case 2:  return .systemYellow
    case 3:  return .systemGreen
    case 4:  return .systemPurple
    case 5:  return .systemPink
    default: return .systemBlue      // nil / unknown → Blue
    }
  }
}

/// Content column geometry — Things-style: rows don't stretch edge-to-edge on
/// a wide window, they float in a centered column with proportional left/right
/// gutters rather than a fixed pixel cap. The horizontal margin is
/// ~`marginFraction` of the container's width on each side, clamped to
/// `[minInset, maxInset]`. Top/bottom scroll breathing room is a fixed
/// `verticalInset` — tying it to the side margin made the header/footer gap
/// swell on wide windows and read as broken.
@MainActor
enum SeptaskKitLayout {
  static let marginFraction: CGFloat = 0.10
  static let minInset: CGFloat = 10
  static let maxInset: CGFloat = 220
  /// Top/bottom `NSScrollView.contentInsets` — fixed so the list doesn't
  /// grow a taller header band as the window widens (sides still flex).
  /// Generous on purpose (Things-style): the first card sits well clear of
  /// the title bar and the last one clears the toolbar.
  static let verticalInset: CGFloat = 48

  /// Clear space between the BOTTOM of the title bar and the first row. The
  /// bar now carries its own height (a unified toolbar), so the top gap is
  /// measured from the bar rather than from the window edge — `verticalInset`
  /// stays the bottom-of-list breathing room, which has no bar under it.
  static let titleBarGap: CGFloat = 20

  /// The left/right margin for a row or header at the given container width.
  static func inset(for width: CGFloat) -> CGFloat {
    min(maxInset, max(minInset, width * marginFraction))
  }
}
#endif
