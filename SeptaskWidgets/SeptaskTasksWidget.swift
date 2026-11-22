import AppIntents
import SwiftUI
import WidgetKit

struct SeptaskTasksEntry: TimelineEntry {
  let date: Date
  let configuration: SeptaskWidgetConfigurationIntent
  let snapshot: TasksWidgetSnapshot
  let list: TasksWidgetListSummary
}

struct SeptaskTasksTimelineProvider: AppIntentTimelineProvider {
  typealias Entry = SeptaskTasksEntry
  typealias Intent = SeptaskWidgetConfigurationIntent

  func placeholder(in context: Context) -> SeptaskTasksEntry {
    let snap = TasksWidgetSnapshot.sample
    return SeptaskTasksEntry(
      date: Date(),
      configuration: SeptaskWidgetConfigurationIntent(),
      snapshot: snap,
      list: snap.todayList
    )
  }

  func snapshot(for configuration: SeptaskWidgetConfigurationIntent, in context: Context) async -> SeptaskTasksEntry {
    makeEntry(for: configuration, isPreview: context.isPreview)
  }

  func timeline(for configuration: SeptaskWidgetConfigurationIntent, in context: Context) async -> Timeline<SeptaskTasksEntry> {
    let entry = makeEntry(for: configuration, isPreview: context.isPreview)
    // Refresh automatically at next local midnight so Today / Lock Screen counts
    // roll over cleanly even if the host app did not launch.
    let cal = Calendar.current
    let nextMidnight = cal.nextDate(
      after: Date(),
      matching: DateComponents(hour: 0, minute: 0, second: 5),
      matchingPolicy: .nextTime
    ) ?? Date().addingTimeInterval(3600 * 6)
    return Timeline(entries: [entry], policy: .after(nextMidnight))
  }

  private func makeEntry(for configuration: SeptaskWidgetConfigurationIntent, isPreview: Bool) -> SeptaskTasksEntry {
    if let live = TasksWidgetSnapshotStore.load() {
      let chosen = live.list(for: configuration.resolvedListID) ?? live.todayList
      return SeptaskTasksEntry(
        date: Date(),
        configuration: configuration,
        snapshot: live,
        list: chosen
      )
    }
    if isPreview {
      let sample = TasksWidgetSnapshot.sample
      let chosen = sample.list(for: configuration.resolvedListID) ?? sample.todayList
      return SeptaskTasksEntry(
        date: Date(),
        configuration: configuration,
        snapshot: sample,
        list: chosen
      )
    }
    let empty = TasksWidgetSnapshot(
      day: "",
      updatedAt: Date(),
      isRedacted: false,
      accentHex: nil,
      lists: []
    )
    return SeptaskTasksEntry(
      date: Date(),
      configuration: configuration,
      snapshot: empty,
      list: empty.todayList
    )
  }
}

struct SeptaskTasksWidget: Widget {
  let kind: String = TasksWidgetKind.tasks

  private var families: [WidgetFamily] {
    #if os(iOS)
    [
      .systemSmall,
      .systemMedium,
      .systemLarge,
      .accessoryRectangular,
      .accessoryCircular,
      .accessoryInline,
    ]
    #else
    [
      .systemSmall,
      .systemMedium,
      .systemLarge,
    ]
    #endif
  }

  var body: some WidgetConfiguration {
    AppIntentConfiguration(
      kind: kind,
      intent: SeptaskWidgetConfigurationIntent.self,
      provider: SeptaskTasksTimelineProvider()
    ) { entry in
      SeptaskTasksWidgetEntryView(entry: entry)
    }
    .configurationDisplayName("Tasks")
    .description("View and check off your Septena tasks. Defaults to Today; edit the widget to choose another list.")
    .supportedFamilies(families)
  }
}
