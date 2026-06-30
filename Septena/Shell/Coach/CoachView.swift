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
// Was a three-band grid of bordered tiles; now a system List so the landing
// reads the same as the grouped drawers it pushes into. The internal section
// key stays "goals" — only the surface and label became "Coach". Coaches push
// within this NavigationStack (lists pair with a stack); exercises and goals
// present modally.

struct CoachView: View {
  @Environment(\.modelContext) private var context
  @Environment(SectionTheme.self) private var theme

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
      #elseif os(macOS)
      .listStyle(.plain)
      .padding(.bottom, Theme.pageBottom)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      #endif
      .septenaTabPage(id: "coach", title: "Coach", add: .action { addGoal() })
      // A coach pushes as a full pane inside this stack — a real screen with a
      // back button — on every idiom. Lists belong with navigation stacks.
      .navigationDestination(for: CoachDomain.self) { domain in
        CoachDetailView(domain: domain)
      }
      .task { refresh() }
      .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { note in
        // refresh() walks every coach domain's availability (unbounded
        // per-section fetches), so only re-run when a section a coach actually
        // reads — or a goal — changed. A scoped post for an unrelated section
        // (e.g. groceries) no longer rebuilds the hub.
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
    return Section {
      ForEach(Array(domains.enumerated()), id: \.element.id) { idx, domain in
        let pills = coachPills[domain] ?? []
        NavigationLink(value: domain) {
          CoachLandingRow(domain: domain, pills: pills)
        }
        // 0 hides the badge, so this doubles as "entries in the window".
        .badge(pills.reduce(0) { $0 + $1.count })
        #if os(macOS)
        .septenaHomeListRow(index: idx, count: domains.count)
        #else
        .pointerListRow()
        #endif
      }
    } header: {
      Text("Coaches")
    } footer: {
      Text("On-device coaches that reflect your logged data back to you.")
    }
  }

  // Section stays visible without Apple Intelligence — a placeholder explains
  // why the exercises aren't offered instead of the rows silently vanishing.
  @ViewBuilder
  private var exercisesSection: some View {
    Section {
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
          #if os(macOS)
          .septenaHomeListRow(index: idx, count: exercises.count)
          #else
          .pointerListRow()
          #endif
        }
      } else {
        AppleIntelligenceUnavailableCard()
          #if os(iOS)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
          #else
          .septenaHomeListRow(index: 0, count: 1)
          #endif
      }
    } header: {
      Text("Exercises")
    } footer: {
      Text("Guided reflections that turn into goals.")
    }
  }

  @ViewBuilder
  private var goalsSection: some View {
    Section {
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
        #if os(macOS)
        .septenaHomeListRow(index: idx, count: max(goals.count, 1))
        #else
        .pointerListRow()
        #endif
      }
      if goals.isEmpty {
        Text("No goals yet. Tag a goal with sections so your coaches have context for what you're working toward.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          #if os(macOS)
          .septenaHomeListRow(index: 0, count: 1)
          #else
          .pointerListRow()
          #endif
      }
    } header: {
      HStack {
        Text("Goals")
        Spacer()
        Button(action: addGoal) {
          Label("Add", systemImage: "plus")
            .font(.subheadline.weight(.medium))
            .textCase(nil)
        }
        .buttonStyle(.plain)
        .tint(theme.color(for: "goals"))
        .keyboardShortcut("n", modifiers: .command)
      }
    } footer: {
      Text("Free-text intentions; tag them so a coach picks them up.")
    }
  }

  // MARK: - Data

  private func refresh() {
    goals = LocalCache.goals(in: context)
    availableSections = SettingsMirror.loadSections(context: context)
      .filter { $0.key != "goals" }
    var next: [CoachDomain: [CoachAreaPill]] = [:]
    for domain in CoachDomain.allCases {
      let pills = CoachContextBuilder.availability(for: domain, window: .default, context: context)
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

// MARK: - Rows

/// The accent-washed icon chip every row on this page uses — coaches,
/// exercises, and goals — so background size and glyph size stay identical
/// across the three. The small counterpart to the old CoachTile's 38pt chip,
/// sized for a list row.
private struct CoachIconChip: View {
  let systemImage: String
  let accent: Color

  var body: some View {
    Image(systemName: systemImage)
      .font(.callout.weight(.semibold))
      .foregroundStyle(accent)
      .frame(width: 29, height: 29)
      .background(accent.opacity(0.14),
                  in: RoundedRectangle(cornerRadius: 7, style: .continuous))
  }
}

/// A coach row: icon chip + title over either its weekly area breakdown (when
/// there's data) or its blurb (when there isn't). The trailing entry count is
/// the NavigationLink's `.badge`.
private struct CoachLandingRow: View {
  let domain: CoachDomain
  let pills: [CoachAreaPill]

  /// "Training 5 · Activity 3" — capped so a wide coach (food, whole-life)
  /// keeps to one line.
  private var summary: String {
    pills.prefix(3).map { "\($0.label) \($0.count)" }.joined(separator: " · ")
  }

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(domain.title)
        Text(pills.isEmpty ? domain.blurb : summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    } icon: {
      CoachIconChip(systemImage: domain.systemImage, accent: domain.accent)
    }
  }
}

/// A plain icon-chip row (no chevron — it presents a modal, not a push). Used
/// for the exercises.
private struct CoachLabelRow: View {
  let systemImage: String
  let title: String
  let subtitle: String
  let accent: Color

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).foregroundStyle(.primary)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    } icon: {
      CoachIconChip(systemImage: systemImage, accent: accent)
    }
  }
}

/// A goal row: a target glyph in the goal's section accent, its title, any
/// metric progress, and the sections it's tagged with. The list supplies the
/// card; the row carries no border of its own (unlike the old GoalTile).
private struct GoalListRow: View {
  @Environment(\.modelContext) private var context
  let goal: Goal
  let theme: SectionTheme

  private var isPlaceholder: Bool { goal.text == "New goal" }

  /// First line is the title; the rest is the goal's description body.
  private var title: String {
    goal.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
      .first.map(String.init) ?? goal.text
  }

  private var accent: Color {
    goal.sections.first.map { theme.color(for: $0) } ?? .secondary
  }

  /// The primary (first) section's glyph, so a goal reads as what it's about;
  /// untagged goals fall back to the generic target.
  private var icon: String {
    goal.sections.first.map { theme.icon(for: $0) } ?? "target"
  }

  private var sectionSummary: String {
    goal.sections.map { $0.capitalized }.joined(separator: " · ")
  }

  private var progress: GoalMetricProgress? {
    GoalMetricEvaluator.evaluate(goal: goal, context: context)
  }

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 4) {
        Text(isPlaceholder ? "New goal" : title)
          .foregroundStyle(isPlaceholder ? .secondary : .primary)
          .lineLimit(2)
        if let progress {
          GoalMetricProgressView(progress: progress, accent: accent)
        }
        if !goal.sections.isEmpty {
          Text(sectionSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    } icon: {
      CoachIconChip(systemImage: icon, accent: accent)
    }
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
