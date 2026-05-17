import SwiftUI

// Type-to-create groceries. Stocked items are shown below — tap to flip
// `low` so the user can mark them as needed without leaving the palette.

struct AddGroceryPage: View {
  @Environment(SeptenaClient.self) private var client
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
                title: "\(item.emoji.isEmpty ? "" : item.emoji + " ")\(item.name)",
                subtitle: item.category,
                systemImage: "cart",
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
    guard !working else { return }
    working = true
    Task {
      defer { working = false }
      do {
        try await client.addGroceryItem(name: name)
        Haptics.tick()
        dismiss()
      } catch { Haptics.warning() }
    }
  }

  private func markLow(_ item: GroceryItem) {
    Task {
      do {
        try await client.patchGroceryItem(id: item.id, low: true)
        Haptics.tick()
        dismiss()
      } catch { Haptics.warning() }
    }
  }

  private func load() async {
    items = (try? await client.groceries()) ?? []
  }
}
