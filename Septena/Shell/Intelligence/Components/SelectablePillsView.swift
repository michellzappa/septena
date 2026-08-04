import SwiftUI

struct SelectablePillsView: View {
  let items: [String]
  @Binding var selectedItems: Set<String>
  let tint: Color
  let maxSelections: Int?
  let onItemToggle: ((String) -> Void)?

  init(items: [String],
       selectedItems: Binding<Set<String>>,
       tint: Color,
       maxSelections: Int? = nil,
       onItemToggle: ((String) -> Void)? = nil) {
    self.items = items
    _selectedItems = selectedItems
    self.tint = tint
    self.maxSelections = maxSelections
    self.onItemToggle = onItemToggle
  }

  var body: some View {
    FlowLayout(spacing: 8) {
      ForEach(items, id: \.self) { item in
        let isSelected = selectedItems.contains(item)
        // Multi-select, so the chip keeps a leading checkmark — but the fill,
        // ink, and type all come from the canonical `SelectableChip`. This view
        // used to add a bespoke stroked border, which read as a second chip
        // language next to the app's other filter strips.
        SelectableChip(isSelected: isSelected, tint: tint) {
          toggleItem(item)
        } label: {
          HStack(spacing: Theme.Spacing.xs + 2) {
            if isSelected {
              Image(systemName: "checkmark.circle.fill")
            }
            Text(item)
          }
        }
        .opacity(isDisabled(item) ? 0.38 : 1)
        .disabled(isDisabled(item))
      }
    }
    .a11yAnimation(.easeInOut(duration: 0.2), value: selectedItems)
  }

  private func isDisabled(_ item: String) -> Bool {
    maxSelections != nil && selectedItems.count >= maxSelections! && !selectedItems.contains(item)
  }

  private func toggleItem(_ item: String) {
    if selectedItems.contains(item) {
      selectedItems.remove(item)
    } else if maxSelections == nil || selectedItems.count < maxSelections! {
      selectedItems.insert(item)
    }
    onItemToggle?(item)
  }
}
