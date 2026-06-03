import WidgetKit
import SwiftUI

struct NextEntry: TimelineEntry {
  let date: Date
  let data: NextComplicationData
}

struct NextProvider: TimelineProvider {
  func placeholder(in context: Context) -> NextEntry {
    NextEntry(
      date: Date(),
      data: NextComplicationData(bucket: "morning", remaining: 3, firstTitle: "Take vitamins", updatedAt: Date())
    )
  }

  func getSnapshot(in context: Context, completion: @escaping (NextEntry) -> Void) {
    completion(NextEntry(date: Date(), data: NextComplicationData.load()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<NextEntry>) -> Void) {
    let entry    = NextEntry(date: Date(), data: NextComplicationData.load())
    // Reload budget is limited on watch; rely on the watch app calling
    // WidgetCenter.shared.reloadTimelines(ofKind:) after every fetch.
    let timeline = Timeline(entries: [entry], policy: .never)
    completion(timeline)
  }
}

struct NextComplication: Widget {
  let kind = "SeptenaNext"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: NextProvider()) { entry in
      NextComplicationView(entry: entry)
    }
    .configurationDisplayName("Next")
    .description("Items remaining in the current bucket.")
    .supportedFamilies([
      .accessoryCircular,
      .accessoryRectangular,
      .accessoryInline,
      .accessoryCorner,
    ])
  }
}
