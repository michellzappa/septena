import SwiftUI

struct ReviewAndSaveView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(SectionTheme.self) private var theme

  let availableSections: [SectionConfig]
  let onSave: ([DraftGoal]) -> Void

  @State private var drafts: [DraftGoal]

  init(drafts: [DraftGoal],
       availableSections: [SectionConfig],
       onSave: @escaping ([DraftGoal]) -> Void) {
    _drafts = State(initialValue: drafts)
    self.availableSections = availableSections
    self.onSave = onSave
  }

  var body: some View {
    List {
      Section {
        Text("Choose which generated items become Goals. You can edit the wording and tag sections before saving.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      ForEach($drafts) { $draft in
        Section {
          Toggle(isOn: $draft.include) {
            Label(draft.kind == .purpose ? "North-star goal" : "Commitment",
                  systemImage: draft.kind == .purpose ? "sparkle.magnifyingglass" : "checkmark.seal")
          }

          TextEditor(text: $draft.text)
            .frame(minHeight: draft.kind == .purpose ? 86 : 64)
            .disabled(!draft.include)
            .foregroundStyle(draft.include ? .primary : .secondary)

          if !availableSections.isEmpty {
            sectionPicker(for: $draft)
              .disabled(!draft.include)
          }
        }
      }
    }
    .navigationTitle("Review Goals")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Back") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          onSave(cleanDrafts)
        }
        .disabled(cleanDrafts.isEmpty)
      }
    }
  }

  private var cleanDrafts: [DraftGoal] {
    drafts.compactMap { draft in
      let clean = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard draft.include, !clean.isEmpty else { return nil }
      var copy = draft
      copy.text = clean
      return copy
    }
  }

  private func sectionPicker(for draft: Binding<DraftGoal>) -> some View {
    let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]
    return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
      ForEach(availableSections, id: \.key) { section in
        let selected = draft.wrappedValue.sections.contains(section.key)
        let color = theme.accentByKey[section.key] ?? Color.secondary
        SelectableChip(isSelected: selected, tint: color, fillsWidth: true) {
          if selected {
            draft.wrappedValue.sections.removeAll { $0 == section.key }
          } else {
            draft.wrappedValue.sections.append(section.key)
          }
        } label: {
          Text(section.label).lineLimit(1)
        }
      }
    }
    .padding(.vertical, 4)
  }
}
