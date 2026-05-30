import SwiftUI

// One chart inside a section drawer, with a small editorial header
// rendered above the card. Replaces the local `chartCard(...)` helpers
// that Sleep (and the inline pattern in other destinations) were
// re-rolling. Same shape as `DrawerSection("Title", padding: .tight)`,
// but with an optional secondary `detail` string next to the title
// (e.g. "avg 800 · max 1200 ppm", "↑ 85+", "last 24h").
//
// The chart caller controls its own `.frame(height:)` — different
// destinations want different heights (140 for sparklines, 180–200 for
// the headline charts) and forcing a single value here would flatten
// information design across sections.

struct ChartCard<Accessory: View, Content: View>: View {
  let title: String
  var detail: String? = nil
  /// Optional trailing view rendered in the header row, after the
  /// `Spacer`. Used by Body's `trendChart` for the "→ X in 7d"
  /// projection so that information survives the migration. Defaults
  /// to `EmptyView`.
  let accessory: Accessory
  @ViewBuilder var content: () -> Content

  init(title: String,
       detail: String? = nil,
       @ViewBuilder accessory: () -> Accessory,
       @ViewBuilder content: @escaping () -> Content) {
    self.title = title
    self.detail = detail
    self.accessory = accessory()
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      HStack(spacing: Theme.Spacing.sm) {
        Text(title)
        if let detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        accessory
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .padding(.horizontal, Theme.Spacing.xl)
      DrawerSection(padding: .tight) {
        content()
      }
    }
  }
}

#Preview("ChartCard") {
  ScrollView {
    VStack(spacing: 24) {
      ChartCard(title: "CO₂ last 24h", detail: "avg 712 · max 980 ppm") {
        Rectangle().fill(.orange.opacity(0.35)).frame(height: 140)
      }
      ChartCard(title: "Sleep score", detail: "↑ 85+") {
        Rectangle().fill(.blue.opacity(0.35)).frame(height: 140)
      }
    }
    .padding()
  }
  .background(Theme.groupedBackground)
}

extension ChartCard where Accessory == EmptyView {
  /// Title + optional `detail` only — no trailing accessory.
  init(title: String,
       detail: String? = nil,
       @ViewBuilder content: @escaping () -> Content) {
    self.init(title: title, detail: detail,
              accessory: { EmptyView() },
              content: content)
  }
}
