import SwiftUI
import SwiftData

// Coach tab — the top-level landing page, a standard grouped List with three
// sections:
//
//   • Coaches   — one NavigationLink row per CoachDomain; tapping pushes its hub
//                 (CoachDetailView: conversation + that coach's context + scoped
//                 goals). A trailing badge counts logged entries in the coach window.
//   • Exercises — the guided reflections (Purpose, Values, Examined Week); each
//                 row launches its mini-app, which can drop in goals on finish.
//   • Goals     — every goal as a row, tapping into the same EditGoalSheet the
//                 section strips use. Goals still strip into their own section
//                 drawers too (dual-homed).
//
// Layout matches the Next home tab: grouped `List`, shared section headers, and
// the same row chrome (`pointerListRow` / `taskCardChrome`) so the two tabs read
// as one family on every idiom.

struct CoachView: View {
  @Environment(\.modelContext) private var context
  @Environment(SectionTheme.self) private var theme
  @Environment(DayClock.self) private var clock

  private var goalMutator: GoalMutator { SeptenaServices.shared.goalMutator }

  /// Sections that can change what `refresh()` computes — the union of every
  /// coach's readable keys plus goals. Gates the data-changed listener.
  private static let coachScope = Set(CoachContextBuilder.supportedKeys + ["goals"])

  @State private var goals: [Goal] = []
  @State private var availableSections: [SectionConfig] = []
  @State private var coachPills: [CoachDomain: [CoachAreaPill]] = [:]
  @State private var editing: Goal? = nil
  @State private var activeExercise: AnyDiscoveryMiniApp? = nil
  @State private var coachPath: [CoachDomain] = []

  var body: some View {
    NavigationStack(path: $coachPath) {
      List {
        coachesSection
        exercisesSection
        goalsSection
      }
      #if os(iOS)
      .listStyle(.insetGrouped)
      .listSectionSpacing(18)
      #else
      .listStyle(.plain)
      .padding(.bottom, Theme.pageBottom)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      #endif
      #if os(macOS)
      .septenaTabPage(id: "coach", title: "Coach", add: .action { addGoal() },
                      wideContentGutter: TaskCardMetrics.margin)
      #else
      .septenaTabPage(id: "coach", title: "Coach", add: .action { addGoal() })
      #endif
      .navigationDestination(for: CoachDomain.self) { domain in
        CoachDetailView(domain: domain)
      }
      .task { refresh() }
      .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { note in
        guard note.affectsAnySection(of: Self.coachScope) else { return }
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
    .iPadReportsNavDepth(id: "coach", atRoot: coachPath.isEmpty)
  }

  // MARK: - Sections

  private var coachesSection: some View {
    let domains = CoachDomain.allCases
    return groupedListSection(
      header: { sectionGroupHeader("Coaches") },
      footer: { Text("On-device coaches that reflect your logged data back to you.") }
    ) {
      ForEach(Array(domains.enumerated()), id: \.element.id) { idx, domain in
        let pills = coachPills[domain] ?? []
        NavigationLink(value: domain) {
          CoachLandingRow(domain: domain, pills: pills)
        }
        .badge(pills.reduce(0) { $0 + $1.count })
        .septenaCoachRow(index: idx, count: domains.count)
      }
    }
  }

  @ViewBuilder
  private var exercisesSection: some View {
    groupedListSection(
      header: { sectionGroupHeader("Exercises") },
      footer: { Text("Guided reflections that turn into goals.") }
    ) {
      if OnDeviceAI.isAvailable {
        let exercises = DiscoveryRegistry.all
        ForEach(Array(exercises.enumerated()), id: \.element.id) { idx, exercise in
          Button {
            activeExercise = AnyDiscoveryMiniApp(descriptor: exercise)
            Haptics.tick()
          } label: {
            CoachLabelRow(systemImage: exercise.systemImage,
                          title: exercise.title,
                          subtitle: exercise.blurb,
                          accent: exercise.accent)
          }
          .buttonStyle(.plain)
          .septenaCoachRow(index: idx, count: exercises.count)
        }
      } else {
        CoachUnavailableRow()
          .septenaCoachRow(index: 0, count: 1)
      }
    }
  }

  @ViewBuilder
  private var goalsSection: some View {
    groupedListSection(
      header: {
        ListSectionHeaderTitle(title: "Goals",
                               onAdd: addGoal,
                               addAccessibilityLabel: "Add goal",
                               accent: theme.color(for: "goals"),
                               keyboardShortcut: "n")
      },
      footer: { Text("Free-text intentions; tag them so a coach picks them up.") }
    ) {
      if goals.isEmpty {
        Text("No goals yet. Tag a goal with sections so your coaches have context for what you're working toward.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .septenaCoachRow(index: 0, count: 1)
      } else {
        ForEach(Array(goals.enumerated()), id: \.element.id) { idx, goal in
          Button { editing = goal } label: {
            GoalListRow(goal: goal, theme: theme)
          }
          .buttonStyle(.plain)
          .contextMenu {
            Button(role: .destructive) { deleteGoal(goal) } label: {
              Label("Delete", systemImage: "trash")
            }
          }
          .septenaCoachRow(index: idx, count: goals.count)
        }
      }
    }
  }

  // MARK: - Data

  private func refresh() {
    goals = LocalCache.goals(in: context)
    availableSections = SettingsMirror.loadSections(context: context)
      .filter { $0.key != "goals" }
    var next: [CoachDomain: [CoachAreaPill]] = [:]
    for domain in CoachDomain.allCases {
      let pills = CoachContextBuilder.availability(for: domain, window: .default,
                                                   context: context, now: clock.now)
      guard !pills.isEmpty else { continue }
      next[domain] = pills.map {
        CoachAreaPill(id: $0.id, label: $0.label, systemImage: $0.systemImage,
                      count: $0.count, accent: theme.color(for: $0.id))
      }
    }
    coachPills = next
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

// MARK: - Row chrome

private extension View {
  /// Cell treatment for a Coach row — mirrors `septenaNextRow` without selection.
  func septenaCoachRow(index: Int, count: Int) -> some View {
    #if os(macOS)
    septenaHomeListRow(index: index, count: count)
    #else
    environment(\.rowHInset, Theme.Spacing.xl)
      .pointerListRow()
    #endif
  }
}

// MARK: - Rows

/// Accent-washed icon chip — shared leading glyph for every row on this page.
private struct CoachIconChip: View {
  let systemImage: String
  let accent: Color

  var body: some View {
    Image(systemName: systemImage)
      .font(.callout.weight(.semibold))
      .foregroundStyle(accent)
      .frame(width: 28, height: 28)
      .background(accent.opacity(0.14),
                  in: RoundedRectangle(cornerRadius: 7, style: .continuous))
  }
}

/// Shared row anatomy: chip · title/subtitle · optional trailing. Matches the
/// Next list's `HStack` + `rowHInset` pattern (not `Label`, which sizes icons
/// inconsistently on macOS).
private struct CoachRowLayout<Trailing: View>: View {
  let systemImage: String
  let accent: Color
  let title: String
  var subtitle: String? = nil
  var subtitleLineLimit: Int = 1
  var titleSecondary: Bool = false
  @ViewBuilder var trailing: () -> Trailing

  @Environment(\.rowHInset) private var rowHInset
  @Environment(\.rowVInset) private var rowVInset

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.iconTextGap) {
      CoachIconChip(systemImage: systemImage, accent: accent)
        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }

      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.septenaTaskTitle)
          .foregroundStyle(titleSecondary ? Theme.inkSecondary : Theme.inkPrimary)
          .lineLimit(2)
        if let subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(.septenaMeta)
            .foregroundStyle(Theme.inkSecondary)
            .lineLimit(subtitleLineLimit)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      trailing()
    }
    .padding(.horizontal, rowHInset)
    .padding(.vertical, rowVInset)
    .contentShape(Rectangle())
  }
}

private struct CoachLandingRow: View {
  let domain: CoachDomain
  let pills: [CoachAreaPill]

