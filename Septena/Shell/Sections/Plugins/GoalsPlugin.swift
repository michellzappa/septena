import SwiftUI

// Goals — free-text intentions tagged with section keys. Skill-only;
// goals don't appear on the Today timeline so `todayEvents` returns [].

@MainActor
enum GoalsPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["goals"]!
  }

  static func todayEvents(date: String, ctx: TodayContext) -> [TodayEvent] { [] }

  static var mcpSkill: SectionSkill? {
    SectionSkill(
      key: "goals",
      summary: "Free-text intentions tagged with section keys. Always available.",
      tools: [
        SectionSkill.Tool("goals_list",   "All goals"),
        SectionSkill.Tool("goals_create", "New goal, optionally tagged with section keys",
              inputs: "required: text · optional: sections (array of section keys)"),
        SectionSkill.Tool("goals_update", "Update text and/or tags. `sections` REPLACES existing tags",
              inputs: "required: id · optional: text, sections (replaces)"),
        SectionSkill.Tool("goals_delete", "Remove",
              inputs: "required: id"),
      ],
      body: """
      Goals are short text intentions (e.g. "swim twice a week") tagged \
      with section keys so they surface in the right section view. \
      `goals_update.sections` replaces — fetch first if you want to add.
      """
    )
  }
}
