import WidgetKit
import SwiftUI

struct NextComplicationView: View {
  let entry: NextEntry

  @Environment(\.widgetFamily) private var family

  var body: some View {
    content
      // Required by WidgetKit (watchOS 10+): without it the widget host
      // refuses to render the view. Circular gets the dark accessory disc;
      // the others are transparent.
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
    case .accessoryCircular:  CircularView(data: entry.data)
    case .accessoryRectangular: RectangularView(data: entry.data)
    case .accessoryInline:    InlineView(data: entry.data)
    case .accessoryCorner:    CornerView(data: entry.data)
    default:                  CircularView(data: entry.data)
    }
  }
}

// MARK: - Corner: glyph shortcut + count along the bezel

private struct CornerView: View {
  let data: NextComplicationData

  var body: some View {
    Image("DiscsMark")
      .font(.title2)
      .widgetLabel {
        Text(data.remaining == 0 ? "All done" : "\(data.remaining) left")
      }
  }
}

// MARK: - Circular: count badge

private struct CircularView: View {
  let data: NextComplicationData

  var body: some View {
    Image("DiscsColor")
      .resizable()
      .scaledToFit()
      .padding(2)
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
