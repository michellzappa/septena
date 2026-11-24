import SwiftUI

/// The app's accent for chrome and task surfaces: the PLATFORM accent (the
/// user's own on macOS, blue on iOS; no target sets a global accent color).
/// Injected app-wide; shared views read it from the environment.
@MainActor
@Observable
final class SectionTheme {
  let accent: Color = .accentColor

  /// The accent for a surface. Every key resolves to the platform accent.
  func color(for sectionKey: String) -> Color { accent }
}
