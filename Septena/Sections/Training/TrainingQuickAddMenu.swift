import SwiftUI

// Single canonical menu for the Training tile — same content from the
// trailing-circle button (Menu) and the tile's `.contextMenu`.
//
// Connects directly to the live exercise logger (TrainingSessionView /
// TrainingDraftStore), skipping the in-sheet picker step by pre-selecting
// the chosen type via `NavigationState.pendingTrainingType`. Replaces
// the old AddTrainingPage stub which never committed anything.
//
// Items, in priority order:
//
//   1. "Start: {suggested}" — when the server returned a suggestion via
//      `/api/training/suggested-workout`. The reason ("Last upper > 5d
//      ago", etc.) is on the destination view, not in the menu.
//   2. "Recent" section — up to 2 most-recently-trained session types
//      from `daysAgo`, excluding the suggested one above. Capped at 2
//      so the menu stays at ~4 items total.
//   3. Training… — opens the AddInfo sheet (existing palette).

struct TrainingQuickAddMenu: View {
  let sessionTypes: [SessionTypeConfig]
  /// `id` of the server-suggested type (or nil if no suggestion). Drives
  /// the highlighted "Start: …" row.
  let suggestedId: String?
  /// Days-since-last per session-type id. Used to surface the 2 most
  /// recently trained types under "Recent".
  let daysAgo: [String: Int]
  /// Called with the chosen type's id (or label fallback) — the dashboard
  /// stuffs it into `nav.pendingTrainingType` and presents the session
  /// sheet, which auto-starts the draft on appear.
  let onStart: (String) -> Void

  private var suggested: SessionTypeConfig? {
    guard let id = suggestedId else { return nil }
    return sessionTypes.first { $0.id == id }
  }

  /// Recent = sorted ascending by daysAgo (smaller = more recent),
  /// excluding the suggested type to avoid duplication.
  private var recent: [SessionTypeConfig] {
    let suggestedID = suggested?.id
    return sessionTypes
      .filter { $0.id != suggestedID }
      .compactMap { type -> (SessionTypeConfig, Int)? in
        guard let d = daysAgo[type.id] else { return nil }
        return (type, d)
      }
      .sorted { $0.1 < $1.1 }
      .prefix(2)
      .map { $0.0 }
  }

  var body: some View {
    if let suggested {
      Button {
        onStart(suggested.id)
      } label: {
        Label("Start: \(suggested.label)", systemImage: "sparkles")
      }
    } else {
      Button {
        // No suggestion → open the picker without pre-selecting.
        onStart("")
      } label: {
        Label("Start session", systemImage: "play.fill")
      }
    }

    if !recent.isEmpty {
      Section("Recent") {
        ForEach(recent) { type in
          Button { onStart(type.id) } label: {
            Label(type.label, systemImage: "dumbbell")
          }
        }
      }
    }

  }
}
