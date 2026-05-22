import SwiftUI

// Edit/create sheet for a supplement definition. Edit enqueues
// `PUT /api/supplements/update` through HTTPOutbox; create enqueues
// `POST /api/supplements/new`.

struct EditSupplementSheet: View {
  @Environment(HTTPOutbox.self) private var outbox
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
      let body: [String: Any] = [
        "id": original.id,
        "name": n,
        "emoji": e,
      ]
      outbox.enqueue(
        method: "PUT",
        path: "/api/supplements/update",
        body: body,
        kind: "supplements.update"
      )
      Haptics.tick()
      var rebuilt = original
      rebuilt.name = n
      rebuilt.emoji = e.isEmpty ? nil : e
      onDone(rebuilt)
    } else {
      let body: [String: Any] = [
        "name": n,
        "emoji": e,
      ]
      outbox.enqueue(
        method: "POST",
        path: "/api/supplements/new",
        body: body,
        kind: "supplements.create"
      )
      Haptics.tick()
      onDone(nil)
    }
    dismiss()
  }
}
