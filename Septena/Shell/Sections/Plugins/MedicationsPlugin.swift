import SwiftData
import SwiftUI

@MainActor
enum MedicationsPlugin: SectionPlugin {
  static var producesTimedEvents: Bool { true }

  static var manifest: SectionManifest {
    SectionManifest.byKey["medications"]!
  }

  static func destinationView() -> AnyView? {
    AnyView(MedicationsDestinationView())
  }

  static var logActions: [LogAction] {
    [
      LogAction(id: "dose", title: "Log dose", systemImage: "cross.case"),
      LogAction(id: "new", title: "New medication", systemImage: "plus"),
    ]
  }

  // Crisp snap — one sharp confirmation beat for a quick utility log.
  // (Was `.sink`; the falling dot read as nothing happening.)
  static var logFlourish: LogFlourish? {
    LogFlourish(motion: .snap)
  }

  static func detailPaneContent() -> AnyView? {
    AnyView(MedicationsDetailContent())
  }

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SectionOnboarding(
      sectionKey: "medications",
      intro: "Create the medication list first, then daily dose logging is a quick taken / skipped / missed check-in.",
      nounPlural: String(localized: "medications"),
      header: String(localized: "Starter medications"),
      footer: String(localized: "Use generic placeholders when exact prescriptions should be entered manually later."),
      items: MedicationStarter.all,
      glyph: { _ in .symbol("pills") },
      primary: { $0.title },
      secondary: { $0.summaryLine },
      existsKey: { AnyHashable($0.title.lowercased()) },
      loadExistingKeys: {
        await MirrorReader.shared.read { ctx in
          Set(((try? ctx.fetch(FetchDescriptor<MedicationDefinitionEntity>())) ?? [])
            .map { AnyHashable($0.title.lowercased()) })
        }
      },
      add: { items in
        let mutator = SeptenaServices.shared.medicationsMutator
        for s in items {
          mutator.addDefinition(title: s.title, genericName: s.genericName,
                                form: s.form, route: s.route,
                                defaultDoseValue: s.doseValue, defaultDoseUnit: s.doseUnit,
                                bucket: s.bucket, scheduleKind: s.scheduleKind,
                                targetDosesPerDay: s.scheduleKind == "daily" ? 1 : nil)
        }
      },
      complete: complete
    ))
  }

  static var exportContribution: SectionExportContribution? {
    SectionExportContribution(
      tables: [
        SchemaTable(name: "medicationDefinition", purpose: "a medication you take", fields: [
          .req("id", "string"), .req("title", "string"),
          .opt("genericName", "string"), .opt("form", "string"),
          .opt("route", "string"), .opt("strengthValue", "number"),
          .opt("strengthUnit", "string"), .opt("defaultDoseValue", "number"),
          .opt("defaultDoseUnit", "string"), .opt("bucket", "string"),
          .opt("scheduleKind", "string", "daily|asNeeded"),
          .opt("targetDosesPerDay", "int"),
          .opt("instructions", "string"), .opt("sortIndex", "int"),
          .opt("archived", "bool"),
        ]),
        SchemaTable(name: "medicationDoseEvent", purpose: "one taken/skipped/missed dose", fields: [
          .req("id", "string"), .req("date", "date"),
          .req("medicationID", "string"), .req("status", "string", "taken|skipped|missed"),
          .opt("time", "time"), .opt("doseValue", "number"),
          .opt("doseUnit", "string"), .opt("reason", "string"),
          .opt("effectNote", "string"), .opt("sideEffectNote", "string"),
          .opt("source", "string"),
        ]),
      ],
      collect: { ctx in
        let defs = try ctx.fetch(FetchDescriptor<MedicationDefinitionEntity>())
        let doses = try ctx.fetch(FetchDescriptor<MedicationDoseEventEntity>())
        return [
          "medicationDefinition": defs.map(medicationDefinitionExportDict),
          "medicationDoseEvent": doses.map(medicationDoseEventExportDict),
        ]
      }
    )
  }

  static var mcpSkill: SectionSkill? {
    SectionSkill(
      key: "medications",
      summary: "Medication definitions and dose logs.",
      tools: [
        SectionSkill.Tool("medications_list", "Definitions and dose logs", inputs: "optional: date, from, to, limit"),
        SectionSkill.Tool("medications_create", "Create a medication definition", inputs: "required: title · optional: genericName, form, route, defaultDoseValue, defaultDoseUnit, bucket, scheduleKind (daily|asNeeded), targetDosesPerDay, instructions"),
        SectionSkill.Tool("medications_log", "Log a dose", inputs: "required: medicationID, status (taken|skipped|missed) · optional: date, time, doseValue, doseUnit, reason, effectNote, sideEffectNote"),
      ],
      body: """
      Medication logs are interventions/adherence data, not supplement habits. \
      Use `status=skipped` for an intentional skip and `status=missed` when the \
      dose should have happened but did not.
      """
    )
  }

  static var aimMetrics: [GoalMetric] {
    [
      GoalMetric(key: "medications.taken_today",
                 label: "Medication doses taken (today)",
                 sectionKey: "medications",
                 window: "today",
                 unitLabel: "doses"),
      GoalMetric(key: "medications.taken_week",
                 label: "Medication doses taken (this week)",
                 sectionKey: "medications",
                 window: "calendarWeek",
                 unitLabel: "doses"),
      GoalMetric(key: "medications.skipped_week",
                 label: "Medication doses skipped/missed (this week)",
                 sectionKey: "medications",
                 window: "calendarWeek",
                 unitLabel: "doses"),
    ]
  }

  static func evaluateAim(metric: GoalMetric, context: ModelContext) -> Double? {
    guard let (startStr, endStr) = GoalMetricWindow.dateStringRange(for: metric.window)
    else { return 0 }
    let rows = (try? context.fetch(FetchDescriptor<MedicationDoseEventEntity>(
      predicate: #Predicate { $0.date >= startStr && $0.date <= endStr }
    ))) ?? []
    switch metric.key {
    case "medications.taken_today", "medications.taken_week":
      return Double(rows.filter { $0.status == "taken" }.count)
    case "medications.skipped_week":
      return Double(rows.filter { $0.status == "skipped" || $0.status == "missed" }.count)
    default:
      return nil
    }
  }

  static var notificationDescriptors: [NotificationDescriptor] {
    [NotificationDescriptor(
      id: "medications.followup", sectionKey: "medications", title: "Medication follow-up",
      priority: 18)]
  }

  static func evaluateNotification(_ descriptorID: String,
                                   context: ModelContext,
                                   now: Date) -> NotificationPlan? {
    guard descriptorID == "medications.followup" else { return nil }
    let today = SeptenaDate.today
    let defs = (try? context.fetch(FetchDescriptor<MedicationDefinitionEntity>(
      predicate: #Predicate { $0.archived == false }
    ))) ?? []
    let routineDefs = defs.filter { ($0.scheduleKind ?? "daily") == "daily" }
    guard !routineDefs.isEmpty else { return nil }
    let rows = (try? context.fetch(FetchDescriptor<MedicationDoseEventEntity>(
      predicate: #Predicate { $0.date == today }
    ))) ?? []
    let takenIDs = Set(rows.filter { $0.status == "taken" }.map(\.medicationID))
    let pending = routineDefs.filter { !takenIDs.contains($0.id) }
    guard !pending.isEmpty else { return nil }
    let body = pending.count == 1
      ? "\(pending[0].title) has no taken dose logged today."
      : "\(pending.count) medications have no taken dose logged today."
    return NotificationPlan(descriptorID: descriptorID, title: "Medications",
                            body: body, threadID: "medications", minuteOfDay: 20 * 60)
  }

  static func correlationFeatures(context: ModelContext) -> [CorrelationFeature] {
    let defs = (try? context.fetch(FetchDescriptor<MedicationDefinitionEntity>())) ?? []
    let doses = (try? context.fetch(FetchDescriptor<MedicationDoseEventEntity>())) ?? []
    return defs.filter { !$0.archived }.compactMap { def in
      let matching = doses.filter { $0.medicationID == def.id }
      guard !matching.isEmpty else { return nil }
      let grouped = Dictionary(grouping: matching, by: \.date)
      let series = grouped.mapValues { rows in
        rows.contains { $0.status == "taken" } ? 1.0 : 0.0
      }
      return CorrelationFeature(key: "medication:\(def.id)",
                                label: def.title,
                                section: "medications",
                                unit: "",
                                role: .lever,
                                distribution: .binary,
                                series: series)
    }
  }
}

