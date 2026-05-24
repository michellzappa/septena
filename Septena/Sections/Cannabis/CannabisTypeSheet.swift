import SwiftUI
import SwiftData

// Manage cannabis-strain presets — add new strains, delete old ones. Opened
// from the "+" button in CannabisDestinationView. Strains appear in the
// quick-add palette and in Cannabis settings.

struct CannabisTypeSheet: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss

  @State private var strains: [CannabisStrain] = []
  @State private var newName = ""
  @FocusState private var addFieldFocused: Bool

  private var mutator: CannabisMutator { SeptenaServices.shared.cannabisMutator }

  private var trimmed: String { newName.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    NavigationStack {
      List {
        Section {
          HStack {
            TextField("Strain name", text: $newName)
              .focused($addFieldFocused)
              .submitLabel(.done)
              .onSubmit { addStrain() }
            Button("Add") { addStrain() }
              .disabled(trimmed.isEmpty)
          }
        }

        if !strains.isEmpty {
          Section("Strains") {
            ForEach(strains) { strain in
              Text(strain.name)
            }
            .onDelete { offsets in
              for i in offsets { mutator.deleteStrain(id: strains[i].id) }
              strains.remove(atOffsets: offsets)
            }
          }
        }
      }
      #if os(macOS)
      .listStyle(.inset)
      #else
      .listStyle(.insetGrouped)
      #endif
      .background(Theme.groupedBackground)
      .navigationTitle("Strains")
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
    }
    .task { strains = ChecklistMirror.loadCannabisStrains(context: modelContext) }
  }

  private func addStrain() {
    guard !trimmed.isEmpty else { return }
    mutator.addStrain(name: trimmed)
    strains = ChecklistMirror.loadCannabisStrains(context: modelContext)
    newName = ""
    Haptics.tick()
  }
}
