import SwiftUI

// Goals tab — a list of free-text intentions tagged with section keys.
// Goals are read-often, write-rarely; agents use them as context for
// understanding what the user is working toward across each section.
//
// Create: tap + in toolbar → POST /api/goals (returns new Goal with server
//   ID) → immediately open the edit sheet so the user fills in real text.
// Edit: tap any row → edit sheet → outbox-enqueued PUT /api/goals/{id}.
// Delete: swipe-to-delete on row OR delete button inside edit sheet →
//   outbox-enqueued DELETE /api/goals/{id}.

struct GoalsView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(HTTPOutbox.self) private var outbox
  @Environment(SectionTheme.self) private var theme

  @State private var goals: [Goal] = []
  @State private var availableSections: [SeptenaClient.SectionConfig] = []
  @State private var loading = true
  @State private var editing: Goal? = nil

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
        .sheet(item: $editing) { goal in
          EditGoalSheet(
            goal: goal,
            availableSections: availableSections,
            theme: theme,
            outbox: outbox,
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
      List {
        ForEach(goals) { goal in
          Button { editing = goal } label: {
            GoalRow(goal: goal, theme: theme)
          }
          .buttonStyle(.plain)
          .listRowInsets(EdgeInsets())
          .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { deleteGoal(goal) } label: {
              Label("Delete", systemImage: "trash")
            }
          }
        }
      }
      .listStyle(.insetGrouped)
    }
  }

  private func load() async {
    loading = true
    defer { loading = false }
    async let g = try? client.goals()
    async let s = try? client.sections()
    goals = await g ?? []
    availableSections = (await s ?? []).filter { $0.key != "goals" }
  }

  private func addGoal() {
    Task {
      do {
        let goal = try await client.createGoal(text: "New goal")
        goals.insert(goal, at: 0)
        editing = goal
        Haptics.tick()
      } catch {
        SeptenaLog.error("createGoal", error)
      }
    }
  }

  private func deleteGoal(_ goal: Goal) {
    outbox.enqueue(
      method: "DELETE",
      path: "/api/goals/\(goal.id)",
      body: nil,
      kind: "goals.delete"
    )
    goals.removeAll { $0.id == goal.id }
    Haptics.warning()
  }
}

// MARK: - Goal row

private struct GoalRow: View {
  let goal: Goal
  let theme: SectionTheme

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(goal.text)
        .font(.body)
        .foregroundStyle(goal.text == "New goal" ? .secondary : .primary)
      if !goal.sections.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(goal.sections, id: \.self) { key in
              let color = theme.color(for: key)
              Text(key.capitalized)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(color.opacity(0.15))
                .foregroundStyle(color)
                .clipShape(Capsule())
            }
          }
        }
      }
    }
    .padding(.vertical, 10)
    .padding(.horizontal, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }
}

// MARK: - Edit sheet

struct EditGoalSheet: View {
  @Environment(\.dismiss) private var dismiss

  let goal: Goal
  let availableSections: [SeptenaClient.SectionConfig]
  let theme: SectionTheme
  let outbox: HTTPOutbox
  let onUpdate: (Goal) -> Void
  let onDelete: (String) -> Void

  @State private var text: String
  @State private var selectedSections: Set<String>
  @State private var showDeleteConfirm = false

  init(goal: Goal,
       availableSections: [SeptenaClient.SectionConfig],
       theme: SectionTheme,
       outbox: HTTPOutbox,
       onUpdate: @escaping (Goal) -> Void,
       onDelete: @escaping (String) -> Void) {
    self.goal = goal
    self.availableSections = availableSections
    self.theme = theme
    self.outbox = outbox
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
    outbox.enqueue(
      method: "PUT",
      path: "/api/goals/\(goal.id)",
      body: ["text": clean, "sections": sections],
      kind: "goals.update"
    )
    Haptics.tick()
    var updated = goal
    updated.text = clean
    updated.sections = sections
    onUpdate(updated)
    dismiss()
  }

  private func delete() {
    outbox.enqueue(
      method: "DELETE",
      path: "/api/goals/\(goal.id)",
      body: nil,
      kind: "goals.delete"
    )
    Haptics.warning()
    onDelete(goal.id)
    dismiss()
  }
}