private struct MedicationsDetailContent: View {
  @State private var showingSheet = false

  // The `.sheet` hangs off the Button, not the enclosing `Section`. A sheet
  // anchored on a structural Form element (a lone `Section` here) mis-anchors
  // and desyncs on the appear/layout pass — it opens then immediately dismisses
  // on the first tap. Anchoring on the concrete Button leaf is stable. See the
  // sibling fix in SupplementsPlugin (commit 736b937).
  var body: some View {
    Section {
      Button {
        showingSheet = true
      } label: {
        Label("Manage Medications", systemImage: "cross.case")
      }
      .sheet(isPresented: $showingSheet) {
        MedicationDefinitionsSheet()
      }
    } footer: {
      Text("Archiving hides a medication from new dose logs but keeps its dose history and exports intact.")
    }
  }
}

struct MedicationStarter: Identifiable, Hashable {
  let id: String
  let title: String
  let genericName: String?
  let form: String
  let route: String
  let doseValue: Double?
  let doseUnit: String?
  let bucket: String?
  let scheduleKind: String

  static let all: [MedicationStarter] = [
    .init(id: "starter-acetaminophen", title: "Acetaminophen", genericName: nil, form: "tablet", route: "oral", doseValue: 500, doseUnit: "mg", bucket: nil, scheduleKind: "asNeeded"),
    .init(id: "starter-ibuprofen", title: "Ibuprofen", genericName: nil, form: "tablet", route: "oral", doseValue: 200, doseUnit: "mg", bucket: nil, scheduleKind: "asNeeded"),
    .init(id: "starter-antihistamine", title: "Antihistamine", genericName: nil, form: "tablet", route: "oral", doseValue: nil, doseUnit: nil, bucket: "evening", scheduleKind: "daily"),
    .init(id: "starter-ssri", title: "SSRI", genericName: nil, form: "tablet", route: "oral", doseValue: nil, doseUnit: "mg", bucket: "morning", scheduleKind: "daily"),
    .init(id: "starter-blood-pressure", title: "Blood pressure medication", genericName: nil, form: "tablet", route: "oral", doseValue: nil, doseUnit: nil, bucket: "morning", scheduleKind: "daily"),
    .init(id: "starter-thyroid", title: "Thyroid medication", genericName: nil, form: "tablet", route: "oral", doseValue: nil, doseUnit: "mcg", bucket: "morning", scheduleKind: "daily"),
    .init(id: "starter-inhaler", title: "Rescue inhaler", genericName: nil, form: "inhaler", route: "inhaled", doseValue: nil, doseUnit: "puffs", bucket: nil, scheduleKind: "asNeeded"),
    .init(id: "starter-birth-control", title: "Birth control", genericName: nil, form: "tablet", route: "oral", doseValue: 1, doseUnit: "pill", bucket: "evening", scheduleKind: "daily"),
  ]

