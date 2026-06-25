import EventKit
import SwiftUI

/// A read-only calendar-event row for the Tasks lists (Today + Upcoming).
///
/// Mirrors `CheckableRow`'s metrics — the same leading column width and the same
/// `rowHInset` / `rowVInset` paddings — so an event's title starts at the same X
/// as every task title in the list. It carries no checkbox and no tap action:
/// Septena never writes events (`CalendarBridge` is read-only), so these rows are
/// here purely to read the day's agenda at a glance alongside its tasks.
struct CalendarEventRow: View {
  let event: EKEvent
  /// Tint used when the event's own calendar has no color (rare). The deep list
  /// passes `theme.color(for: "calendar")` so the fallback matches the dashboard.
  var fallback: Color

  @Environment(\.rowHInset) private var rowHInset

  /// The event's calendar color — the leading rail and the time stamp wear it,
  /// the way the dashboard timeline tints its calendar bars.
  private var color: Color {
    event.calendar?.cgColor.map { Color($0) } ?? fallback
  }

  /// Locale-aware short start time ("09:00" / "9:00 AM"). Nil for all-day events,
  /// which read as a plain titled bar with no clock.
  private var timeLabel: String? {
    guard !event.isAllDay else { return nil }
    return Self.timeFormatter.string(from: event.startDate)
  }

  /// The event's title, never blank. `EKEvent.title` is an implicitly-unwrapped
  /// `String!`, so `?? "Event"` only catches a true nil — but busy blocks,
  /// private/declined invites, and some imported calendars hand us an *empty*
  /// (or whitespace-only) string, which slid past that guard and drew a blank
  /// agenda line. Trim and fall back so every row reads as something.
  private var displayTitle: String {
    let trimmed = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Event" : trimmed
  }

  var body: some View {
    // A condensed agenda line — denser and quieter than a task row (smaller
    // text, tighter rows) so the whole block reads as a calm reference strip,
    // halfway to Things' grey calendar card. The calendar-colored time keeps it
    // scannable and ties each event to its calendar.
    HStack(alignment: .center, spacing: 8) {
      // The calendar color rides the time stamp itself (not a leading rail) —
      // it ties the event to its calendar while keeping the strip quiet. All-day
      // events have no time, so they read as a plain titled line.
      if let timeLabel {
        Text(timeLabel)
          .font(.system(size: 13))
          .monospacedDigit()
          .foregroundStyle(color)
      }
      Text(displayTitle)
        .font(.system(size: 13))
        .foregroundStyle(event.isAllDay ? Theme.inkSecondary : Theme.inkPrimary)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, rowHInset)
    .padding(.vertical, 5)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityText)
  }

  private var accessibilityText: String {
    if let timeLabel { return "\(timeLabel), \(displayTitle)" }
    return "All day, \(displayTitle)"
  }

  private static let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = .current
    f.timeStyle = .short
    f.dateStyle = .none
    return f
  }()
}

extension EKEvent {
  /// A stable identity for `ForEach`. `eventIdentifier` is shared across the
  /// occurrences of a recurring event, so it's paired with the start instant to
  /// keep each occurrence distinct (and to survive a nil identifier).
  var calendarRowID: String {
    "\(eventIdentifier ?? "evt")@\(startDate.timeIntervalSince1970)"
  }
}
