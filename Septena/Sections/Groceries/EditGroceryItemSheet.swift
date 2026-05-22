import SwiftUI

// Edit/create sheet for a grocery item — name, emoji, category. Category is a
// picker bound to the user's configured groceries categories (fetched
// from the server and passed in by the dashboard). Edit enqueues
// `PATCH /api/groceries/item/{id}` through HTTPOutbox; create enqueues
// `POST /api/groceries/item`.

struct EditGroceryItemSheet: View {
  @Environment(HTTPOutbox.self) private var outbox
  @Environment(\.dismiss) private var dismiss

  let original: GroceryItem?
  let categories: [GroceryCategory]
  let onDone: (GroceryItem?) -> Void

  @State private var name: String = ""
  @State private var emoji: String = ""
  @State private var category: String = ""

  private var fallbackID: String {
    categories.first(where: { $0.id == "other" })?.id ?? categories.first?.id ?? "other"
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Item") {
          TextField("Name", text: $name)
          Picker("Category", selection: $category) {
            ForEach(categories) { cat in
              Text(cat.name).tag(cat.id)
            }
          }
        }
      }
      .navigationTitle(original == nil ? "New Item" : "Edit Item")
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
    name = original?.name ?? ""
    emoji = original?.emoji ?? ""
    if let original {
      let knownIDs = Set(categories.map { $0.id })
      category = knownIDs.contains(original.category) ? original.category : fallbackID
    } else {
      category = fallbackID
    }
  }

  private func save() {
    let n = name.trimmingCharacters(in: .whitespaces)
    let e = emoji.trimmingCharacters(in: .whitespaces)
    let c = category.isEmpty ? fallbackID : category
    let body: [String: Any] = [
      "name": n,
      "emoji": e,
      "category": c,
    ]
    if let original {
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
      rebuilt.category = c
      onDone(rebuilt)
    } else {
      outbox.enqueue(
        method: "POST",
        path: "/api/groceries/item",
        body: body,
        kind: "groceries.create"
      )
      Haptics.tick()
      onDone(nil)
    }
    dismiss()
  }
}
