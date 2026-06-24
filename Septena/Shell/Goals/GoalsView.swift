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
  @Environment(SectionTheme.self) private var theme
  @Environment(\.modelContext) private var context
  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var hSize
  #endif

  private var goalMutator: GoalMutator { SeptenaServices.shared.goalMutator }

  @State private var goals: [Goal] = []
  @State private var availableSections: [SectionConfig] = []
  @State private var loading = true
  @State private var editing: Goal? = nil
  @State private var activeMiniApp: AnyDiscoveryMiniApp? = nil

  // Keyboard navigation (iPad/Mac). The grid auto-focuses on appear — the
  // Goals tab is single-pane, so there's no detail view to fight over focus
  // (unlike the Tasks split view). Arrow keys move a highlighted selection
  // (linear, so it's column-count-agnostic), Return / Space opens the editor.
  // Works with macOS "Full Keyboard Access" OFF because focus is grabbed
  // programmatically, the same way QuickFind / the task list already do it.
  @State private var kbSelection: Int? = nil
  @FocusState private var gridFocused: Bool

  private func moveSelection(_ delta: Int) -> KeyPress.Result {
    guard !goals.isEmpty else { return .ignored }
    let current = kbSelection ?? 0
    kbSelection = min(max(0, current + delta), goals.count - 1)
    return .handled
  }

  private func activateSelection() -> KeyPress.Result {
    guard let s = kbSelection, goals.indices.contains(s) else { return .ignored }
    editing = goals[s]
    return .handled
  }

  /// Mirrors WeekDashboardView's grid: iPhone compact = 1 col, iPad regular
  /// = 3 cols, macOS = adaptive ~280pt tiles. (Shared with the Coach grid.)
  private var columns: [GridItem] {
    #if os(iOS)
    return GoalGrid.columns(regularWidth: hSize == .regular)
    #else
    return GoalGrid.columns(regularWidth: true)
    #endif
  }

  var body: some View {
    NavigationStack {
      SectionDrawer(sectionKey: "goals",
                    quickAdd: DrawerQuickAdd("New goal") { addGoal() }) {
        content
      }
      .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { note in
          if note.affectsSection("goals") { goals = LocalCache.goals(in: context) }
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
        .discoveryPresentation(activeMiniApp: $activeMiniApp) { drafts in
          if !drafts.isEmpty {
            saveDrafts(drafts)
          }
          activeMiniApp = nil
          Task { await load() }
        }
    }
  }

  @ViewBuilder
  private var content: some View {
    if loading && goals.isEmpty {
      ProgressView()
        .frame(maxWidth: .infinity, minHeight: 160)
    } else {
      VStack(alignment: .leading, spacing: 18) {
        if OnDeviceAI.isAvailable {
          DiscoveryShelf { app in
            activeMiniApp = app
            Haptics.tick()
          }
        } else {
          AppleIntelligenceUnavailableCard()
        }

        if goals.isEmpty {
          ContentUnavailableView {
            Label("No Goals Yet", systemImage: "target")
          } description: {
            Text("Free-text intentions. Tag with sections so agents have context for what you're working toward.")
          } actions: {
            Button("Add First Goal", action: addGoal)
          }
          .frame(maxWidth: .infinity, minHeight: 260)
        } else {
          LazyVGrid(columns: columns, spacing: 14) {
            ForEach(Array(goals.enumerated()), id: \.element.id) { index, goal in
              Button { editing = goal } label: {
                GoalTile(goal: goal, theme: theme)
                  .overlay {
                    if gridFocused && kbSelection == index {
                      RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .strokeBorder(theme.accent, lineWidth: 2)
                    }
                  }
              }
              .buttonStyle(.plain)
              .contextMenu {
                Button { togglePinned(goal) } label: {
                  Label(goal.pinned ? "Unpin from dashboard" : "Pin to dashboard",
                        systemImage: goal.pinned ? "pin.slash" : "pin")
                }
                Button(role: .destructive) { deleteGoal(goal) } label: {
                  Label("Delete", systemImage: "trash")
                }
              }
            }
          }
          // Programmatic focus → arrow keys work with Full Keyboard Access off.
          // We draw our own selection ring, so suppress the system focus halo.
          .focusable()
          .focused($gridFocused)
          .focusEffectDisabled()
          .onAppear {
            gridFocused = true
            if kbSelection == nil { kbSelection = 0 }
          }
          .onKeyPress(.upArrow) { moveSelection(-1) }
          .onKeyPress(.leftArrow) { moveSelection(-1) }
          .onKeyPress(.downArrow) { moveSelection(1) }
          .onKeyPress(.rightArrow) { moveSelection(1) }
          .onKeyPress(.return) { activateSelection() }
          .onKeyPress(.space) { activateSelection() }
        }
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

  private func togglePinned(_ goal: Goal) {
    let next = !goal.pinned
    goalMutator.setPinned(id: goal.id, pinned: next)
    if let idx = goals.firstIndex(where: { $0.id == goal.id }) {
      goals[idx].pinned = next
    }
    Haptics.tick()
  }

  private func saveDrafts(_ drafts: [DraftGoal]) {
    let created = GoalDrafts.save(drafts, mutator: goalMutator)
    if !created.isEmpty {
      goals.insert(contentsOf: created, at: 0)
      Haptics.success()
    }
  }
}

private extension View {
  @ViewBuilder
  func discoveryPresentation(activeMiniApp: Binding<AnyDiscoveryMiniApp?>,
                             onFinish: @escaping ([DraftGoal]) -> Void) -> some View {
    #if os(macOS)
    sheet(item: activeMiniApp) { app in
      app.descriptor.makeView(onFinish)
    }
    #else
    fullScreenCover(item: activeMiniApp) { app in
      app.descriptor.makeView(onFinish)
    }
    #endif
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

struct GoalTile: View {
  @Environment(\.modelContext) private var context
  let goal: Goal
  let theme: SectionTheme

  private var accent: Color {
    goal.sections.first.map { theme.color(for: $0) } ?? .secondary
  }

  private var isPlaceholder: Bool { goal.text == "New goal" }

  /// First line is the goal's title; everything after is its description.
  private var titleAndBody: (title: String, body: String) {
    let lines = goal.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
    let title = lines.first.map(String.init) ?? goal.text
    let body = lines.count > 1
      ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines)
      : ""
    return (title, body)
  }

  private var progress: GoalMetricProgress? {
    GoalMetricEvaluator.evaluate(goal: goal, context: context)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text(isPlaceholder ? "New goal" : titleAndBody.title)
          .font(.septenaGoalTitle)
          .foregroundStyle(isPlaceholder ? .secondary : .primary)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
        if !isPlaceholder, !titleAndBody.body.isEmpty {
          Text(titleAndBody.body)
            .font(.septenaNotes)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      if let progress {
        GoalMetricProgressView(progress: progress, accent: accent)
      }
      Spacer(minLength: 0)
      if !goal.sections.isEmpty {
        sectionPills
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 16)
    .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        .fill(Theme.secondaryGroupedBackground)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        .strokeBorder(accent.opacity(0.5), lineWidth: 1.5)
    )
    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    .contentShape(Rectangle())
    .tileHover()
  }

  private var sectionPills: some View {
    // Wrap pills so multi-section goals don't clip on narrow widths.
    let columns = [GridItem(.adaptive(minimum: 70), spacing: 6, alignment: .leading)]
    return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
      ForEach(goal.sections, id: \.self) { key in
        let color = theme.color(for: key)
        Label {
          Text(key.capitalized)
        } icon: {
          Image(systemName: theme.icon(for: key))
        }
        .labelStyle(.titleAndIcon)
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
  let availableSections: [SectionConfig]
  let theme: SectionTheme
  let mutator: GoalMutator
  let onUpdate: (Goal) -> Void
  let onDelete: (String) -> Void

  @State private var text: String
  @State private var selectedSections: Set<String>
  @State private var showDeleteConfirm = false
  /// Pin this goal to the top of the Week dashboard. Applied on Save.
  @State private var pinned: Bool

  // Optional measurement attachment — UI state for the disclosure section.
  // V1 ships a single metric (weekly training sessions); the picker is a
  // segmented control so adding the next metric only needs a new case.
  @State private var trackMetric: Bool
  @State private var metricKey: String
  @State private var metricComparator: String   // "gte" | "lte" | "eq" | "range"
  @State private var metricTargetText: String
  /// Upper bound, used only when the comparator is "range" (Between).
  @State private var metricUpperText: String
  /// Optional starting value for the progress bar. Empty string = no
  /// baseline; the bar falls back to the simple current/target math.
  @State private var metricBaselineText: String

  /// Weight-unit preference. Body's weight/mass metrics store kilograms; the
  /// editor shows + accepts the user's unit and converts on the way in (init)
  /// and out (save). Reactive so the suffix updates if the user flips the
  /// setting elsewhere while the sheet is open.
  @AppStorage(WeightUnit.defaultsKey) private var weightUnitRaw = WeightUnit.kg.rawValue
  private var weightUnit: WeightUnit { WeightUnit(rawValue: weightUnitRaw) ?? .kg }

  /// Unit suffix to show beside the target fields for a given metric — the
  /// weight preference for kg-stored body metrics, the catalog label otherwise.
  private func unitLabel(for key: String) -> String? {
    guard let metric = GoalMetricCatalog.metric(for: key) else { return nil }
    return metric.isWeight ? weightUnit.suffix : metric.unitLabel
  }

  init(goal: Goal,
       availableSections: [SectionConfig],
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
    _pinned = State(initialValue: goal.pinned)
    let hasMetric = goal.metricKey != nil
    _trackMetric = State(initialValue: hasMetric)
    // Default to the first metric in the catalog (currently training
    // sessions) if the goal has no measurement yet. If the catalog is
    // somehow empty, fall back to an empty key — picker will hide.
    let key = goal.metricKey
              ?? GoalMetricCatalog.all.first?.key
              ?? ""
    _metricKey = State(initialValue: key)
    _metricComparator = State(initialValue: goal.metricComparator ?? "gte")
    // Body weight/mass targets are stored in kg; show them in the user's unit
    // for editing (and convert back on save). Non-weight metrics pass through.
    let isWeight = GoalMetricCatalog.metric(for: key)?.isWeight ?? false
    let unit = WeightUnit.current
    let toDisplay: (Double) -> Double = { isWeight ? unit.display($0) : $0 }
    _metricTargetText = State(initialValue: goal.metricTarget.map { Self.formatTarget(toDisplay($0)) } ?? "3")
    _metricUpperText = State(initialValue: goal.metricTargetUpper.map { Self.formatTarget(toDisplay($0)) } ?? "")
    _metricBaselineText = State(initialValue: goal.metricBaseline.map { Self.formatTarget(toDisplay($0)) } ?? "")
  }

  private static func formatTarget(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
  }

  /// A "between" band needs a parseable upper strictly above the lower bound —
  /// otherwise the stored goal could never be hit (`hit` requires
  /// lower ≤ current ≤ upper). Blocks Save instead of silently clearing the
  /// metric so the typed band isn't lost. An invalid *lower* keeps the existing
  /// behavior (metric clears on save), so it doesn't block here.
  private var rangeBlocksSave: Bool {
    guard trackMetric, metricComparator == "range" else { return false }
    guard let lower = Double(metricTargetText.replacingOccurrences(of: ",", with: ".")),
          lower >= 0 else { return false }
    guard let upper = Double(metricUpperText.replacingOccurrences(of: ",", with: ".")) else { return true }
    return upper <= lower
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
          Toggle("Track with a metric", isOn: $trackMetric)
        } footer: {
          Text("Attach a measurement so this goal shows live progress against a target.")
        }
        if trackMetric {
          let availableMetrics = GoalMetricCatalog.metrics(for: selectedSections)
          Section {
            if availableMetrics.isEmpty {
              // No metric matches the tagged sections — nudge the user to
              // either tag a section that has metrics or pick from the
              // full catalog. Keeping the disclosure honest beats silently
              // showing irrelevant options.
              Text("Tag a section above (Training, Caffeine, Gut, Nutrition…) to see metrics you can measure.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
              Picker("Measure", selection: $metricKey) {
                ForEach(availableMetrics) { metric in
                  Text(metric.label).tag(metric.key)
                }
              }
              Picker("Comparator", selection: $metricComparator) {
                Text("At least").tag("gte")
                Text("At most").tag("lte")
                Text("Exactly").tag("eq")
                Text("Between").tag("range")
              }
              .pickerStyle(.segmented)
              HStack {
                Text(metricComparator == "range" ? "Lower" : "Target")
                Spacer()
                TextField("3", text: $metricTargetText)
                  #if os(iOS)
                  .keyboardType(.decimalPad)
                  #endif
                  .multilineTextAlignment(.trailing)
                  .frame(maxWidth: 80)
                if let unit = unitLabel(for: metricKey) {
                  Text(unit)
                    .foregroundStyle(.secondary)
                }
              }
              if metricComparator == "range" {
                HStack {
                  Text("Upper")
                  Spacer()
                  TextField("0", text: $metricUpperText)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 80)
                  if let unit = unitLabel(for: metricKey) {
                    Text(unit)
                      .foregroundStyle(.secondary)
                  }
                }
                if rangeBlocksSave {
                  Text("Upper must be greater than the lower bound.")
                    .font(.footnote)
                    .foregroundStyle(.red)
                }
              }
              HStack {
                Text("Baseline")
                Spacer()
                TextField("optional", text: $metricBaselineText)
                  #if os(iOS)
                  .keyboardType(.decimalPad)
                  #endif
                  .multilineTextAlignment(.trailing)
                  .frame(maxWidth: 80)
                if let unit = unitLabel(for: metricKey) {
                  Text(unit)
                    .foregroundStyle(.secondary)
                }
              }
            }
          } header: {
            Text("Metric")
          } footer: {
            VStack(alignment: .leading, spacing: 4) {
              if let implied = GoalMetricCatalog.sectionKey(for: metricKey),
                 !selectedSections.contains(implied) {
                Text("This goal will also appear in the \(implied.capitalized) section.")
              }
              Text("Baseline is where you started — the bar will show how much of the distance from baseline to target you've covered. Leave blank for count-style metrics that start at 0.")
            }
          }
          .onChange(of: selectedSections) { _, newSet in
            // If the user un-tags the section the current metric belongs
            // to, snap to the first still-valid option so the picker stays
            // consistent. No silent stash — the goal stays measurable.
            let valid = GoalMetricCatalog.metrics(for: newSet)
            if !valid.contains(where: { $0.key == metricKey }),
               let first = valid.first {
              metricKey = first.key
            }
          }
        }
        Section {
          Toggle(isOn: $pinned) {
            Label("Pin to dashboard", systemImage: "pin")
          }
        } footer: {
          Text("Show this goal at the top of the Week dashboard. Goals with a metric show live progress; habit goals show their streak.")
        }
        // Earned milestone history — latched rungs from MilestoneEngine,
        // newest first. Grandfathered grants (celebrated == false) appear
        // dimmed: honest history, but they never had a moment.
        let earned = SeptenaServices.shared.milestoneMutator.milestones(goalID: goal.id)
        if !earned.isEmpty {
          Section("Milestones") {
            ForEach(earned, id: \.id) { m in
              HStack {
                Image(systemName: "flag.checkered")
                  .foregroundStyle(m.celebrated ? .primary : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                  Text(MilestoneUnits.label(m))
                  Text(m.occurredAt, style: .date)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
              }
              .foregroundStyle(m.celebrated ? .primary : .secondary)
            }
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
      // Grouped style keeps the macOS sheet from collapsing to no height
      // (default-styled Forms report no flexible height) — same rule the
      // shared AdaptiveEditScaffold applies to its sheet branch.
      .formStyle(.grouped)
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
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || rangeBlocksSave)
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
    mutator.setPinned(id: goal.id, pinned: pinned)

    // Metric: write only if the user toggled it on AND provided a valid
    // target. Toggling off (or invalid target) clears all four fields.
    let parsedTarget = Double(metricTargetText.replacingOccurrences(of: ",", with: "."))
    // Target ≥ 0 is valid — "at most 0 blood events" and "no caffeine after
    // 2pm" both need target = 0. Only reject negative or unparseable values.
    let willTrack = trackMetric && (parsedTarget ?? -1) >= 0
    // Window is baked into each catalog entry for v1, not user-picked.
    let metricWindow = GoalMetricCatalog.metric(for: metricKey)?.window ?? "calendarWeek"
    let parsedBaseline = Double(metricBaselineText.replacingOccurrences(of: ",", with: "."))
    let parsedUpper = Double(metricUpperText.replacingOccurrences(of: ",", with: "."))
    let upperToStore = metricComparator == "range" ? parsedUpper : nil
    // Weight metrics are entered in the user's unit; store kg. Non-weight
    // metrics (and all the gate/validation above, which is unit-agnostic since
    // the comparisons are within one unit) pass through unchanged.
    let isWeightMetric = GoalMetricCatalog.metric(for: metricKey)?.isWeight ?? false
    let toKg: (Double?) -> Double? = { v in
      guard let v else { return nil }
      return isWeightMetric ? weightUnit.toKilograms(v) : v
    }
    if willTrack, let target = toKg(parsedTarget) {
      mutator.updateGoalMetric(id: goal.id,
                               metricKey: metricKey,
                               window: metricWindow,
                               comparator: metricComparator,
                               target: target,
                               baseline: toKg(parsedBaseline),
                               upper: toKg(upperToStore))
    } else {
      mutator.updateGoalMetric(id: goal.id,
                               metricKey: nil,
                               window: nil,
                               comparator: nil,
                               target: nil,
                               baseline: nil)
    }

    Haptics.tick()
    var updated = goal
    updated.text = clean
    updated.sections = sections
    updated.pinned = pinned
    if willTrack, let target = toKg(parsedTarget) {
      updated.metricKey = metricKey
      updated.metricWindow = metricWindow
      updated.metricComparator = metricComparator
      updated.metricTarget = target
      updated.metricBaseline = toKg(parsedBaseline)
      updated.metricTargetUpper = toKg(upperToStore)
    } else {
      updated.metricKey = nil
      updated.metricWindow = nil
      updated.metricComparator = nil
      updated.metricTarget = nil
      updated.metricBaseline = nil
      updated.metricTargetUpper = nil
    }
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
