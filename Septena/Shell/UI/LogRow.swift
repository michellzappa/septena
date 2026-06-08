import SwiftUI

// Read-only historical row. Sibling to TaskRow / HabitRow / ChoreRow, used
// by modules whose entries are *records* rather than checkable items
// (training entries today; sleep logs, nutrition meals, weight reads,
// cannabis sessions, etc later). No checkbox, no swipe actions, no
// completion state — just a title, optional detail line, and trailing
// metadata.

struct LogRow: View {
  let title: String
  var detail: String? = nil       // "60kg × 3×8" or "5 km · 28 min"
  var trailing: String? = nil     // "07:42" or "yesterday" — recency
  // Optional micrographic shown to the right of `detail` — used by the
  // training log for difficulty pips and cardio level bars.
  var accessory: AnyView? = nil
  // Optional leading glyph (e.g. a status dot) shown before the title column.
  // Used by the per-item detail's recent timeline to mark done/skipped/missed
  // days. Omitted by default so existing log rows are unchanged.
  var leading: AnyView? = nil
  // Active/selected highlight: painted while this entry's edit modal is open,
  // so the row that opened it stays visibly anchored. `tint` supplies the
  // section accent for the wash. Mirrors `CheckableRow`'s selection treatment.
  var tint: Color = Theme.inkPrimary
  var isSelected: Bool = false

  @Environment(\.rowHInset) private var rowHInset

  var body: some View {
    HStack(spacing: Theme.iconTextGap) {
      if let leading {
        leading.frame(width: 18)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.septenaTaskTitle)
          .foregroundStyle(Theme.inkPrimary)
        if detail != nil || accessory != nil {
          HStack(spacing: 6) {
            if let detail {
              Text(detail)
                .font(.septenaMeta)
                .foregroundStyle(Theme.inkSecondary)
            }
            if let accessory {
              accessory
            }
          }
        }
      }
      Spacer()
      if let trailing {
        Text(trailing)
          .font(.septenaMeta.monospacedDigit())
          .foregroundStyle(Theme.inkSecondary)
      }
    }
    .padding(.horizontal, rowHInset)
    .padding(.vertical, Theme.rowVPadding + 2)
    .background(selectionHighlight)
  }

  @ViewBuilder private var selectionHighlight: some View {
    if isSelected {
      RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
        .fill(tint.opacity(0.18))
        .padding(.horizontal, max(0, rowHInset - 6))
    }
  }
}

#Preview {
  VStack(spacing: 0) {
    LogRow(title: "Bench press",
           detail: "60kg · 3×8",
           trailing: "07:42")
    Divider()
    LogRow(title: "Z2 cycling",
           detail: "30 min · 12.2 km",
           trailing: "07:10")
    Divider()
    LogRow(title: "Pull-ups",
           detail: "BW · 4×6")
  }
  .background(Theme.secondaryGroupedBackground)
  .clipShape(RoundedRectangle(cornerRadius: 10))
  .padding()
  .background(Theme.groupedBackground)
}
