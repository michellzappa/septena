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
        Button {
          toggleItem(item)
        } label: {
          HStack(spacing: 6) {
            Image(systemName: selectedItems.contains(item) ? "checkmark.circle.fill" : "circle")
            Text(item)
              .font(.callout)
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .tint(selectedItems.contains(item) ? tint : .secondary)
        .disabled(maxSelections != nil && selectedItems.count >= maxSelections! && !selectedItems.contains(item))
      }
    }
    .animation(.easeInOut(duration: 0.2), value: selectedItems)
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
