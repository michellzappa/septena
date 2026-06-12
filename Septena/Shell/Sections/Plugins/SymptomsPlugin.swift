import SwiftData
import SwiftUI

@MainActor
enum SymptomsPlugin: SectionPlugin {
  static var producesTimedEvents: Bool { true }

  static var manifest: SectionManifest {
    SectionManifest.byKey["symptoms"]!
  }

  static func destinationView() -> AnyView? {
    AnyView(SymptomsDestinationView())
  }

  static var logActions: [LogAction] {
    [LogAction(id: "symptom", title: "Log symptom", systemImage: "waveform.path.ecg")]
  }

  static var logFlourish: LogFlourish? {
    LogFlourish(motion: .sink)
  }

  static func detailPaneContent() -> AnyView? {
    AnyView(SymptomsDetailContent())
  }

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SymptomsOnboardingView(complete: complete))
  }

  static var exportContribution: SectionExportContribution? {
    SectionExportContribution(
      tables: [
        SchemaTable(name: "symptomDefinition", purpose: "a symptom or pain type", fields: [
          .req("id", "string"), .req("title", "string"),
          .opt("emoji", "string"), .opt("bodySystem", "string"),
          .opt("defaultBodyRegion", "string"), .opt("sortIndex", "int"),
          .opt("archived", "bool"),
        ]),
        SchemaTable(name: "symptomEvent", purpose: "one symptom log", fields: [
          .req("id", "string"), .req("date", "date"),
          .req("symptomID", "string"), .req("severity", "int", "0-10"),
          .opt("time", "time"), .opt("durationMinutes", "int"),
          .opt("bodyRegion", "string"), .opt("side", "string"),
          .opt("quality", "string"), .opt("triggerNote", "string"),
          .opt("reliefNote", "string"), .opt("note", "string"),
          .opt("source", "string"),
        ]),
      ],
      collect: { ctx in
        let defs = try ctx.fetch(FetchDescriptor<SymptomDefinitionEntity>())
        let events = try ctx.fetch(FetchDescriptor<SymptomEventEntity>())
        return [
          "symptomDefinition": defs.map(symptomDefinitionExportDict),
          "symptomEvent": events.map(symptomEventExportDict),
        ]
      }
    )
  }

  static var mcpSkill: SectionSkill? {
    SectionSkill(
      key: "symptoms",
      summary: "Pain and symptom severity logs.",
      tools: [
        SectionSkill.Tool("symptoms_list", "Definitions and recent logs", inputs: "optional: date, from, to, limit"),
        SectionSkill.Tool("symptoms_create", "Create a symptom definition", inputs: "required: title · optional: emoji, bodySystem, defaultBodyRegion"),
        SectionSkill.Tool("symptoms_log", "Log severity", inputs: "required: symptomID, severity (0-10) · optional: date, time, durationMinutes, bodyRegion, side, quality, triggerNote, reliefNote, note"),
      ],
      body: """
      Treat symptoms as outcomes. Prefer structured severity (0-10), body \
      region and side over burying everything in `note`; use trigger/relief \
      notes for possible causes and interventions.
      """
    )
  }

  static var aimMetrics: [GoalMetric] {
    [
      GoalMetric(key: "symptoms.event_count",
                 label: "Symptom events (this week)",
                 sectionKey: "symptoms",
                 window: "calendarWeek",
                 unitLabel: "events"),
      GoalMetric(key: "symptoms.peak_severity",
                 label: "Peak symptom severity (this week)",
                 sectionKey: "symptoms",
                 window: "calendarWeek",
                 unitLabel: "/10"),
      GoalMetric(key: "symptoms.avg_severity",
                 label: "Average symptom severity (this week)",
                 sectionKey: "symptoms",
                 window: "calendarWeek",
                 unitLabel: "/10"),
    ]
  }

  static func evaluateAim(metric: GoalMetric, context: ModelContext) -> Double? {
    guard let (startStr, endStr) = GoalMetricWindow.dateStringRange(for: metric.window)
    else { return 0 }
    let rows = (try? context.fetch(FetchDescriptor<SymptomEventEntity>(
      predicate: #Predicate { $0.date >= startStr && $0.date <= endStr }
    ))) ?? []
    switch metric.key {
    case "symptoms.event_count":
      return Double(rows.count)
    case "symptoms.peak_severity":
      return Double(rows.map(\.severity).max() ?? 0)
    case "symptoms.avg_severity":
      guard !rows.isEmpty else { return 0 }
      return Double(rows.reduce(0) { $0 + $1.severity }) / Double(rows.count)
    default:
      return nil
    }
  }

  static func correlationFeatures(context: ModelContext) -> [CorrelationFeature] {
    let defs = (try? context.fetch(FetchDescriptor<SymptomDefinitionEntity>())) ?? []
    let events = (try? context.fetch(FetchDescriptor<SymptomEventEntity>())) ?? []
    return defs.filter { !$0.archived }.compactMap { def in
      let matching = events.filter { $0.symptomID == def.id }
      guard !matching.isEmpty else { return nil }
      let grouped = Dictionary(grouping: matching, by: \.date)
      let series = grouped.mapValues { Double($0.map(\.severity).max() ?? 0) }
      return CorrelationFeature(key: "symptom:\(def.id)",
                                label: def.title,
                                section: "symptoms",
                                unit: "/10",
                                role: .outcome,
                                distribution: .continuous,
                                series: series)
    }
  }
}

