import SwiftUI

// Edit sheet for a supplement definition. Save enqueues
// `PUT /api/supplements/update` through HTTPOutbox.

struct EditSupplementSheet: View {
  @Environment(HTTPOutbox.self) private var outbox
  @Environment(\.dismiss) private var dismiss

  let original: SupplementDayItem
  let onSave: (SupplementDayItem) -> Void

  @State private var name: String = ""
  @State private var emoji: String = ""

  var body: some View {
    NavigationStack {
      Form {
        Section("Supplement") {
          TextField("Name", text: $name)
          TextField("Emoji", text: $emoji)
        }
      }
      .navigationTitle("Edit supplement")
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
        name = original.name
        emoji = original.emoji ?? ""
      }
    }
  }

  private func save() {
    let n = name.trimmingCharacters(in: .whitespaces)
    let e = emoji.trimmingCharacters(in: .whitespaces)
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
    onSave(rebuilt)
    dismiss()
  }
}
