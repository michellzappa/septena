import SwiftUI

// Goals — free-text intentions tagged with section keys. Skill-only;
// goals don't appear on the Today timeline so `todayEvents` returns [].

@MainActor
enum GoalsPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["goals"]!
  }

  static func todayEvents(date: String, ctx: TodayContext) -> [TodayEvent] { [] }

  static var logActions: [LogAction] {
    [LogAction(id: "new", title: "New goal", systemImage: "plus")]
  }

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SectionExplainerView(
      sectionKey: "goals",
      title: "Goals",
      intro: "Short text intentions tagged with section keys. A training goal shows up inside Training, a nutrition goal inside Nutrition — wherever you're already looking.",
      bullets: [
        .init("Free-form text", "\"Swim twice a week\", \"Read 12 books this year.\" No deadlines, no progress bars — just readable intentions.", icon: "text.alignleft"),
        .init("Tag by section", "One or more section keys per goal; they surface in the relevant destinations automatically.", icon: "tag"),
      ],
      primaryActionLabel: "Add your first goal",
      complete: complete
    ))
  }

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
