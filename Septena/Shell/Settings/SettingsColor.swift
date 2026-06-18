import SwiftUI

/// Adaptive parse of a section/swatch color token, used for display of curated
/// swatches and the current section accent. Routes through the shared
/// `AdaptiveColor` resolver (handles "#rrggbb"/rgb()/hsl() and the dark-mode
/// lift); falls back to gray on unparseable input.
func parseHexColor(_ s: String) -> Color {
  AdaptiveColor.adaptive(s) ?? .gray
}
