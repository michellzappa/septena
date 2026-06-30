import SwiftUI
import SwiftData

// A single coach's hub. Four bands inside the standard section drawer:
//
//   • Conversation — opens the on-device chat (CoachChatView) full-screen,
//     so the scroll-greedy transcript never fights the drawer's ScrollView.
//   • Goals — the user's goals scoped to this coach's section(s), tappable
//     into the same EditGoalSheet the Goals surface uses.
//   • Exercises — the guided Discovery mini-apps mapped to this coach.
//   • Context — the sections (and entry counts) the coach can see in its window;
//     for the custom coach these pills also pick its scope.
//
// Hosted under the "goals" section key (unchanged) so it inherits the goals
// theme/accent and Settings deep-link.

struct CoachDetailView: View {
  let domain: CoachDomain

  @Environment(\.modelContext) private var context
  @Environment(SectionTheme.self) private var theme
  @Environment(DayClock.self) private var clock

  private var goalMutator: GoalMutator { SeptenaServices.shared.goalMutator }

  @Query(sort: [
    SortDescriptor(\GoalEntity.sortIndex, order: .reverse),
    SortDescriptor(\GoalEntity.updatedAt, order: .reverse),
  ]) private var allGoals: [GoalEntity]

  @State private var availableSections: [SectionConfig] = []
  @State private var editing: Goal? = nil
  @State private var showingChat = false
  @State private var showingVoice = false
  @State private var voice: CoachVoice? = nil
  @State private var pills: [CoachDataPill] = []
  /// Custom coach only: the sections the user tapped to scope it (ephemeral
  /// in Step 1 — persisted alongside the transcript in Step 2).
  @State private var customScope: Set<String> = []

  /// Sections this coach scopes goals to. `nil` means "all goals" (the
  /// whole-life coach); an empty set means "user hasn't scoped yet" (custom).
  private var goalScope: Set<String>? {
    if domain.handPicksContext { return customScope }
    if let keys = domain.sectionKeys { return Set(keys) }
    return nil   // wholeLife → every goal
  }

  /// Sections whose changes should rebuild this coach: the keys it reads
  /// (all of `supportedKeys` for the whole-life coach), plus goals.
  private var refreshScope: Set<String> {
    Set(domain.sectionKeys ?? CoachContextBuilder.supportedKeys).union(["goals"])
  }

  private var scopedGoals: [Goal] {
    allGoals
      .filter { entity in
        guard let scope = goalScope else { return true }   // wholeLife: all
        return SectionGoalsStrip.matches(entity, in: scope)
      }
      .map(Goal.init)
  }

  var body: some View {
    SectionDrawer(sectionKey: "goals",
                  title: domain.title,
                  accent: domain.accent) {
      conversationSection
      goalsSection
      contextSection
    }
    .task { refresh() }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { note in
      // refresh() rebuilds this coach's availability via per-section fetches;
      // only re-run when one of the sections it reads (or goals) changed.
      guard note.affectsAnySection(of: refreshScope) else { return }
      refresh()
    }
    .adaptiveDetail(item: $editing) { goal in
      EditGoalSheet(
        goal: goal,
        availableSections: availableSections,
        theme: theme,
        mutator: goalMutator,
        onUpdate: { _ in },   // @Query repaints from the store
        onDelete: { _ in }
      )
    }
    .coachChatPresentation(isPresented: $showingChat, domain: domain) { drafts in
      if !drafts.isEmpty { GoalDrafts.save(drafts, mutator: goalMutator) }
      showingChat = false
    }
    .adaptiveDetail(isPresented: $showingVoice,
                    onDismiss: { voice = CoachVoiceStore.load(domain) }) {
      CoachVoiceEditor(domain: domain)
    }
  }

  // MARK: - Conversation

