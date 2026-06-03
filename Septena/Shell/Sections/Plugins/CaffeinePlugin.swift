import SwiftUI
import SwiftData

// First real-data section migration. Caffeine's display-label helper
// and its full MCP/agent contract all live here. Anyone reading or
// modifying caffeine behavior only edits this file — the Settings
// detail pane and the MCP gateway all consume from this single source
// of truth.

@MainActor
enum CaffeinePlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["caffeine"]!
  }

  static func destinationView() -> AnyView? { AnyView(CaffeineDestinationView()) }

  // A coffee is a warm cup → a gentle bloom. CaffeineCommit scales its
  // loudness by dose, but the motion is the same any time of day.
  static var logFlourish: LogFlourish? { LogFlourish(motion: .bloom) }

  // + menu surfaces the two quick-log brews on top, then the catalog
  // editor below. Order matches the most common path: tap +, pick V60,
  // accept the prefilled bean.
  static var logActions: [LogAction] {
    [
      LogAction(id: "log-v60",    title: "Log V60",      systemImage: "cup.and.saucer"),
      LogAction(id: "log-matcha", title: "Log Matcha",   systemImage: "leaf"),
      LogAction(id: "log-other",  title: "Log other",    systemImage: "plus.circle"),
      LogAction(id: "manage",     title: "Manage types", systemImage: "gearshape"),
    ]
  }

  static func detailPaneContent() -> AnyView? { AnyView(CaffeineDetailContent()) }

  // MARK: - Import/Export

  static var exportContribution: SectionExportContribution? {
    SectionExportContribution(
      tables: [
        SchemaTable(name: "caffeineBean", purpose: "a coffee bean / source you use", fields: [
          .req("id", "string"), .req("name", "string"),
          .opt("sortIndex", "int"),
        ]),
        SchemaTable(name: "caffeineEvent", purpose: "one drink", fields: [
          .req("id", "string"), .req("date", "date"), .req("time", "time"),
          .req("method", "string", "v60 | matcha | other"),
          .opt("beans", "string", "caffeineBean.id"),
          .opt("grams", "double"), .opt("note", "string"),
        ]),
      ],
      collect: { ctx in
        let beans = try ctx.fetch(FetchDescriptor<CaffeineBeanEntity>())
        let events = try ctx.fetch(FetchDescriptor<CaffeineEventEntity>())
        return [
          "caffeineBean":  beans.map(caffeineBeanExportDict),
          "caffeineEvent": events.map(caffeineEventExportDict),
        ]
      }
    )
  }

  // MARK: - First-enable onboarding

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(CaffeineOnboardingView(complete: complete))
  }

  /// Human-readable label for a caffeine entry's brewing method. Used
  /// both by the Today timeline (above) and by the caffeine edit sheet
  /// when the user changes an entry's method — keeping the mapping in one
  /// place prevents the two surfaces from drifting apart.
  static func label(for entry: CaffeineEntry) -> String {
    switch entry.method {
    case "v60":       return "V60"
    case "matcha":    return "Matcha"
    case "aeropress": return "Aeropress"
    case "espresso":  return "Espresso"
    default:          return entry.method.capitalized
    }
  }

  // MARK: - MCP / agent contract
  //
  // Tightly bound to the plugin: the read/write tools advertised here
  // ARE the section's contract. Adding a column to CaffeineEvent, or
  // a new method, is a single-file edit that updates the catalog
  // declaration, the tools list, and the label helper together —
  // they can't drift apart because they live in the same file.

  static var mcpSkill: SectionSkill? {
    SectionSkill(
      key: "caffeine",
      summary: "Log coffee, matcha, and other caffeine sources.",
      tools: [
        SectionSkill.Tool("caffeine_events_list", "By day or range. Defaults to last 7 days",
              inputs: "optional: date, from, to, limit"),
        SectionSkill.Tool("caffeine_event_log",   "Log an intake",
              inputs: "required: method (v60|matcha|aeropress|espresso|other) · optional: date (default today), time (HH:MM:SS), beans (CaffeineBean id), grams (dose), note"),
        SectionSkill.Tool("caffeine_event_delete", "Remove an event",
              inputs: "required: id"),
        SectionSkill.Tool("caffeine_beans_list",  "Bean / source catalog"),
        SectionSkill.Tool("caffeine_bean_create", "Add a new source",
              inputs: "required: name"),
        SectionSkill.Tool("caffeine_bean_delete", "Remove a source",
              inputs: "required: id"),
      ],
      body: """
      ### Example
      **"I had a v60 with the Ethiopian beans"**
      ```
      caffeine_beans_list()                                        → find bean id
      caffeine_event_log(method: "v60", beans: <id>, grams: 18)
      ```

      Matcha doesn't need a bean reference unless tracking source.
      """
    )
  }

  // MARK: - Aim metrics

  static var aimMetrics: [GoalMetric] {
    [
      GoalMetric(key: "caffeine.cup_count",
                 label: "Caffeine drinks (today)",
                 sectionKey: "caffeine",
                 window: "today",
                 unitLabel: "cups"),
      GoalMetric(key: "caffeine.cup_count_week",
                 label: "Caffeine drinks (this week)",
                 sectionKey: "caffeine",
                 window: "calendarWeek",
                 unitLabel: "cups"),
    ]
  }

  static func evaluateAim(metric: GoalMetric, context: ModelContext) -> Double? {
    switch metric.key {
    case "caffeine.cup_count", "caffeine.cup_count_week":
      // Each CaffeineEventEntity = one drink. Grams varies by method so
      // we deliberately count drinks rather than convert to mg.
      guard let (startStr, endStr) = GoalMetricWindow.dateStringRange(for: metric.window) else { return 0 }
      let descriptor = FetchDescriptor<CaffeineEventEntity>(
        predicate: #Predicate { $0.date >= startStr && $0.date <= endStr }
      )
      return Double((try? context.fetch(descriptor).count) ?? 0)
    default:
      return nil
    }
  }
}

