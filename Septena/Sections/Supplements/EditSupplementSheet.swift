import SwiftUI

// Edit/create sheet for a supplement definition. Edit enqueues
// `PUT /api/supplements/update` through HTTPOutbox; create enqueues
// `POST /api/supplements/new`.

struct EditSupplementSheet: View {
  @Environment(ChecklistMutator.self) private var checklistMutator

  let original: SupplementDayItem?
  let onDone: (SupplementDayItem?) -> Void

  @State private var name: String = ""
  @State private var emoji: String = ""

  var body: some View {
    AdaptiveEditScaffold(
      title: original == nil ? "New Supplement" : "Edit Supplement",
      canSave: !name.trimmingCharacters(in: .whitespaces).isEmpty,
      onSave: save
    ) {
      formBody.onAppear {
        name = original?.name ?? ""
        emoji = original?.emoji ?? ""
      }
    }
  }

  @ViewBuilder private var formBody: some View {
    Form {
      Section("Supplement") {
        TextField("Name", text: $name)
      }
    }
  }

  private func save() {
    let n = name.trimmingCharacters(in: .whitespaces)
    let e = emoji.trimmingCharacters(in: .whitespaces)
    if let original {
      checklistMutator.updateSupplement(id: original.id, name: n, emoji: e)
      Haptics.tick()
      var rebuilt = original
      rebuilt.name = n
      rebuilt.emoji = e.isEmpty ? nil : e
      onDone(rebuilt)
    } else {
      _ = checklistMutator.createSupplement(name: n, emoji: e)
      Haptics.tick()
      onDone(nil)
    }
  }
}
