import SwiftUI

// Single canonical menu for the Training tile — same content from the
// trailing-circle button (Menu) and the tile's `.contextMenu`.
//
// Connects directly to the live exercise logger (TrainingSessionView /
// TrainingDraftStore), skipping the in-sheet picker step by pre-selecting
// the chosen type via `NavigationState.pendingTrainingType`.
//
// Items, in order:
//
//   1. "Suggested" section (only when the server returned a suggestion) —
//      one row, the suggested routine, identified by its kind's SF
//      Symbol (no special "sparkles" marker — the section header is
//      the only signal that this row is a suggestion).
//   2. "All routines" section — every non-archived routine in the
//      user's catalog (the same order Settings → Training → Routines
//      shows). The suggested routine is excluded from this list so it
//      isn't duplicated. Each row shows the routine's kind icon.
//
// Long-form thinking: the old version only listed the suggested type
// plus the 2 most-recent — which silently hid routines like Yoga if
// the user trained other things more frequently. With every routine
// visible the menu becomes a comprehensive launcher; the "suggested"
// nudge is preserved by section position + header, not by an icon
// flourish.

struct TrainingQuickAddMenu: View {
  let sessionTypes: [SessionTypeConfig]
  /// `id` of the server-suggested type (or nil if no suggestion).
  /// Drives the "Suggested" section.
  let suggestedId: String?
  /// Days-since-last per session-type id. No longer used for ordering
  /// (now strictly catalog order), kept for API-stability with the
  /// dashboard call site — may be removed in a follow-up.
  let daysAgo: [String: Int]
  /// Live in-progress draft, if one exists. Surfaces a "Resume {label}"
  /// row at the top of the menu so the user can return to a session
  /// without first opening the Training pane. Matches the
  /// `activeSessionSection` affordance in TrainingDestinationView.
  let activeDraft: DraftSession?
  /// Called with the chosen type's id. The dashboard stuffs it into
  /// `nav.pendingTrainingType` and presents the session sheet, which
  /// auto-starts the draft on appear. Pass `""` to open the picker
  /// without pre-selecting (used when no routines exist).
  let onStart: (String) -> Void
  /// Tapped when the user picks "Resume". Caller should present the
  /// session sheet *without* setting `pendingTrainingType` so the
  /// live draft is shown as-is.
  let onResume: () -> Void

  private var suggested: SessionTypeConfig? {
    guard let id = suggestedId else { return nil }
    return sessionTypes.first { $0.id == id && !$0.archived }
  }

  /// Every non-archived routine, in catalog order. The suggested
  /// routine is filtered out so it isn't duplicated — it has its
  /// own section above.
  private var allRoutines: [SessionTypeConfig] {
    let suggestedID = suggested?.id
    return sessionTypes.filter { !$0.archived && $0.id != suggestedID }
  }

  var body: some View {
    // Resume sits above everything else — if there's a draft, the
    // user almost certainly wants to continue it rather than start
    // anything new. The matching routine's kind icon keeps the visual
    // vocabulary consistent with the start-rows below.
    if let draft = activeDraft {
      Section("In progress") {
        Button {
          onResume()
        } label: {
          Label("Resume \(draft.label)", systemImage: resumeIcon(for: draft))
        }
      }
    }

    if let suggested {
      Section("Suggested") {
        routineButton(suggested)
      }
    }

    if !allRoutines.isEmpty {
      Section("All routines") {
        ForEach(allRoutines) { type in
          routineButton(type)
        }
      }
    } else if suggested == nil && activeDraft == nil {
      // Degenerate: no routines, no draft. Offer to open the picker
      // (which will let the user create one or pick later).
      Button {
        onStart("")
      } label: {
        Label("Start session", systemImage: "figure.mixed.cardio")
      }
    }
  }

  /// Look up the draft's routine in the catalog to borrow its kind
  /// icon. Falls back to a generic mixed-cardio glyph if the routine
  /// was deleted while the draft was running.
  private func resumeIcon(for draft: DraftSession) -> String {
    sessionTypes.first { $0.id == draft.sessionType }?.kind.icon
      ?? "figure.mixed.cardio"
  }

  /// One row per routine. Icon comes from the routine's kind so the
  /// user can see at-a-glance whether a row is strength / cardio /
  /// mobility / mixed without parsing the label.
  private func routineButton(_ type: SessionTypeConfig) -> some View {
    Button {
      onStart(type.id)
    } label: {
      Label(type.label, systemImage: type.kind.icon)
    }
  }
}
