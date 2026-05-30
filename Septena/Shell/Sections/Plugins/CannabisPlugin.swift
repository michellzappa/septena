import SwiftUI
import SwiftData

// Cannabis log section. Same pattern as CaffeinePlugin: one file owns
// the display-label helper and the full MCP contract, so adding a new
// method or column updates everything in lock-step.

@MainActor
enum CannabisPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["cannabis"]!
  }

  static func destinationView() -> AnyView? { AnyView(CannabisDestinationView()) }

  static var logActions: [LogAction] {
    [
      LogAction(id: "log-vape",   title: "Log vape",      systemImage: "wind"),
      LogAction(id: "log-edible", title: "Log edible",    systemImage: "leaf.circle"),
      LogAction(id: "manage",     title: "Manage strains", systemImage: "gearshape"),
    ]
  }

  static func detailPaneContent() -> AnyView? { AnyView(CannabisDetailContent()) }

  static var exportContribution: SectionExportContribution? {
    SectionExportContribution(
      tables: [
        SchemaTable(name: "cannabisStrain", purpose: "a strain you use", fields: [
          .req("id", "string"), .req("name", "string"),
          .opt("sortIndex", "int"),
        ]),
        SchemaTable(name: "cannabisEvent", purpose: "one session", fields: [
          .req("id", "string"), .req("date", "date"), .req("time", "time"),
          .req("method", "string", "vape | edible"),
          .opt("strain", "string", "cannabisStrain.id"),
          .opt("hit", "int"), .opt("grams", "double"),
          .opt("effect", "string"), .opt("note", "string"),
        ]),
      ],
      collect: { ctx in
        let strains = try ctx.fetch(FetchDescriptor<CannabisStrainEntity>())
        let events  = try ctx.fetch(FetchDescriptor<CannabisEventEntity>())
        return [
          "cannabisStrain": strains.map(cannabisStrainExportDict),
          "cannabisEvent":  events.map(cannabisEventExportDict),
        ]
      }
    )
  }

  // MARK: - First-enable onboarding

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(CannabisOnboardingView(complete: complete))
  }

  /// Human-readable label for an intake method. Used by both the Today
  /// timeline and the cannabis edit sheet — single source of truth.
  static func label(for entry: CannabisEntry) -> String {
    switch entry.method {
    case "vape":   return "Vape"
    case "edible": return "Edible"
    default:       return entry.method.capitalized
    }
  }

  // MARK: - MCP / agent contract

  static var mcpSkill: SectionSkill? {
    SectionSkill(
      key: "cannabis",
      summary: "Log cannabis intake with strain and effect.",
      tools: [
        SectionSkill.Tool("cannabis_events_list",  "By day or range. Defaults to last 7 days",
              inputs: "optional: date, from, to, limit"),
        SectionSkill.Tool("cannabis_event_log",    "Log an intake",
              inputs: "required: method (vape|edible) · optional: date (default today), time (HH:MM:SS), strain (CannabisStrain id), hit (count for vape), grams (for edibles), effect (free-form, e.g. relaxed/creative), note"),
        SectionSkill.Tool("cannabis_event_delete", "Remove an event",
              inputs: "required: id"),
        SectionSkill.Tool("cannabis_strains_list", "Strain catalog"),
        SectionSkill.Tool("cannabis_strain_create", "Add a strain",
              inputs: "required: name"),
        SectionSkill.Tool("cannabis_strain_delete", "Remove a strain",
              inputs: "required: id"),
      ],
      body: """
      `effect` is subjective free-form: "relaxed", "creative", "couch-locked".
      """
    )
  }

  // MARK: - Aim metrics

  static var aimMetrics: [GoalMetric] {
    [
      GoalMetric(key: "cannabis.event_count",
                 label: "Cannabis sessions (today)",
                 sectionKey: "cannabis",
                 window: "today",
                 unitLabel: "sessions"),
      GoalMetric(key: "cannabis.event_count_week",
                 label: "Cannabis sessions (this week)",
                 sectionKey: "cannabis",
                 window: "calendarWeek",
                 unitLabel: "sessions"),
    ]
  }

  static func evaluateAim(metric: GoalMetric, context: ModelContext) -> Double? {
    switch metric.key {
    case "cannabis.event_count", "cannabis.event_count_week":
      // Each CannabisEventEntity = one session. Grams + hit count vary so
      // we count sessions rather than try to synthesise a dose number.
      guard let (startStr, endStr) = GoalMetricWindow.dateStringRange(for: metric.window) else { return 0 }
      let descriptor = FetchDescriptor<CannabisEventEntity>(
        predicate: #Predicate { $0.date >= startStr && $0.date <= endStr }
      )
      return Double((try? context.fetch(descriptor).count) ?? 0)
    default:
      return nil
    }
  }
}

