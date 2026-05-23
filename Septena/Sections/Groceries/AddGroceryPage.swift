import SwiftUI
import SwiftData

// Type-to-create groceries. Stocked items are shown below — tap to flip
// `low` so the user can mark them as needed without leaving the palette.

struct AddGroceryPage: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme
  @Environment(\.dismiss) private var dismiss
  @Bindable var router: AddInfoRouter
  @State private var items: [GroceryItem] = []
  @State private var working = false

  private var grocery: GroceryMutator { SeptenaServices.shared.groceryMutator }

  private var trimmed: String {
    router.query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    let tint = AddInfoSection.groceries.accent(theme: theme)
    let stocked = items.filter { !$0.low }
    let filtered = stocked.filter { trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed) }
    let exactMatch = items.contains { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }

    List {
      if !trimmed.isEmpty, !exactMatch {
        Section {
          Button { create(name: trimmed) } label: {
            AddInfoRow(
              title: "Add: “\(trimmed)”",
              subtitle: "other",
              systemImage: "plus.circle.fill",
              tint: tint
            )
          }
          .buttonStyle(.plain)
          .disabled(working)
        }
      }
      if !filtered.isEmpty {
        Section("Stocked") {
          ForEach(filtered) { item in
            Button { markLow(item) } label: {
              AddInfoRow(
                title: item.name,
                subtitle: item.category,
                tint: tint
              )
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
    .task { load() }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #endif
  }

  private func create(name: String) {
    // Default new items to low=true since the user is creating them
    // from the QuickAdd palette — implicit "I need this".
    let entity = grocery.addItem(name: name, category: "other")
    grocery.setLow(id: entity.id, low: true)
    AddInfoSection.groceries.notifyTilesChanged()
    Haptics.tick()
    dismiss()
  }

  private func markLow(_ item: GroceryItem) {
    grocery.setLow(id: item.id, low: true)
    AddInfoSection.groceries.notifyTilesChanged()
    Haptics.tick()
    dismiss()
  }

  private func load() {
    items = ChecklistMirror.loadGroceryItems(context: modelContext)
  }
}
