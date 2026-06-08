import SwiftUI
import SwiftData

// Coach tab — the top-level landing page. Three bands:
//
//   • Coaches   — a tile per CoachDomain; tap pushes its hub (CoachDetailView:
//                 conversation + that coach's context + scoped goals).
//   • Exercises — the guided reflections (Purpose, Values, Examined Week),
//                 each launches its mini-app; finishing can drop in goals.
//   • Goals     — every goal, tappable into the same EditGoalSheet the
//                 section strips use. Goals still strip into their own
//                 section drawers too (dual-homed).
//
// Replaced the old flat Goals grid. The internal section key stays "goals" —
// only the surface and label became "Coach".

struct CoachView: View {
  @Environment(\.modelContext) private var context
  @Environment(SectionTheme.self) private var theme
  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var hSize
  #endif

  private var goalMutator: GoalMutator { SeptenaServices.shared.goalMutator }

  @State private var goals: [Goal] = []
  @State private var availableSections: [SectionConfig] = []
  @State private var subtitles: [CoachDomain: String] = [:]
  @State private var editing: Goal? = nil
  @State private var activeExercise: AnyDiscoveryMiniApp? = nil

  private var columns: [GridItem] {
    #if os(iOS)
    return GoalGrid.columns(regularWidth: hSize == .regular)
    #else
    return GoalGrid.columns(regularWidth: true)
    #endif
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          coachesBand
          if OnDeviceAI.isAvailable { exercisesBand }
          goalsBand
        }
        .padding(.horizontal, Theme.pageGutter)
        .padding(.top, Theme.Spacing.sm)
        .padding(.bottom, 24)
      }
      .background(Theme.groupedBackground)
      .navigationTitle("Coach")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button { addGoal() } label: { Label("New goal", systemImage: "plus") }
            .buttonStyle(.glassProminent)
            .tint(theme.color(for: "goals"))
            .keyboardShortcut("n", modifiers: .command)
        }
      }
      .navigationDestination(for: CoachDomain.self) { domain in
        CoachDetailView(domain: domain)
      }
      .task { refresh() }
      .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in
        refresh()
      }
      .adaptiveDetail(item: $editing) { goal in
        EditGoalSheet(
          goal: goal,
          availableSections: availableSections,
          theme: theme,
          mutator: goalMutator,
          onUpdate: { updated in
            if let idx = goals.firstIndex(where: { $0.id == updated.id }) { goals[idx] = updated }
          },
          onDelete: { id in goals.removeAll { $0.id == id } }
        )
      }
      .coachExercisePresentation(activeExercise: $activeExercise) { drafts in
        let created = GoalDrafts.save(drafts, mutator: goalMutator)
        if !created.isEmpty { goals.insert(contentsOf: created, at: 0); Haptics.success() }
        activeExercise = nil
      }
    }
  }

  // MARK: - Bands

  private var coachesBand: some View {
    VStack(alignment: .leading, spacing: 12) {
      bandHeader("Coaches", "On-device coaches that reflect your logged data back to you.")
      LazyVGrid(columns: columns, spacing: 14) {
        ForEach(CoachDomain.allCases) { domain in
          NavigationLink(value: domain) {
            CoachTile(systemImage: domain.systemImage,
                      title: domain.title,
                      subtitle: subtitles[domain] ?? domain.blurb,
                      accent: domain.accent)
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private var exercisesBand: some View {
    VStack(alignment: .leading, spacing: 12) {
      bandHeader("Exercises", "Guided reflections that turn into goals.")
      LazyVGrid(columns: columns, spacing: 14) {
        ForEach(DiscoveryRegistry.all) { exercise in
          Button {
            activeExercise = AnyDiscoveryMiniApp(descriptor: exercise)
            Haptics.tick()
          } label: {
            CoachTile(systemImage: exercise.systemImage,
                      title: exercise.title,
                      subtitle: exercise.blurb,
                      accent: exercise.accent,
                      actionLabel: "Begin")
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  @ViewBuilder
  private var goalsBand: some View {
    VStack(alignment: .leading, spacing: 12) {
      bandHeader("Goals", "Free-text intentions; tag them so a coach picks them up.")
      if goals.isEmpty {
        ContentUnavailableView {
          Label("No Goals Yet", systemImage: "target")
        } description: {
          Text("Free-text intentions. Tag with sections so your coaches have context for what you're working toward.")
        } actions: {
          Button("Add First Goal", action: addGoal)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
      } else {
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
      }
    }
  }

  private func bandHeader(_ title: String, _ subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.headline)
      Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
    }
  }

  // MARK: - Data

  private func refresh() {
    goals = LocalCache.goals(in: context)
    availableSections = SettingsMirror.loadSections(context: context)
      .filter { $0.key != "goals" }
    var next: [CoachDomain: String] = [:]
    for domain in CoachDomain.allCases {
      let pills = CoachContextBuilder.availability(for: domain, window: .week, context: context)
      guard !pills.isEmpty else { continue }
      let entries = pills.reduce(0) { $0 + $1.count }
      let areas = pills.count
      next[domain] = "\(areas) area\(areas == 1 ? "" : "s") · \(entries) entr\(entries == 1 ? "y" : "ies") this week"
    }
    subtitles = next
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

// MARK: - Exercise presentation

private extension View {
  @ViewBuilder
  func coachExercisePresentation(activeExercise: Binding<AnyDiscoveryMiniApp?>,
                                 onFinish: @escaping ([DraftGoal]) -> Void) -> some View {
    #if os(macOS)
    sheet(item: activeExercise) { app in app.descriptor.makeView(onFinish) }
    #else
    fullScreenCover(item: activeExercise) { app in app.descriptor.makeView(onFinish) }
    #endif
  }
}
