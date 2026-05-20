import WidgetKit
import SwiftUI

struct NextComplicationView: View {
  let entry: NextEntry

  @Environment(\.widgetFamily) private var family

  var body: some View {
    switch family {
    case .accessoryCircular:  CircularView(data: entry.data)
    case .accessoryRectangular: RectangularView(data: entry.data)
    case .accessoryInline:    InlineView(data: entry.data)
    default:                  CircularView(data: entry.data)
    }
  }
}

// MARK: - Circular: count badge

private struct CircularView: View {
  let data: NextComplicationData

  var body: some View {
    ZStack {
      AccessoryWidgetBackground()
      if data.remaining == 0 {
        Image(systemName: "checkmark")
          .font(.title3.bold())
          .foregroundStyle(.green)
      } else {
        VStack(spacing: 0) {
          Text("\(data.remaining)")
            .font(.title3.bold())
          Text(data.bucket.prefix(3).uppercased())
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}

// MARK: - Rectangular: bucket + first item

private struct RectangularView: View {
  let data: NextComplicationData

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(data.bucket.capitalized)
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
          .lineLimit(2)
      } else {
        Text("All done")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 2)
  }
}

// MARK: - Inline: single line

private struct InlineView: View {
  let data: NextComplicationData

  var body: some View {
    if data.remaining == 0 {
      Label("All done", systemImage: "checkmark.circle.fill")
    } else {
      Text("\(data.remaining) · \(data.bucket.capitalized)")
    }
  }
}
