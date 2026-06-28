import SwiftUI

// One log entry row inside a section drawer's "Today" stack. Replaces
// the Button + LogRow + .contextMenu(Edit / Delete) trio that every
// event-log section (Gut, Intake, Mood, Training) re-rolled
// by hand. Designed to be dropped into `DrawerSection(padding: .none)`
// where LogRow's intrinsic h/v padding provides the row's own breathing
// room — no additional outer padding needed.

struct LogEntryRow: View {
  let title: String
  var detail: String? = nil
  var trailing: String? = nil
  var accessory: AnyView? = nil
  /// Optional leading glyph (e.g. a status dot) shown before the title.
  var leading: AnyView? = nil
  /// Section accent for the selection wash (see `isSelected`).
  var tint: Color = Theme.inkPrimary
  /// Highlight this row while its edit modal is open.
  var isSelected: Bool = false

  /// Fires on tap. Conventionally opens the section's edit sheet for
  /// the underlying entry. Pass `nil` to make the row non-interactive
  /// (e.g. read-only browse contexts).
  var onEdit: (() -> Void)? = nil

  /// Fires from the long-press context menu's destructive button.
  /// Conventionally deletes the entry via the section's mutator. Pass
  /// `nil` to omit the menu entirely.
  var onDelete: (() -> Void)? = nil

  var body: some View {
    Group {
      if let onEdit {
        Button(action: onEdit) { row }
          .buttonStyle(PlainHoverRowButtonStyle(cornerRadius: 10))
      } else {
        row
      }
    }
    .contextMenu {
      if let onEdit {
        Button(action: onEdit) {
          Label("Edit", systemImage: "pencil")
        }
      }
      if let onDelete {
        Button(role: .destructive, action: onDelete) {
          Label("Delete", systemImage: "trash")
        }
      }
    }
  }

  private var row: some View {
    LogRow(title: title,
           detail: detail,
           trailing: trailing,
           accessory: accessory,
           leading: leading,
           tint: tint,
           isSelected: isSelected)
  }
}

#Preview("LogEntryRow — full") {
  VStack(spacing: 0) {
    LogEntryRow(
      title: "Type 4 · smooth",
      detail: "medium",
      trailing: "07:42",
      onEdit: {},
      onDelete: {}
    )
    LogEntryRow(
      title: "V60",
      detail: "Wakuli · 10.0g",
      trailing: "08:15",
      onEdit: {}
    )
  }
  .background(Theme.secondaryGroupedBackground,
              in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
  .padding()
  .background(Theme.groupedBackground)
}
