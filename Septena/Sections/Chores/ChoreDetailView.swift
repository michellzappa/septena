import SwiftUI
import SwiftData

// Per-item detail for a chore — reached by tapping a chore row (the checkbox
// still completes it). Surfaces completion history and the *learned* cadence:
// how often the chore is actually done versus the cadence the user configured,
// plus when it's next due. All derived at read time from the chore's `complete`
// events via `ChecklistMirror.choreCompletionDates` and the shared `Cadence`
// learner. A thin builder over the shared `LogDetailScaffold`.

struct ChoreDetailView: View {
  let chore: ChoreItem
  /// Routes the toolbar "Edit" back to the parent's `EditChoreSheet`.
  let onEdit: () -> Void

  @Environment(SectionTheme.self) private var theme
  @Environment(DayClock.self) private var clock
  private var accent: Color { theme.color(for: "chores") }

  var body: some View {
    LogDetailScaffold(
      title: chore.name,
      accent: accent,
      load: { ctx in
        Self.detail(chore: chore,
                    dates: ChecklistMirror.choreCompletionDates(context: ctx, choreID: chore.id),
                    today: clock.today)
      },
      onEdit: onEdit
    )
  }

  static func detail(chore: ChoreItem, dates: [String], today: String) -> LogDetail {
    let cadence = Cadence.acrossDays(dates: dates)
    let learnedDays = cadence?.medianGap
    let confident = cadence?.isConfident ?? false
    let lastCompleted = chore.lastCompleted ?? dates.last

    var d = LogDetail()
    d.emoji = chore.emoji
    d.subtitle = dates.isEmpty
      ? "Not done yet"
      : "Done \(dates.count) \(dates.count == 1 ? "time" : "times")"

    d.tiles = [
      LogStat(value: lastCompleted.map { LogDetailFormat.relativeDay($0, today: today) } ?? "—", caption: "Last done"),
      LogStat(value: chore.dueDate.map { LogDetailFormat.relativeDay($0, today: today) } ?? "—",
              caption: "Next due",
              tone: chore.daysOverdue > 0 ? .warn : .normal),
    ]

    // Cadence card — configured vs learned, plus a prediction when trusted.
    var cadenceCard = LogCard(title: "Cadence")
    if let configured = chore.cadenceDays {
      cadenceCard.rows.append(LogKeyValue(label: "Scheduled",
                                          value: "every \(cadenceLabel(configured))"))
    }
    if let learned = learnedDays {
      cadenceCard.rows.append(LogKeyValue(label: "Actual rhythm",
                                          value: "about every \(cadenceLabel(learned))",
                                          muted: !confident))
      if confident, let predicted = learnedNextDue(last: lastCompleted, gap: learned) {
        cadenceCard.note = "At your real pace, expect this again \(LogDetailFormat.relativeDay(predicted, today: today))."
      } else if !confident {
        cadenceCard.note = "Learning your rhythm — a couple more completions and Septena will predict the next one."
      }
    } else {
      cadenceCard.note = "No rhythm yet — the schedule drives the next-due date until there's a pattern to learn from."
    }
    d.cards = [cadenceCard]

    if !dates.isEmpty {
      let done = Set(dates)
      d.heatmap = LogHeatmap(firstDate: LogDetailFormat.firstDate(dates),
                             level: { HeatmapLevel.done(done.contains($0)) })
    }
    d.recent = dates.reversed().prefix(12).map {
      LogRecent(title: LogDetailFormat.longDay($0), trailing: LogDetailFormat.relativeDay($0, today: today))
    }
    return d
  }

  private static func learnedNextDue(last: String?, gap: Int) -> String? {
    guard let last, let base = SeptenaDate.parse(last),
          let next = Calendar.current.date(byAdding: .day, value: gap, to: base) else { return nil }
    return SeptenaDate.format(next)
  }

  private static func cadenceLabel(_ days: Int) -> String {
    switch days {
    case 1: return "day"
    case 7: return "week"
    case 14: return "2 weeks"
    case 30, 31: return "month"
    default: return "\(days) days"
    }
  }
}
