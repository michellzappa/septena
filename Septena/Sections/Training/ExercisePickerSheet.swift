import SwiftUI
import SwiftData

// Catalog-backed exercise picker. Two modes:
//
//   • `.multiple` (default) — checkbox multi-select with a "Done" button,
//     returning the chosen definition ids via `onDone`. Used by
//     `RoutineDetailView` to edit a routine's exercise list, and by the
//     in-session "Add exercise" affordance.
//   • `.single` — tap a row to commit immediately via `onPick` (no Done
//     button). Used by the in-session "Switch exercise" affordance, where
//     replacing one card with one other exercise is the whole interaction.
//
// `disabledNames` greys out exercises already in the active session so the
// user can't add a duplicate (a `DraftEntry`'s identity is its exercise
// name). `alternativesTo` floats same-muscle / same-subgroup options into
// an "Alternatives" section at the top in single mode — the common
// "machine's taken, what else hits this muscle" case.

struct ExercisePickerSheet: View {
  enum SelectionMode { case single, multiple }

  @Query(sort: [SortDescriptor(\ExerciseDefinitionEntity.sortIndex),
                SortDescriptor(\ExerciseDefinitionEntity.name)])
  private var allExercises: [ExerciseDefinitionEntity]

  @Environment(\.dismiss) private var dismiss
  @State private var searchText = ""
  @State private var selected: Set<String> = []

  // IDs already in the routine — passed in so we can pre-check them.
  let preselected: [String]
  let selectionMode: SelectionMode
  /// Exercise names (or slugs) already in the active session; rendered
  /// disabled so the user can't pick a duplicate.
  let disabledNames: Set<String>
  /// Anchor exercise for single-select "Switch": its same-muscle /
  /// same-subgroup peers float to an "Alternatives" section, and it's
  /// itself dropped from the list (you don't switch to what you have).
  let alternativesTo: String?
  /// Single-select commit. Receives the picked definition; caller reads `.name`.
  let onPick: ((ExerciseDefinitionEntity) -> Void)?
  /// Multi-select commit. Receives the selected definition ids in catalog order.
  let onDone: ([String]) -> Void

  init(preselected: [String] = [],
       selectionMode: SelectionMode = .multiple,
       disabledNames: Set<String> = [],
       alternativesTo: String? = nil,
       onPick: ((ExerciseDefinitionEntity) -> Void)? = nil,
       onDone: @escaping ([String]) -> Void = { _ in }) {
    self.preselected = preselected
    self.selectionMode = selectionMode
    self.disabledNames = disabledNames
    self.alternativesTo = alternativesTo
    self.onPick = onPick
    self.onDone = onDone
  }

  /// Active (non-archived) catalog rows matching the search, with the
  /// switch anchor removed in single mode.
  private var visibleExercises: [ExerciseDefinitionEntity] {
    var active = allExercises.filter { !$0.archived }
    if selectionMode == .single, let key = alternativesTo.map(exerciseKey) {
      active = active.filter { exerciseKey($0.name) != key && exerciseKey($0.id) != key }
    }
    guard !searchText.isEmpty else { return active }
    let q = searchText.lowercased()
    return active.filter { e in
      e.name.lowercased().contains(q) || e.aliases.contains { $0.lowercased().contains(q) }
    }
  }

  private var disabledKeys: Set<String> { Set(disabledNames.map(exerciseKey)) }

  private func isDisabled(_ e: ExerciseDefinitionEntity) -> Bool {
    disabledKeys.contains(exerciseKey(e.name)) || disabledKeys.contains(exerciseKey(e.id))
  }

  /// The anchor's catalog row, if it resolves — drives the alternatives split.
  private var anchorDef: ExerciseDefinitionEntity? {
    guard let key = alternativesTo.map(exerciseKey) else { return nil }
    return allExercises.first { exerciseKey($0.name) == key || exerciseKey($0.id) == key }
  }

  /// Same primary muscle or subgroup as the anchor. Deliberately does NOT
  /// fall back to "same type" — that would sweep nearly every strength
  /// lift into the section and defeat the point.
  private func isAlternative(_ e: ExerciseDefinitionEntity, to anchor: ExerciseDefinitionEntity) -> Bool {
    if let pm = anchor.primaryMuscle, !pm.isEmpty, e.primaryMuscle == pm { return true }
    if let sg = anchor.subgroup, !sg.isEmpty, e.subgroup == sg { return true }
    return false
  }

  var body: some View {
    NavigationStack {
      List {
        if selectionMode == .single, let anchor = anchorDef {
          let alts = visibleExercises.filter { isAlternative($0, to: anchor) }
          if alts.isEmpty {
            ForEach(visibleExercises) { rowView($0) }
          } else {
            Section("Alternatives") { ForEach(alts) { rowView($0) } }
            Section("All exercises") {
              ForEach(visibleExercises.filter { !isAlternative($0, to: anchor) }) { rowView($0) }
            }
          }
        } else {
          ForEach(visibleExercises) { rowView($0) }
        }
      }
      .searchable(text: $searchText)
      .navigationTitle(selectionMode == .single ? "Switch Exercise" : "Pick Exercises")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        if selectionMode == .multiple {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
              // Preserve catalog order for selected items
              let orderedIDs = visibleExercises
                .filter { selected.contains($0.id) }
                .map(\.id)
              onDone(orderedIDs)
              dismiss()
            }
          }
        }
      }
      .onAppear {
        selected = Set(preselected)
      }
    }
  }

  private func rowView(_ entity: ExerciseDefinitionEntity) -> some View {
    let disabled = isDisabled(entity)
    return Button {
      guard !disabled else { return }
      switch selectionMode {
      case .single:
        onPick?(entity)
        dismiss()
      case .multiple:
        if selected.contains(entity.id) {
          selected.remove(entity.id)
        } else {
          selected.insert(entity.id)
        }
      }
    } label: {
      HStack {
        Text(entity.name)
          .foregroundStyle(disabled ? .secondary : .primary)
        if disabled {
          Text("In session")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if selectionMode == .multiple, selected.contains(entity.id) {
          Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
        }
      }
    }
    .buttonStyle(.plain)
    .disabled(disabled)
  }
}
