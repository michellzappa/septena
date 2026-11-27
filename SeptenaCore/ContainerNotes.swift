import Foundation

/// An agent's suggested replacement for a project's or area's brief (the part
/// above `## Log`). Written via MCP `tasks_notes_propose` and cleared when the
/// user accepts or rejects it in the app (ADR 0012, docs/PROJECT_NOTES_SPEC.md).
struct NotesProposal: Codable, Hashable, Sendable {
  let body: String
  let agent: String
  let at: String
  let why: String?

  var date: Date? {
    TaskHistory.parseStamp(at)
  }

  /// Friendly agent label shown on the proposal card.
  var displayAgent: String {
    let trimmed = agent.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed.lowercased() == "claude" {
      return RegistrySurfaces.provenanceAgentFallbackName
    }
    return trimmed
  }
}

/// One line in a compact brief diff shown inside a proposal card.
struct NotesDiffLine: Identifiable, Hashable, Sendable {
  enum Kind: Hashable, Sendable {
    case context
    case added
    case removed
    case separator
  }

  let id: Int
  let kind: Kind
  let text: String
}

/// One line of notes as a page shows them while nobody edits them.
enum NotesPreviewLine: Hashable, Sendable {
  case heading(level: Int, text: String)
  case blank
  /// A list item: its nesting depth, its marker ("•", "☐", "☑", "1.") and text.
  case item(depth: Int, marker: String, text: String)
  case quote(String)
  case body(String)
}

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
  enum Container: String, Codable, Sendable {
    case project
    case area
  }

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

  /// True when the note contains a `## Log` section.
  static func hasLog(_ body: String?) -> Bool {
    split(body).log != nil
  }

  /// Replaces only the brief (everything above `## Log`) with `proposedBrief`,
  /// preserving the `## Log` heading and every log entry below it verbatim.
  static func replacingBrief(in current: String?, with proposedBrief: String) -> String {
    let (_, log) = split(current)
    let cleanBrief = proposedBrief
      .replacingOccurrences(of: "\r\n", with: "\n")
      .trimmingTrailingWhitespace()
    guard let log else { return cleanBrief }
    if cleanBrief.isEmpty {
      return "\(logHeading)\(log)"
    }
    return "\(cleanBrief)\n\n\(logHeading)\(log)"
  }

  /// Compact line diff comparing the current brief (text above `## Log`) to a
  /// proposed brief. Shows changed lines with 1 line of surrounding context and
  /// collapses long unchanged runs into `.separator`.
  static func diffLines(from currentNotes: String?, to proposedBrief: String, contextRadius: Int = 1) -> [NotesDiffLine] {
    let currentBrief = split(currentNotes).brief
      .replacingOccurrences(of: "\r\n", with: "\n")
      .trimmingTrailingWhitespace()
    let targetBrief = proposedBrief
      .replacingOccurrences(of: "\r\n", with: "\n")
      .trimmingTrailingWhitespace()

    let oldLines = currentBrief.isEmpty ? [] : currentBrief.components(separatedBy: "\n")
    let newLines = targetBrief.isEmpty ? [] : targetBrief.components(separatedBy: "\n")
    if oldLines == newLines { return [] }

    // Guard against quadratic memory on huge notes.
    let raw: [(NotesDiffLine.Kind, String)]
    if oldLines.count * newLines.count > 160_000 {
      raw = oldLines.map { (.removed, $0) } + newLines.map { (.added, $0) }
    } else {
      raw = lcsDiff(oldLines, newLines)
    }

    // Keep lines within `contextRadius` of any change; collapse the rest.
    var keep = [Bool](repeating: false, count: raw.count)
    for idx in raw.indices where raw[idx].0 != .context {
      let lo = max(0, idx - contextRadius)
      let hi = min(raw.count - 1, idx + contextRadius)
      for j in lo...hi { keep[j] = true }
    }

    var out: [NotesDiffLine] = []
    var skipping = false
    for idx in raw.indices {
      if keep[idx] {
        if skipping {
          out.append(NotesDiffLine(id: out.count, kind: .separator, text: "…"))
          skipping = false
        }
        out.append(NotesDiffLine(id: out.count, kind: raw[idx].0, text: raw[idx].1))
      } else if !out.isEmpty {
        skipping = true
      }
    }
    return out
  }

  /// The notes as a page shows them, line by line. The user's line breaks
  /// survive as typed (CommonMark would fold a single newline into a space).
  /// Runs of blank lines collapse to one; blank lines at both ends and directly
  /// under a heading drop; so does a heading with nothing under it (an unfilled
  /// template section). The text of a line still holds its inline markdown.
  static func previewLines(_ raw: String) -> [NotesPreviewLine] {
    let source = raw.replacingOccurrences(of: "\r\n", with: "\n")
      .components(separatedBy: "\n").map(previewLine)

    // A heading is empty when the next non-blank line is a heading of the same
    // or a higher level, or the end of the notes.
    var kept: [NotesPreviewLine] = []
    for (index, line) in source.enumerated() {
      if case .heading(let level, _) = line {
        let next = source[(index + 1)...].first { $0 != .blank }
        switch next {
        case nil: continue
        case .heading(let nextLevel, _)? where nextLevel <= level: continue
        default: break
        }
      }
      kept.append(line)
    }

    var result: [NotesPreviewLine] = []
    for line in kept {
      if line == .blank {
        guard let last = result.last, last != .blank else { continue }
        if case .heading = last { continue }
      }
      result.append(line)
    }
    while result.last == .blank { result.removeLast() }
    return result
  }

  private static func previewLine(_ line: String) -> NotesPreviewLine {
    let content = line.trimmingCharacters(in: .whitespaces)
    if content.isEmpty { return .blank }
    let hashes = content.prefix(while: { $0 == "#" }).count
    if (1...6).contains(hashes) {
      let rest = content.dropFirst(hashes)
      if rest.first == " " || rest.first == "\t" {
        return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces))
      }
    }
    let depth = min(line.prefix(while: { $0 == " " || $0 == "\t" }).count / 2, 4)
    if let match = content.firstMatch(of: #/^[-*+]\s+\[([ xX])\]\s+(.*)$/#) {
      return .item(depth: depth, marker: match.1 == " " ? "☐" : "☑", text: String(match.2))
    }
    if let match = content.firstMatch(of: #/^[-*+]\s+(.*)$/#) {
      return .item(depth: depth, marker: "•", text: String(match.1))
    }
    if let match = content.firstMatch(of: #/^(\d+[.)])\s+(.*)$/#) {
      return .item(depth: depth, marker: String(match.1), text: String(match.2))
    }
    if let match = content.firstMatch(of: #/^>\s?(.*)$/#) { return .quote(String(match.1)) }
    return .body(content)
  }

  /// Inline markdown of one line (**bold**, *italic*, `code`, [links]); plain
  /// text when the parse fails.
  static func inlineMarkdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
  }

  private static func lcsDiff(_ a: [String], _ b: [String]) -> [(NotesDiffLine.Kind, String)] {
    let m = a.count
    let n = b.count
    var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
    if m > 0 && n > 0 {
      for i in stride(from: m - 1, through: 0, by: -1) {
        for j in stride(from: n - 1, through: 0, by: -1) {
          if a[i] == b[j] {
            dp[i][j] = dp[i + 1][j + 1] + 1
          } else {
            dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
          }
        }
      }
    }
    var result: [(NotesDiffLine.Kind, String)] = []
    var i = 0
    var j = 0
    while i < m && j < n {
      if a[i] == b[j] {
        result.append((.context, a[i]))
        i += 1
        j += 1
      } else if dp[i + 1][j] >= dp[i][j + 1] {
        result.append((.removed, a[i]))
        i += 1
      } else {
        result.append((.added, b[j]))
        j += 1
      }
    }
    while i < m { result.append((.removed, a[i])); i += 1 }
    while j < n { result.append((.added, b[j])); j += 1 }
    return result
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

/// Shared UI copy for notes proposals and notes history so iOS SwiftUI and
/// macOS AppKit stay in lockstep.
enum ContainerNotesCopy {
  static func proposalHeading(agent: String) -> String {
    String(localized: "\(agent) suggested a notes update",
           comment: "Header of a project or area notes proposal card")
  }

  static var acceptButton: String {
    String(localized: "Accept", comment: "Accept a proposed notes brief update")
  }

  static var rejectButton: String {
    String(localized: "Reject", comment: "Reject a proposed notes brief update")
  }

  static var noChangesInBrief: String {
    String(localized: "No changes to the brief.", comment: "Shown when a proposal matches the current brief")
  }

  static var logPreservedHint: String {
    String(localized: "Entries under ## Log stay untouched.",
           comment: "Reassurance on a notes proposal card when the note has a log section")
  }

  static var historyMenuTitle: String {
    String(localized: "Notes History", comment: "Menu item and sheet title for project/area notes revisions")
  }

  static var editNotesMenuTitle: String {
    String(localized: "Edit Notes", comment: "Context menu item on project or area notes")
  }

  static var loadingHistory: String {
    String(localized: "Loading history…", comment: "Loading indicator in notes history sheet")
  }

  static var emptyHistory: String {
    String(localized: "No saved versions yet.", comment: "Empty state in notes history sheet")
  }

  static var failedHistory: String {
    String(localized: "Couldn’t load notes history.", comment: "Error message in notes history sheet")
  }

  static var signInForHistory: String {
    String(localized: "Sign in to view notes history.", comment: "Shown when notes history is opened without sync sign-in")
  }

  static var emptyRevisionBody: String {
    String(localized: "Empty notes", comment: "Placeholder when previewing a blank notes revision")
  }

  static var restoreButton: String {
    String(localized: "Restore", comment: "Button that restores a selected notes revision")
  }

  static var currentBadge: String {
    String(localized: "Current", comment: "Badge marking the latest notes revision")
  }

  static var loadOlderButton: String {
    String(localized: "Load older versions", comment: "Pagination button in notes history")
  }

  static var selectRevisionPrompt: String {
    String(localized: "Choose a version to preview.", comment: "Empty selection state in macOS notes history detail pane")
  }

  static func versionLabel(_ rev: Int) -> String {
    String(localized: "v\(rev)", comment: "Short revision number label in notes history")
  }

  static func revisionTitle(_ rev: Int) -> String {
    String(localized: "Version \(rev)", comment: "Navigation title for a selected notes revision")
  }

  static var undoRestoreName: String {
    String(localized: "Restore Notes", comment: "Undo action name when restoring an older notes version")
  }

  static var undoAcceptProposalName: String {
    String(localized: "Accept Notes Suggestion", comment: "Undo action name when accepting an agent notes proposal")
  }

  static var undoRejectProposalName: String {
    String(localized: "Reject Notes Suggestion", comment: "Undo action name when rejecting an agent notes proposal")
  }
}

private extension String {
  func trimmingTrailingWhitespace() -> String {
    var s = Substring(self)
    while let last = s.last, last.isWhitespace { s.removeLast() }
    return String(s)
  }
}
