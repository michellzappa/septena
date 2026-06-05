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

// MARK: - Category model — the next item in each open category

/// One open category (tasks / chores / habits / …) reduced to its next item
/// plus how many remain in it. Built from the bucket-filtered flat feed, in the
/// feed's existing section order.
private struct NextCategory: Identifiable {
  let kind: String
  let title: String   // the next item's title
  let count: Int      // open items in this category (current bucket)
  let overdue: Bool   // is the next item overdue
  var id: String { kind }
}

private func categories(_ items: [NextItem]) -> [NextCategory] {
  var order: [String] = []
  var byKind: [String: [NextItem]] = [:]
  for item in items {
    if byKind[item.kind] == nil { order.append(item.kind) }
    byKind[item.kind, default: []].append(item)
  }
  return order.map { kind in
    let group = byKind[kind]!
    return NextCategory(kind: kind, title: group[0].title, count: group.count, overdue: group[0].overdue)
  }
}

// MARK: - Home Screen: small — top categories

private struct SmallView: View {
  let entry: NextEntry
  private var cats: [NextCategory] { categories(entry.items) }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Header(bucket: entry.bucket, total: entry.remaining)
      if cats.isEmpty {
        Spacer(minLength: 0)
        AllDone()
        Spacer(minLength: 0)
      } else {
        ForEach(cats.prefix(3)) { CategoryRow(cat: $0, compact: true) }
        Spacer(minLength: 0)
      }
    }
  }
}

// MARK: - Home Screen: medium — one row per open category

private struct MediumView: View {
  let entry: NextEntry
  private var cats: [NextCategory] { categories(entry.items) }

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      Header(bucket: entry.bucket, total: entry.remaining)
      if cats.isEmpty {
        Spacer(minLength: 0)
        AllDone()
        Spacer(minLength: 0)
      } else {
        ForEach(cats.prefix(4)) { CategoryRow(cat: $0, compact: false) }
        Spacer(minLength: 0)
      }
    }
  }
}

// MARK: - Shared home-screen pieces

private struct Header: View {
  let bucket: DayBucket
  let total: Int

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: bucket.icon)
        .font(.system(size: 8, weight: .semibold))
      Text(bucket.title.uppercased())
      Spacer()
      Text("\(total) left")
    }
    .font(.system(size: 9.5, weight: .semibold))
    .foregroundStyle(.secondary)
  }
}

private struct CategoryRow: View {
  let cat: NextCategory
  let compact: Bool

  // Icons −30%, text −15% vs. the prior callout/subheadline/footnote sizes.
  private var iconSize: CGFloat { compact ? 9 : 11 }
  private var iconFrame: CGFloat { compact ? 11 : 14 }
  private var titleSize: CGFloat { compact ? 11 : 12.5 }

  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: kindIcon(cat.kind))
        .font(.system(size: iconSize))
        .foregroundStyle(.secondary)
        .frame(width: iconFrame)
      Text(cat.title)
        .font(.system(size: titleSize, weight: .medium))
        .foregroundStyle(cat.overdue ? Color.red : Color.primary)
        .lineLimit(1)
      Spacer(minLength: 4)
      if cat.count > 1 {
        Text("\(cat.count)")
          .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
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
  private var cats: [NextCategory] { categories(entry.items) }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("NEXT · \(entry.bucket.title.uppercased())")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      if cats.isEmpty {
        Text("All done")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(cats.prefix(2)) { cat in
          HStack(spacing: 5) {
            Image(systemName: kindIcon(cat.kind)).font(.caption2)
            Text(cat.title).font(.caption.weight(.medium)).lineLimit(1)
          }
        }
      }
    }
  }
}

private struct InlineView: View {
  let entry: NextEntry

  var body: some View {
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

// MARK: - Category → glyph

/// Per-category SF Symbol. Now load-bearing (distinguishes categories), not
/// decoration. Mirrors the app's per-section iconography.
private func kindIcon(_ kind: String) -> String {
  switch kind {
  case "task":       return "checklist"
  case "chore":      return "house"
  case "habit":      return "repeat"
  case "supplement": return "pills"
  case "suggestion": return "sparkles"
  default:           return "circle"
  }
}
