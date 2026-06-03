import SwiftUI
import SwiftData

// SectionGoalsStrip — a read-only strip of the user's goals tagged with
// the host section, surfaced at the top of every section drawer so the
// daily logging UI reads as "this is what you're working toward; here's
// today's data against it." Source of truth stays in the Goals tab —
// tapping a row opens the same EditGoalSheet used there.
//
// Renders nothing when the section has no tagged goals (no empty state).
// Designed to be the first child of a List — rows match the width and
// inset of the surrounding section rows (no inner card chrome, no extra
// horizontal margin), so it reads as part of the page rather than a
// nested mini-card. @Query paints synchronously on first render so the
// goals appear with the rest of the list, not after a delayed .task hop.

struct SectionGoalsStrip: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(\.modelContext) private var context

  let sectionKey: String

  @Query(sort: [
    SortDescriptor(\GoalEntity.sortIndex, order: .reverse),
    SortDescriptor(\GoalEntity.updatedAt, order: .reverse),
  ]) private var allGoals: [GoalEntity]

  @State private var editing: Goal? = nil
  @State private var availableSections: [SectionConfig] = []

  private var mutator: GoalMutator { SeptenaServices.shared.goalMutator }

  private var goals: [Goal] {
    allGoals
      .filter { SectionGoalsStrip.matches($0, sectionKey: sectionKey) }
      .map(Goal.init)
  }

  /// Shared membership test for "does this goal belong to `sectionKey`":
  /// an explicit section tag, OR a measurement whose metric's home section
  /// is this one (the metric implies a section so the user needn't
  /// double-tag). Kept static so the drawer's goals toolbar toggle can gate
  /// its visibility on the exact same rule the strip renders by.
  static func matches(_ entity: GoalEntity, sectionKey: String) -> Bool {
    if entity.sections.contains(sectionKey) { return true }
    if let key = entity.metricKey,
       GoalMetricCatalog.sectionKey(for: key) == sectionKey {
      return true
    }
    return false
  }

  var body: some View {
    Group {
      if !goals.isEmpty {
        VStack(spacing: 8) {
          ForEach(goals) { goal in
            Button { openEdit(goal) } label: {
              SectionGoalRow(goal: goal, theme: theme)
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
    .sheet(item: $editing) { goal in
      EditGoalSheet(
        goal: goal,
        availableSections: availableSections,
        theme: theme,
        mutator: mutator,
        onUpdate: { _ in },
        onDelete: { _ in }
      )
    }
  }

  private func openEdit(_ goal: Goal) {
    // Defer the SettingsMirror fetch until the sheet actually opens —
    // the strip itself doesn't need the section catalog to render.
    if availableSections.isEmpty {
      availableSections = SettingsMirror.loadSections(context: context)
        .filter { $0.key != "goals" }
    }
    editing = goal
  }
}

// MARK: - Toolbar toggle

/// The `target` toolbar affordance that reveals/hides `SectionGoalsStrip`.
/// Lives next to the drawer's "+" button (just to its left). Renders
/// nothing when the host section has no tagged goals, so a section without
/// goals shows no button at all — matching the strip's own empty behavior.
/// Runs its own lightweight `@Query` so the host `SectionDrawer` stays
/// SwiftData-agnostic and the visibility stays reactive to goal edits.
struct SectionGoalsToggleButton: View {
  let sectionKey: String
  @Binding var isExpanded: Bool
  let accent: Color

  @Query private var allGoals: [GoalEntity]

  private var hasGoals: Bool {
    allGoals.contains { SectionGoalsStrip.matches($0, sectionKey: sectionKey) }
  }

  var body: some View {
    if hasGoals {
      Button {
        withAnimation(.snappy) { isExpanded.toggle() }
      } label: {
        Image(systemName: "target")
      }
      .tint(accent)
      .accessibilityLabel(isExpanded ? "Hide goals" : "Show goals")
    }
  }
}

// MARK: - Row

/// Outlined card used inside the strip. The host List row chrome is
/// suppressed (`listRowBackground(.clear)` + hidden separator), so this
/// view draws the entire visual — accent-colored stroke around the
/// secondary grouped background — and lines up edge-to-edge with the
/// neighbouring section cards.
private struct SectionGoalRow: View {
  @Environment(\.modelContext) private var context
  let goal: Goal
  let theme: SectionTheme

  private var accent: Color {
    goal.sections.first.map { theme.color(for: $0) } ?? .secondary
  }

  private var isPlaceholder: Bool { goal.text == "New goal" }

  private var progress: GoalMetricProgress? {
    GoalMetricEvaluator.evaluate(goal: goal, context: context)
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
        pills
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
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

  private var pills: some View {
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
