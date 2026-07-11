import SwiftUI

// Grid of dashboard tiles used by Sleep and Body. Replaces two copies
// of the same LazyVGrid+rounded-tile chrome by sharing the grid wrapper
// (`StatGrid`) and the tile background (`StatTile`). Each destination
// keeps its bespoke tile *contents* — a scoreRing has a Circle gauge, a
// bedtimeTile has two stacked time blocks — so the information design
// per tile stays intact. Only the outer card frame is unified.

/// LazyVGrid pre-configured for the N-column, evenly-spaced tile layout
/// Sleep / Body use. Drop `StatTile { … }` instances inside.
struct StatGrid<Content: View>: View {
  var columns: Int
  var spacing: CGFloat
  @ViewBuilder var content: () -> Content

  init(columns: Int = 2,
       spacing: CGFloat = Theme.Spacing.sm,
       @ViewBuilder content: @escaping () -> Content) {
    self.columns = columns
    self.spacing = spacing
    self.content = content
  }

  var body: some View {
    LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: spacing),
                     count: columns),
      spacing: spacing
    ) {
      content()
    }
  }
}

/// One dashboard tile — the rounded secondary-grouped surface that Sleep
/// and Body's stat tiles all share. Wraps your bespoke tile body and
/// applies the standard `Theme.cornerRadius` corner + uniform vertical
/// padding so every tile lands at the same height regardless of which
/// destination drew it.
struct StatTile<Content: View>: View {
  var verticalPadding: CGFloat
  @ViewBuilder var content: () -> Content

  init(verticalPadding: CGFloat = Theme.Spacing.md,
       @ViewBuilder content: @escaping () -> Content) {
    self.verticalPadding = verticalPadding
    self.content = content
  }

  var body: some View {
    content()
      .frame(maxWidth: .infinity)
      .padding(.vertical, verticalPadding)
      // Surface from the injected style: opaque card on a solid host, a floating
      // Liquid Glass panel on the glass (translucent-sheet) host. One place owns
      // the decision (`drawerCardSurface`).
      .drawerCardSurface()
  }
}

#Preview("StatGrid + StatTile") {
  StatGrid(columns: 2) {
    StatTile {
      VStack(spacing: 4) {
        Text("7h 24m")
          .font(.septenaHeroMetric())
        Text("Total Sleep").font(.caption).foregroundStyle(.secondary)
        Text("7–9 h").font(.caption2).foregroundStyle(.secondary.opacity(0.7))
      }
    }
    StatTile {
      VStack(spacing: 4) {
        Text("85")
          .font(.septenaHeroMetric())
        Text("Sleep Score").font(.caption).foregroundStyle(.secondary)
        Text("85+").font(.caption2).foregroundStyle(.secondary.opacity(0.7))
      }
    }
  }
  .padding()
  .background(Theme.groupedBackground)
}
