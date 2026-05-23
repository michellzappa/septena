import SwiftUI
import SwiftData

// Goals tab — a list of free-text intentions tagged with section keys.
// Goals are read-often, write-rarely; agents use them as context for
// understanding what the user is working toward across each section.
//
// Mutations go through GoalMutator → SwiftData → CKEngine (CloudKit).
// Reads come from the local SwiftData mirror painted instantly on load;
// .septenaDataChanged triggers a cache refresh after CKEngine delivers
// new/updated records from other devices.

struct GoalsView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme
  @Environment(\.modelContext) private var context
  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var hSize
  #endif

  private var goalMutator: GoalMutator { SeptenaServices.shared.goalMutator }

  @State private var goals: [Goal] = []
  @State private var availableSections: [SeptenaClient.SectionConfig] = []
  @State private var loading = true
  @State private var editing: Goal? = nil

  /// Mirrors WeekDashboardView's grid: iPhone compact = 1 col, iPad regular
  /// = 3 cols, macOS = adaptive ~280pt tiles.
  private var columns: [GridItem] {
    #if os(iOS)
    let count = (hSize == .regular) ? 3 : 1
    return Array(repeating: GridItem(.flexible(), spacing: 14), count: count)
    #else
    return [GridItem(.adaptive(minimum: 280), spacing: 14)]
    #endif
  }

  var body: some View {
    NavigationStack {
      content
        .navigationTitle("Goals")
        .trackScreen("goals")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .background(Theme.groupedBackground)
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            Button(action: addGoal) {
              Image(systemName: "plus")
            }
          }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in
          goals = LocalCache.goals(in: context)
        }
        .sheet(item: $editing) { goal in
          EditGoalSheet(
            goal: goal,
            availableSections: availableSections,
            theme: theme,
            mutator: goalMutator,
            onUpdate: { updated in
              if let idx = goals.firstIndex(where: { $0.id == updated.id }) {
                goals[idx] = updated
              }
            },
            onDelete: { id in
              goals.removeAll { $0.id == id }
            }
          )
        }
    }
  }

  @ViewBuilder
  private var content: some View {
    if loading && goals.isEmpty {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if goals.isEmpty {
      ContentUnavailableView {
        Label("No Goals Yet", systemImage: "target")
      } description: {
        Text("Free-text intentions. Tag with sections so agents have context for what you're working toward.")
      } actions: {
        Button("Add First Goal", action: addGoal)
      }
    } else {
      ScrollView {
        LazyVGrid(columns: columns, spacing: 14) {
          ForEach(goals) { goal in
            Button { editing = goal } label: {
              GoalTile(goal: goal, theme: theme)
            }
            .buttonStyle(.plain)
            .contextMenu {
              Button(role: .destructive) { deleteGoal(goal) } label: {
                Label("Delete", systemImage: "trash")
              }
            }
          }
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 12)
        .padding(.bottom, 80)
      }
    }
  }

  private func load() async {
    loading = true
    defer { loading = false }
    // Goals + sections both come from the local SwiftData mirror (CK-authoritative).
    goals = LocalCache.goals(in: context)
    availableSections = SettingsMirror.loadSections(context: context)
      .filter { $0.key != "goals" }
  }

  private func addGoal() {
    let goal = goalMutator.createGoal(text: "New goal")
    goals.insert(goal, at: 0)
    editing = goal
    Haptics.tick()
  }

  private func deleteGoal(_ goal: Goal) {
    goalMutator.deleteGoal(id: goal.id)
    goals.removeAll { $0.id == goal.id }
    Haptics.warning()
  }
}

// MARK: - Goal tile
//
// Matches the Week dashboard's ModuleTile shape: rounded card on the
// grouped background, accent stripe on the leading edge sourced from the
// goal's first tagged section (falls back to a neutral tone when the goal
// has no sections yet). Inside: large goal text up top, section pills
// along the bottom so each card reads as "this is what I'm working toward
// in <area>" at a glance.