/// Section-specific content for the Settings detail pane. Read-only
/// display of the user's bean catalog + brewing methods from the live
/// SettingsStore — catalog editing happens on the Caffeine destination
/// screen, not here.
private struct CaffeineDetailContent: View {
  @Environment(SettingsStore.self) private var store

  var body: some View {
    if let caf = store.caffeine {
      if !caf.beans.isEmpty {
        Section("Beans") {
          ForEach(caf.beans) { bean in
            HStack {
              Text(bean.name)
              Spacer()
              Text(bean.id)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      if let methods = caf.methods, !methods.isEmpty {
        Section("Methods") {
          ForEach(methods, id: \.self) { Text($0) }
        }
      }
    }
  }
}

/// Common bean / source names. Additive only — pre-existing beans
/// with matching names (case-insensitive) appear as "Already added".
private struct CaffeineBeanStarter: Identifiable, Hashable {
  let id: String
  let name: String

  static let all: [CaffeineBeanStarter] = [
    .init(id: "starter-house-blend",  name: "House blend"),
    .init(id: "starter-ethiopian",    name: "Ethiopian"),
    .init(id: "starter-colombian",    name: "Colombian"),
    .init(id: "starter-decaf",        name: "Decaf"),
    .init(id: "starter-matcha-grade", name: "Ceremonial matcha"),
    .init(id: "starter-cold-brew",    name: "Cold brew concentrate"),
  ]
}

private struct CaffeineOnboardingView: View {
  let complete: () -> Void
  @Environment(SectionTheme.self) private var theme
  @Environment(\.modelContext) private var modelContext
  @State private var selected: Set<String> = []
  @State private var existingNames: Set<String> = []

  private var accent: Color { theme.color(for: "caffeine") }
  private var mutator: CaffeineMutator { SeptenaServices.shared.caffeineMutator }

  private func alreadyExists(_ s: CaffeineBeanStarter) -> Bool {
    existingNames.contains(s.name.lowercased())
  }

  private func loadExisting() {
    let rows = (try? modelContext.fetch(FetchDescriptor<CaffeineBeanEntity>())) ?? []
    existingNames = Set(rows.map { $0.name.lowercased() })
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          SectionOnboardingHero(
            sectionKey: "caffeine",
            title: "Caffeine",
            intro: "Logs coffee, matcha, and other sources. Pick a few common beans below to start — you can rename or add more later."
          )
          .onboardingHeroSection()
        }
        Section("Beans / sources") {
          ForEach(CaffeineBeanStarter.all) { starter in
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
  private func starterRow(_ s: CaffeineBeanStarter) -> some View {
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
    selected.isEmpty ? "Done" : "Add \(selected.count) source\(selected.count == 1 ? "" : "s")"
  }

  private func addAndFinish() {
    let toAdd = CaffeineBeanStarter.all.filter {
      selected.contains($0.id) && !alreadyExists($0)
    }
    for s in toAdd {
      _ = mutator.addBean(name: s.name)
    }
    complete()
  }
}

// MARK: - Export dict mappers
//
// Same shape as the legacy helpers in SettingsView.swift; moved here
// so a future change to CaffeineEvent's columns updates the catalog
// declaration, the tools list, and the JSON shape in one file.

@MainActor func caffeineBeanExportDict(_ e: CaffeineBeanEntity) -> [String: Any] {
  compact([
    "id": e.id, "name": e.name, "sortIndex": e.sortIndex,
    "updatedAt": isoDate(e.updatedAt),
  ])
}

@MainActor func caffeineEventExportDict(_ e: CaffeineEventEntity) -> [String: Any] {
  compact([
    "id": e.id, "date": e.date, "time": e.time, "method": e.method,
    "beans": e.beans, "grams": e.grams, "note": e.note,
    "updatedAt": isoDate(e.updatedAt),
  ])
}
