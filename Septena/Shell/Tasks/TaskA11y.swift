import Foundation

// Shared spoken vocabulary for task rows — SwiftUI markers and the AppKit
// kit both read from here so VoiceOver never learns two dialects for the
// same cue. English SOURCE strings match existing Localizable.xcstrings
// keys (AgentCueMarker / ArrivedTodayMarker / "Has notes") — do not invent
// parallel wording.

enum TaskA11y {

  // MARK: Cue labels (exact catalog keys)

  static var agentCue: String {
    String(localized: "Added by Claude, not yet seen",
           comment: "Agent provenance cue on a fresh unacknowledged task")
  }

  static var arrivedToday: String {
    String(localized: "Arrived in Today",
           comment: "Cue for a task that rolled into Today on its own")
  }

  static var hasNotes: String {
    String(localized: "Has notes",
           comment: "Task row trailing notes glyph")
  }

  static var recurring: String {
    String(localized: "Repeats",
           comment: "Task row trailing recurrence glyph")
  }

  // MARK: Checkbox

  /// Primary label for the row checkbox. Keeps the control short; state and
  /// cue fragments ride on `checkboxValue` / `checkboxHelp`.
  static func checkboxLabel(isHeading: Bool = false) -> String {
    if isHeading {
      return String(localized: "Section",
                    comment: "A11y: project heading row (not a to-do)")
    }
    return String(localized: "Task",
                  comment: "A11y: task checkbox label")
  }

  static func checkboxValue(isDone: Bool) -> String {
    isDone
      ? String(localized: "Completed", comment: "A11y: checkbox value when done")
      : String(localized: "Incomplete", comment: "A11y: checkbox value when open")
  }

  /// Extra VoiceOver help for open-box cues (proposal / Today / agent / unread).
  static func checkboxHelp(isDone: Bool,
                           isDashed: Bool,
                           isToday: Bool,
                           tenureFill: Double?,
                           agentCue: Bool,
                           cornerDot: Bool) -> String? {
    guard !isDone else { return nil }
    var parts: [String] = []
    if isDashed {
      parts.append(String(localized: "Proposal, not yet confirmed",
                          comment: "A11y: dashed checkbox = MCP triage proposal"))
    }
    if isToday {
      parts.append(String(localized: "On Today",
                          comment: "A11y: task is pinned/due on Today"))
    } else if let tenureFill, tenureFill > 0 {
      parts.append(String(localized: "Carried on Today",
                          comment: "A11y: tenure dial — days deferred on Today"))
    }
    if agentCue { parts.append(Self.agentCue) }
    if cornerDot {
      parts.append(String(localized: "Unread conversation",
                          comment: "A11y: corner dot = started agent conversation"))
    }
    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: ", ")
  }

  // MARK: Row

  /// Combined row announce: title, optional notes, heading vs task.
  static func rowLabel(title: String, hasNotes: Bool, isHeading: Bool) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = trimmed.isEmpty
      ? (isHeading
         ? String(localized: "Untitled section",
                  comment: "A11y: heading with empty title")
         : String(localized: "Untitled task",
                  comment: "A11y: task with empty title"))
      : trimmed
    if isHeading { return base }
    if hasNotes { return "\(base), \(Self.hasNotes)" }
    return base
  }

  // MARK: Sidebar / headers

  static func expand(_ title: String) -> String {
    String(localized: "Expand \(title)",
           comment: "A11y: sidebar disclosure chevron, collapsed")
  }

  static func collapse(_ title: String) -> String {
    String(localized: "Collapse \(title)",
           comment: "A11y: sidebar disclosure chevron, expanded")
  }

  /// Trailing "+" on a grouped Today header. Same words as SwiftUI's
  /// `HeaderQuickAddButton(accessibilityLabel:)`, so both shells speak alike.
  static func addTaskTo(_ title: String) -> String {
    String(localized: "Add task to \(title)",
           comment: "A11y: quick-add button on a Today area/project header")
  }

  static func navigationTitle(_ title: String) -> String {
    String(localized: "\(title), navigation menu",
           comment: "A11y: project/area/smart-list page title that opens the nav menu")
  }
}
