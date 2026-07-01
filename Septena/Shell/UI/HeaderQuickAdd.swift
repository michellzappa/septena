import SwiftUI

// HeaderQuickAdd — shared trailing "+" for section/group headers above row
// lists (Next "Tasks Today", Coach "Goals", Tasks area/project clusters).
// One `plus.circle` glyph family; two placements for where the header lives.

// MARK: - Plus button

/// Trailing quick-add control for a section or group header.
struct HeaderQuickAddButton: View {
  let accessibilityLabel: String
  let action: () -> Void
  /// Section accent — tints the glyph so the control reads as a live action.
  var accent: Color? = nil
  /// `.listSectionHeader` — borderless footnote glyph inside a grouped `Section`
  /// header (Next / Coach). `.scrollGroupHeader` — plain scaled glyph with pointer
  /// hover for in-scroll cluster headers (Tasks area / project).
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
      if hapticOnTap { Haptics.tick() }
      action()
    } label: {
      glyph
    }
    .accessibilityLabel(accessibilityLabel)

    switch placement {
    case .listSectionHeader:
      control
        .buttonStyle(.borderless)
        .textCase(nil)
        .tint(accent)
    case .scrollGroupHeader:
      control
        .buttonStyle(.plain)
        .inlineHover(capsule: true)
    }
  }

  @ViewBuilder
  private var glyph: some View {
    switch placement {
    case .listSectionHeader:
      Image(systemName: "plus.circle")
        .font(.footnote.weight(.semibold))
    case .scrollGroupHeader:
      Image(systemName: "plus.circle")
        .scaledFont(size: 16, weight: .semibold)
        .foregroundStyle(accent ?? Theme.inkSecondary)
        .contentShape(Circle())
    }
  }
}

// MARK: - Section title row

/// Standard grouped-list section header: title on the left, optional trailing "+".
/// Compose inside `nextSection` / `coachSection` headers (or any `Section`).
struct ListSectionHeaderTitle: View {
  let title: String
  var onAdd: (() -> Void)? = nil
  var addAccessibilityLabel: String = "Add"
  var accent: Color? = nil
  var keyboardShortcut: KeyEquivalent? = nil
  var keyboardModifiers: EventModifiers = .command

  var body: some View {
    if let onAdd {
      HStack {
        Text(title)
        Spacer()
        HeaderQuickAddButton(accessibilityLabel: addAccessibilityLabel,
                             action: onAdd,
                             accent: accent,
                             placement: .listSectionHeader,
                             keyboardShortcut: keyboardShortcut,
                             keyboardModifiers: keyboardModifiers)
      }
    } else {
      Text(title)
    }
  }
}