private struct SymptomsDetailContent: View {
  @State private var showingSheet = false

  var body: some View {
    Section {
      Button {
        showingSheet = true
      } label: {
        Label("Manage Symptoms", systemImage: "waveform.path.ecg")
      }
    } footer: {
      Text("Archiving hides a symptom from new logs but keeps its history and exports intact.")
    }
    .sheet(isPresented: $showingSheet) {
      SymptomDefinitionsSheet()
    }
  }
}

struct SymptomStarter: Identifiable, Hashable {
  let id: String
  let title: String
  let emoji: String
  let bodySystem: String
  let region: String

  static let all: [SymptomStarter] = [
    .init(id: "starter-headache", title: "Headache", emoji: "🤕", bodySystem: "Neurological", region: "Head"),
    .init(id: "starter-migraine", title: "Migraine", emoji: "🧠", bodySystem: "Neurological", region: "Head"),
    .init(id: "starter-fatigue", title: "Fatigue", emoji: "🪫", bodySystem: "General", region: "Whole body"),
    .init(id: "starter-nausea", title: "Nausea", emoji: "🤢", bodySystem: "Digestive", region: "Stomach"),
    .init(id: "starter-abdominal-pain", title: "Abdominal pain", emoji: "🫃", bodySystem: "Digestive", region: "Abdomen"),
    .init(id: "starter-abdominal-discomfort", title: "Abdominal discomfort", emoji: "🫄", bodySystem: "Digestive", region: "Abdomen"),
    .init(id: "starter-bloating", title: "Bloating", emoji: "🎈", bodySystem: "Digestive", region: "Abdomen"),
    .init(id: "starter-gas", title: "Gas", emoji: "💨", bodySystem: "Digestive", region: "Abdomen"),
    .init(id: "starter-cramps", title: "Cramps", emoji: "🌀", bodySystem: "Digestive", region: "Abdomen"),
    .init(id: "starter-reflux", title: "Reflux", emoji: "🔥", bodySystem: "Digestive", region: "Chest"),
    .init(id: "starter-blood-stool", title: "Blood in stool", emoji: "🩸", bodySystem: "Digestive", region: "Rectum"),
    .init(id: "starter-back-pain", title: "Back pain", emoji: "🦴", bodySystem: "Musculoskeletal", region: "Back"),
    .init(id: "starter-joint-pain", title: "Joint pain", emoji: "🦵", bodySystem: "Musculoskeletal", region: "Joints"),
    .init(id: "starter-sore-throat", title: "Sore throat", emoji: "🗣️", bodySystem: "Respiratory", region: "Throat"),
    .init(id: "starter-congestion", title: "Congestion", emoji: "👃", bodySystem: "Respiratory", region: "Nose"),
    .init(id: "starter-anxiety", title: "Anxiety", emoji: "🌫️", bodySystem: "Mental", region: "Chest"),
  ]
}

