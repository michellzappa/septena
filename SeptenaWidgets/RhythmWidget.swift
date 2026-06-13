import WidgetKit
import SwiftUI

// MARK: - Timeline entry

struct RhythmEntry: TimelineEntry {
  let date: Date
  let content: RhythmWidgetSnapshot.Content

  /// "Now" as a clock fraction (0..<1) at the entry's instant — the dial's
  /// hairline hand. Recomputed each entry so it stays roughly current between
  /// the 30-minute timeline reloads.
  var nowFraction: Double {
    let c = Calendar.current.dateComponents([.hour, .minute], from: date)
    return (Double(c.hour ?? 0) * 60 + Double(c.minute ?? 0)) / 1440
  }

  /// Placeholder / gallery preview — a plausible day across a few sections.
  static var sample: RhythmEntry {
    func ev(_ id: String, _ frac: Double, _ ago: Int, _ color: Color) -> TimeOfDayWheel.Event {
      .init(id: id, fraction: frac, daysAgo: ago, color: color)
    }
    let coffee = Color.brown, meal = Color.orange, mood = Color.purple, gut = Color.teal
    var events: [TimeOfDayWheel.Event] = []
    for day in 0..<7 {
      events.append(ev("c\(day)", 7.5 / 24 + Double(day) * 0.004, day, coffee))
      events.append(ev("c2\(day)", 10.0 / 24, day, coffee))
      events.append(ev("m\(day)", 8.0 / 24, day, meal))
      events.append(ev("m2\(day)", 13.0 / 24, day, meal))
      events.append(ev("m3\(day)", 19.5 / 24, day, meal))
      if day % 2 == 0 { events.append(ev("mo\(day)", 21.0 / 24, day, mood)) }
      if day % 3 == 0 { events.append(ev("g\(day)", 9.0 / 24, day, gut)) }
    }
    let bands = (0..<3).map {
      TimeOfDayWheel.Band(id: "t\($0)", start: 17.5 / 24, end: 18.5 / 24, daysAgo: $0 * 2,
                          color: .green, opaque: true)
    }
    let legend = [
      RhythmWidgetSnapshot.LegendItem(key: "intake", label: "Coffee", color: coffee),
      RhythmWidgetSnapshot.LegendItem(key: "nutrition", label: "Meals", color: meal),
      RhythmWidgetSnapshot.LegendItem(key: "training", label: "Training", color: .green),
      RhythmWidgetSnapshot.LegendItem(key: "mood", label: "Mood", color: mood),
      RhythmWidgetSnapshot.LegendItem(key: "gut", label: "Gut", color: gut),
    ]
    return RhythmEntry(
      date: .now,
      content: .init(events: events, bands: bands, legend: legend, windowDays: 7)
    )
  }

  static var empty: RhythmEntry {
    RhythmEntry(date: .now, content: .init())
  }
}

// MARK: - Provider

struct RhythmProvider: TimelineProvider {
  func placeholder(in context: Context) -> RhythmEntry { .sample }

  func getSnapshot(in context: Context, completion: @escaping (RhythmEntry) -> Void) {
    if context.isPreview {
      completion(.sample)
      return
    }
    Task {
      let content = await RhythmWidgetSnapshot.load()
      completion(RhythmEntry(date: .now, content: content))
    }
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<RhythmEntry>) -> Void) {
    Task {
      let content = await RhythmWidgetSnapshot.load()
      let entry = RhythmEntry(date: .now, content: content)
      // The app pokes `WidgetCenter.reloadTimelines(ofKind: "RhythmWidget")` on
      // every logged mutation + foreground (see `WatchSnapshotPublisher`); this
      // 30-minute cadence is just a backstop that also advances the now-hand.
      let next = Calendar.current.date(byAdding: .minute, value: 30, to: .now)
        ?? Date(timeIntervalSinceNow: 1800)
      completion(Timeline(entries: [entry], policy: .after(next)))
    }
  }
}