  private var conversationSection: some View {
    DrawerSection {
      VStack(spacing: 0) {
        Button {
          showingChat = true
          Haptics.tick()
        } label: {
          coachRow(icon: "bubble.left.and.text.bubble.right.fill",
                   title: "Talk to your \(shortName) coach",
                   subtitle: domain.blurb)
        }
        .buttonStyle(.plain)

        Divider().padding(.vertical, 4)

        Button {
          showingVoice = true
          Haptics.tick()
        } label: {
          coachRow(icon: "waveform",
                   title: "Voice & tone",
                   subtitle: (voice ?? CoachVoiceStore.load(domain)).summary)
        }
        .buttonStyle(.plain)
      }
    }
  }

  /// The coach's name without the trailing " Coach" — for inline copy.
  private var shortName: String {
    domain.title.replacingOccurrences(of: " Coach", with: "").lowercased()
  }

  private func coachRow(icon: String, title: String, subtitle: String) -> some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.title3)
        .foregroundStyle(domain.accent)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.body.weight(.medium))
          .foregroundStyle(.primary)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.leading)
      }
      Spacer(minLength: 0)
      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tertiary)
    }
    .contentShape(Rectangle())
  }

  // MARK: - Goals

  @ViewBuilder
  private var goalsSection: some View {
    DrawerSection("Goals") {
      if domain.handPicksContext && customScope.isEmpty {
        captionRow("Pick areas in the section below to scope this coach, then add goals here.")
      } else if scopedGoals.isEmpty {
        captionRow("No goals here yet. Tag a goal with this coach's sections and it shows up.")
      } else {
        VStack(spacing: 8) {
          ForEach(scopedGoals) { goal in
            Button { openEdit(goal) } label: {
              CoachGoalRow(goal: goal, theme: theme)
            }
            .buttonStyle(.plain)
          }
        }
      }
      Button(action: addGoal) {
        Label("Add goal", systemImage: "plus")
          .font(.subheadline.weight(.medium))
          .foregroundStyle(domain.accent)
      }
      .buttonStyle(.plain)
      .padding(.top, 2)
      .disabled(domain.handPicksContext && customScope.isEmpty)
    }
  }

  // MARK: - Context

  private var contextSection: some View {
    DrawerSection("What I can see · last \(CoachWindow.default.label)") {
      if pills.isEmpty {
        captionRow(domain.handPicksContext
                   ? "Nothing logged in the sections this coach can reach in the last \(CoachWindow.default.label)."
                   : "Nothing logged in this coach's areas in the last \(CoachWindow.default.label).")
      } else {
        let columns = [GridItem(.adaptive(minimum: 110), spacing: 8, alignment: .leading)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
          ForEach(pills) { pill in
            contextPill(pill)
          }
        }
        if domain.handPicksContext {
          captionRow("Tap a section to scope this coach.")
        }
      }
    }
  }

  @ViewBuilder
  private func contextPill(_ pill: CoachDataPill) -> some View {
    let inScope = !domain.handPicksContext || customScope.contains(pill.id)
    let tint = inScope ? domain.accent : Color.secondary
    let content = HStack(spacing: 5) {
      Image(systemName: pill.systemImage).font(.caption2)
      Text(pill.label).font(.caption.weight(.medium))
      Text("\(pill.count)")
        .font(.caption2.weight(.semibold).monospacedDigit())
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(tint.opacity(0.22), in: Capsule())
    }
    .foregroundStyle(tint)
    .padding(.horizontal, 10).padding(.vertical, 6)
    .background(tint.opacity(0.12), in: Capsule())
    .opacity(inScope ? 1 : 0.6)

    if domain.handPicksContext {
      Button { toggleScope(pill.id) } label: { content }
        .buttonStyle(.plain)
    } else {
      content
    }
  }

  private func captionRow(_ text: String) -> some View {
    Text(text)
      .font(.footnote)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Actions

  private func refresh() {
    availableSections = SettingsMirror.loadSections(context: context)
      .filter { $0.key != "goals" }
    pills = CoachContextBuilder.availability(for: domain, window: .default,
                                             context: context, now: clock.now)
    voice = CoachVoiceStore.load(domain)
  }

  private func toggleScope(_ key: String) {
    if customScope.contains(key) { customScope.remove(key) } else { customScope.insert(key) }
    Haptics.tick()
  }

  private func openEdit(_ goal: Goal) {
    editing = goal
  }

  private func addGoal() {
    let goal = goalMutator.createGoal(text: "New goal")
    // Seed the new goal into this coach's scope so it lands here: the coach's
    // first section (custom → first picked section), else untagged (wholeLife).
    let seed: [String]
    if domain.handPicksContext {
      seed = customScope.sorted().first.map { [$0] } ?? []
    } else {
      seed = domain.sectionKeys?.first.map { [$0] } ?? []
    }
    if !seed.isEmpty {
      goalMutator.updateGoal(id: goal.id, text: goal.text, sections: seed)
    }
    var seeded = goal
    seeded.sections = seed
    editing = seeded
    Haptics.tick()
  }
}

