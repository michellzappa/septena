import WidgetKit
import SwiftUI
import UIKit

/// Deep link the whole widget opens. Routed in `App.handleDeepLink`.
private let nextDeepLink = URL(string: "septena://next")

struct NextWidgetView: View {
  let entry: NextEntry
  @Environment(\.widgetFamily) private var family

  var body: some View {
    content
      .widgetURL(nextDeepLink)
      .containerBackground(for: .widget) { background }
  }

  /// Home Screen families get an adaptive opaque surface (white in light,
  /// near-black in dark) via system colors, so the widget reads correctly in
  /// both appearances. Lock Screen accessories stay transparent — the system
  /// renders them monochrome over the wallpaper — and the circular accessory
  /// uses the standard dark accessory disc.
  @ViewBuilder
  private var background: some View {
    switch family {
    case .accessoryCircular:
      AccessoryWidgetBackground()
    case .accessoryRectangular, .accessoryInline:
      Color.clear
    default:
      LinearGradient(
        colors: [Color(.systemBackground), Color(.secondarySystemBackground)],
        startPoint: .top,
        endPoint: .bottom
      )
    }
  }

  @ViewBuilder
  private var content: some View {
    switch family {
    case .systemSmall:          SmallView(entry: entry)
    case .systemMedium:         MediumView(entry: entry)
    case .accessoryRectangular: RectangularView(entry: entry)
    case .accessoryInline:      InlineView(entry: entry)
    case .accessoryCircular:    CircularView(entry: entry)
    default:                    SmallView(entry: entry)
    }
  }
}

// MARK: - "more" phrasing shared across families

/// "+2 more" / "+1 more" / nil when the hero item is the only one.
private func moreText(_ entry: NextEntry) -> String? {
  let more = entry.remaining - 1
  guard more > 0 else { return nil }
  return "+\(more) more"
}

// MARK: - Home Screen: small — one hero item

private struct SmallView: View {
  let entry: NextEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      BucketEyebrow(bucket: entry.bucket)
      Spacer(minLength: 6)
      if let next = entry.first {
        Text(next.title)
          .font(.title3.weight(.semibold))
          .foregroundStyle(next.overdue ? Color.red : Color.primary)
          .lineLimit(3)
      } else {
        AllDone()
      }
      Spacer(minLength: 6)
      if let more = moreText(entry) {
        Text(more)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

// MARK: - Home Screen: medium — hero item + a hint of what's after

private struct MediumView: View {
  let entry: NextEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      BucketEyebrow(bucket: entry.bucket)

      if let next = entry.first {
        VStack(alignment: .leading, spacing: 3) {
          Text(next.title)
            .font(.title2.weight(.bold))
            .foregroundStyle(next.overdue ? Color.red : Color.primary)
            .lineLimit(2)
          if let trailing = next.trailing, !trailing.isEmpty {
            Text(trailing)
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 0)
        // One step of look-ahead — keeps the focus on "next" while hinting
        // continuity, without becoming a checklist.
        if entry.items.count > 1 {
          let after = entry.items[1]
          (Text("Then  ").foregroundStyle(.tertiary)
            + Text(after.title).foregroundStyle(.secondary))
            .font(.subheadline)
            .lineLimit(1)
        }
      } else {
        Spacer(minLength: 0)
        AllDone()
        Spacer(minLength: 0)
      }
    }
  }
}

// MARK: - Shared home-screen pieces

private struct BucketEyebrow: View {
  let bucket: DayBucket

  var body: some View {
    Text("NEXT · \(bucket.title.uppercased())")
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.secondary)
  }
}

private struct AllDone: View {
  var body: some View {
    Text("All done")
      .font(.title3.weight(.semibold))
      .foregroundStyle(.secondary)
  }
}

// MARK: - Lock Screen accessories

private struct RectangularView: View {
  let entry: NextEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("NEXT · \(entry.bucket.title.uppercased())")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      if let next = entry.first {
        Text(next.title)
          .font(.caption.weight(.medium))
          .lineLimit(2)
        if let more = moreText(entry) {
          Text(more)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      } else {
        Text("All done")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct InlineView: View {
  let entry: NextEntry

  var body: some View {
    // Inline is a single short line; lead with the thing, no glyph.
    Text(entry.first?.title ?? "All done")
  }
}

private struct CircularView: View {
  let entry: NextEntry

  var body: some View {
    VStack(spacing: 0) {
      Text(entry.remaining == 0 ? "✓" : "\(entry.remaining)")
        .font(.title2.weight(.semibold).monospacedDigit())
      Text("left")
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
        .opacity(entry.remaining == 0 ? 0 : 1)
    }
  }
}