// MARK: - Widget

struct RhythmWidget: Widget {
  /// Reload kind — `WatchSnapshotPublisher` calls
  /// `WidgetCenter.reloadTimelines(ofKind:)` with this exact string.
  static let kind = "RhythmWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: RhythmProvider()) { entry in
      RhythmWidgetView(entry: entry)
    }
    .configurationDisplayName("Rhythm")
    .description("Your day's shape — every section's events on a 24-hour dial.")
    .supportedFamilies([.systemSmall, .systemLarge])
  }
}

// MARK: - Views

private let homeDeepLink = URL(string: "septena://home")

struct RhythmWidgetView: View {
  let entry: RhythmEntry
  @Environment(\.widgetFamily) private var family

  var body: some View {
    content
      .widgetURL(homeDeepLink)
      .containerBackground(for: .widget) {
        LinearGradient(
          colors: [Color(.systemBackground), Color(.secondarySystemBackground)],
          startPoint: .top, endPoint: .bottom
        )
      }
  }

  @ViewBuilder
  private var content: some View {
    if entry.content.isEmpty {
      EmptyRhythm()
    } else if family == .systemLarge {
      LargeView(entry: entry)
    } else {
      SmallView(entry: entry)
    }
  }
}

/// The dial itself — sized to fill whatever square it's handed. Compact
/// rendering (no glass, labels, or hub) so it reads as a clean thumbnail.
private struct WheelFill: View {
  let entry: RhythmEntry
  /// Whether to draw the live "now" hairline (large only — too busy at small).
  var showsNow: Bool

  var body: some View {
    GeometryReader { geo in
      let d = min(geo.size.width, geo.size.height)
      TimeOfDayWheel(
        events: entry.content.events,
        accent: .secondary,
        bands: entry.content.bands,
        windowDays: entry.content.windowDays,
        nowFraction: showsNow ? entry.nowFraction : nil,
        diameter: d,
        compact: true
      )
      .frame(width: geo.size.width, height: geo.size.height)
    }
  }
}

// MARK: - Small — wheel fills the square

private struct SmallView: View {
  let entry: RhythmEntry
  var body: some View {
    WheelFill(entry: entry, showsNow: false)
  }
}

// MARK: - Large — header + dial + legend

private struct LargeView: View {
  let entry: RhythmEntry

  var body: some View {
    VStack(spacing: 8) {
      HStack(spacing: 5) {
        Image(systemName: "clock")
          .font(.system(size: 10, weight: .semibold))
        Text("RHYTHM")
        Spacer()
        Text("\(entry.content.windowDays) DAYS")
      }
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(.secondary)

      WheelFill(entry: entry, showsNow: true)
        .frame(maxHeight: .infinity)

      Legend(items: entry.content.legend)
    }
  }
}

/// Section color key — a wrapping run of dot + name chips, capped so it never
/// crowds the dial. Overflow collapses into a "+N".
private struct Legend: View {
  let items: [RhythmWidgetSnapshot.LegendItem]
  private let cap = 5

  var body: some View {
    let shown = Array(items.prefix(cap))
    let overflow = items.count - shown.count
    HStack(spacing: 10) {
      ForEach(shown) { item in
        HStack(spacing: 4) {
          Circle().fill(item.color).frame(width: 7, height: 7)
          Text(item.label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      if overflow > 0 {
        Text("+\(overflow)")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.tertiary)
      }
    }
    .frame(maxWidth: .infinity)
  }
}

// MARK: - Empty

private struct EmptyRhythm: View {
  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: "clock")
        .font(.title2)
        .foregroundStyle(.tertiary)
      Text("No timed activity yet")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Previews

#Preview("Large", as: .systemLarge) { RhythmWidget() } timeline: {
  RhythmEntry.sample
  RhythmEntry.empty
}

#Preview("Small", as: .systemSmall) { RhythmWidget() } timeline: {
  RhythmEntry.sample
  RhythmEntry.empty
}
