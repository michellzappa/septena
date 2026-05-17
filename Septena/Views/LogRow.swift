import SwiftUI

// Read-only historical row. Sibling to TaskRow / HabitRow / ChoreRow, used
// by modules whose entries are *records* rather than checkable items
// (training entries today; sleep logs, nutrition meals, weight reads,
// cannabis sessions, etc later). No checkbox, no swipe actions, no
// completion state — just a title, optional detail line, and trailing
// metadata. A subtle leading accent dot keeps it visually tied to its
// section without painting the row.

struct LogRow: View {
  let title: String
  var detail: String? = nil       // "60kg × 3×8" or "5 km · 28 min"
  var trailing: String? = nil     // "07:42" or "yesterday" — recency
  var accent: Color = .accentColor

  var body: some View {
    HStack(spacing: Theme.iconTextGap) {
      Circle()
        .fill(accent)
        .frame(width: 6, height: 6)
        .padding(.leading, 2)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.septenaTaskTitle)
          .foregroundStyle(Theme.inkPrimary)
        if let detail {
          Text(detail)
            .font(.septenaMeta)
            .foregroundStyle(Theme.inkSecondary)
        }
      }
      Spacer()
      if let trailing {
        Text(trailing)
          .font(.septenaMeta.monospacedDigit())
          .foregroundStyle(Theme.inkSecondary)
      }
    }
    .padding(.horizontal, Theme.hPadding)
    .padding(.vertical, Theme.rowVPadding + 2)
  }
}

#Preview {
  VStack(spacing: 0) {
    LogRow(title: "Bench press",
           detail: "60kg · 3×8",
           trailing: "07:42",
           accent: .orange)
    Divider()
    LogRow(title: "Z2 cycling",
           detail: "30 min · 12.2 km",
           trailing: "07:10",
           accent: .orange)
    Divider()
    LogRow(title: "Pull-ups",
           detail: "BW · 4×6",
           accent: .orange)
  }
  .background(Color(.secondarySystemGroupedBackground))
  .clipShape(RoundedRectangle(cornerRadius: 10))
  .padding()
  .background(Color(.systemGroupedBackground))
}
