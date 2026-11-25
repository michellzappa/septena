import SwiftUI

// GroupedListSection — shared section chrome for the Next and Coach home tabs
// (and any grouped List that wants the same header rhythm). Title typography,
// optional trailing quick-add "+", and the macOS scroll-in-content header
// pattern live here so the two tabs can't drift.

// MARK: - Typography

extension View {
  /// Section/group header title — `.septenaSectionTitle` / title2 at
  /// `Theme.groupHeaderFontSize` (17pt mac / 20pt iOS).
  func sectionGroupHeaderTitleStyle() -> some View {
    scaledFont(size: Theme.groupHeaderFontSize, weight: .semibold,
               relativeTo: .title2)
      .foregroundStyle(Theme.inkPrimary)
  }
}

// MARK: - Section wrapper

// MARK: - Quick add

/// Trailing quick-add control for a section or group header.
struct HeaderQuickAddButton: View {
  let accessibilityLabel: String
  let action: () -> Void
  /// Section accent — tints the glyph so the control reads as a live action.
  var accent: Color? = nil
  /// `.listSectionHeader` — borderless glyph inside a grouped `Section` header.
  /// `.scrollGroupHeader` — plain glyph + pointer hover (Tasks area / project).
  var placement: Placement = .listSectionHeader
  var hapticOnTap: Bool = false
  var keyboardShortcut: KeyEquivalent? = nil
  var keyboardModifiers: EventModifiers = .command

  enum Placement {
    case listSectionHeader
    case scrollGroupHeader
  }

  var body: some View {
    Group {
      if let keyboardShortcut {
        button
          .keyboardShortcut(keyboardShortcut, modifiers: keyboardModifiers)
      } else {
        button
      }
    }
  }

  @ViewBuilder
  private var button: some View {
    let control = Button {
      if hapticOnTap { Haptics.press() }
      action()
    } label: {
      glyph
    }
    .accessibilityLabel(accessibilityLabel)

    switch placement {
    case .listSectionHeader:
      if let accent {
        control
          .buttonStyle(.borderless)
          .textCase(nil)
          .tint(accent)
      } else {
        control
          .buttonStyle(.borderless)
          .textCase(nil)
      }
    case .scrollGroupHeader:
      control
        .buttonStyle(.plain)
        .inlineHover(capsule: true)
    }
  }

  private var glyph: some View {
    Image(systemName: "plus.circle")
      .scaledFont(size: Theme.headerQuickAddGlyphSize, weight: .semibold,
                  relativeTo: .title2)
      .foregroundStyle(accent ?? Theme.inkSecondary)
      .contentShape(Circle())
  }
}