private struct CannabisDetailContent: View {
  @Environment(SettingsStore.self) private var store

  var body: some View {
    if let cnb = store.cannabis {
      if !cnb.strains.isEmpty {
        Section("Strains") {
          ForEach(cnb.strains) { st in
            HStack {
              Text(st.name)
              Spacer()
              Text(st.id)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      Section("Dosing") {
        sectionDetailRow("Uses per capsule", "\(cnb.usesPerCapsule)")
      }
    }
  }
}

/// Generic strain placeholders. Real strains vary widely — these are
/// safe defaults that map to common categories the user can rename or
/// extend later. Additive only.
private struct CannabisStrainStarter: Identifiable, Hashable {
  let id: String
  let name: String

  static let all: [CannabisStrainStarter] = [
    .init(id: "starter-indica",       name: "Indica (generic)"),
    .init(id: "starter-sativa",       name: "Sativa (generic)"),
    .init(id: "starter-hybrid",       name: "Hybrid (generic)"),
    .init(id: "starter-cbd-dominant", name: "CBD-dominant"),
  ]
}

private struct CannabisOnboardingView: View {
  let complete: () -> Void
  @Environment(SectionTheme.self) private var theme
  @Environment(\.modelContext) private var modelContext
  @State private var selected: Set<String> = []
  @State private var existingNames: Set<String> = []

  private var accent: Color { theme.color(for: "cannabis") }
  private var mutator: CannabisMutator { SeptenaServices.shared.cannabisMutator }

  private func alreadyExists(_ s: CannabisStrainStarter) -> Bool {
    existingNames.contains(s.name.lowercased())
  }

  private func loadExisting() {
    let rows = (try? modelContext.fetch(FetchDescriptor<CannabisStrainEntity>())) ?? []
    existingNames = Set(rows.map { $0.name.lowercased() })
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          SectionOnboardingHero(
            sectionKey: "cannabis",
            title: "Cannabis",
            intro: "Logs intake with strain and effect. Pick a few generic placeholders to start — rename them later as you identify specific strains, or skip and add your own."
          )
          .onboardingHeroSection()
        }
        Section("Strains") {
          ForEach(CannabisStrainStarter.all) { starter in
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
  private func starterRow(_ s: CannabisStrainStarter) -> some View {
    let exists = alreadyExists(s)
    let isSelected = selected.contains(s.id)
    Button {
      guard !exists else { return }
      if isSelected { selected.remove(s.id) } else { selected.insert(s.id) }
    } label: {
      HStack(spacing: 12) {
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
    selected.isEmpty ? "Done" : "Add \(selected.count) strain\(selected.count == 1 ? "" : "s")"
  }

  private func addAndFinish() {
    let toAdd = CannabisStrainStarter.all.filter {
      selected.contains($0.id) && !alreadyExists($0)
    }
    for s in toAdd {
      _ = mutator.addStrain(name: s.name)
    }
    complete()
  }
}

@MainActor func cannabisStrainExportDict(_ e: CannabisStrainEntity) -> [String: Any] {
  compact([
    "id": e.id, "name": e.name, "sortIndex": e.sortIndex,
    "updatedAt": isoDate(e.updatedAt),
  ])
}

@MainActor func cannabisEventExportDict(_ e: CannabisEventEntity) -> [String: Any] {
  compact([
    "id": e.id, "date": e.date, "time": e.time, "method": e.method,
    "strain": e.strain, "hit": e.hit, "grams": e.grams,
    "effect": e.effect, "note": e.note,
    "updatedAt": isoDate(e.updatedAt),
  ])
}
