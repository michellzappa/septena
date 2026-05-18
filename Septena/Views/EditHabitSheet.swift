import SwiftUI

// Edit sheet for a habit definition. Standard SwiftUI `Form` in a
// `NavigationStack` presented via `.sheet(item:)`. Save enqueues
// `PUT /api/habits/update` through HTTPOutbox.

struct EditHabitSheet: View {
  @Environment(HTTPOutbox.self) private var outbox
  @Environment(\.dismiss) private var dismiss

  let original: HabitDayItem
  /// Allowed buckets for this app/server (e.g. ["morning","afternoon","evening"]).
  let buckets: [String]
  let onSave: (HabitDayItem) -> Void

  @State private var name: String = ""
  @State private var emoji: String = ""
  @State private var bucket: String = "morning"

  var body: some View {
    NavigationStack {
      Form {
        Section("Habit") {
          TextField("Name", text: $name)
          TextField("Emoji", text: $emoji)
        }
        Section("Bucket") {
          Picker("Bucket", selection: $bucket) {
            ForEach(buckets, id: \.self) { b in
              Text(b.capitalized).tag(b)
            }
          }
          .pickerStyle(.segmented)
        }
      }
      .navigationTitle("Edit habit")
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
    emoji = original.emoji ?? ""
    bucket = buckets.contains(original.bucket) ? original.bucket : (buckets.first ?? original.bucket)
  }

  private func save() {
    let n = name.trimmingCharacters(in: .whitespaces)
    let e = emoji.trimmingCharacters(in: .whitespaces)
    let body: [String: Any] = [
      "id": original.id,
      "name": n,
      "bucket": bucket,
      "emoji": e,
    ]
    outbox.enqueue(
      method: "PUT",
      path: "/api/habits/update",
      body: body,
      kind: "habits.update"
    )
    Haptics.tick()
    var rebuilt = original
    rebuilt.name = n
    rebuilt.bucket = bucket
    rebuilt.emoji = e.isEmpty ? nil : e
    onSave(rebuilt)
    dismiss()
  }
}
