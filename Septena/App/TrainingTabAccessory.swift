#if os(iOS)
import SwiftUI

// Bottom tab-bar accessory for an in-flight training session — the
// in-app twin of the training Live Activity. Both render the same
// `DraftSession` (TrainingDraftStore is the single source of truth), so
// the pill above the tab bar and the Lock Screen / Dynamic Island activity
// always agree. This surface only displays + opens; advancing the workout
// still happens inside TrainingSessionView.
//
// Mounted via `.tabViewBottomAccessory` in RootTabView. When no session is
// in flight the content collapses to nothing and the accessory bar hides.
struct TrainingTabAccessory: View {
  @Environment(TrainingDraftStore.self) private var draftStore
  @Environment(NavigationState.self) private var nav
  @Environment(SectionTheme.self) private var theme
  // `.inline` when the tab bar is minimized (collapsed beside the bar),
  // `.expanded` when it sits as a full pill above the bar.
  @Environment(\.tabViewBottomAccessoryPlacement) private var placement

  private var accent: Color { theme.color(for: "training") }

  var body: some View {
    if let draft = draftStore.draft, draft.totalCount > 0 {
      Button {
        // Same destination as the Live Activity's `septena://training/active`
        // deep link — reuse the existing session sheet instead of a URL hop.
        nav.showTrainingSession = true
      } label: {
        content(for: draft)
          // Make the WHOLE pill tappable, not just the glyph/text/chevron —
          // without this the `Spacer` gap in the expanded layout swallows
          // taps, so only the corners feel "live".
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
    }
  }

  @ViewBuilder
  private func content(for draft: DraftSession) -> some View {
    if placement == .inline {
      // Minimized bar: just the glyph + running clock.
      HStack(spacing: 8) {
        Image(systemName: draft.sessionKind.icon)
          .foregroundStyle(accent)
        elapsed(from: draft)
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 12)
    } else {
      HStack(spacing: 12) {
        Image(systemName: draft.sessionKind.icon)
          .font(.title3)
          .foregroundStyle(accent)

        VStack(alignment: .leading, spacing: 1) {
          Text(draft.label)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
          HStack(spacing: 6) {
            // Single-exercise sessions have no meaningful "0 of 1"
            // progress — just show the clock.
            if draft.totalCount > 1 {
              Text("\(draft.doneCount) of \(draft.totalCount)")
              Text("·")
            }
            elapsed(from: draft)
              .monospacedDigit()
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        }

        Spacer(minLength: 0)

        Image(systemName: "chevron.up")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 12)
    }
  }

  // Self-updating elapsed clock driven off the draft's ISO start stamp —
  // no Timer needed; `.timer` style ticks on its own. Falls back to a
  // static dash if the stamp can't be parsed (should never happen for a
  // live draft).
  @ViewBuilder
  private func elapsed(from draft: DraftSession) -> some View {
    if let start = Self.isoFormatter.date(from: draft.startedAt) {
      Text(start, style: .timer)
    } else {
      Text("—")
    }
  }

  private static let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
  }()
}
#endif
