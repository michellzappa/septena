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

  /// Start of the entry's day — the date shown in the dial's hollow.
  var dayStart: Date { Calendar.current.startOfDay(for: date) }

  /// Placeholder / gallery preview — a plausible single day across sections.
  static var sample: RhythmEntry {
    func ev(_ id: String, _ frac: Double, _ color: Color) -> TimeOfDayWheel.Event {
      .init(id: id, fraction: frac, daysAgo: 0, color: color)
    }
    let coffee = Color.brown, meal = Color.orange, mood = Color.purple, gut = Color.teal
    let events: [TimeOfDayWheel.Event] = [
      ev("c1", 7.5 / 24, coffee), ev("c2", 10.0 / 24, coffee), ev("c3", 14.0 / 24, coffee),
      ev("m1", 8.0 / 24, meal), ev("m2", 13.0 / 24, meal), ev("m3", 19.5 / 24, meal),
      ev("mo1", 9.0 / 24, mood), ev("mo2", 21.0 / 24, mood),
      ev("g1", 11.0 / 24, gut),
    ]
    let bands = [
      TimeOfDayWheel.Band(id: "t1", start: 17.5 / 24, end: 18.5 / 24, daysAgo: 0,
                          color: .green, opaque: true),
    ]
    return RhythmEntry(
      date: .now,
      content: .init(events: events, bands: bands, windowDays: 1)
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
    .description("Today as a 24-hour dial — your day's shape across every section.")
    .supportedFamilies([.systemSmall, .systemLarge])
    .septenaWidgetMargins()
  }
}

// MARK: - Views

private let homeDeepLink = URL(string: "septena://home")

struct RhythmWidgetView: View {
  let entry: RhythmEntry

  var body: some View {
    content
      .widgetSurfaceInsets()
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
    } else {
      DialFill(entry: entry)
    }
  }
}

/// The day dial — a static mirror of the front-door `DayDialHero`: today's
/// events as section-colored dots, the solar night arc darkening the night
/// hours (computed on-device from `SolarClock`, no permission), the now-hand,
/// and the date in the hollow. Sized to fill whatever square it's handed.
private struct DialFill: View {
  let entry: RhythmEntry

  var body: some View {
    // Solar night arc (sunset → sunrise) for the entry's day — the dark glass
    // wedge the homepage hero wears, recomputed here so the widget needs no
    // payload field for it.
    let solar = SolarClock.today(now: entry.date)
    let night = (start: solar.sunsetHour / 24, end: solar.sunriseHour / 24)

    GeometryReader { geo in
      let d = min(geo.size.width, geo.size.height)
      TimeOfDayWheel(
        events: entry.content.events,
        // Neutral frame — the dots carry the section colors, same as the hero.
        accent: .secondary,
        bands: entry.content.bands,
        windowDays: entry.content.windowDays,
        nowFraction: entry.nowFraction,
        diameter: d,
        heroDate: entry.dayStart,
        nightArc: night,
        // Single day, fixed midnight-at-top orientation: a widget snapshot
        // can't animate, so it doesn't spin "now" to the top (that's the live
        // hero's motion) — a steady clock reads better at a glance.
        lockToday: true,
        // `.glassEffect` can't render in a static widget — stand in a flat face.
        flatGlass: true
      )
      .frame(width: geo.size.width, height: geo.size.height)
    }
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
