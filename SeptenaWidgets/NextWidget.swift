import WidgetKit
import SwiftUI

// MARK: - Timeline entry

struct NextEntry: TimelineEntry {
  let date: Date
  let bucket: DayBucket
  /// Already narrowed to `bucket` by `NextWidgetSnapshot`.
  let items: [NextItem]

  var remaining: Int { items.count }
  var first: NextItem? { items.first }

  /// Placeholder / gallery preview content.
  static var sample: NextEntry {
    NextEntry(
      date: .now,
      bucket: .current,
      items: [
        NextItem(id: "s1", kind: "task",       title: "Reply to the landlord", subtitle: nil, trailing: nil, overdue: false, sortKey: 0),
        NextItem(id: "s2", kind: "habit",      title: "10 min stretch",        subtitle: nil, trailing: nil, overdue: false, sortKey: 1),
        NextItem(id: "s3", kind: "supplement", title: "Vitamin D",             subtitle: nil, trailing: nil, overdue: false, sortKey: 2),
        NextItem(id: "s4", kind: "chore",      title: "Water the plants",      subtitle: nil, trailing: nil, overdue: false, sortKey: 3),
      ]
    )
  }
}

// MARK: - Provider

struct NextProvider: TimelineProvider {
  func placeholder(in context: Context) -> NextEntry { .sample }

  func getSnapshot(in context: Context, completion: @escaping (NextEntry) -> Void) {
    // In the widget gallery (`isPreview`) show sample content immediately
    // rather than waiting on a CloudKit round-trip.
    if context.isPreview {
      completion(.sample)
      return
    }
    Task {
      let items = await NextWidgetSnapshot.loadItems()
      completion(NextEntry(date: .now, bucket: .current, items: items))
    }
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<NextEntry>) -> Void) {
    Task {
      let items = await NextWidgetSnapshot.loadItems()
      let entry = NextEntry(date: .now, bucket: .current, items: items)
      // Backstop only: the app pokes `WidgetCenter.reloadTimelines` on every
      // checklist mutation, so this just guards against a missed poke and keeps
      // the bucket label fresh as the day rolls over.
      let next = Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? Date(timeIntervalSinceNow: 1800)
      completion(Timeline(entries: [entry], policy: .after(next)))
    }
  }
}

// MARK: - Widget

struct NextWidget: Widget {
  /// Reload kind — the app calls `WidgetCenter.shared.reloadTimelines(ofKind:)`
  /// with this string. Kept in sync with `NextWidget.kind` on the app side.
  static let kind = "NextWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: NextProvider()) { entry in
      NextWidgetView(entry: entry)
    }
    .configurationDisplayName("Next")
    .description("The one thing to do right now.")
    .supportedFamilies([
      .systemSmall,
      .systemMedium,
      .accessoryRectangular,
      .accessoryInline,
      .accessoryCircular,
    ])
  }
}

@main
struct SeptenaWidgetsBundle: WidgetBundle {
  var body: some Widget {
    NextWidget()
    // RhythmWidget() — the time-wheel/day-dial widget is DISABLED for now: the
    // hero's Liquid Glass face can't render in a static widget snapshot, and a
    // flat-faced fallback doesn't carry the look. All of its code is kept and
    // still compiles (RhythmWidget / RhythmWidgetSnapshot here; RhythmWire /
    // RhythmSnapshotBuilder + TimeOfDayWheel.flatGlass in SeptenaCore) so it can
    // be switched back on if WidgetKit gains glass support. Re-enable by
    // un-commenting this line AND the `rhythmPayload` publish in
    // `WatchSnapshotPublisher`.
  }
}

// MARK: - Previews (canvas — flip light/dark with the appearance toggle)

private extension NextEntry {
  /// Several items across categories, some with more than one open, so the
  /// per-category rows and count badges are exercised.
  static var richSample: NextEntry {
    NextEntry(
      date: .now,
      bucket: .afternoon,
      items: [
        NextItem(id: "t1", kind: "task",       title: "Reply to the landlord", subtitle: nil, trailing: nil, overdue: true,  sortKey: 0),
        NextItem(id: "t2", kind: "task",       title: "Book dentist",          subtitle: nil, trailing: nil, overdue: false, sortKey: 1),
        NextItem(id: "c1", kind: "chore",      title: "Water the plants",      subtitle: nil, trailing: nil, overdue: false, sortKey: 2),
        NextItem(id: "h1", kind: "habit",      title: "10 min stretch",        subtitle: nil, trailing: nil, overdue: false, sortKey: 3),
        NextItem(id: "s1", kind: "supplement", title: "Vitamin D",             subtitle: nil, trailing: nil, overdue: false, sortKey: 4),
        NextItem(id: "s2", kind: "supplement", title: "Magnesium",             subtitle: nil, trailing: nil, overdue: false, sortKey: 5),
      ]
    )
  }

  static var empty: NextEntry {
    NextEntry(date: .now, bucket: .evening, items: [])
  }
}

#Preview("Small", as: .systemSmall) { NextWidget() } timeline: {
  NextEntry.richSample
  NextEntry.empty
}

#Preview("Medium", as: .systemMedium) { NextWidget() } timeline: {
  NextEntry.richSample
  NextEntry.empty
}

#Preview("Rectangular", as: .accessoryRectangular) { NextWidget() } timeline: {
  NextEntry.richSample
}

#Preview("Inline", as: .accessoryInline) { NextWidget() } timeline: {
  NextEntry.richSample
}

#Preview("Circular", as: .accessoryCircular) { NextWidget() } timeline: {
  NextEntry.richSample
}
