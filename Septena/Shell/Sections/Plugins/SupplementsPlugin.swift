import SwiftUI
import SwiftData

@MainActor
enum SupplementsPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["supplements"]!
  }

  static func destinationView() -> AnyView? { AnyView(SupplementsDestinationView()) }

  static var logActions: [LogAction] {
    [LogAction(id: "new", title: "New supplement", systemImage: "plus")]
  }

  static func detailPaneContent() -> AnyView? { AnyView(SupplementsDetailContent()) }

  static var exportContribution: SectionExportContribution? {
    SectionExportContribution(
      tables: [
        SchemaTable(name: "supplementDefinition", purpose: "a supplement you take", fields: [
          .req("id", "string"), .req("title", "string"),
          .opt("emoji", "string"), .opt("sortIndex", "int"),
        ]),
        SchemaTable(name: "supplementDayState", purpose: "one supplement on one day", fields: [
          .req("id", "string"), .req("date", "date"),
          .req("supplementID", "string"), .req("done", "bool"),
          .opt("note", "string"), .opt("time", "time"),
        ]),
      ],
      collect: { ctx in
        let defs   = try ctx.fetch(FetchDescriptor<SupplementDefinitionEntity>())
        let states = try ctx.fetch(FetchDescriptor<SupplementDayStateEntity>())
        return [
          "supplementDefinition": defs.map(supplementDefinitionExportDict),
          "supplementDayState":   states.map(supplementDayStateExportDict),
        ]
      }
    )
  }

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SupplementsOnboardingView(complete: complete))
  }

  static var mcpSkill: SectionSkill? {
    SectionSkill(
      key: "supplements",
      summary: "Daily supplement log — same shape as habits.",
      tools: [
        SectionSkill.Tool("supplements_list",   "Definitions with today's state merged",
              inputs: "optional: date (default today)"),
        SectionSkill.Tool("supplements_create", "New definition",
              inputs: "required: title · optional: emoji"),
        SectionSkill.Tool("supplements_update", "Update fields",
              inputs: "required: id · optional: title, emoji"),
        SectionSkill.Tool("supplements_delete", "Delete definition and events",
              inputs: "required: id"),
        SectionSkill.Tool("supplements_toggle", "Mark taken/untaken for a date",
              inputs: "required: id, done · optional: date"),
      ],
      body: """
      Same definition+state shape as habits. \
      `supplements_toggle(id, done: false)` removes today's mark.
      """
    )
  }

  // MARK: - Aim metrics

  static var aimMetrics: [GoalMetric] {
    [
      GoalMetric(key: "supplements.done_today",
                 label: "Supplements taken (today)",
                 sectionKey: "supplements",
                 window: "today",
                 unitLabel: "items"),
      GoalMetric(key: "supplements.days_active_week",
                 label: "Days with ≥1 supplement (this week)",
                 sectionKey: "supplements",
                 window: "calendarWeek",
                 unitLabel: "days"),
    ]
  }

  static func evaluateAim(metric: GoalMetric, context: ModelContext) -> Double? {
    guard let (startStr, endStr) = GoalMetricWindow.dateStringRange(for: metric.window)
    else { return 0 }
    switch metric.key {
    case "supplements.done_today":
      let descriptor = FetchDescriptor<SupplementDayStateEntity>(
        predicate: #Predicate {
          $0.date >= startStr && $0.date <= endStr && $0.done == true
        }
      )
      return Double((try? context.fetch(descriptor).count) ?? 0)
    case "supplements.days_active_week":
      // Distinct days with ≥1 supplement marked — counts adherence in
      // day-shape, not pill-shape, so taking five pills one day still
      // counts as one day.
      let descriptor = FetchDescriptor<SupplementDayStateEntity>(
        predicate: #Predicate {
          $0.date >= startStr && $0.date <= endStr && $0.done == true
        }
      )
      let rows = (try? context.fetch(descriptor)) ?? []
      return Double(Set(rows.map { $0.date }).count)
    default:
      return nil
    }
  }
}

private struct SupplementsDetailContent: View {
  @State private var showingSheet = false

  var body: some View {
    Section {
      Button {
        showingSheet = true
      } label: {
        Label("Manage Supplements", systemImage: "pills")
      }
    } footer: {
      Text("Renaming a supplement doesn't affect its history — events are linked by ID.")
    }
    .sheet(isPresented: $showingSheet) {
      SupplementTypeSheet()
        .environment(SeptenaServices.shared.checklistMutator)
    }

    // Contextual Siri tip — teaches the spoken phrase right where the user
    // manages supplements. The canonical per-section pattern: one
    // `sectionSiriTip(_:)` call with the section's primary log intent.
    sectionSiriTip(MarkSupplementTakenIntent())
  }
}

