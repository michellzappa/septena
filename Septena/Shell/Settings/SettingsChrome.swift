// Settings-root chrome shared by both shells (docs/SEPTASK.md): the disc
// tile for About rows, the top luminance wash, and the root-row accent
// palette — extracted from SettingsView.swift so Septask's Settings can
// mirror the full app's look without compiling its destination graph.

import SwiftUI

/// The seven root-row tints, in row order — Septena's section rainbow.
enum SettingsAccentPalette {
  static let colors: [Color] = [
    parseHexColor("#ef4444"), // red
    parseHexColor("#f97316"), // orange
    parseHexColor("#eab308"), // yellow
    parseHexColor("#22c55e"), // green
    parseHexColor("#06b6d4"), // cyan
    parseHexColor("#3b82f6"), // blue
    parseHexColor("#8b5cf6"), // purple
  ]
}

/// The Settings-row and About-pane icon: renders the user's active Septena
/// Upright Compass app icon (`AppearancePreferences.shared`) at any size,
/// adapting to Light/Dark appearance (while Stealth stays dark).
struct SeptenaDiscTile: View {
  var size: CGFloat = 29
  private let appearance = AppearancePreferences.shared
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let isDark = colorScheme == .dark
    SeptenaCompassIconView(
      finish: appearance.resolvedAppIconFinish,
      color: appearance.resolvedAppIconColor,
      isDarkOS: isDark
    )
    .frame(width: size, height: size)
    .shadow(
      color: Color.black.opacity(size >= 40 ? (isDark ? 0.42 : 0.16) : 0.0),
      radius: size >= 40 ? 8 : 0,
      y: size >= 40 ? 4 : 0
    )
  }
}

/// Soft top-down luminance wash behind the Settings list — the same
/// subtle lift Apple's Settings.app draws under the title. A near-white
/// (or, in dark mode, a faint white) band fades into the grouped
/// background over the first ~300pt, so the top of the list reads a touch
/// brighter without changing the rest of the surface.
struct SettingsTopGradient: View {
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    ZStack(alignment: .top) {
      Theme.groupedBackground
      LinearGradient(
        colors: [scheme == .dark ? Color.white.opacity(0.06)
                                 : Color.white.opacity(0.9),
                 .clear],
        startPoint: .top, endPoint: .bottom
      )
      .frame(height: 300)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .ignoresSafeArea()
  }
}

#if os(macOS)
extension View {
  /// One row of a macOS Settings sidebar (`List(selection:)` in a
  /// `NavigationSplitView`), shared by Septena and Septask. The native
  /// selection would paint the app accent, which is the black/white ink, as a
  /// solid bar with inverted text. So the native fill is suppressed and the
  /// selected row wears the app's canonical inset selection instead
  /// (`SidebarMacRowBackground`, the same token as the Tasks sidebar), with
  /// normal ink text. One selection language, see `SelectionLanguage.swift`.
  func settingsSidebarRow<Tag: Hashable>(_ tag: Tag, selection: Tag?) -> some View {
    self
      .tag(tag)
      .listRowBackground(SidebarMacRowBackground(isSelected: selection == tag))
      .septenaSuppressListCellSelection()
      // The list still treats the row as selected and flips its text to
      // white for a prominent background. The selection here is a light
      // accent wash, so the text keeps its normal ink.
      .environment(\.backgroundProminence, .standard)
  }
}
#endif
