import SwiftUI
import SwiftData

// Manage coffee-bean presets — add new beans, delete old ones. Opened from
// the "+" button in CaffeineDestinationView. Beans appear in the quick-add
// palette and in Caffeine settings.

struct CaffeineTypeSheet: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss

  @State private var beans: [CaffeineBean] = []
  @State private var newName = ""
  @FocusState private var addFieldFocused: Bool

  private var mutator: CaffeineMutator { SeptenaServices.shared.caffeineMutator }

  private var trimmed: String { newName.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    NavigationStack {
      List {
        Section {
          HStack {
            TextField("Bean name", text: $newName)
              .focused($addFieldFocused)
              .submitLabel(.done)
              .onSubmit { addBean() }
            Button("Add") { addBean() }
              .disabled(trimmed.isEmpty)
          }
        }

        if !beans.isEmpty {
          Section("Beans") {
            ForEach(beans) { bean in
              Text(bean.name)
            }
            .onDelete { offsets in
              for i in offsets { mutator.deleteBean(id: beans[i].id) }
              beans.remove(atOffsets: offsets)
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
      .navigationTitle("Coffee Beans")
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
    .task { beans = ChecklistMirror.loadCaffeineBeans(context: modelContext) }
  }

  private func addBean() {
    guard !trimmed.isEmpty else { return }
    mutator.addBean(name: trimmed)
    beans = ChecklistMirror.loadCaffeineBeans(context: modelContext)
    newName = ""
    Haptics.tick()
  }
}
