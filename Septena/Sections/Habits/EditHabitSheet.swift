import SwiftUI

// Edit/create sheet for a habit definition. A standard SwiftUI `Form`
// wrapped in `AdaptiveEditScaffold`, which supplies all chrome (inline
// header when docked as an inspector on regular width; NavigationStack +
// Cancel/Save toolbar when presented as a bottom sheet) and closes after
// save/cancel. Presented via `.adaptiveDetail(item:)` (edit) or
// `.adaptiveDetail(isPresented:)` (create). Edit enqueues
// `PUT /api/habits/update` through HTTPOutbox; create enqueues
// `POST /api/habits/new`.

struct EditHabitSheet: View {
  @Environment(ChecklistMutator.self) private var checklistMutator

  let original: HabitDayItem?
  /// Allowed buckets for this app/server (e.g. ["morning","afternoon","evening"]).
  let buckets: [String]
  let onDone: (HabitDayItem?) -> Void

  @State private var name: String = ""
  @State private var emoji: String = ""
  @State private var bucket: String = "morning"
  @FocusState private var nameFocused: Bool

  private var navTitle: String { original == nil ? "New Habit" : "Edit Habit" }

  var body: some View {
    AdaptiveEditScaffold(title: navTitle,
                         canSave: !name.trimmingCharacters(in: .whitespaces).isEmpty,
                         onSave: save) {
      formBody
        .onAppear { seed() }
        .defaultFocus($nameFocused, true)
    }
  }

  @ViewBuilder private var formBody: some View {
    Form {
      Section("Habit") {
        HStack(spacing: 12) {
          TextField("Emoji", text: $emoji)
            .frame(width: 44)
            .multilineTextAlignment(.center)
          TextField("Name", text: $name)
            .focused($nameFocused)
        }
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
      checklistMutator.updateHabit(id: original.id, name: n, bucket: bucket, emoji: e)
      Haptics.tick()
      var rebuilt = original
      rebuilt.name = n
      rebuilt.bucket = bucket
      rebuilt.emoji = e.isEmpty ? nil : e
      onDone(rebuilt)
    } else {
      _ = checklistMutator.createHabit(name: n, bucket: bucket, emoji: e)
      Haptics.tick()
      onDone(nil)
    }
  }
}
