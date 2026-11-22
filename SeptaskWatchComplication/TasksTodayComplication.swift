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

// MARK: - Septena Symbol Complication

struct SeptenaSymbolEntry: TimelineEntry {
  let date: Date
}

struct SeptenaSymbolProvider: TimelineProvider {
  func placeholder(in context: Context) -> SeptenaSymbolEntry {
    SeptenaSymbolEntry(date: Date())
  }

  func getSnapshot(in context: Context, completion: @escaping (SeptenaSymbolEntry) -> Void) {
    completion(SeptenaSymbolEntry(date: Date()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<SeptenaSymbolEntry>) -> Void) {
    completion(Timeline(entries: [SeptenaSymbolEntry(date: Date())], policy: .never))
  }
}

struct SeptenaSymbolComplication: Widget {
  let kind = "SeptenaSymbol"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: SeptenaSymbolProvider()) { _ in
      SeptenaSymbolComplicationView()
    }
    .configurationDisplayName("Septena")
    .description("Just the Septena symbol — tap to open Today.")
    .supportedFamilies([.accessoryCircular, .accessoryCorner])
  }
}

private struct SeptenaSymbolComplicationView: View {
  @Environment(\.widgetFamily) private var family

  var body: some View {
    Group {
      if family == .accessoryCorner {
        SeptenaCompassMark()
          .padding(3)
          .widgetLabel { Text("Septena") }
      } else {
        ZStack {
          AccessoryWidgetBackground()
          SeptenaCompassMark()
            .padding(4)
        }
      }
    }
    .containerBackground(for: .widget) {
      if family == .accessoryCircular {
        AccessoryWidgetBackground()
      } else {
        Color.clear
      }
    }
  }
}

/// The canonical Septena Upright Compass symbol (from AppIconPickerSection):
/// 6 machined ticks + upright North pointer (-90°) + sculpted checkmark.
/// Scaled from its 720-unit inner dial so it fills a circular complication crisply.
private struct SeptenaCompassMark: View {
  var body: some View {
    ZStack {
      // 6 radial ticks (neutral)
      Canvas { ctx, size in
        let sc = min(size.width, size.height) / 720.0
        let cx = size.width / 2
        let cy = size.height / 2
        let step = 360.0 / 7.0
        let tickStyle = StrokeStyle(lineWidth: max(1.4, 28 * sc), lineCap: .round)
        for i in 1..<7 {
          let rad = (-90.0 + Double(i) * step) * .pi / 180.0
          var p = Path()
          p.move(to: CGPoint(x: cx + cos(rad) * 260 * sc, y: cy + sin(rad) * 260 * sc))
          p.addLine(to: CGPoint(x: cx + cos(rad) * 316 * sc, y: cy + sin(rad) * 316 * sc))
          ctx.stroke(p, with: .color(.primary.opacity(0.65)), style: tickStyle)
        }
      }
      // Sculpted checkmark (primary)
      Canvas { ctx, size in
        let sc = min(size.width, size.height) / 720.0
        let cx = size.width / 2
        let cy = size.height / 2
        var check = Path()
        check.move(to: CGPoint(x: cx + (377 - 512) * sc, y: cy + (511 - 512) * sc))
        check.addLine(to: CGPoint(x: cx + (460 - 512) * sc, y: cy + (598 - 512) * sc))
        check.addLine(to: CGPoint(x: cx + (639 - 512) * sc, y: cy + (426 - 512) * sc))
        let checkStyle = StrokeStyle(lineWidth: max(2.2, 68 * sc), lineCap: .round, lineJoin: .round)
        ctx.stroke(check, with: .color(.primary), style: checkStyle)
      }
      // Upright North compass pointer (accentable on tinted watch faces)
      Canvas { ctx, size in
        let sc = min(size.width, size.height) / 720.0
        let cx = size.width / 2
        let cy = size.height / 2
        let a0 = -90.0 * .pi / 180.0
        let aL = (-90.0 - 12.0) * .pi / 180.0
        let aR = (-90.0 + 12.0) * .pi / 180.0
        var north = Path()
        north.move(to: CGPoint(x: cx + cos(a0) * 342 * sc, y: cy + sin(a0) * 342 * sc))
        north.addLine(to: CGPoint(x: cx + cos(aR) * 238 * sc, y: cy + sin(aR) * 238 * sc))
        north.addLine(to: CGPoint(x: cx + cos(a0) * 260 * sc, y: cy + sin(a0) * 260 * sc))
        north.addLine(to: CGPoint(x: cx + cos(aL) * 238 * sc, y: cy + sin(aL) * 238 * sc))
        north.closeSubpath()
        ctx.fill(north, with: .color(.accentColor))
      }
      .widgetAccentable()
    }
    .aspectRatio(1, contentMode: .fit)
  }
}
