import Foundation

// Task Conversations — the persisted conversation state for a task.
//
// Phase 0 (docs/TASK_CONVERSATIONS_PHASE0.md): the whole struct serializes to
// `TaskEntity.conversationJSON` — one additive CloudKit STRING column — so we add
// no new record types. PLAINTEXT on purpose (not ENCRYPTED_STRING like the legacy
// `notes`): the async-Claude provider reads/writes it via the gateway's CloudKit
// Web Services, which can't see encrypted fields (same reason `notesText` exists).
//
// Mutators are the only writers (see TasksBackend). The shape was frozen
// empirically across four dry-runs (code bug, epic, human_only, agent_assisted)
// — rationale in docs/TASK_CONVERSATIONS_PLAN.md.

/// One persisted turn. Propose and choose are SEPARATE turns — a provider turn
/// offers `options`; a later user turn records the tap via `inReplyTo` — so the
/// log stays append-only and auditable.
struct ConvoTurn: Codable, Hashable {
  var seq: Int
  var role: Role                 // who authored this turn
  var step: Step                 // which loop step it belongs to
  var provider: Provider?        // nil = deterministic `compute` (no model ran)
  var confidence: Double?        // provider turns; the escalation trigger
  var question: String?          // provider turns: the prompt shown on the card
  var options: [String]?         // the buttons offered
  var chosen: String?            // user turns: which button…
  var otherText: String?         // …or the free-text escape hatch
  var inReplyTo: Int?            // user turn → the proposal turn (`seq`) it answers
  var note: String?              // narration / `compute` output
  var ts: Date

  enum Role: String, Codable { case user, provider }
  enum Step: String, Codable { case confirm, ground, scope, decide, work }
  enum Provider: String, Codable { case onDevice, claude }
}

/// What an `agent_assisted` task PRODUCED (research, a table, a draft) — the
/// agent's deliverable, distinct from the human last-mile (`ConvoHandoff`).
struct ConvoArtifact: Codable, Hashable {
  var kind: String               // e.g. "availability-table", "draft-email"
  var title: String
  var body: String
  var refs: [String]?
}

/// The human last-mile, rendered as the terminal action button. Reaching this
/// means the AGENT is done (`acceptance` met); the TASK stays open until the
/// human takes the action.
struct ConvoHandoff: Codable, Hashable {
  var instruction: String        // "Buy septana.app (~€11/yr)"
  var actionType: ActionType
  var payload: String?           // the URL / email / phone number
  enum ActionType: String, Codable { case openURL = "open_url", compose, call, none }
}

/// Terminal end-state of the CONVERSATION (≠ task `status`, which tracks the
/// human's completion). Open/append-only — the dry-runs minted `needsVerify`
/// and `decomposed` unbidden; expect more.
enum ConvoEndState: String, Codable {
  case agentDone = "agent_done"
  case humanDone = "human_done"
  case agentAssistedDone = "agent_assisted_done"
  case needsVerify = "needs_verify"        // agent shipped; human must eyeball
  case decomposed                          // became subtasks; work lives in children
  case reminderSet = "reminder_set"        // human_only hand-off to notifications
  case promotedToToday = "promoted_to_today"
  case wontDo = "wont_do"
  case open
}

/// Who the user wants on a task. `nil` = router-decided. Setting `.claude`
/// proactively pushes the task into the reasoning queue ("mark for Claude").
enum ConvoAssignee: String, Codable { case me, local, claude }

/// The full persisted conversation for a task, stored as JSON in
/// `TaskEntity.conversationJSON`. `confirmedIntent`/`acceptance` are DENORMALIZED
/// caches of what `thread` already records — quick to read, never source of truth.
struct TaskConvo: Codable, Hashable {
  var confirmedIntent: String?   // set when the confirm gate passes
  var acceptance: String?        // the AGENT-done bar (≠ task status = human-done)
  var thread: [ConvoTurn] = []
  var subtasks: [String] = []    // child task ids (epic decompose)
  var artifact: ConvoArtifact?
  var handoff: ConvoHandoff?
  var endState: ConvoEndState?
  var endStateNote: String?      // e.g. needsVerify: *what* to verify
  var assignee: ConvoAssignee?   // nil = router-decided

  /// True once a terminal `endState` is recorded.
  var isTerminal: Bool { endState != nil && endState != .open }

  /// `seq` for the next appended turn (1-based).
  var nextSeq: Int { (thread.map(\.seq).max() ?? 0) + 1 }
}

// MARK: - JSON coders (ISO-8601 dates, stable across app + gateway)

extension JSONEncoder {
  static let taskConvo: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    return e
  }()
}

extension JSONDecoder {
  static let taskConvo: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }()
}

// MARK: - TaskEntity accessor

extension TaskEntity {
  /// Decoded conversation (empty if none yet). Assigning re-encodes to
  /// `conversationJSON`. Go through `TaskMutator` to persist + sync — this
  /// accessor only (de)serializes.
  var conversation: TaskConvo {
    get {
      guard let json = conversationJSON,
            let data = json.data(using: .utf8),
            let convo = try? JSONDecoder.taskConvo.decode(TaskConvo.self, from: data)
      else { return TaskConvo() }
      return convo
    }
    set {
      conversationJSON = (try? JSONEncoder.taskConvo.encode(newValue))
        .flatMap { String(data: $0, encoding: .utf8) }
    }
  }
}
