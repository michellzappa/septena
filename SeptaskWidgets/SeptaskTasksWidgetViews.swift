import AppIntents
import SwiftUI
import WidgetKit

// Calm, minimal Home Screen, Lock Screen, and macOS Desktop task widget views
// matching docs/TASK_WIDGETS_SPEC.md §3 and docs/DesignSpec.md.
// Adapts automatically to Light, Dark, Tinted/Clear Glass, and Dynamic Type.

struct SeptaskTasksWidgetEntryView: View {
  let entry: SeptaskTasksEntry

  @Environment(\.widgetFamily) private var family
  @Environment(\.widgetRenderingMode) private var renderingMode

  private var accentColor: Color {
    if renderingMode == .accented { return .accentColor }
    if let hex = entry.snapshot.accentHex {
      return WidgetColorHelper.color(fromHex: hex)
    }
    switch entry.list.kind {
    case .today:    return Color(red: 0.96, green: 0.78, blue: 0.13) // Today gold
    case .upcoming: return Color(red: 0.85, green: 0.28, blue: 0.35)
    case .inbox:    return Color(red: 0.16, green: 0.52, blue: 0.96)
    case .starred:  return Color(red: 0.95, green: 0.65, blue: 0.12)
    case .project, .area:
      return .accentColor
    }
  }

  var body: some View {
    content
      .widgetURL(TasksWidgetDeepLink.list(id: entry.list.id).url)
      .containerBackground(for: .widget) {
        #if os(iOS)
        if family == .accessoryCircular {
          AccessoryWidgetBackground()
        } else if family == .accessoryRectangular || family == .accessoryInline {
          Color.clear
        } else {
          Color(.systemBackground)
        }
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
      }
  }

  @ViewBuilder
  private var content: some View {
    switch family {
    case .systemSmall:
      SmallTasksWidgetView(entry: entry, accent: accentColor)
    case .systemMedium:
      MediumTasksWidgetView(entry: entry, accent: accentColor)
    case .systemLarge:
      LargeTasksWidgetView(entry: entry, accent: accentColor)
    #if os(iOS)
    case .accessoryRectangular:
      AccessoryRectangularTasksView(entry: entry)
    case .accessoryCircular:
      AccessoryCircularTasksView(entry: entry)
    case .accessoryInline:
      AccessoryInlineTasksView(entry: entry)
    #endif
    default:
      MediumTasksWidgetView(entry: entry, accent: accentColor)
    }
  }
}

// MARK: - Home Screen / Desktop

private struct SmallTasksWidgetView: View {
  let entry: SeptaskTasksEntry
  let accent: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      WidgetListHeader(list: entry.list, accent: accent, compact: true)

      if entry.snapshot.isRedacted {
        RedactedCountView(list: entry.list, compact: true)
      } else if entry.list.items.isEmpty {
        AllDoneView(compact: true)
      } else {
        VStack(alignment: .leading, spacing: 5) {
          ForEach(entry.list.items.prefix(3)) { item in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Circle()
                .strokeBorder(item.isOverdue ? Color.red : Color.secondary.opacity(0.6), lineWidth: 1.25)
                .frame(width: 9, height: 9)
              Text(item.title)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
            }
          }
        }
        Spacer(minLength: 0)
        if entry.list.count > 3 {
          Text(String(localized: "+\(entry.list.count - 3) more"))
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

private struct MediumTasksWidgetView: View {
  let entry: SeptaskTasksEntry
  let accent: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      WidgetListHeader(list: entry.list, accent: accent, compact: false)

      if entry.snapshot.isRedacted {
        RedactedCountView(list: entry.list, compact: false)
      } else if entry.list.items.isEmpty {
        AllDoneView(compact: false)
      } else {
        VStack(alignment: .leading, spacing: 5) {
          ForEach(entry.list.items.prefix(4)) { item in
            InteractiveTaskRowView(item: item, accent: accent, showSubtitle: false)
          }
        }
        Spacer(minLength: 0)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

private struct LargeTasksWidgetView: View {
  let entry: SeptaskTasksEntry
  let accent: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      WidgetListHeader(list: entry.list, accent: accent, compact: false)

      if entry.snapshot.isRedacted {
        RedactedCountView(list: entry.list, compact: false)
      } else if entry.list.items.isEmpty {
        AllDoneView(compact: false)
      } else {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(entry.list.items.prefix(9)) { item in
            InteractiveTaskRowView(item: item, accent: accent, showSubtitle: true)
          }
        }
        Spacer(minLength: 0)
        if entry.list.count > 9 {
          Text(String(localized: "+\(entry.list.count - 9) more"))
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

// MARK: - Shared Rows & Chrome

private struct WidgetListHeader: View {
  let list: TasksWidgetListSummary
  let accent: Color
  let compact: Bool

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: list.symbol)
        .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
        .foregroundStyle(accent)
        .widgetAccentable()

      Text(list.title)
        .font(compact ? .subheadline.weight(.semibold) : .headline.weight(.semibold))
        .foregroundStyle(.primary)
        .lineLimit(1)

      if list.count > 0 {
        Text("\(list.count)")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 4)

      Link(destination: TasksWidgetDeepLink.quickAdd.url) {
        Image(systemName: "plus")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 24, height: 24)
          .background(Color.secondary.opacity(0.12), in: Circle())
          .contentShape(Rectangle())
      }
      .accessibilityLabel("Quick Add Task")
    }
  }
}

private struct InteractiveTaskRowView: View {
  let item: TasksWidgetTaskItem
  let accent: Color
  let showSubtitle: Bool

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      Button(intent: CompleteTaskWidgetIntent(taskID: item.id)) {
        Image(systemName: "circle")
          .font(.system(size: 15, weight: .regular))
          .foregroundStyle(item.isOverdue ? Color.red : Color.secondary.opacity(0.75))
          .frame(width: 20, height: 20)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Complete \(item.title)")

      Link(destination: TasksWidgetDeepLink.task(id: item.id).url) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(item.title)
            .font(.callout)
            .foregroundStyle(.primary)
            .lineLimit(1)

          if item.isStarred {
            Image(systemName: "star.fill")
              .font(.caption2)
              .foregroundStyle(Color(red: 0.95, green: 0.65, blue: 0.12))
              .widgetAccentable()
          }

          Spacer(minLength: 4)

          if let time = item.timeBadge {
            Text(time)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          } else if let deadline = item.deadlineBadge, item.isOverdue {
            Text(deadline)
              .font(.caption2.weight(.medium))
              .foregroundStyle(.red)
              .lineLimit(1)
          } else if showSubtitle, let subtitle = item.subtitle, !subtitle.isEmpty {
            Text(subtitle)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        .contentShape(Rectangle())
      }
    }
  }
}

private struct AllDoneView: View {
  let compact: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Spacer(minLength: 0)
      HStack(spacing: 6) {
        Image(systemName: "checkmark.circle")
          .font(compact ? .subheadline : .body)
          .foregroundStyle(.secondary)
        Text("All done")
          .font(compact ? .caption : .subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
  }
}

private struct RedactedCountView: View {
  let list: TasksWidgetListSummary
  let compact: Bool

