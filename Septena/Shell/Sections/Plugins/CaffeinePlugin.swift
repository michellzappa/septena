import SwiftUI

// First real-data section migration. Caffeine's Today block, its
// display-label helper, and its full MCP/agent contract all live here.
// Anyone reading or modifying caffeine behavior only edits this file —
// the Today log, the Settings detail pane, and the MCP gateway all
// consume from this single source of truth.

@MainActor
enum CaffeinePlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["caffeine"]!
  }

  // MARK: - Today timeline

  static func todayEvents(date: String, ctx: TodayContext) -> [TodayEvent] {
    let accent = ctx.theme.color(for: "caffeine")
    return ctx.caffeine.map { entry in
      TodayEvent(
        id: "caf-\(entry.id)",
        time: entry.time,
        section: "caffeine",
        color: accent,
        title: label(for: entry),
        detail: entry.beans,
        kind: .caffeine(entry)
      )
    }
  }

  /// Human-readable label for a caffeine entry's brewing method. Used
  /// both by the Today timeline (above) and by the in-flight edit
  /// sheet in TodayLogView when the user changes an entry's method —
  /// keeping the mapping in one place prevents the two surfaces from
  /// drifting apart.
  static func label(for entry: CaffeineEntry) -> String {
    switch entry.method {
    case "v60":       return "V60"
    case "matcha":    return "Matcha"
    case "aeropress": return "Aeropress"
    case "espresso":  return "Espresso"
    default:          return entry.method.capitalized
    }
  }

  // MARK: - MCP / agent contract
  //
  // Tightly bound to the plugin: the read/write tools advertised here
  // ARE the section's contract. Adding a column to CaffeineEvent, or
  // a new method, is a single-file edit that updates the catalog
  // declaration, the tools list, and the label helper together —
  // they can't drift apart because they live in the same file.

  static var mcpSkill: SectionSkill? {
    SectionSkill(
      key: "caffeine",
      summary: "Log coffee, matcha, and other caffeine sources.",
      tools: [
        SectionSkill.Tool("caffeine_events_list", "By day or range. Defaults to last 7 days",
              inputs: "optional: date, from, to, limit"),
        SectionSkill.Tool("caffeine_event_log",   "Log an intake",
              inputs: "required: method (v60|matcha|aeropress|espresso|other) · optional: date (default today), time (HH:MM:SS), beans (CaffeineBean id), grams (dose), note"),
        SectionSkill.Tool("caffeine_event_delete", "Remove an event",
              inputs: "required: id"),
        SectionSkill.Tool("caffeine_beans_list",  "Bean / source catalog"),
        SectionSkill.Tool("caffeine_bean_create", "Add a new source",
              inputs: "required: name"),
        SectionSkill.Tool("caffeine_bean_delete", "Remove a source",
              inputs: "required: id"),
      ],
      body: """
      ### Example
      **"I had a v60 with the Ethiopian beans"**
      ```
      caffeine_beans_list()                                        → find bean id
      caffeine_event_log(method: "v60", beans: <id>, grams: 18)
      ```

      Matcha doesn't need a bean reference unless tracking source.
      """
    )
  }
}
