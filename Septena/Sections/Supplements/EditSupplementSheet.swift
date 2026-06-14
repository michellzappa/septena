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
  /// Picker selection. Uses `DayBucket.anytimeKey` as the "no slot" sentinel
  /// (mapped to a nil bucket at save time); morning/afternoon/evening scope
  /// the supplement to that window onward on the home feed.
  @State private var bucket: String = DayBucket.anytimeKey
  @FocusState private var nameFocused: Bool

  /// "Anytime" first, then the day's buckets in order.
  private var bucketOptions: [String] { [DayBucket.anytimeKey] + DayBucket.allCases.map(\.rawValue) }

  var body: some View {
    AdaptiveEditScaffold(
      title: original == nil ? "New Supplement" : "Edit Supplement",
      canSave: !name.trimmingCharacters(in: .whitespaces).isEmpty,
      onSave: save
    ) {
      formBody
        .onAppear {
          name = original?.name ?? ""
          emoji = original?.emoji ?? ""
          bucket = original?.bucket ?? DayBucket.anytimeKey
        }
        .defaultFocus($nameFocused, true)
    }
  }

  @ViewBuilder private var formBody: some View {
    Form {
      Section("Supplement") {
        HStack(spacing: 12) {
          EmojiSlotPicker(emoji: $emoji)
          TextField("Name", text: $name)
            .focused($nameFocused)
        }
      }
      Section {
        Picker("Time of day", selection: $bucket) {
          ForEach(bucketOptions, id: \.self) { Text(DayBucket.label(forKey: $0)).tag($0) }
        }
        .pickerStyle(.segmented)
      } header: {
        Text("Time of day")
      } footer: {
        Text("“Anytime” keeps it on the home feed all day. Pick a slot and it only appears from then on — so you’re not staring at the whole day’s stack at once.")
      }
    }
  }

  private func save() {
    let n = name.trimmingCharacters(in: .whitespaces)
    let e = emoji.trimmingCharacters(in: .whitespaces)
    let resolvedBucket: String? = (bucket == DayBucket.anytimeKey) ? nil : bucket
    if let original {
      checklistMutator.updateSupplement(id: original.id, name: n, emoji: e, bucket: resolvedBucket)
      Haptics.tick()
      var rebuilt = original
      rebuilt.name = n
      rebuilt.emoji = e.isEmpty ? nil : e
      rebuilt.bucket = resolvedBucket
      onDone(rebuilt)
    } else {
      _ = checklistMutator.createSupplement(name: n, emoji: e, bucket: resolvedBucket)
      Haptics.tick()
      onDone(nil)
    }
  }
}
