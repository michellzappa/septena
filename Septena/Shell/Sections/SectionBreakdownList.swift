import SwiftUI

// Standardized "By X" per-item breakdown list for a section's Patterns mode.
// Every loggable section with multiple named items — habits, supplements,
// chores, medications, symptoms — renders one of these beneath its aggregate
// pattern viz. Each row is the named item plus an optional one-line stat;
// tapping it opens that item's shared per-item detail (the heatmap surface in
// `LogDetailScaffold`). One component so the drill-into-history interaction is
// identical across every section.

/// A row in a `SectionBreakdownList`. `id` is handed back on tap so the host
/// maps it to its own item type and drives its existing detail binding.
struct BreakdownRow: Identifiable {
  let id: String
  /// Display title, with any emoji prefix already applied by the caller.
  let title: String
  /// Optional one-line stat ("80% last 30 days", "12 logged · peak 6/10").
  var detail: String? = nil
}

struct SectionBreakdownList: View {
  /// "By symptom" / "By habit" / … — the card header.
  let title: String
  let rows: [BreakdownRow]
  let accent: Color
  /// The currently-open item, for the selection wash (mirrors log rows).
  var selectedID: String? = nil
  let onTap: (String) -> Void

  var body: some View {
    if !rows.isEmpty {
      DrawerSection(title, padding: .none) {
        ForEach(rows) { row in
          Button { onTap(row.id) } label: {
            LogRow(title: row.title,
                   detail: row.detail,
                   trailing: "›",
                   tint: accent,
                   isSelected: selectedID == row.id)
          }
          .buttonStyle(PlainHoverRowButtonStyle(cornerRadius: 10))
        }
      }
    }
  }
}
