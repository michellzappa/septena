import SwiftUI

// Cannabis log section. Same pattern as CaffeinePlugin: one file owns
// the Today block, the display-label helper, and the full MCP contract,
// so adding a new method or column updates everything in lock-step.

@MainActor
enum CannabisPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["cannabis"]!
  }

  // MARK: - Today timeline

  static func todayEvents(date: String, ctx: TodayContext) -> [TodayEvent] {
    let accent = ctx.theme.color(for: "cannabis")
    return ctx.cannabis.map { entry in
      TodayEvent(
        id: "cnb-\(entry.id)",
        time: entry.time,
        section: "cannabis",
        color: accent,
        title: label(for: entry),
        detail: entry.strain,
        kind: .cannabis(entry)
      )
    }
  }

  /// Human-readable label for an intake method. Used by both the Today
  /// row and the edit sheet in TodayLogView — single source of truth.
  static func label(for entry: CannabisEntry) -> String {
    switch entry.method {
    case "vape":   return "Vape"
    case "edible": return "Edible"
    default:       return entry.method.capitalized
    }
  }

  // MARK: - MCP / agent contract

  static var mcpSkill: SectionSkill? {
    SectionSkill(
      key: "cannabis",
      summary: "Log cannabis intake with strain and effect.",
      tools: [
        SectionSkill.Tool("cannabis_events_list",  "By day or range. Defaults to last 7 days",
              inputs: "optional: date, from, to, limit"),
        SectionSkill.Tool("cannabis_event_log",    "Log an intake",
              inputs: "required: method (vape|edible) · optional: date (default today), time (HH:MM:SS), strain (CannabisStrain id), hit (count for vape), grams (for edibles), effect (free-form, e.g. relaxed/creative), note"),
        SectionSkill.Tool("cannabis_event_delete", "Remove an event",
              inputs: "required: id"),
        SectionSkill.Tool("cannabis_strains_list", "Strain catalog"),
        SectionSkill.Tool("cannabis_strain_create", "Add a strain",
              inputs: "required: name"),
        SectionSkill.Tool("cannabis_strain_delete", "Remove a strain",
              inputs: "required: id"),
      ],
      body: """
      `effect` is subjective free-form: "relaxed", "creative", "couch-locked".
      """
    )
  }
}
