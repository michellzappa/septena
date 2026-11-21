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

  /// Theme.septenaMetaStrong — the title line of an inline notice
  /// (`KitNoticeCell`), one weight step above `meta`.
  static var metaStrong: NSFont {
    .systemFont(ofSize: SeptenaTypeScale.size(.footnote), weight: .semibold)
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
  /// Theme.checkboxFill (done box / completion pulse) — dynamic platform accent,
  /// matching the standard macOS checkbox in both light and dark appearances.
  static var checkboxFill: NSColor { systemAccentColor }
  /// Theme.checkboxCheck — crisp white check over the accent fill.
  static let checkboxCheck: NSColor = .white
  /// Theme.todayAccent — the gold "promoted to Today" cue on the checkbox.
  static let todayAccent = NSColor(Theme.todayAccent)
  /// Theme.overdueRed — late deadlines, platform red.
  static let overdueRed: NSColor = .systemRed
  /// Theme.noticeWarning — the glyph of a warning notice (`KitNoticeCell`).
  static let noticeWarning = NSColor(Theme.noticeWarning)
  /// Light wash over the card surface for a warning notice's fill.
  /// Dynamic provider so `.withAlphaComponent` resolves per-appearance instead
  /// of freezing to light mode at static init time.
  static let noticeWarningWash = NSColor(name: nil) { appearance in
    var resolved = NSColor.systemOrange
    appearance.performAsCurrentDrawingAppearance {
      resolved = NSColor(Theme.noticeWarning).withAlphaComponent(0.12)
    }
    return resolved
  }
  /// Theme.inkPrimary.
  static let inkPrimary: NSColor = .labelColor
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
  /// Theme.mutedSurface — the row's list-membership chip fill, and the
  /// unset elective-pill fill on the composer rail.
  static let chipFill = NSColor(Theme.mutedSurface)
  /// Theme.inkPrimary.opacity(0.10) — filled/active elective pill. Matches
  /// SwiftUI's neutral `AttributePill` (a gray wash, never a black slab).
  /// Dynamic provider so `.labelColor.withAlphaComponent` adapts to dark mode.
  static let pillOnFill = NSColor(name: nil) { appearance in
    var resolved = NSColor.labelColor
    appearance.performAsCurrentDrawingAppearance {
      resolved = NSColor.labelColor.withAlphaComponent(0.10)
    }
    return resolved
  }
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
      // The accent where the keyboard is, gray elsewhere: the standard Mac
      // focus cue (Finder, Mail). Decided 2026-11-19.
      if emphasized {
        let alpha: CGFloat = isDark
          ? CGFloat(RegistryTokens.Selection.emphasizedAlphaDark)
          : CGFloat(RegistryTokens.Selection.emphasizedAlphaLight)
        return systemAccentColor.withAlphaComponent(alpha)
      }
      // A tint over the background, not an opaque gray: white 0.93 at 0.5
      // matched the sidebar material, so an unfocused sidebar selection was
      // invisible (2026-11-20). Black in light, white in dark, like Finder.
      return isDark
        ? NSColor(white: 1, alpha: CGFloat(RegistryTokens.Selection.unemphasizedAlphaDark))
        : NSColor(white: 0, alpha: CGFloat(RegistryTokens.Selection.unemphasizedAlphaLight))
    }
  }

  /// User's System Settings accent, bypassing the app's AccentColor asset
  /// (adaptive ink). `AppleAccentColor` is the documented preference key;
  /// `nil` means Blue (the system default). Do NOT call
  /// `NSColor.controlAccentColor` here — with a Global Accent Color Name set
  /// it returns the asset ink, and reading it can also break SwiftUI's
  /// accent resolution (FB13688723).
  private static var systemAccentColor: NSColor { Theme.systemAccentNSColor }
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
  static let marginFraction: CGFloat = CGFloat(RegistryTokens.DesktopColumn.marginFraction)
  static let minInset: CGFloat = CGFloat(RegistryTokens.DesktopColumn.minInset)
  static let maxInset: CGFloat = CGFloat(RegistryTokens.DesktopColumn.maxInset)
  /// Top/bottom `NSScrollView.contentInsets` — fixed so the list doesn't
  /// grow a taller header band as the window widens (sides still flex).
  /// Generous on purpose (Things-style): the first card sits well clear of
  /// the title bar and the last one clears the toolbar.
  static let verticalInset: CGFloat = CGFloat(RegistryTokens.DesktopColumn.verticalInset)

  /// Clear space between the BOTTOM of the title bar and the first row. The
  /// bar now carries its own height (a unified toolbar), so the top gap is
  /// measured from the bar rather than from the window edge — `verticalInset`
  /// stays the bottom-of-list breathing room, which has no bar under it.
  static let titleBarGap: CGFloat = CGFloat(RegistryTokens.DesktopColumn.titleBarGap)

  // MARK: Leading glyph column
  //
  // One vertical axis for every leading mark in the list: a task's checkbox,
  // a group header's sun / tray / emoji / project ring, and the page title's
  // glyph all share the SAME horizontal CENTER. Header glyphs are centered on
  // that axis (not left-aligned to the column edge), so a glyph wider than the
  // checkbox grows to the left of the text column — a negative leading margin
  // by derivation, never by a hand-tuned offset. All values are measured from
  // the width-dependent content inset (`inset(for:)`).

  /// Content inset → a row's leading control (checkbox, event dot, ring).
  static let rowLeadingPad: CGFloat = 6

  /// Content inset → the CENTER of a row's checkbox. Every leading glyph
  /// centers here. `KitCheckboxView` draws its box centered in its tap area.
  static var leadingGlyphCenterX: CGFloat { rowLeadingPad + KitCheckboxView.tapSize / 2 }

  /// Content inset → a group header's title. Unchanged by the glyph axis
  /// (the old icon-column arithmetic: 4 + 22 + 6), so header titles do not
  /// move when their glyphs re-center.
  static let headerTitleLeading: CGFloat = 32

  /// Content inset → the page title's dropdown button. The borderless
  /// `NSButton` carries its own content inset, so its frame sits left of
  /// `headerTitleLeading` to keep its text where it read before (4 + 18 + 6).
  static let screenTitleLeading: CGFloat = 28

  /// The left/right margin for a row or header at the given container width.
  static func inset(for width: CGFloat) -> CGFloat {
    min(maxInset, max(minInset, width * marginFraction))
  }
}
#endif
