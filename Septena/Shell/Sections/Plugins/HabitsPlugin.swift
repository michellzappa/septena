import SwiftUI

@MainActor
enum HabitsPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["habits"]!
  }

  static func todayEvents(date: String, ctx: TodayContext) -> [TodayEvent] {
    let accent = ctx.theme.color(for: "habits")
    return ctx.habits
      .filter { $0.done }
      .compactMap { habit -> TodayEvent? in
        guard let time = habit.time else { return nil }
        return TodayEvent(
          id: "habit-\(habit.id)",
          time: time,
          section: "habits",
          color: accent,
          title: [habit.emoji, habit.name].compactMap { $0 }.joined(separator: " "),
          detail: nil,
          kind: .habit(habit)
        )
      }
  }

  static var mcpSkill: SectionSkill? {
    SectionSkill(
      key: "habits",
      summary: "Daily routines with done/skipped state per date.",
      tools: [
        SectionSkill.Tool("habits_list",   "Definitions with today's state merged",
              inputs: "optional: date (YYYY-MM-DD, default today)"),
        SectionSkill.Tool("habits_create", "New definition",
              inputs: "required: title, bucket (morning|evening|anytime) · optional: emoji"),
        SectionSkill.Tool("habits_update", "Update fields",
              inputs: "required: id · optional: title, bucket (morning|evening|anytime), emoji"),
        SectionSkill.Tool("habits_delete", "Delete definition and all its events",
              inputs: "required: id"),
        SectionSkill.Tool("habits_toggle", "Mark done/skipped/unmarked for a date. Idempotent",
              inputs: "required: id, done · optional: date, skipped"),
      ],
      body: """
      Habits separate **definitions** (the thing) from **events** (per-date state).

      ### Examples
      **"Mark my morning habits done"**
      ```
      habits_list()                         → filter bucket == "morning"
      habits_toggle(id, done: true)         → for each
      ```

      **"I'm taking a rest day from exercise"**
      ```
      habits_toggle(id, done: false, skipped: true)
      ```

      ### Don't
      - Don't create a new definition to log today's completion.
      """
    )
  }
}
