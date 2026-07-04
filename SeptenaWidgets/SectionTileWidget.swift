import WidgetKit
import SwiftUI
import AppIntents

enum SectionTileWidgetMetrics {
  /// Medium widget heatmap — ~15 week columns (105 days).
  static let heatmapWindowDays = 105
}

struct SectionTileEntry: TimelineEntry {
  let date: Date
  let itemID: String?
  let display: TileDisplayData?
  let isMissing: Bool

  static var sample: SectionTileEntry {
    SectionTileEntry(
      date: .now,
      itemID: HomepageDomain.habits.rawValue,
      display: TileWidgetCatalog.sampleHabits.display,
      isMissing: false
    )
  }

  static var empty: SectionTileEntry {
    SectionTileEntry(date: .now, itemID: nil, display: nil, isMissing: true)
  }
}

struct SectionTileProvider: AppIntentTimelineProvider {
  typealias Entry = SectionTileEntry
  typealias Intent = SectionTileConfigurationIntent

  func placeholder(in context: Context) -> SectionTileEntry { .sample }

  func snapshot(for configuration: SectionTileConfigurationIntent, in context: Context) async -> SectionTileEntry {
    if context.isPreview { return .sample }
    return entry(for: configuration)
  }

  func timeline(for configuration: SectionTileConfigurationIntent, in context: Context) async -> Timeline<SectionTileEntry> {
    let entry = entry(for: configuration)
    let next = Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? Date(timeIntervalSinceNow: 1800)
    return Timeline(entries: [entry], policy: .after(next))
  }

  private func entry(for configuration: SectionTileConfigurationIntent) -> SectionTileEntry {
    guard let itemID = configuration.section?.itemID else {
      return SectionTileEntry(date: .now, itemID: nil, display: nil, isMissing: true)
    }
    let catalog = TileWidgetSnapshotStore.load()
    guard let wire = catalog.tiles[itemID] else {
      return SectionTileEntry(date: .now, itemID: itemID, display: nil, isMissing: true)
    }
    return SectionTileEntry(date: .now, itemID: itemID, display: wire.display, isMissing: false)
  }
}

struct SectionTileWidgetView: View {
  let entry: SectionTileEntry

  @Environment(\.widgetFamily) private var family

  var body: some View {
    content
      .widgetSurfaceInsets()
      .widgetURL(deepLink)
      .containerBackground(for: .widget) {
        Theme.widgetSurface
      }
  }

  @ViewBuilder
  private var content: some View {
    if let display = entry.display {
      switch family {
      case .systemMedium:
        HeatmapTileRow(
          display: display,
          windowDays: SectionTileWidgetMetrics.heatmapWindowDays
        )
      default:
        DomainTile(display: display)
      }
    } else {
      placeholder
    }
  }

  private var deepLink: URL? {
    guard let itemID = entry.itemID else { return URL(string: "septena://home") }
    var components = URLComponents()
    components.scheme = "septena"
    components.host = "section"
    components.path = "/\(itemID)"
    return components.url
  }

  private var placeholder: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Section Tile")
        .font(.subheadline.weight(.semibold))
      Text(entry.itemID == nil
           ? "Pick a section when adding this widget."
           : "Section off or no data yet — open Septena once.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .padding(.horizontal, 6)
    .padding(.vertical, 12)
  }
}

struct SectionTileWidget: Widget {
  static let kind = "SectionTileWidget"

  var body: some WidgetConfiguration {
    AppIntentConfiguration(kind: Self.kind,
                           intent: SectionTileConfigurationIntent.self,
                           provider: SectionTileProvider()) { entry in
      SectionTileWidgetView(entry: entry)
    }
    .configurationDisplayName("Section Tile")
    .description("Small: 7-day histogram. Wide: ~15-week heatmap.")
    .supportedFamilies([.systemSmall, .systemMedium])
    .septenaWidgetMargins()
  }
}

#Preview("Small", as: .systemSmall) {
  SectionTileWidget()
} timeline: {
  SectionTileEntry.sample
}

#Preview("Medium", as: .systemMedium) {
  SectionTileWidget()
} timeline: {
  SectionTileEntry.sample
}
