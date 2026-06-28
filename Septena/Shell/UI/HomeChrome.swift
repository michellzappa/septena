import SwiftUI

// The shared toolbar overflow ("···") glyph. The page-chrome system
// (SeptenaPage.swift / `.pageChrome`) owns how the three slots — gear / "···" /
// "+" — are placed and hoisted; this is just the one canonical "···" label so
// every overflow menu across the app reads the same and the glyph lives in
// exactly one place.
//
// History: this file used to host `HomeMenu` + `HomeToolbarExtras` +
// `homeChrome`/`homeToolbar`, an imperative per-tab hoist that conflated global
// Settings with page-local rows in one menu. That model was replaced by
// `.pageChrome` (see docs/PAGE_CHROME_SPEC.md); only `OverflowMenu` survives.

/// The standard toolbar overflow ("···") menu. Owns the glyph and the "More"
/// accessibility label so every overflow menu across the app reads the same.
/// `systemImage` only varies for menus that show a transient state in the slot
/// (e.g. an hourglass while busy).
struct OverflowMenu<Content: View>: View {
  private let systemImage: String
  private let content: Content

  init(systemImage: String = "ellipsis", @ViewBuilder content: () -> Content) {
    self.systemImage = systemImage
    self.content = content()
  }

  var body: some View {
    Menu {
      content
    } label: {
      // Bare glyph (not `ellipsis.circle`) so it sits on the system's glass
      // toolbar circle without doubling the ring on iOS 26.
      Image(systemName: systemImage)
    }
    .accessibilityLabel("More")
  }
}
