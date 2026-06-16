import SwiftUI
import SwiftData

// The final first-run step: "Set your starting targets". Aggregates the
// suggested goals for the sections the user just picked (see
// `SuggestedGoal.all`), grouped by section. A small universal set starts
// pre-checked (`recommended`); the rest are opt-in. Targets are editable inline
// before seeding. Finishing seeds the checked goals as real, metric-bound Goals
// (dedup-guarded) so they show progress immediately in the Goals tab, the
// section strips, and — where applicable — the watch ring.
//
// Skipping seeds nothing: a new user can always add goals later from any
// section's goals strip. This step never blocks onboarding from completing.

struct OnboardingTargetsView: View {
  let suggestions: [SuggestedGoal]
  let onComplete: () -> Void

  @Environment(SectionTheme.self) private var theme
  @Environment(\.modelContext) private var modelContext

  @State private var selected: Set<String>
  /// Per-metric edited bounds, seeded from each suggestion's defaults.
  @State private var bounds: [String: Bounds]

  private struct Bounds: Hashable { var target: Double; var upper: Double? }

  init(suggestions: [SuggestedGoal], onComplete: @escaping () -> Void) {
    self.suggestions = suggestions
    self.onComplete = onComplete
    _selected = State(initialValue: Set(suggestions.filter(\.recommended).map(\.id)))
    _bounds = State(initialValue: Dictionary(uniqueKeysWithValues:
      suggestions.map { ($0.id, Bounds(target: $0.target, upper: $0.upper)) }))
  }

  /// Section keys in the order suggestions arrived (registry order).
  private var sectionOrder: [String] {
    var seen = Set<String>(); var out: [String] = []
    for s in suggestions where !seen.contains(s.sectionKey) { seen.insert(s.sectionKey); out.append(s.sectionKey) }
    return out
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          hero.listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        }
        ForEach(sectionOrder, id: \.self) { key in
          sectionGroup(key)
        }
      }
      .formStyle(.grouped)
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .navigationTitle("Starting targets")
      .safeAreaInset(edge: .bottom) { bottomBar }
    }
  }

  private var hero: some View {
    VStack(spacing: 10) {
      Image(systemName: "target")
        .font(.system(size: 34))
        .foregroundStyle(Color.accentColor)
        .accessibilityHidden(true)
      Text("Set a few starting targets")
        .font(.title3.weight(.semibold))
        .multilineTextAlignment(.center)
      Text("Goals turn what you track into progress. We've pre-picked a couple of common ones — adjust, add, or skip. You can change any of these anytime.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 4)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
  }

  @ViewBuilder
  private func sectionGroup(_ key: String) -> some View {
    let items = suggestions.filter { $0.sectionKey == key }
    let label = SectionManifest.byKey[key]?.defaultLabel ?? key.capitalized
    Section {
      ForEach(items) { s in row(s) }
    } header: {
      Text(label)
    }
  }

  private func row(_ s: SuggestedGoal) -> some View {
    let isOn = selected.contains(s.id)
    let accent = theme.color(for: s.sectionKey)
    return VStack(alignment: .leading, spacing: isOn ? 8 : 0) {
      Toggle(isOn: Binding(
        get: { selected.contains(s.id) },
        set: { on in if on { selected.insert(s.id) } else { selected.remove(s.id) } }
      )) {
        Text(s.text)
          .font(.subheadline.weight(.medium))
          .foregroundStyle(isOn ? .primary : .secondary)
      }
      .tint(accent)

      if isOn { editor(s) }
    }
    .padding(.vertical, 2)
  }

  /// Inline target editor — one field for a single bound, two for a range.
  @ViewBuilder
  private func editor(_ s: SuggestedGoal) -> some View {
    HStack(spacing: 8) {
      if s.comparator == "range" {
        Text("Between").font(.caption).foregroundStyle(.secondary)
        numberField(s, \.target)
        Text("and").font(.caption).foregroundStyle(.secondary)
        numberField(s, \.upper)
      } else {
        Text(comparatorWord(s.comparator)).font(.caption).foregroundStyle(.secondary)
        numberField(s, \.target)
      }
      Text(s.unitLabel).font(.caption).foregroundStyle(.secondary)
      Spacer()
    }
  }

  private func comparatorWord(_ c: String) -> String {
    switch c { case "lte": return "At most"; case "eq": return "Exactly"; default: return "At least" }
  }

  private func numberField(_ s: SuggestedGoal, _ path: WritableKeyPath<Bounds, Double?>) -> some View {
    numberFieldBinding(Binding(
      get: { bounds[s.id]?[keyPath: path] ?? 0 },
      set: { var b = bounds[s.id] ?? Bounds(target: s.target, upper: s.upper); b[keyPath: path] = $0; bounds[s.id] = b }
    ))
  }
  private func numberField(_ s: SuggestedGoal, _ path: WritableKeyPath<Bounds, Double>) -> some View {
    numberFieldBinding(Binding(
      get: { bounds[s.id]?[keyPath: path] ?? s.target },
      set: { var b = bounds[s.id] ?? Bounds(target: s.target, upper: s.upper); b[keyPath: path] = $0; bounds[s.id] = b }
    ))
  }

  private func numberFieldBinding(_ value: Binding<Double>) -> some View {
    TextField("", value: value, format: .number.precision(.fractionLength(0)))
      .frame(width: 56)
      .multilineTextAlignment(.center)
      .font(.subheadline.monospacedDigit())
      .textFieldStyle(.roundedBorder)
      #if os(iOS)
      .keyboardType(.numberPad)
      #endif
  }

  private var bottomBar: some View {
    VStack(spacing: 6) {
      Button(action: finish) {
        Text(selected.isEmpty ? "Skip for now" : "Set \(selected.count) target\(selected.count == 1 ? "" : "s")")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
    }
    .padding()
    .background(.bar)
  }

  private func finish() {
    let mutator = SeptenaServices.shared.goalMutator
    var existingKeys = Set(LocalCache.goals(in: modelContext).compactMap(\.metricKey))
    for s in suggestions where selected.contains(s.id) {
      let b = bounds[s.id]
      s.with(target: b?.target ?? s.target, upper: b?.upper ?? s.upper)
        .seedIfAbsent(existingKeys: existingKeys, mutator: mutator)
      existingKeys.insert(s.metricKey)
    }
    onComplete()
  }
}
