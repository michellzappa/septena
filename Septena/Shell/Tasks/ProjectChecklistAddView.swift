import SwiftUI

/// Shared Add Item field for the iOS project page and the Mac project popover.
struct ProjectChecklistAddView: View {
  let rows: [SeptenaTask]
  let initialHeading: String?
  let add: (String, String?) -> Void
  let reopen: (String) -> Void

  @State private var title = ""
  @FocusState private var focused: Bool

  var body: some View {
    let headings = Dictionary(uniqueKeysWithValues: rows.filter(\.isHeading).map { ($0.id, $0.title) })
    let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    let matches = ProjectChecklist.layout(rows: rows, query: title)?.matches ?? []
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        TextField(RegistrySurfaces.checklistAddItem, text: $title)
          .focused($focused)
          .onSubmit(commit)
        Button("Add", action: commit)
          .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      ForEach(matches, id: \.self) { id in
        if let row = byID[id] {
          let heading = row.heading.flatMap { headings[$0] }
          Button {
            reopen(id)
            title = ""
          } label: {
            HStack {
              Text(row.title)
              Spacer()
              if let heading { Text(heading).foregroundStyle(.secondary) }
              if row.status == .open { Text(RegistrySurfaces.checklistOnList).foregroundStyle(.secondary) }
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(row.status == .open)
        }
      }
    }
    .onAppear { focused = true }
  }

  private func commit() {
    let input = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty else { return }
    add(input, initialHeading)
    title = ""
  }
}