private struct SymptomsOnboardingView: View {
  let complete: () -> Void
  @Environment(SectionTheme.self) private var theme
  @Environment(\.modelContext) private var modelContext
  @State private var selected: Set<String> = []
  @State private var existingTitles: Set<String> = []

  private var accent: Color { theme.color(for: "symptoms") }
  private var mutator: SymptomsMutator { SeptenaServices.shared.symptomsMutator }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          SectionOnboardingHero(
            sectionKey: "symptoms",
            title: "Symptoms",
            intro: "Pick the symptoms you want ready for one-tap logging. Each log still captures severity, time and optional context."
          )
          .onboardingHeroSection()
        }
        Section {
          ForEach(SymptomStarter.all) { starter in
            starterRow(starter)
          }
        } header: {
          Text("Starter symptoms")
        }
      }
      .formStyle(.grouped)
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .safeAreaInset(edge: .bottom) { bottomBar }
      .onAppear { loadExisting() }
    }
  }

  @ViewBuilder
  private func starterRow(_ starter: SymptomStarter) -> some View {
    let exists = existingTitles.contains(starter.title.lowercased())
    let isSelected = selected.contains(starter.id)
    Button {
      guard !exists else { return }
      if isSelected { selected.remove(starter.id) } else { selected.insert(starter.id) }
    } label: {
      HStack(spacing: 12) {
        Text(starter.emoji).font(.title3).opacity(exists ? 0.4 : 1)
        VStack(alignment: .leading, spacing: 2) {
          Text(starter.title)
            .foregroundStyle(exists ? .secondary : .primary)
            .strikethrough(exists, color: .secondary)
          Text(starter.region)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if exists {
          Text("Already added").font(.caption).foregroundStyle(.secondary)
        } else {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? accent : Color.secondary.opacity(0.6))
        }
      }
    }
    .buttonStyle(.plain)
    .disabled(exists)
  }

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
    selected.isEmpty ? String(localized: "Done") : String(localized: "Add \(selected.count) symptoms")
  }

  private func loadExisting() {
    let rows = (try? modelContext.fetch(FetchDescriptor<SymptomDefinitionEntity>())) ?? []
    existingTitles = Set(rows.map { $0.title.lowercased() })
  }

  private func addAndFinish() {
    for starter in SymptomStarter.all where selected.contains(starter.id) && !existingTitles.contains(starter.title.lowercased()) {
      mutator.addDefinition(title: starter.title,
                            emoji: starter.emoji,
                            bodySystem: starter.bodySystem,
                            defaultBodyRegion: starter.region)
    }
    complete()
  }
}

@MainActor func symptomDefinitionExportDict(_ e: SymptomDefinitionEntity) -> [String: Any] {
  compact([
    "id": e.id, "title": e.title, "emoji": e.emoji,
    "bodySystem": e.bodySystem, "defaultBodyRegion": e.defaultBodyRegion,
    "sortIndex": e.sortIndex, "archived": e.archived,
    "createdAt": isoDate(e.createdAt), "updatedAt": isoDate(e.updatedAt),
  ])
}

@MainActor func symptomEventExportDict(_ e: SymptomEventEntity) -> [String: Any] {
  compact([
    "id": e.id, "date": e.date, "time": EventTimestamp.hhmm(from: e.occurredAt),
    "symptomID": e.symptomID, "severity": e.severity,
    "durationMinutes": e.durationMinutes, "bodyRegion": e.bodyRegion,
    "side": e.side, "quality": e.quality,
    "triggerNote": e.triggerNote, "reliefNote": e.reliefNote,
    "note": e.note, "source": e.source, "updatedAt": isoDate(e.updatedAt),
  ])
}