  private var countPhrase: String {
    if list.count == 0 { return "All done" }
    if list.kind == .today { return String(localized: "\(list.count) tasks today") }
    return String(localized: "\(list.count) tasks")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Spacer(minLength: 0)
      HStack(spacing: 6) {
        Image(systemName: "lock.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(countPhrase)
          .font(compact ? .caption.weight(.medium) : .subheadline.weight(.medium))
          .foregroundStyle(.primary)
      }
      if !compact {
        Text("Unlock Septena to view task titles")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
  }
}

// MARK: - iOS Lock Screen Accessories

#if os(iOS)
private struct AccessoryRectangularTasksView: View {
  let entry: SeptaskTasksEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 4) {
        Image(systemName: entry.list.symbol)
          .font(.caption2.weight(.semibold))
        Text(entry.list.title)
          .font(.caption2.weight(.semibold))
        Spacer()
        if entry.list.count > 0 {
          Text("\(entry.list.count)")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }

      if entry.snapshot.isRedacted {
        Text(entry.list.count == 0 ? "All done" : String(localized: "\(entry.list.count) tasks"))
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if entry.list.items.isEmpty {
        Text("All done")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(entry.list.items.prefix(2)) { item in
          Text(item.title)
            .font(.caption)
            .lineLimit(1)
        }
      }
    }
  }
}

private struct AccessoryCircularTasksView: View {
  let entry: SeptaskTasksEntry

  var body: some View {
    ZStack {
      AccessoryWidgetBackground()
      VStack(spacing: 1) {
        if entry.list.count > 0 {
          Text("\(entry.list.count)")
            .font(.title3.weight(.semibold))
          Image(systemName: entry.list.symbol)
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else {
          Image(systemName: "checkmark")
            .font(.body.weight(.semibold))
        }
      }
    }
  }
}

private struct AccessoryInlineTasksView: View {
  let entry: SeptaskTasksEntry

  var body: some View {
    if entry.list.count == 0 {
      Label("All done", systemImage: "checkmark.circle.fill")
    } else if entry.list.kind == .today {
      Text(String(localized: "\(entry.list.count) tasks today"))
    } else {
      Text("\(entry.list.count) · \(entry.list.title)")
    }
  }
}
#endif

// MARK: - Helpers

private enum WidgetColorHelper {
  static func color(fromHex hex: String) -> Color {
    let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard cleaned.count == 6, let n = UInt32(cleaned, radix: 16) else { return .accentColor }
    let r = Double((n >> 16) & 0xFF) / 255.0
    let g = Double((n >> 8) & 0xFF) / 255.0
    let b = Double(n & 0xFF) / 255.0
    return Color(red: r, green: g, blue: b)
  }
}
