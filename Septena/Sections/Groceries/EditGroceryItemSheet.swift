import SwiftUI

// Edit/create sheet for a grocery item — name, emoji, category. Category is a
// picker bound to the user's configured groceries categories (fetched
// from the server and passed in by the dashboard). Edit enqueues
// `PATCH /api/groceries/item/{id}` through HTTPOutbox; create enqueues
// `POST /api/groceries/item`.

struct EditGroceryItemSheet: View {
  private var grocery: GroceryMutator { SeptenaServices.shared.groceryMutator }

  let original: GroceryItem?
  let categories: [GroceryCategory]
  let onDone: (GroceryItem?) -> Void

  @State private var name: String = ""
  @State private var emoji: String = ""
  @State private var category: String = ""
  @FocusState private var nameFocused: Bool

  private var fallbackID: String {
    categories.first(where: { $0.id == "other" })?.id ?? categories.first?.id ?? "other"
  }

  var body: some View {
    AdaptiveEditScaffold(
      title: original == nil ? "New Item" : "Edit Item",
      canSave: !name.trimmingCharacters(in: .whitespaces).isEmpty,
      onSave: save
    ) {
      formBody.onAppear { seed() }
    }
  }

  @ViewBuilder private var formBody: some View {
    Form {
      Section("Item") {
        TextField("Name", text: $name)
          .focused($nameFocused)
        Picker("Category", selection: $category) {
          ForEach(categories) { cat in
            Text(cat.name).tag(cat.id)
          }
        }
      }
    }
    .defaultFocus($nameFocused, true)
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
    if let original {
      grocery.updateItem(id: original.id, name: n, category: c, emoji: e)
      Haptics.tick()
      var rebuilt = original
      rebuilt.name = n
      rebuilt.emoji = e
      rebuilt.category = c
      onDone(rebuilt)
    } else {
      grocery.addItem(name: n, category: c, emoji: e)
      Haptics.tick()
      onDone(nil)
    }
  }
}
