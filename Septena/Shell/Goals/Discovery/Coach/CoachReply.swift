import Foundation

// Forward-looking shapes for the coach's I/O. Today's on-device backend
// only fills `CoachReply.text`, and `CoachScope` is enforced by pre-filtering
// the facts snapshot. The richer fields exist so swapping in a reasoning
// backend (Claude via Private Cloud Compute, post–iOS 27) is additive: it
// lights up citations + proposed actions and enforces scope at the tool
// boundary, with no change to the chat UI contract.

/// The data a coach is permitted to read — the pill toggles, as a value.
/// `permitted` is the preset's sections minus the ones the user muted.
///
/// Enforcement today: the snapshot is built from exactly these sections, so
/// muted data never reaches the model. Enforcement later: a tool-using
/// backend consults this before answering any "read section X" tool call.
struct CoachScope: Equatable {
  let permitted: Set<String>

  func allows(_ sectionKey: String) -> Bool { permitted.contains(sectionKey) }
}

/// A coach's structured turn. Text-only backends populate just `text`.
struct CoachReply {
  var text: String
  var citations: [CoachCitation] = []
  var actions: [CoachProposedAction] = []
}

/// A pointer back to the data that informed a reply. Future: tappable, to
/// jump to those entries in the owning section.
struct CoachCitation: Identifiable, Hashable {
  let id = UUID()
  let section: String     // section key
  let label: String       // e.g. "Protein, Tue–Thu"
}

/// A change the coach proposes. NEVER executed by the model — it surfaces
/// as a confirmable card that the user accepts, and the accept routes through
/// `GoalMutator` (the write-boundary invariant). "Read always, write only with
/// the user's permission, through the UX."
struct CoachProposedAction: Identifiable, Hashable {
  let id = UUID()
  var section: String     // section key the action belongs to
  var title: String       // human summary, e.g. "Commit: Protein 140–170 g/day"

  // Structured goal payload. On accept: if a goal already exists for
  // `metricKey`, its target is moved (edit); otherwise a new goal is created.
  var goalText: String = ""
  var sections: [String] = []
  var metricKey: String? = nil
  var metricWindow: String? = nil
  var metricComparator: String? = nil   // "gte" | "lte" | "eq" | "range"
  var metricTarget: Double? = nil
  var metricUpper: Double? = nil
}
