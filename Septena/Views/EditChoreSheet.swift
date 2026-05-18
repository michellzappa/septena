import SwiftUI

// Edit sheet for a chore definition — name, emoji, cadence. Save enqueues
// `PUT /api/chores/definitions/{id}` through HTTPOutbox.

struct EditChoreSheet: View {
  @Environment(HTTPOutbox.self) private var outbox
  @Environment(\.dismiss) private var dismiss

  let original: ChoreItem
  let onSave: (ChoreItem) -> Void

  @State private var name: String = ""
  @State private var emoji: String = ""
  @State private var cadenceDays: Int = 7
  /// Recognised cadence presets — picking one drives `cadenceDays`. Same
  /// shape the webapp's chore editor uses.
  @State private var cadencePreset: String = "custom"

  private static let presets: [(label: String, days: Int)] = [
    ("Daily", 1),
    ("Every 2 days", 2),
    ("Weekly", 7),
    ("Every 2 weeks", 14),
    ("Monthly", 30),
    ("Every 3 months", 90),
  ]

  var body: some View {
    NavigationStack {
      Form {
        Section("Chore") {
          TextField("Name", text: $name)
          TextField("Emoji", text: $emoji)
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
            Text("\(cadenceDays) day\(cadenceDays == 1 ? "" : "s")")
          }
          .onChange(of: cadenceDays) { _, new in
            // Snap preset back to "custom" when stepping away from a known value.
            if !Self.presets.contains(where: { $0.days == new }) {
              cadencePreset = "custom"
            }
          }
        }
      }
      .navigationTitle("Edit chore")
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
    cadenceDays = original.cadenceDays ?? 7
    cadencePreset = Self.presets.first(where: { $0.days == cadenceDays })?.label ?? "custom"
  }

  private func save() {
    let n = name.trimmingCharacters(in: .whitespaces)
    let e = emoji.trimmingCharacters(in: .whitespaces)
    let body: [String: Any] = [
      "name": n,
      "emoji": e,
      "cadence_days": cadenceDays,
    ]
    outbox.enqueue(
      method: "PUT",
      path: "/api/chores/definitions/\(original.id)",
      body: body,
      kind: "chores.update"
    )
    Haptics.tick()
    var rebuilt = original
    rebuilt.name = n
    rebuilt.emoji = e.isEmpty ? nil : e
    rebuilt.cadenceDays = cadenceDays
    onSave(rebuilt)
    dismiss()
  }
}
