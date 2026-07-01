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

/// Plain grouped-list section title — "Tasks Today", "Coaches", "Suggested", …
@ViewBuilder
func sectionGroupHeader(_ title: String) -> some View {
  Text(title).sectionGroupHeaderTitleStyle()
}

// MARK: - Section wrapper

/// Header chrome for a grouped `List` section. macOS parks the header in the
/// scroll content (Tasks rhythm); iOS uses the native `Section` header slot.
@ViewBuilder
func groupedListSectionHeader<Content: View>(@ViewBuilder content: () -> Content) -> some View {
  #if os(macOS)
  content()
    .textCase(nil)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.leading, TaskCardMetrics.headerLeading)
    .padding(.trailing, TaskCardMetrics.margin)
    .padding(.top, 24)
    .padding(.bottom, 8)
  #else
  content()
    .textCase(nil)
  #endif
}

/// Grouped `List` section without a footer — Next open blocks, suggestions, …
@ViewBuilder
func groupedListSection<Header: View, Content: View>(
  @ViewBuilder header: () -> Header,
  @ViewBuilder content: () -> Content
) -> some View {
  #if os(macOS)
  Section {
    groupedListSectionHeader(content: header)
      .listRowInsets(EdgeInsets())
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
      .selectionDisabled()
    content()
  }
  #else
  Section {
    content()
  } header: {
    groupedListSectionHeader(content: header)
  }
  #endif
}

/// Grouped `List` section with explanatory footer copy — Coach bands.
@ViewBuilder
func groupedListSection<Header: View, Footer: View, Content: View>(
  @ViewBuilder header: () -> Header,
  @ViewBuilder footer: () -> Footer,
  @ViewBuilder content: () -> Content
) -> some View {
  #if os(macOS)
  Section {
    groupedListSectionHeader(content: header)
      .listRowInsets(EdgeInsets())
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
      .selectionDisabled()
    content()
  } footer: {
    footer()
  }
  #else
  Section {
    content()
  } header: {
    groupedListSectionHeader(content: header)
  } footer: {
    footer()
  }
  #endif
}

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
      if hapticOnTap { Haptics.tick() }
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

/// Grouped-list section title with an optional trailing quick-add "+".
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
        sectionGroupHeader(title)
        Spacer()
        HeaderQuickAddButton(accessibilityLabel: addAccessibilityLabel,
                             action: onAdd,
                             accent: accent,
                             placement: .listSectionHeader,
                             keyboardShortcut: keyboardShortcut,
                             keyboardModifiers: keyboardModifiers)
      }
    } else {
      sectionGroupHeader(title)
    }
  }
}
