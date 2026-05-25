import SwiftUI

@MainActor
enum ChoresPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["chores"]!
  }

  static func todayEvents(date: String, ctx: TodayContext) -> [TodayEvent] {
    let accent = ctx.theme.color(for: "chores")
    return ctx.chores
      .filter { $0.lastCompleted == date }
      .map { chore in
        TodayEvent(
          id: "chore-\(chore.id)",
          time: chore.lastCompletedTime ?? "00:00",
          section: "chores",
          color: accent,
          title: [chore.emoji, chore.name].compactMap { $0 }.joined(separator: " "),
          detail: nil,
          kind: .chore(chore)
        )
      }
  }

  static var mcpSkill: SectionSkill? {
    SectionSkill(
      key: "chores",
      summary: "Recurring household tasks with computed due dates.",
      tools: [
        SectionSkill.Tool("chores_list",       "Definitions + computed due/last-completed (replays 180d)"),
        SectionSkill.Tool("chores_create",     "New chore",
              inputs: "required: title, cadenceDays · optional: emoji"),
        SectionSkill.Tool("chores_update",     "Update fields",
              inputs: "required: id · optional: title, cadenceDays (min 1), emoji"),
        SectionSkill.Tool("chores_delete",     "Delete definition and events",
              inputs: "required: id"),
        SectionSkill.Tool("chores_complete",   "Log completion for today or a given date",
              inputs: "required: id · optional: date (default today)"),
        SectionSkill.Tool("chores_defer",      "Defer to 'day' (tomorrow) or 'weekend' (next Saturday)",
              inputs: "required: id, mode (day|weekend) · optional: date"),
        SectionSkill.Tool("chores_uncomplete", "Remove most recent completion",
              inputs: "required: id · optional: date"),
      ],
      body: """
      `chores_list` replays the last 180 days of events to compute when each \
      chore is next due. Surface overdue items first.
      """
    )
  }
}
