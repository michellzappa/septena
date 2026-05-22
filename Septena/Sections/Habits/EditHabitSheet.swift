import SwiftUI

// Edit/create sheet for a habit definition. Standard SwiftUI `Form` in a
// `NavigationStack` presented via `.sheet(item:)` (edit) or
// `.sheet(isPresented:)` (create). Edit enqueues `PUT /api/habits/update`
// through HTTPOutbox; create enqueues `POST /api/habits/new`.

struct EditHabitSheet: View {
  @Environment(HTTPOutbox.self) private var outbox
  @Environment(\.dismiss) private var dismiss

  let original: HabitDayItem?
  /// Allowed buckets for this app/server (e.g. ["morning","afternoon","evening"]).
  let buckets: [String]
  let onDone: (HabitDayItem?) -> Void

  @State private var name: String = ""
  @State private var emoji: String = ""
  @State private var bucket: String = "morning"

  var body: some View {
    NavigationStack {
      Form {
        Section("Habit") {
          TextField("Name", text: $name)
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
      .navigationTitle(original == nil ? "New Habit" : "Edit Habit")
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
    bucket = original.flatMap { buckets.contains($0.bucket) ? $0.bucket : nil } ?? buckets.first ?? "morning"
  }

  private func save() {
    let n = name.trimmingCharacters(in: .whitespaces)
    let e = emoji.trimmingCharacters(in: .whitespaces)
    if let original {
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
      onDone(rebuilt)
    } else {
      let body: [String: Any] = [
        "name": n,
        "bucket": bucket,
        "emoji": e,
      ]
      outbox.enqueue(
        method: "POST",
        path: "/api/habits/new",
        body: body,
        kind: "habits.create"
      )
      Haptics.tick()
      onDone(nil)
    }
    dismiss()
  }
}
