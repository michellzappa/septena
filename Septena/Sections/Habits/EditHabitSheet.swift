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
  let onDone: (HabitDayItem?) -> Void

  @State private var name: String = ""
  @State private var emoji: String = ""
  /// Selection key. Mirrors Supplements: `DayBucket.anytimeKey` for an
  /// all-day habit, else a canonical bucket. New habits default to morning
  /// (the most common routine slot); supplements default to anytime — each
  /// section keeps the default that fits its nature, but both offer the full
  /// set.
  @State private var bucket: String = DayBucket.morning.rawValue
  @FocusState private var nameFocused: Bool

  /// "Anytime" first, then the day's buckets in order — same options as
  /// `EditSupplementSheet`.
  private var bucketOptions: [String] { [DayBucket.anytimeKey] + DayBucket.allCases.map(\.rawValue) }

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
      Section("Time of day") {
        Picker("Time of day", selection: $bucket) {
          ForEach(bucketOptions, id: \.self) { Text(DayBucket.label(forKey: $0)).tag($0) }
        }
        .pickerStyle(.segmented)
      }
    }
  }

  private func seed() {
    name = original?.name ?? ""
    emoji = original?.emoji ?? ""
    let stored = original?.bucket ?? DayBucket.morning.rawValue
    bucket = bucketOptions.contains(stored) ? stored : DayBucket.morning.rawValue
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
