import SwiftUI

// MARK: - The app's one selection / emphasis language
//
// THE RULE (DesignSpec §4 + the "one selection language per surface" convention
// in CLAUDE.md): there is exactly ONE visual treatment for "this thing is
// selected / active / current" on any surface, and it is defined here or in
// `Theme`. A new interaction that needs to emphasize something REUSES one of
// these; it never invents a second style.
//
// There are exactly three emphasis shapes in the app, by container:
//
//  1. ROW IN A LIST  → `Theme.listSelectionFill` painted full-bleed behind the
//     row via `listRowBackground` (`SelectableListRowBackground` /
//     `.selectableListRow(tag:isSelected:)` in PlatformShims). Neutral gray,
//     never a hue. Native platform rings are suppressed with
//     `.septenaSuppressListCellSelection()`.
//
//  2. ROW IN A FLOATING PALETTE OR SOURCE LIST → the same
//     `Theme.listSelectionFill`, drawn as an INSET continuous rounded rect
//     (`InsetSelectionBackground`). This is the native macOS inset-selection
//     shape. It is the *only* sanctioned inset highlight — used by the macOS
//     Tasks sidebar and the ⌘K quick-find palette.
//
//  3. CHIP / SEGMENT / FILTER  → `SelectableChip` (below). A tinted wash plus
//     tinted ink, NOT a saturated slab with white text.
//
// WHY NOT A SOLID ACCENT FILL WITH WHITE INK: the app accent is deliberately
// monochrome adaptive label ink — black in light mode, WHITE in dark mode (see
// `SectionTheme.accent`). Outside a `SectionDrawer` there is no section hue in
// scope, so `Color.accentColor` resolves to that ink. A chip painted
// `.background(Color.accentColor).foregroundStyle(.white)` is therefore white
// text on a white fill in dark mode — invisible. The wash-plus-matching-ink
// form below is contrast-safe for ANY tint in BOTH appearances, because the
// fill is a low-opacity derivative of the ink it carries.

// MARK: - Inset selection background

/// `Theme.listSelectionFill` drawn as an inset continuous rounded rect — the
/// native macOS inset-selection shape.
///
/// Use for rows in a floating palette or a source list, where the highlight
/// should read as a capsule inside the container's padding rather than a
/// full-bleed band. For ordinary list rows use `SelectableListRowBackground`
/// (full-bleed) instead — an inset highlight on a plain list row reads as a
/// chip floating *on top of* the row rather than the row itself being selected.
struct InsetSelectionBackground: View {
  let isSelected: Bool
  var cornerRadius: CGFloat = Theme.cornerRadiusSmall
  var horizontalInset: CGFloat = Theme.Spacing.sm
  var verticalInset: CGFloat = 1

  var body: some View {
    if isSelected {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(Theme.listSelectionFill)
        .padding(.horizontal, horizontalInset)
        .padding(.vertical, verticalInset)
    } else {
      Color.clear
    }
  }
}

// MARK: - Selectable chip

/// Shape of a `SelectableChip`. Capsule is the default; `.roundedRect` exists
/// for grid-packed segments (the training effort-rung picker) where a capsule
/// would read as a pill floating in a cell.
enum SelectableChipShape {
  case capsule
  case roundedRect

  @ViewBuilder
  func fill(_ color: Color) -> some View {
    switch self {
    case .capsule:
      Capsule().fill(color)
    case .roundedRect:
      RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
        .fill(color)
    }
  }
}

/// Canonical fill + ink for a selectable chip, exposed separately so a call
/// site with bespoke layout (a multi-line segment, a chip with its own trailing
/// badge) can wear the same treatment without re-deriving the colors.
enum SelectableChipStyle {
  /// Selected chips carry a low-opacity wash of their own tint. Contrast-safe
  /// in both appearances for any hue *including* the monochrome app accent,
  /// because ink and fill share a hue and only differ in opacity.
  static let selectedFillOpacity: Double = 0.22

  static func fill(tint: Color, isSelected: Bool) -> Color {
    isSelected ? tint.opacity(selectedFillOpacity) : Theme.mutedSurface
  }

  static func ink(tint: Color, isSelected: Bool) -> Color {
    isSelected ? tint : Theme.inkSecondary
  }
}

/// The app's one filter / segment / toggle chip.
///
/// Selected = a wash of `tint` behind `tint` ink, semibold. Unselected =
/// `Theme.mutedSurface` behind `Theme.inkSecondary`, regular. Do not hand-roll
/// a chip; extend this if a surface needs an axis it doesn't have.
struct SelectableChip<Label: View>: View {
  let isSelected: Bool
  var tint: Color = .accentColor
  var shape: SelectableChipShape = .capsule
  /// Fill the available width — for chips laid out in an even grid.
  var fillsWidth: Bool = false
  let action: () -> Void
  @ViewBuilder let label: () -> Label

  var body: some View {
    Button(action: action) {
      label()
        .font(.septenaChip(isSelected: isSelected))
        .foregroundStyle(SelectableChipStyle.ink(tint: tint, isSelected: isSelected))
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs + 2)
        .frame(maxWidth: fillsWidth ? .infinity : nil)
        .background(shape.fill(SelectableChipStyle.fill(tint: tint, isSelected: isSelected)))
        .contentShape(shape == .capsule ? AnyShape(Capsule())
                                        : AnyShape(RoundedRectangle(
                                            cornerRadius: Theme.cornerRadiusSmall,
                                            style: .continuous)))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

extension SelectableChip where Label == Text {
  /// Text-only chip — the common case.
  init(_ title: String,
       isSelected: Bool,
       tint: Color = .accentColor,
       shape: SelectableChipShape = .capsule,
       fillsWidth: Bool = false,
       action: @escaping () -> Void) {
    self.isSelected = isSelected
    self.tint = tint
    self.shape = shape
    self.fillsWidth = fillsWidth
    self.action = action
    self.label = { Text(title) }
  }
}