/// Curated starter supplements. Additive only — items the user already
/// has (case-insensitive title match) render as "Already added".
private struct SupplementStarter: Identifiable, Hashable {
  let id: String
  let name: String
  let emoji: String

  static let all: [SupplementStarter] = [
    .init(id: "starter-vitamin-d",     name: "Vitamin D",         emoji: "☀️"),
    .init(id: "starter-omega-3",       name: "Omega-3",           emoji: "🐟"),
    .init(id: "starter-magnesium",     name: "Magnesium",         emoji: "🧂"),
    .init(id: "starter-multivitamin",  name: "Multivitamin",      emoji: "💊"),
    .init(id: "starter-creatine",      name: "Creatine",          emoji: "💪"),
    .init(id: "starter-protein",       name: "Protein",           emoji: "🥛"),
    .init(id: "starter-probiotic",     name: "Probiotic",         emoji: "🦠"),
    .init(id: "starter-b-complex",     name: "B-complex",         emoji: "🌾"),
    .init(id: "starter-iron",          name: "Iron",              emoji: "🩸"),
    .init(id: "starter-zinc",          name: "Zinc",              emoji: "⚙️"),
  ]
}

private struct SupplementsOnboardingView: View {
  let complete: () -> Void
  @Environment(ChecklistMutator.self) private var mutator
  @Environment(SectionTheme.self) private var theme
  @Environment(\.modelContext) private var modelContext
  @State private var selected: Set<String> = []
  @State private var existingTitles: Set<String> = []

  private var accent: Color { theme.color(for: "supplements") }

  private func alreadyExists(_ s: SupplementStarter) -> Bool {
    existingTitles.contains(s.name.lowercased())
  }

  private func loadExisting() {
    let rows = (try? modelContext.fetch(FetchDescriptor<SupplementDefinitionEntity>())) ?? []
    existingTitles = Set(rows.map { $0.title.lowercased() })
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          SectionOnboardingHero(
            sectionKey: "supplements",
            title: "Supplements",
            intro: "Logs the things you take daily. Pick a few common ones to start — edit, delete, or add your own anytime."
          )
          .onboardingHeroSection()
        }
        Section {
          ForEach(SupplementStarter.all) { starter in
            starterRow(starter)
          }
        }
      }
      .formStyle(.grouped)
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .safeAreaInset(edge: .bottom) {
        bottomBar
      }
      .onAppear { loadExisting() }
    }
  }

  @ViewBuilder
  private func starterRow(_ s: SupplementStarter) -> some View {
    let exists = alreadyExists(s)
    let isSelected = selected.contains(s.id)
    Button {
      guard !exists else { return }
      if isSelected { selected.remove(s.id) } else { selected.insert(s.id) }
    } label: {
      HStack(spacing: 12) {
        Text(s.emoji).font(.title3)
          .opacity(exists ? 0.4 : 1)
        Text(s.name)
          .foregroundStyle(exists ? .secondary : .primary)
          .strikethrough(exists, color: .secondary)
        Spacer()
        if exists {
          Text("Already added")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isSelected ? accent : Color.secondary.opacity(0.6))
            .font(.title3)
        }
      }
    }
    .buttonStyle(.plain)
    .disabled(exists)
  }

  @ViewBuilder
  private var bottomBar: some View {
    HStack(spacing: 12) {
      Button("Skip") { complete() }
        .buttonStyle(.bordered)
      Spacer()
      Button(actionTitle) { addAndFinish() }
        .buttonStyle(.borderedProminent)
        .tint(accent)
    }
    .padding()
    .background(.bar)
  }

  private var actionTitle: String {
    selected.isEmpty ? "Done" : "Add \(selected.count) supplement\(selected.count == 1 ? "" : "s")"
  }

  private func addAndFinish() {
    let toAdd = SupplementStarter.all.filter {
      selected.contains($0.id) && !alreadyExists($0)
    }
    for s in toAdd {
      mutator.createSupplement(name: s.name, emoji: s.emoji)
    }
    complete()
  }
}

@MainActor func supplementDefinitionExportDict(_ e: SupplementDefinitionEntity) -> [String: Any] {
  compact([
    "id": e.id, "title": e.title, "emoji": e.emoji,
    "sortIndex": e.sortIndex, "updatedAt": isoDate(e.updatedAt),
  ])
}

@MainActor func supplementDayStateExportDict(_ e: SupplementDayStateEntity) -> [String: Any] {
  compact([
    "id": e.id, "date": e.date, "supplementID": e.supplementID,
    "done": e.done, "note": e.note, "time": e.time,
    "updatedAt": isoDate(e.updatedAt),
  ])
}
