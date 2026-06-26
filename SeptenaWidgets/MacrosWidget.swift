import WidgetKit
import SwiftUI

struct MacroEntry: TimelineEntry {
  let date: Date
  let wire: MacroWidgetWire?

  var isMissing: Bool { wire == nil }

  static var sample: MacroEntry {
    MacroEntry(date: .now, wire: .sample)
  }

  static var empty: MacroEntry {
    MacroEntry(date: .now, wire: nil)
  }
}

struct MacrosProvider: TimelineProvider {
  func placeholder(in context: Context) -> MacroEntry { .sample }

  func getSnapshot(in context: Context, completion: @escaping (MacroEntry) -> Void) {
    if context.isPreview {
      completion(.sample)
      return
    }
    completion(entry())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<MacroEntry>) -> Void) {
    let entry = entry()
    let next = Calendar.current.date(byAdding: .minute, value: 30, to: .now)
      ?? Date(timeIntervalSinceNow: 1800)
    completion(Timeline(entries: [entry], policy: .after(next)))
  }

  private func entry() -> MacroEntry {
    guard let wire = MacroWidgetSnapshotStore.load() else { return .empty }
    return MacroEntry(date: .now, wire: wire)
  }
}

struct MacrosWidgetView: View {
  let entry: MacroEntry

  var body: some View {
    content
      .widgetTileInnerPadding()
      .widgetSurfaceInsets()
      .widgetURL(URL(string: "septena://section/nutrition"))
      .containerBackground(for: .widget) {
        Theme.cardSurface
      }
  }

  @ViewBuilder
  private var content: some View {
    if let wire = entry.wire {
      MacroWidgetGridView(tiles: wire.tiles, accentHex: wire.accentHex)
    } else {
      placeholder
    }
  }

  private var placeholder: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Macros")
        .font(.subheadline.weight(.semibold))
      Text("Nutrition off or no targets yet — open Septena once.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .padding(.horizontal, 6)
    .padding(.vertical, 12)
  }
}

struct MacrosWidget: Widget {
  static let kind = "MacrosWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: MacrosProvider()) { entry in
      MacrosWidgetView(entry: entry)
    }
    .configurationDisplayName("Macros")
    .description("Small: kcal + protein snapshot. Wide: your nutrition pattern tiles.")
    .supportedFamilies([.systemSmall, .systemMedium])
    .septenaWidgetMargins()
  }
}

#Preview("Small", as: .systemSmall) {
  MacrosWidget()
} timeline: {
  MacroEntry.sample
}

#Preview("Medium", as: .systemMedium) {
  MacrosWidget()
} timeline: {
  MacroEntry.sample
}