// MARK: - Goal row (coach hub)

/// Outlined goal card for the coach hub. Mirrors the Goals-strip row but
/// kept local so the two surfaces can diverge without coupling.
private struct CoachGoalRow: View {
  @Environment(\.modelContext) private var context
  @Environment(DayClock.self) private var clock
  let goal: Goal
  let theme: SectionTheme

  private var accent: Color {
    goal.sections.first.map { theme.color(for: $0) } ?? .secondary
  }

  private var isPlaceholder: Bool { goal.text == "New goal" }

  private var progress: GoalMetricProgress? {
    GoalMetricEvaluator.evaluate(goal: goal, context: context, now: clock.now)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(isPlaceholder ? "New goal" : goal.text)
        .font(.septenaCardTitle)
        .foregroundStyle(isPlaceholder ? .secondary : .primary)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
      if let progress {
        GoalMetricProgressView(progress: progress, accent: accent)
      }
      if !goal.sections.isEmpty {
        let columns = [GridItem(.adaptive(minimum: 70), spacing: 6, alignment: .leading)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
          ForEach(goal.sections, id: \.self) { key in
            let color = theme.color(for: key)
            Text(key.capitalized)
              .font(.caption2.weight(.medium))
              .lineLimit(1)
              .padding(.horizontal, 8).padding(.vertical, 3)
              .background(color.opacity(0.15))
              .foregroundStyle(color)
              .clipShape(Capsule())
          }
        }
      }
    }
    .padding(.horizontal, 14).padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        .fill(Theme.secondaryGroupedBackground)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        .strokeBorder(accent, lineWidth: 1.5)
    )
    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    .contentShape(Rectangle())
  }
}

// MARK: - Presentation helpers

private extension View {
  /// The coach chat, full-screen on iOS / sheet on macOS, wrapped in its own
  /// NavigationStack (CoachChatView relies on one for its title + toolbar)
  /// with a Done affordance. Mirrors the Discovery presentation idiom.
  @ViewBuilder
  func coachChatPresentation(isPresented: Binding<Bool>,
                             domain: CoachDomain,
                             onFinish: @escaping ([DraftGoal]) -> Void) -> some View {
    #if os(macOS)
    sheet(isPresented: isPresented) {
      CoachChatHost(domain: domain, onFinish: onFinish)
        .frame(width: 560, height: 640)
    }
    #else
    fullScreenCover(isPresented: isPresented) {
      CoachChatHost(domain: domain, onFinish: onFinish)
    }
    #endif
  }

}

/// NavigationStack wrapper that gives CoachChatView a home and a Done button
/// when presented modally from the hub.
private struct CoachChatHost: View {
  let domain: CoachDomain
  let onFinish: ([DraftGoal]) -> Void

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      CoachChatView(domain: domain, onFinish: onFinish)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
          }
        }
    }
  }
}