  private var summary: String {
    pills.prefix(3).map { "\($0.label) \($0.count)" }.joined(separator: " · ")
  }

  var body: some View {
    CoachRowLayout(
      systemImage: domain.systemImage,
      accent: domain.accent,
      title: domain.title,
      subtitle: pills.isEmpty ? domain.blurb : summary
    ) {
      EmptyView()
    }
  }
}

private struct CoachLabelRow: View {
  let systemImage: String
  let title: String
  let subtitle: String
  let accent: Color

  var body: some View {
    CoachRowLayout(
      systemImage: systemImage,
      accent: accent,
      title: title,
      subtitle: subtitle,
      subtitleLineLimit: 2
    ) {
      EmptyView()
    }
  }
}

/// Stand-in when Apple Intelligence isn't available — same row shape as the
/// exercise rows (not a nested card that fights `taskCardChrome`).
private struct CoachUnavailableRow: View {
  private var detail: String {
    OnDeviceAI.unavailableReason ?? "On-device intelligence is unavailable right now."
  }

  private var subtitle: String {
    switch OnDeviceAI.status {
    case .notEnabled, .modelNotReady, .unknown:
      return "\(detail) Details in Settings ▸ AI."
    case .deviceNotEligible, .available:
      return detail
    }
  }

  var body: some View {
    CoachRowLayout(
      systemImage: "apple.intelligence",
      accent: .secondary,
      title: "Needs Apple Intelligence",
      subtitle: subtitle,
      subtitleLineLimit: 3
    ) {
      EmptyView()
    }
  }
}

private struct GoalListRow: View {
  @Environment(\.modelContext) private var context
  @Environment(DayClock.self) private var clock
  @Environment(\.rowHInset) private var rowHInset
  @Environment(\.rowVInset) private var rowVInset
  let goal: Goal
  let theme: SectionTheme

  private var isPlaceholder: Bool { goal.text == "New goal" }

  private var title: String {
    goal.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
      .first.map(String.init) ?? goal.text
  }

  private var accent: Color {
    goal.sections.first.map { theme.color(for: $0) } ?? .secondary
  }

  private var icon: String {
    goal.sections.first.map { theme.icon(for: $0) } ?? "target"
  }

  private var sectionSummary: String {
    goal.sections.map { $0.capitalized }.joined(separator: " · ")
  }

  private var progress: GoalMetricProgress? {
    GoalMetricEvaluator.evaluate(goal: goal, context: context, now: clock.now)
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.iconTextGap) {
      CoachIconChip(systemImage: icon, accent: accent)
        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }

      VStack(alignment: .leading, spacing: 4) {
        Text(isPlaceholder ? "New goal" : title)
          .font(.septenaTaskTitle)
          .foregroundStyle(isPlaceholder ? Theme.inkSecondary : Theme.inkPrimary)
          .lineLimit(2)
        if let progress {
          GoalMetricProgressView(progress: progress, accent: accent)
        }
        if !goal.sections.isEmpty {
          Text(sectionSummary)
            .font(.septenaMeta)
            .foregroundStyle(Theme.inkSecondary)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, rowHInset)
    .padding(.vertical, rowVInset)
    .contentShape(Rectangle())
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
