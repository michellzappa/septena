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

  @Environment(\.rowHInset) private var rowHInset

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
    HStack(alignment: .center, spacing: Theme.iconTextGap) {
      // The time rides the same `checkboxTap` column (centered + nudged) as the
      // row checkboxes and header icons above, so it sits under that leading
      // grid and the title lands on the shared task-title X. Neutral ink keeps
      // the strip quiet; all-day events leave the column empty but still reserved.
      Group {
        if let timeLabel {
          Text(timeLabel)
            .font(.system(size: 11))
            .monospacedDigit()
            .lineLimit(1)
            // The time is wider than the `checkboxTap` column it centers in, so
            // pin it to its ideal one-line width and let it overflow rather than
            // wrap/truncate ("9:00 AM" locales included).
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(Theme.inkSecondary)
        }
      }
      .frame(width: Theme.checkboxTap, alignment: .center)
      .offset(x: -Theme.checkboxLeadingNudge)
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
