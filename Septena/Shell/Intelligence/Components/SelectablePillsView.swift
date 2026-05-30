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
            if selectedItems.contains(item) {
              Image(systemName: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
            }
            Text(item)
              .font(.callout.weight(selectedItems.contains(item) ? .semibold : .regular))
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .foregroundStyle(selectedItems.contains(item) ? tint : .primary)
          .background(selectedItems.contains(item) ? tint.opacity(0.15) : Color.secondary.opacity(0.10), in: Capsule())
          .overlay {
            Capsule()
              .strokeBorder(selectedItems.contains(item) ? tint.opacity(0.38) : Color.secondary.opacity(0.16), lineWidth: 1)
          }
        }
        .buttonStyle(.plain)
        .opacity(isDisabled(item) ? 0.38 : 1)
        .disabled(isDisabled(item))
      }
    }
    .animation(.easeInOut(duration: 0.2), value: selectedItems)
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
