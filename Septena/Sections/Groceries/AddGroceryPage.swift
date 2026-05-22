import SwiftUI

// Type-to-create groceries. Stocked items are shown below — tap to flip
// `low` so the user can mark them as needed without leaving the palette.

struct AddGroceryPage: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(HTTPOutbox.self) private var outbox
  @Environment(SectionTheme.self) private var theme
  @Environment(\.dismiss) private var dismiss
  @Bindable var router: AddInfoRouter
  @State private var items: [GroceryItem] = []
  @State private var working = false

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
    .task { await load() }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #endif
  }

  private func create(name: String) {
    outbox.enqueue(method: "POST", path: "/api/groceries/item",
                   body: ["name": name, "category": "other"],
                   kind: "groceries.add")
    AddInfoSection.groceries.notifyTilesChanged()
    Haptics.tick()
    dismiss()
  }

  private func markLow(_ item: GroceryItem) {
    outbox.enqueue(method: "PATCH", path: "/api/groceries/item/\(item.id)",
                   body: ["low": true],
                   kind: "groceries.patch")
    AddInfoSection.groceries.notifyTilesChanged()
    Haptics.tick()
    dismiss()
  }

  private func load() async {
    items = (try? await client.groceries()) ?? []
  }
}
