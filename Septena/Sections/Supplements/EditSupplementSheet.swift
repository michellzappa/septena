import SwiftUI

// Edit/create sheet for a supplement definition. Edit enqueues
// `PUT /api/supplements/update` through HTTPOutbox; create enqueues
// `POST /api/supplements/new`.

struct EditSupplementSheet: View {
  @Environment(ChecklistMutator.self) private var checklistMutator
  @Environment(\.dismiss) private var dismiss

  let original: SupplementDayItem?
  let onDone: (SupplementDayItem?) -> Void

  @State private var name: String = ""
  @State private var emoji: String = ""

  var body: some View {
    NavigationStack {
      Form {
        Section("Supplement") {
          TextField("Name", text: $name)
        }
      }
      .navigationTitle(original == nil ? "New Supplement" : "Edit Supplement")
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
      .onAppear {
        name = original?.name ?? ""
        emoji = original?.emoji ?? ""
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
    dismiss()
  }
}
