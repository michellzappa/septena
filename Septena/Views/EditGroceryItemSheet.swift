import SwiftUI

// Edit sheet for a grocery item — name, emoji, category. Standard
// SwiftUI `Form` in a `NavigationStack` presented via `.sheet(item:)`.
// Save enqueues `PATCH /api/groceries/item/{id}` through HTTPOutbox.

struct EditGroceryItemSheet: View {
  @Environment(HTTPOutbox.self) private var outbox
  @Environment(\.dismiss) private var dismiss

  let original: GroceryItem
  let onSave: (GroceryItem) -> Void

  @State private var name: String = ""
  @State private var emoji: String = ""
  @State private var category: String = ""

  var body: some View {
    NavigationStack {
      Form {
        Section("Item") {
          TextField("Name", text: $name)
          TextField("Emoji", text: $emoji)
          TextField("Category", text: $category)
        }
      }
      .navigationTitle("Edit grocery item")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { save() }
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
      .onAppear { seed() }
    }
  }

  private func seed() {
    name = original.name
    emoji = original.emoji
    category = original.category
  }

  private func save() {
    let n = name.trimmingCharacters(in: .whitespaces)
    let e = emoji.trimmingCharacters(in: .whitespaces)
    let c = category.trimmingCharacters(in: .whitespaces)
    let body: [String: Any] = [
      "name": n,
      "emoji": e,
      "category": c.isEmpty ? "other" : c,
    ]
    outbox.enqueue(
      method: "PATCH",
      path: "/api/groceries/item/\(original.id)",
      body: body,
      kind: "groceries.update"
    )
    Haptics.tick()
    var rebuilt = original
    rebuilt.name = n
    rebuilt.emoji = e
    rebuilt.category = c.isEmpty ? "other" : c
    onSave(rebuilt)
    dismiss()
  }
}
