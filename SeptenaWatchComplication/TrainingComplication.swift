import WidgetKit
import SwiftUI

struct TrainingEntry: TimelineEntry {
  let date: Date
  let data: TrainingComplicationData
}

struct TrainingProvider: TimelineProvider {
  func placeholder(in context: Context) -> TrainingEntry {
    TrainingEntry(date: Date(), data: .sample)
  }

  /// Real published data, or — in DEBUG only — the sample week when nothing has
  /// been published yet, so a placed complication on a fresh simulator shows
  /// filled rings without an iCloud-signed-in sim pair.
  private func currentData() -> TrainingComplicationData {
    let loaded = TrainingComplicationData.load()
    #if DEBUG
    if loaded.rings.isEmpty { return .sample }
    #endif
    return loaded
  }

  func getSnapshot(in context: Context, completion: @escaping (TrainingEntry) -> Void) {
    completion(TrainingEntry(date: Date(), data: currentData()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<TrainingEntry>) -> Void) {
    let entry = TrainingEntry(date: Date(), data: currentData())
    completion(Timeline(entries: [entry], policy: .never))
  }
}

struct TrainingComplication: Widget {
  let kind = "SeptenaTraining"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: TrainingProvider()) { entry in
      TrainingComplicationView(entry: entry)
    }
    .configurationDisplayName("Training")
    .description("This week's strength, cardio, and sessions as rings.")
    .supportedFamilies([
      .accessoryCircular,
      .accessoryRectangular,
    ])
  }
}
