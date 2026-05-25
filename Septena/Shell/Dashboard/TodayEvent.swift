import SwiftUI
import EventKit

// Today log event model — shared between TodayLogView (which renders rows
// and dispatches edits via `kind`) and SectionPlugin implementations
// (which construct events for their own section in a single loop).
//
// `kind` carries the typed payload so the row renderer can wire each
// row to its section-specific edit sheet / context menu. New section
// plugins that want fully-generic Today rendering can use `.generic`
// — TodayLogView falls back to plain text rendering for that case.

enum TodayEventKind {
  case habit(HabitDayItem)
  case supplement(SupplementDayItem)
  case chore(ChoreItem)
  case task(SeptenaTask)
  case caffeine(CaffeineEntry)
  case cannabis(CannabisEntry)
  case gut(GutEntry)
  case nutrition(NutritionEntry)
  case training(ExerciseEntry)
  case calendar(EKEvent)
  case mood(MoodEntry)
}

struct TodayEvent: Identifiable {
  let id: String
  let time: String      // HH:MM — used for sort and display
  let section: String
  let color: Color
  let title: String
  let detail: String?
  let kind: TodayEventKind

  var timeLabel: String { time }
}
