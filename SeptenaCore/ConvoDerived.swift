import Foundation

// Derived view-state for a task's conversation — COMPUTED, never stored. The
// stored facts live in `TaskConvo`; this is a pure projection the UI badge and
// the reasoning queue read. Phase 1: docs/TASK_CONVERSATIONS_PHASE1.md.

/// Where the conversation sits in its lifecycle.
enum ConvoStage { case open, clarifying, inProgress, awaitingHuman, terminal }

/// Ball-in-whose-court — the daily-driver signal on a task row. (`youOnly` for
/// the `human_only` disposition arrives with that breadth phase; Phase 1 is
/// `agent_doable`, so needsYou / working / done / wontDo.)
enum ConvoBadge { case needsYou, working, done, wontDo }

struct ConvoDerived {
  var stage: ConvoStage
  var badge: ConvoBadge?        // nil = no conversation worth surfacing
  var nextAction: String
  var pendingReasoning: Bool
}

extension TaskConvo {
  /// Most recent provider turn, if any.
  var lastProviderTurn: ConvoTurn? { thread.last { $0.role == .provider } }

  /// True when the last turn is a provider turn still awaiting the human's tap
  /// (it offered options and no user turn followed). The 🟡 state.
  var hasOpenProviderQuestion: Bool {
    guard let last = thread.last else { return false }
    return last.role == .provider && (last.options?.isEmpty == false)
  }

  /// True when an agent finished work and handed the task back for the human
  /// to verify and accept or send back (`#87`). Single source of truth for the
  /// Review smart list and badge.
  var needsHumanReview: Bool { endState == .needsVerify }

  /// True when the conversation is waiting on a human action — either verifying
  /// finished agent work (`needs_verify`) or answering an open choice card.
  var awaitsHuman: Bool { needsHumanReview || hasOpenProviderQuestion }

  /// There's a conversation worth surfacing at all.
  var hasStarted: Bool {
    !thread.isEmpty || confirmedIntent != nil || isTerminal || artifact != nil || handoff != nil
  }

  /// SINGLE source of truth for the reasoning queue, shared by the in-app
  /// backend filter and the badge (the gateway mirrors this rule in TS): marked
  /// for Claude, OR last provider turn low-confidence — and not terminal.
  func isPendingReasoning() -> Bool {
    guard !isTerminal, stoppedAt == nil else { return false }
    if assignee == .claude { return true }
    if let c = lastProviderTurn?.confidence, c < 0.5 { return true }
    return false
  }
}

/// The five stages the Agent smart list groups by (docs/TASK_FACTORY_SPEC.md
/// §3). Derived, never stored. Raw values are the group ids of the `agent`
/// destination in `registry/destinations.json`, which owns titles and icons.
enum AgentStage: String, CaseIterable, Sendable {
  case queued, working, yourTurn, review, done

  /// Registry title + symbol for this stage's section header.
  var group: RegistryDestinationGroup? {
    RegistryDestinations.groups["agent"]?.first { $0.id == rawValue }
  }
}

extension TaskConvo {
  /// The Agent-list stage of this conversation, or nil when the task is not
  /// agent work (not assigned to Claude, no live claim, not handed back for
  /// review). Order of checks follows the spec table: Review and Done win over
  /// a stale assignee; a stop counts as Your turn, because only the human can
  /// resume it (ADR 0008).
  func agentStage(at now: Date) -> AgentStage? {
    let claimed = isClaimed(at: now)
    guard assignee == .claude || claimed || needsHumanReview else { return nil }
    if needsHumanReview { return .review }
    if isTerminal { return .done }
    if hasOpenProviderQuestion || stoppedAt != nil { return .yourTurn }
    if claimed { return .working }
    return .queued
  }
}

/// Pure projection of a conversation into UI/queue state.
func deriveConvo(_ convo: TaskConvo) -> ConvoDerived {
  let pending = convo.isPendingReasoning()

  if convo.needsHumanReview {
    return ConvoDerived(stage: .awaitingHuman, badge: .needsYou,
                        nextAction: convo.endStateNote ?? "Needs review",
                        pendingReasoning: false)
  }

  if convo.isTerminal {
    let badge: ConvoBadge = (convo.endState == .wontDo) ? .wontDo : .done
    return ConvoDerived(stage: .terminal, badge: badge,
                        nextAction: convo.endStateNote ?? "Resolved",
                        pendingReasoning: false)
  }

  guard convo.hasStarted else {
    return ConvoDerived(stage: .open, badge: nil,
                        nextAction: "No conversation yet", pendingReasoning: pending)
  }

  // The user stopped agent work: nothing is owed by anyone until they resume.
  if convo.stoppedAt != nil {
    return ConvoDerived(stage: .inProgress, badge: nil,
                        nextAction: "Stopped", pendingReasoning: false)
  }

  if convo.hasOpenProviderQuestion {
    return ConvoDerived(stage: .awaitingHuman, badge: .needsYou,
                        nextAction: "Tap to answer", pendingReasoning: pending)
  }

  // Agent owes the next move (just confirmed, or the user just chose).
  let stage: ConvoStage = (convo.confirmedIntent == nil) ? .clarifying : .inProgress
  // A claim lease is wall-clock time on the backend, not the app's day, and
  // this projection is nonisolated, so it reads the real clock.
  let working = convo.isClaimed(at: Date())
  return ConvoDerived(stage: stage, badge: .working,
                      nextAction: working ? "Claude is working" : "Claude's move", pendingReasoning: pending)
}

