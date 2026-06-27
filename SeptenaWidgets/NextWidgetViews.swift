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

  /// Home Screen families share the list-widget card surface (`Theme.cardSurface`)
  /// with Today, so the two read as siblings. Lock Screen accessories stay
  /// transparent — the system renders them monochrome over the wallpaper — and
  /// the circular accessory uses the standard dark accessory disc.
  @ViewBuilder
  private var background: some View {
    switch family {
    case .accessoryCircular:
      AccessoryWidgetBackground()
    case .accessoryRectangular, .accessoryInline:
      Color.clear
    default:
      Theme.cardSurface
    }
  }

  @ViewBuilder
  private var content: some View {
    switch family {
    case .systemSmall:          SmallView(entry: entry).widgetHorizontalBleed()
    case .systemMedium:         MediumView(entry: entry).widgetHorizontalBleed()
    case .accessoryRectangular: RectangularView(entry: entry)
    case .accessoryInline:      InlineView(entry: entry)
    case .accessoryCircular:    CircularView(entry: entry)
    default:                    SmallView(entry: entry).widgetHorizontalBleed()
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
  var showsOverdueMarker: Bool { kind == "chore" && overdue }
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

// MARK: - Home Screen: small (top 3 categories) & medium (top 4)
//
// Both render through the shared `WidgetListLayout` so Next and Today are the
// same widget with a different accent and leading glyph. Next's glyph is the
// per-category SF Symbol — load-bearing, it tells the categories apart — tinted
// with `Theme.nextAccent`; the header carries the same accent on the bucket icon.

private struct SmallView: View { var entry: NextEntry; var body: some View { HomeList(entry: entry, compact: true) } }
private struct MediumView: View { var entry: NextEntry; var body: some View { HomeList(entry: entry, compact: false) } }

private struct HomeList: View {
  let entry: NextEntry
  let compact: Bool
  private var cats: [NextCategory] { categories(entry.items) }

  var body: some View {
    WidgetListLayout(
      compact: compact,
      header: WidgetListHeader(
        icon: entry.bucket.icon,
        title: entry.bucket.title,
        accent: Theme.nextAccent,
        trailing: "\(entry.remaining)",
        compact: compact
      ),
      isEmpty: cats.isEmpty
    ) {
      ForEach(cats.prefix(compact ? 3 : 4)) { cat in
        WidgetListRow(
          compact: compact,
          title: displayTitle(cat.title),
          overdue: cat.showsOverdueMarker,
          trailingCount: cat.count
        ) {
          Image(systemName: kindIcon(cat.kind))
            .font(.system(size: compact ? 11 : 12))
            .foregroundStyle(Theme.nextAccent)
        }
      }
    }
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
            Text(displayTitle(cat.title)).font(.caption.weight(.medium)).lineLimit(1)
          }
        }
      }
    }
  }
}

private struct InlineView: View {
  let entry: NextEntry

  var body: some View {
    Text(entry.first.map { displayTitle($0.title) } ?? "All done")
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

// MARK: - Title cleanup

/// Category titles arrive emoji-prefixed from the shared Next snapshot (e.g.
/// `"☕️ Coffee"`) — the watch list leans on the glyph to tell items apart. The
/// widget already shows a load-bearing per-kind SF Symbol, so the leading emoji
/// is redundant noise here. Strip it for display only; the shared feed (watch +
/// phone Next list) is left untouched.
private func displayTitle(_ title: String) -> String {
  guard let first = title.unicodeScalars.first,
        first.properties.isEmojiPresentation || (first.properties.isEmoji && first.value > 0x7F),
        let space = title.firstIndex(of: " ")
  else { return title }
  return String(title[title.index(after: space)...])
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
