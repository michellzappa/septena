import SwiftUI
import SwiftData

// SectionGoalsStrip — a read-only strip of the user's goals tagged with
// the host section, surfaced at the top of every section drawer so the
// daily logging UI reads as "this is what you're working toward; here's
// today's data against it." Source of truth stays in the Goals tab —
// tapping a tile opens the same EditGoalSheet used there.
//
// Renders nothing when the section has no tagged goals (no empty state),
// so unused sections stay visually clean. Designed to drop in as the
// first child of a List (Section context) or a ScrollView (renders as a
// labelled group). All read paths go through the local SwiftData mirror;
// .septenaDataChanged keeps it fresh when goals are edited elsewhere or
// arrive from another device via CKEngine.

struct SectionGoalsStrip: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(\.modelContext) private var context

  let sectionKey: String

  @State private var goals: [Goal] = []
  @State private var availableSections: [SectionConfig] = []
  @State private var editing: Goal? = nil

  private var mutator: GoalMutator { SeptenaServices.shared.goalMutator }

  var body: some View {
    Group {
      if !goals.isEmpty {
        Section("Goals") {
          ForEach(goals) { goal in
            Button { editing = goal } label: {
              GoalTile(goal: goal, theme: theme)
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowSeparator(.hidden)
          }
        }
      }
    }
    .task { reload() }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in
      reload()
    }
    .sheet(item: $editing) { goal in
      EditGoalSheet(
        goal: goal,
        availableSections: availableSections,
        theme: theme,
        mutator: mutator,
        onUpdate: { _ in reload() },
        onDelete: { _ in reload() }
      )
    }
  }

  private func reload() {
    goals = LocalCache.goals(in: context).filter { $0.sections.contains(sectionKey) }
    if availableSections.isEmpty {
      availableSections = SettingsMirror.loadSections(context: context)
        .filter { $0.key != "goals" }
    }
  }
}