  /// Secondary row line: form · route · dose · bucket · schedule.
  var summaryLine: String {
    var parts = [form, route]
    if let value = doseValue {
      parts.append("\(value.decimalString(2)) \(doseUnit ?? "")".trimmingCharacters(in: .whitespaces))
    } else if let unit = doseUnit {
      parts.append(unit)
    }
    if let bucket { parts.append(bucket) }
    parts.append(scheduleKind == "asNeeded" ? "as needed" : "daily")
    return parts.joined(separator: " · ")
  }
}

@MainActor func medicationDefinitionExportDict(_ e: MedicationDefinitionEntity) -> [String: Any] {
  compact([
    "id": e.id, "title": e.title, "genericName": e.genericName,
    "form": e.form, "route": e.route,
    "strengthValue": e.strengthValue, "strengthUnit": e.strengthUnit,
    "defaultDoseValue": e.defaultDoseValue, "defaultDoseUnit": e.defaultDoseUnit,
    "bucket": e.bucket, "scheduleKind": e.scheduleKind,
    "targetDosesPerDay": e.targetDosesPerDay, "instructions": e.instructions,
    "sortIndex": e.sortIndex, "archived": e.archived,
    "createdAt": isoDate(e.createdAt), "updatedAt": isoDate(e.updatedAt),
  ])
}

@MainActor func medicationDoseEventExportDict(_ e: MedicationDoseEventEntity) -> [String: Any] {
  compact([
    "id": e.id, "date": e.date, "time": EventTimestamp.hhmm(from: e.occurredAt),
    "medicationID": e.medicationID, "status": e.status,
    "doseValue": e.doseValue, "doseUnit": e.doseUnit,
    "reason": e.reason, "effectNote": e.effectNote,
    "sideEffectNote": e.sideEffectNote, "source": e.source,
    "updatedAt": isoDate(e.updatedAt),
  ])
}
