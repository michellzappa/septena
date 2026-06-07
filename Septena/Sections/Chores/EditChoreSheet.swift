import SwiftUI

// Edit/create sheet for a chore definition — name, emoji, cadence. Edit
// enqueues `PUT /api/chores/definitions/{id}` through HTTPOutbox; create
// enqueues `POST /api/chores/definitions`.

struct EditChoreSheet: View {
  @Environment(ChecklistMutator.self) private var checklistMutator

  let original: ChoreItem?
  let onDone: (ChoreItem?) -> Void

  @State private var name: String = ""
  @State private var emoji: String = ""
  @State private var cadenceDays: Int = 7
  @FocusState private var nameFocused: Bool
  /// Recognised cadence presets — picking one drives `cadenceDays`. Same
  /// shape the webapp's chore editor uses.
  @State private var cadencePreset: String = "Weekly"

  private static let presets: [(label: String, days: Int)] = [
    ("Daily", 1),
    ("Every 2 days", 2),
    ("Weekly", 7),
    ("Every 2 weeks", 14),
    ("Monthly", 30),
    ("Every 3 months", 90),
  ]

  var body: some View {
    AdaptiveEditScaffold(
      title: original == nil ? "New Chore" : "Edit Chore",
      canSave: !name.trimmingCharacters(in: .whitespaces).isEmpty,
      onSave: save
    ) {
      formBody
        .onAppear { seed() }
        .defaultFocus($nameFocused, true)
    }
  }

  @ViewBuilder private var formBody: some View {
      Form {
        Section("Chore") {
          HStack(spacing: 12) {
            TextField("Emoji", text: $emoji)
              .frame(width: 44)
              .multilineTextAlignment(.center)
            TextField("Name", text: $name)
              .focused($nameFocused)
          }
        }
        Section("Cadence") {
          Picker("Preset", selection: $cadencePreset) {
            ForEach(Self.presets, id: \.label) { p in
              Text(p.label).tag(p.label)
            }
            Text("Custom").tag("custom")
          }
          .onChange(of: cadencePreset) { _, new in
            if let preset = Self.presets.first(where: { $0.label == new }) {
              cadenceDays = preset.days
            }
          }
          Stepper(value: $cadenceDays, in: 1...365) {
            Text("\(cadenceDays) days")
          }
          .onChange(of: cadenceDays) { _, new in
            // Snap preset back to "custom" when stepping away from a known value.
            if !Self.presets.contains(where: { $0.days == new }) {
              cadencePreset = "custom"
            }
          }
        }
      }
  }

  private func seed() {
    name = original?.name ?? ""
    emoji = original?.emoji ?? ""
    cadenceDays = original?.cadenceDays ?? 7
    cadencePreset = Self.presets.first(where: { $0.days == cadenceDays })?.label ?? "Weekly"
  }

  private func save() {
    let n = name.trimmingCharacters(in: .whitespaces)
    let e = emoji.trimmingCharacters(in: .whitespaces)
    if let original {
      checklistMutator.updateChore(id: original.id, name: n, cadenceDays: cadenceDays, emoji: e)
      Haptics.tick()
      var rebuilt = original
      rebuilt.name = n
      rebuilt.emoji = e.isEmpty ? nil : e
      rebuilt.cadenceDays = cadenceDays
      onDone(rebuilt)
    } else {
      _ = checklistMutator.createChore(name: n, cadenceDays: cadenceDays, emoji: e)
      Haptics.tick()
      onDone(nil)
    }
  }
}
