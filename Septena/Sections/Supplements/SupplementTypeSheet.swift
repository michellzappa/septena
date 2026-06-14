import SwiftUI
import SwiftData

// Manage supplement definitions — add, rename, delete. Opened from
// Settings > Supplements. History is preserved on rename because
// SupplementDayStateEntity references the supplement ID, not the name.

struct SupplementTypeSheet: View {
  @Environment(ChecklistMutator.self) private var checklistMutator
  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss

  @State private var supplements: [SupplementDefinition] = []
  @State private var newName = ""
  @State private var newEmoji = ""
  @State private var editingItem: SupplementDefinition? = nil
  @FocusState private var addFieldFocused: Bool

  private var trimmed: String { newName.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    NavigationStack {
      List {
        Section {
          HStack {
            EmojiSlotPicker(emoji: $newEmoji)
            TextField("Name", text: $newName)
              .focused($addFieldFocused)
              .submitLabel(.done)
              .onSubmit { addSupplement() }
            Button("Add") { addSupplement() }
              .disabled(trimmed.isEmpty)
          }
        }

        if !supplements.isEmpty {
          Section("Supplements") {
            ForEach(supplements) { supp in
              Button {
                editingItem = supp
              } label: {
                HStack {
                  if let e = supp.emoji, !e.isEmpty { Text(e) }
                  Text(supp.name).foregroundStyle(.primary)
                  Spacer()
                  if let raw = supp.bucket, let bucket = DayBucket(rawValue: raw) {
                    Text(bucket.title)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
              }
              .buttonStyle(.plain)
            }
            .onDelete { offsets in
              for i in offsets {
                checklistMutator.deleteSupplement(id: supplements[i].id)
              }
              supplements.remove(atOffsets: offsets)
            }
          }
        }
      }
      #if os(macOS)
      .listStyle(.inset)
      #else
      .listStyle(.insetGrouped)
      #endif
      .navigationTitle("Supplements")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
        #if os(iOS)
        ToolbarItem(placement: .primaryAction) {
          EditButton()
        }
        #endif
      }
      .sheet(item: $editingItem) { item in
        EditSupplementSheet(original: SupplementDayItem(
          id: item.id,
          name: item.name,
          emoji: item.emoji,
          bucket: item.bucket,
          done: false,
          note: nil,
          time: nil
        )) { updated in
          reload()
        }
      }
      .defaultFocus($addFieldFocused, true)
    }
    .task { reload() }
  }

  private func addSupplement() {
    guard !trimmed.isEmpty else { return }
    let e = newEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
    _ = checklistMutator.createSupplement(name: trimmed, emoji: e.isEmpty ? nil : e)
    reload()
    newName = ""
    newEmoji = ""
    Haptics.tick()
  }

  private func reload() {
    supplements = ChecklistMirror.loadSupplementDefinitions(context: modelContext)
  }
}
