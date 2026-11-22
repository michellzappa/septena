import WidgetKit
import SwiftUI

struct TasksTodayEntry: TimelineEntry {
  let date: Date
  let data: TasksTodayComplicationData
}

struct TasksTodayProvider: TimelineProvider {
  func placeholder(in context: Context) -> TasksTodayEntry {
    TasksTodayEntry(
      date: Date(),
      data: .placeholder)
  }

  func getSnapshot(in context: Context, completion: @escaping (TasksTodayEntry) -> Void) {
    completion(TasksTodayEntry(date: Date(), data: TasksTodayComplicationData.load()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<TasksTodayEntry>) -> Void) {
    let entry = TasksTodayEntry(date: Date(), data: TasksTodayComplicationData.load())
    // The app reloads after every change; the midnight entry stops showing
    // yesterday's count until the app refreshes.
    let midnight = Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400))
    var tomorrow = entry.data
    tomorrow.firstTitle = nil
    tomorrow.secondTitle = nil
    tomorrow.day = nil
    let timeline = Timeline(entries: [entry, TasksTodayEntry(date: midnight, data: tomorrow)], policy: .never)
    completion(timeline)
  }
}

struct TasksTodayComplication: Widget {
  let kind = TasksTodayComplicationData.widgetKind

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: TasksTodayProvider()) { entry in
      TasksTodayComplicationView(entry: entry)
    }
    .configurationDisplayName("Today")
    .description("What’s left for today, and what’s next.")
    .supportedFamilies([
      .accessoryCircular,
      .accessoryRectangular,
      .accessoryInline,
      .accessoryCorner,
    ])
  }
}

struct TasksTodayComplicationView: View {
  let entry: TasksTodayEntry

  @Environment(\.widgetFamily) private var family

  var body: some View {
    content
      .containerBackground(for: .widget) {
        if family == .accessoryCircular {
          AccessoryWidgetBackground()
        } else {
          Color.clear
        }
      }
  }

  @ViewBuilder
  private var content: some View {
    switch family {
    case .accessoryCircular: CircularView(data: entry.data)
    case .accessoryRectangular: RectangularView(data: entry.data)
    case .accessoryInline: InlineView(data: entry.data)
    case .accessoryCorner: CornerView(data: entry.data)
    default: CircularView(data: entry.data)
    }
  }
}

private struct CornerView: View {
  let data: TasksTodayComplicationData

  var body: some View {
    Image(systemName: data.remaining == 0 ? "checkmark.circle" : "checklist")
      .font(.title3.weight(.semibold))
      .widgetLabel {
        Text(data.remaining == 0 ? String(localized: "All clear") : String(localized: "\(data.remaining) left"))
      }
  }
}

private struct CircularView: View {
  let data: TasksTodayComplicationData

  var body: some View {
    ZStack {
      AccessoryWidgetBackground()
      if data.remaining > 0 {
        Text("\(data.remaining)")
          .font(.caption2.weight(.bold))
      } else {
        Image(systemName: "checkmark")
          .font(.caption2.weight(.bold))
      }
    }
  }
}

private struct RectangularView: View {
  let data: TasksTodayComplicationData

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text("Today")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Text("\(data.remaining) left")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      if let title = data.firstTitle {
        Text(title)
          .font(.caption.weight(.medium))
          .lineLimit(data.secondTitle == nil ? 2 : 1)
        if let second = data.secondTitle {
          Text(second)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      } else if !data.connected {
        Text("Open Septena")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Text("All clear")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 2)
  }
}

private struct InlineView: View {
  let data: TasksTodayComplicationData

  var body: some View {
    if data.remaining == 0 {
      Label("All clear", systemImage: "checkmark.circle.fill")
    } else if let first = data.firstTitle {
      Text("\(data.remaining) · \(first)")
    } else {
      Text("\(data.remaining) · Today")
    }
  }
}
