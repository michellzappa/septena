import SwiftUI

@MainActor
enum SupplementsPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["supplements"]!
  }

  static func todayEvents(date: String, ctx: TodayContext) -> [TodayEvent] {
    let accent = ctx.theme.color(for: "supplements")
    return ctx.supplements
      .filter { $0.done }
      .compactMap { sup -> TodayEvent? in
        guard let time = sup.time else { return nil }
        return TodayEvent(
          id: "supp-\(sup.id)",
          time: time,
          section: "supplements",
          color: accent,
          title: [sup.emoji, sup.name].compactMap { $0 }.joined(separator: " "),
          detail: nil,
          kind: .supplement(sup)
        )
      }
  }

  static var mcpSkill: SectionSkill? {
    SectionSkill(
      key: "supplements",
      summary: "Daily supplement log — same shape as habits.",
      tools: [
        SectionSkill.Tool("supplements_list",   "Definitions with today's state merged",
              inputs: "optional: date (default today)"),
        SectionSkill.Tool("supplements_create", "New definition",
              inputs: "required: title · optional: emoji"),
        SectionSkill.Tool("supplements_update", "Update fields",
              inputs: "required: id · optional: title, emoji"),
        SectionSkill.Tool("supplements_delete", "Delete definition and events",
              inputs: "required: id"),
        SectionSkill.Tool("supplements_toggle", "Mark taken/untaken for a date",
              inputs: "required: id, done · optional: date"),
      ],
      body: """
      Same definition+state shape as habits. \
      `supplements_toggle(id, done: false)` removes today's mark.
      """
    )
  }
}
