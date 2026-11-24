// Settings-root chrome shared by both shells (docs/SEPTASK.md): the icon
// tile for About rows and the top luminance wash — extracted from
// SettingsView.swift so Septask's Settings can mirror the full app's look
// without compiling its destination graph.

import SwiftUI

/// The Settings-row and About-pane icon: renders the user's active Septena
/// Upright Compass app icon (`AppearancePreferences.shared`) at any size,
/// adapting to Light/Dark appearance.
struct SeptenaIconTile: View {
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