private struct GoalTile: View {
  let goal: Goal
  let theme: SectionTheme

  private var accent: Color {
    goal.sections.first.map { theme.color(for: $0) } ?? .secondary
  }

  private var isPlaceholder: Bool { goal.text == "New goal" }

  var body: some View {
    HStack(spacing: 0) {
      Rectangle()
        .fill(accent)
        .frame(width: 3)
      VStack(alignment: .leading, spacing: 16) {
        Text(isPlaceholder ? "New goal" : goal.text)
          .font(.title3.weight(.semibold))
          .foregroundStyle(isPlaceholder ? .secondary : .primary)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
        if !goal.sections.isEmpty {
          sectionPills
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(
      RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        .fill(Theme.secondaryGroupedBackground)
    )
    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    .contentShape(Rectangle())
  }

  private var sectionPills: some View {
    // Wrap pills so multi-section goals don't clip on narrow widths.
    let columns = [GridItem(.adaptive(minimum: 70), spacing: 6, alignment: .leading)]
    return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
      ForEach(goal.sections, id: \.self) { key in
        let color = theme.color(for: key)
        Text(key.capitalized)
          .font(.caption2.weight(.medium))
          .lineLimit(1)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(color.opacity(0.15))
          .foregroundStyle(color)
          .clipShape(Capsule())
      }
    }
  }
}

// MARK: - Edit sheet

struct EditGoalSheet: View {
  @Environment(\.dismiss) private var dismiss

  let goal: Goal
  let availableSections: [SeptenaClient.SectionConfig]
  let theme: SectionTheme
  let mutator: GoalMutator
  let onUpdate: (Goal) -> Void
  let onDelete: (String) -> Void

  @State private var text: String
  @State private var selectedSections: Set<String>
  @State private var showDeleteConfirm = false

  init(goal: Goal,
       availableSections: [SeptenaClient.SectionConfig],
       theme: SectionTheme,
       mutator: GoalMutator,
       onUpdate: @escaping (Goal) -> Void,
       onDelete: @escaping (String) -> Void) {
    self.goal = goal
    self.availableSections = availableSections
    self.theme = theme
    self.mutator = mutator
    self.onUpdate = onUpdate
    self.onDelete = onDelete
    _text = State(initialValue: goal.text == "New goal" ? "" : goal.text)
    _selectedSections = State(initialValue: Set(goal.sections))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Goal") {
          TextEditor(text: $text)
            .frame(minHeight: 80)
        }
        if !availableSections.isEmpty {
          Section("Sections") {
            let columns = [GridItem(.adaptive(minimum: 90), spacing: 8)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
              ForEach(availableSections, id: \.key) { sec in
                let selected = selectedSections.contains(sec.key)
                let color = theme.accentByKey[sec.key] ?? Color.secondary
                Button {
                  if selected { selectedSections.remove(sec.key) }
                  else { selectedSections.insert(sec.key) }
                } label: {
                  Text(sec.label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(selected ? color : color.opacity(0.12))
                    .foregroundStyle(selected ? .white : color)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
              }
            }
            .padding(.vertical, 4)
          }
        }
        Section {
          Button(role: .destructive) {
            showDeleteConfirm = true
          } label: {
            Label("Delete Goal", systemImage: "trash")
          }
        }
      }
      .navigationTitle("Edit Goal")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { save() }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .confirmationDialog(
        "Delete this goal?",
        isPresented: $showDeleteConfirm,
        titleVisibility: .visible
      ) {
        Button("Delete", role: .destructive) { delete() }
        Button("Cancel", role: .cancel) {}
      }
    }
  }

  private func save() {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return }
    let sections = Array(selectedSections)
    mutator.updateGoal(id: goal.id, text: clean, sections: sections)
    Haptics.tick()
    var updated = goal
    updated.text = clean
    updated.sections = sections
    onUpdate(updated)
    dismiss()
  }

  private func delete() {
    mutator.deleteGoal(id: goal.id)
    Haptics.warning()
    onDelete(goal.id)
    dismiss()
  }
}
