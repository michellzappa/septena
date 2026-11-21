import Foundation

/// Project and area notes: the context agents read before they decide
/// anything about a task (ADR 0012, docs/PROJECT_NOTES_SPEC.md).
///
/// The split rule is the backend's (`splitNotes` in
/// backend/src/store/TaskStore.ts), which ENFORCES it on agent writes: the
/// brief is everything above the first line that is exactly `## Log`, and the
/// log is everything below it. The brief is the user's; agents append dated
/// `### <day> · <agent>` entries to the log. Keep the two in step.
///
/// An area's notes live in `AreaEntity.context` (the wire name stayed); a
/// project's in `ProjectEntity.notes`. `ProjectEntity.context` is retired:
/// the backend merged it into notes once, and the apps no longer read or
/// push it.
enum ContainerNotes {
  /// The line that starts the agent log. Not localized: the backend matches
  /// it byte for byte.
  static let logHeading = "## Log"

  /// The brief and the log, split at the first exact `## Log` line (trailing
  /// spaces or tabs allowed, as in the backend). No such line means the whole
  /// note is brief and `log` is nil.
  static func split(_ body: String?) -> (brief: String, log: String?) {
    guard let body, !body.isEmpty else { return ("", nil) }
    guard let match = body.firstMatch(of: logLine) else { return (body, nil) }
    return (String(body[..<match.range.lowerBound]), String(body[match.range.upperBound...]))
  }

  /// Built per call: `Regex` is not `Sendable`, so it cannot be a static
  /// stored property under strict concurrency.
  private static var logLine: Regex<AnyRegexOutput> {
    // The pattern is a constant, so construction cannot fail.
    (try! Regex("^## Log[ \\t]*$")).anchorsMatchLineEndings()
  }

  /// The headings a project's notes start with (spec §6). Inserted when the
  /// user first starts writing empty project notes.
  static var template: String {
    let headings = [
      String(localized: "Goal", comment: "Project notes template heading"),
      String(localized: "Current state", comment: "Project notes template heading"),
      String(localized: "People", comment: "Project notes template heading"),
      String(localized: "Decisions", comment: "Project notes template heading"),
      String(localized: "Constraints", comment: "Project notes template heading"),
    ]
    return headings.map { "## \($0)\n\n" }.joined() + logHeading + "\n"
  }

  /// Where the cursor goes in a fresh template: the blank line under the
  /// first heading, as a UTF-16 offset (NSTextView) and as an index (SwiftUI).
  static var templateCursorUTF16Offset: Int {
    (template.components(separatedBy: "\n").first ?? "").utf16.count + 1
  }

  static func templateCursorIndex(in text: String) -> String.Index {
    let utf16 = text.utf16
    return utf16.index(utf16.startIndex, offsetBy: min(templateCursorUTF16Offset, utf16.count))
  }

  /// True when the text is the template the app inserted, with nothing typed
  /// into it. Such text is never saved: empty notes stay empty.
  static func isUntouchedTemplate(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
      == template.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Placeholder for empty project notes.
  static var projectPlaceholder: String {
    String(localized: "Goal, current state, people, decisions, constraints",
           comment: "Placeholder for empty project notes")
  }

  /// Placeholder for empty area notes.
  static var areaPlaceholder: String {
    String(localized: "What this area covers", comment: "Placeholder for empty area notes")
  }

  /// A retired project `context` folded into notes above the log. The same
  /// shape as the backend's one-time merge (`mergeContextIntoNotes`), for
  /// export files written before the merge.
  static func mergingLegacyContext(notes: String?, context: String?, day: String) -> String? {
    guard let context = context?.trimmingCharacters(in: .whitespacesAndNewlines),
          !context.isEmpty else { return notes }
    let block = "## Context (merged \(day))\n\n\(context)\n"
    let (brief, log) = split(notes)
    let briefTrimmed = brief.trimmingCharacters(in: .whitespacesAndNewlines)
    let top = briefTrimmed.isEmpty ? block : "\(brief.trimmingTrailingWhitespace())\n\n\(block)"
    guard let log else { return top }
    return "\(top)\n\(logHeading)\(log)"
  }
}

private extension String {
  func trimmingTrailingWhitespace() -> String {
    var s = Substring(self)
    while let last = s.last, last.isWhitespace { s.removeLast() }
    return String(s)
  }
}