// MARK: - Linked GitHub issues / PRs

/// A GitHub issue or pull request associated with a task's conversation
/// (`artifact.refs`, `handoff.payload`, `endStateNote`, or a provider turn).
/// Surfaces `#N` on task rows and a clickable link in the conversation card
/// until first-class linked tasks (`extKey`/`extUrl`, L0) ship.
struct ConvoIssueLink: Hashable, Sendable {
  enum Kind: String, Hashable, Sendable { case issue, pullRequest }

  let owner: String
  let repo: String
  let number: Int
  let kind: Kind
  let url: URL

  /// Compact row chip label, e.g. `#147`.
  var shortLabel: String { "#\(number)" }

  /// Detail/accessibility label, e.g. `GitHub #147` or `PR #147`.
  var fullLabel: String {
    switch kind {
    case .issue: return "GitHub #\(number)"
    case .pullRequest: return "PR #\(number)"
    }
  }

  /// SF Symbol matching the link kind (dot-in-circle for issues, merge-pull for PRs).
  var symbolName: String {
    switch kind {
    case .issue: return "circle.inset.filled"
    case .pullRequest: return "arrow.triangle.pull"
    }
  }

  /// Parse the first `https://github.com/<owner>/<repo>/issues/<n>` (or `/pull/<n>`)
  /// URL appearing anywhere in `text`.
  static func parse(in text: String) -> ConvoIssueLink? {
    guard text.contains("github.com/") else { return nil }
    let pattern = #"https?://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/(issues|pull)/([0-9]+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let ownerRange = Range(match.range(at: 1), in: text),
          let repoRange = Range(match.range(at: 2), in: text),
          let kindRange = Range(match.range(at: 3), in: text),
          let numRange = Range(match.range(at: 4), in: text),
          let number = Int(text[numRange]) else { return nil }
    let owner = String(text[ownerRange])
    let repo = String(text[repoRange])
    let kindSegment = String(text[kindRange])
    let kind: Kind = (kindSegment == "pull") ? .pullRequest : .issue
    guard let url = URL(string: "https://github.com/\(owner)/\(repo)/\(kindSegment)/\(number)") else {
      return nil
    }
    return ConvoIssueLink(owner: owner, repo: repo, number: number, kind: kind, url: url)
  }

  /// Parse a standalone HTTP(S) URL string (used for clickable non-GitHub artifact refs).
  static func parseURL(_ raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://"),
          let url = URL(string: trimmed), url.host != nil else { return nil }
    return url
  }
}

extension ConvoArtifact {
  /// The GitHub issue or PR carried by this artifact, if any.
  var linkedIssue: ConvoIssueLink? {
    if let refs {
      for ref in refs {
        if let link = ConvoIssueLink.parse(in: ref) { return link }
      }
    }
    if let link = ConvoIssueLink.parse(in: body) { return link }
    return ConvoIssueLink.parse(in: title)
  }
}

extension TaskConvo {
  /// Best GitHub issue or PR associated with this conversation:
  /// artifact first, then handoff URL, end-state note, and newest provider turn.
  var linkedIssue: ConvoIssueLink? {
    if let link = artifact?.linkedIssue { return link }
    if let payload = handoff?.payload, let link = ConvoIssueLink.parse(in: payload) { return link }
    if let note = endStateNote, let link = ConvoIssueLink.parse(in: note) { return link }
    for turn in thread.reversed() where turn.role == .provider {
      if let note = turn.note, let link = ConvoIssueLink.parse(in: note) { return link }
      if let question = turn.question, let link = ConvoIssueLink.parse(in: question) { return link }
    }
    return nil
  }
}

extension SeptenaTask {
  /// Associated GitHub issue or PR for this task, if any.
  /// Single entry point so L0 (`extKey`/`extUrl`) can plug in ahead of `conversation`.
  var linkedIssue: ConvoIssueLink? { conversation.linkedIssue }
}
