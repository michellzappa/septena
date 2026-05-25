import SwiftUI

// Digestive event log. The Bristol stool scale labels and the
// detail-line construction (volume, blood, note) live here with the
// rest of the section's contract.

@MainActor
enum GutPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["gut"]!
  }

  // MARK: - First-enable onboarding

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SectionExplainerView(
      sectionKey: "gut",
      title: "Set up Gut",
      intro: "Gut is a private digestive event log. Useful when tracking down a food sensitivity, recovering from antibiotics, or just curious about patterns.",
      bullets: [
        ("Bristol Stool Scale", "1 = hard pellets, 7 = watery. Required for every entry."),
        ("Volume + blood", "Small / medium / large; blood as a count. Both optional."),
        ("Discomfort window", "Optional HH:MM start / end when cramping or pain matters."),
      ],
      actionLabel: "Got it",
      complete: complete
    ))
  }

  // MARK: - Today timeline

  static func todayEvents(date: String, ctx: TodayContext) -> [TodayEvent] {
    let accent = ctx.theme.color(for: "gut")
    return ctx.gut.map { entry in
      TodayEvent(
        id: "gut-\(entry.id)",
        time: entry.time,
        section: "gut",
        color: accent,
        title: bristolLabel(entry.bristol),
        detail: detail(for: entry),
        kind: .gut(entry)
      )
    }
  }

  /// Bristol Stool Scale 1–7 → human label. Also used by TodayLogView's
  /// edit sheet replacement so the displayed string stays in sync.
  static func bristolLabel(_ n: Int) -> String {
    switch n {
    case 1: return "Type 1 — Separate lumps"
    case 2: return "Type 2 — Lumpy sausage"
    case 3: return "Type 3 — Cracked sausage"
    case 4: return "Type 4 — Smooth sausage"
    case 5: return "Type 5 — Soft blobs"
    case 6: return "Type 6 — Fluffy pieces"
    case 7: return "Type 7 — Liquid"
    default: return "Bristol \(n)"
    }
  }

  /// Composite secondary line: volume · blood count · note. Returns nil
  /// when every field is empty so the row renders a clean single-line.
  static func detail(for entry: GutEntry) -> String? {
    var parts: [String] = []
    if let vol = entry.volume { parts.append(vol) }
    if entry.blood > 0 { parts.append("blood \(entry.blood)") }
    if let note = entry.note { parts.append(note) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  // MARK: - MCP / agent contract

  static var mcpSkill: SectionSkill? {
    SectionSkill(
      key: "gut",
      summary: "Digestive event log.",
      tools: [
        SectionSkill.Tool("gut_events_list",  "By day or range. Defaults to last 7 days",
              inputs: "optional: date, from, to, limit"),
        SectionSkill.Tool("gut_event_log",    "Log an event",
              inputs: "required: bristol (1-7) · optional: date (default today), time (HH:MM:SS), blood (boolean), volume (small|medium|large), discomfortLevel (free-form), discomfortStart (HH:MM), discomfortEnd (HH:MM), note"),
        SectionSkill.Tool("gut_event_delete", "Remove an event",
              inputs: "required: id"),
      ],
      body: """
      `bristol` is the Bristol Stool Scale (1 = hard pellets, 7 = watery) and \
      is required. Log `discomfortStart`/`discomfortEnd` as `HH:MM` when the \
      user describes cramping or pain.
      """
    )
  }
}
