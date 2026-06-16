import WidgetKit
import SwiftUI

struct MacroEntry: TimelineEntry {
  let date: Date
  let data: MacroComplicationData
}

struct MacroProvider: TimelineProvider {
  func placeholder(in context: Context) -> MacroEntry {
    MacroEntry(date: Date(), data: MacroComplicationData(
      rings: [
        .init(key: "kcal", value: 1400, goal: 2200),
        .init(key: "protein", value: 90, goal: 150),
        .init(key: "carbs", value: 120, goal: 220),
        .init(key: "fat", value: 40, goal: 70),
        .init(key: "fiber", value: 14, goal: 30),
      ],
      updatedAt: Date()))
  }

  /// Real published data, or — in DEBUG only — the sample day when nothing has
  /// been published yet, so a placed complication on a fresh simulator shows
  /// filled rings without needing an iCloud-signed-in sim pair. Release builds
  /// always show real data (empty tracks until the first sync).
  private func currentData() -> MacroComplicationData {
    let loaded = MacroComplicationData.load()
    #if DEBUG
    if loaded.rings.isEmpty { return .sample }
    #endif
    return loaded
  }

  func getSnapshot(in context: Context, completion: @escaping (MacroEntry) -> Void) {
    completion(MacroEntry(date: Date(), data: currentData()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<MacroEntry>) -> Void) {
    let entry = MacroEntry(date: Date(), data: currentData())
    // Reload budget is tight on watchOS — the watch app calls
    // WidgetCenter.shared.reloadTimelines(ofKind:) after every snapshot fetch,
    // so a static, never-expiring timeline is enough.
    completion(Timeline(entries: [entry], policy: .never))
  }
}

struct MacroComplication: Widget {
  let kind = "SeptenaMacroRings"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: MacroProvider()) { entry in
      MacroComplicationView(entry: entry)
    }
    .configurationDisplayName("Macros")
    .description("Today's calories and macros as activity rings.")
    .supportedFamilies([
      .accessoryCircular,
      .accessoryRectangular,
    ])
  }
}
