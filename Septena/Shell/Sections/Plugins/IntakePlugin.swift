import SwiftUI
import SwiftData

// IntakePlugin — behavior for the generic `intake` host section. Identity is
// the `intake` manifest row; kinds are user data (rows, not sections). The one
// genuinely dynamic surface is aimMetrics: one metric set PER kind, generated
// at runtime from the live store (the SectionPlugin.aimMetrics(context:) seam).
// Dashboard tile-per-kind (WeekDashboardView) and the MCP tools land next; this
// file owns everything else. See docs/CONSUMABLES_PLAN.md.

@MainActor
enum IntakePlugin: SectionPlugin {
  static var producesTimedEvents: Bool { true }

  static var manifest: SectionManifest { SectionManifest.byKey["intake"]! }

  // Intake has no single "whole section" screen: each kind is surfaced as its
  // own dashboard tile that opens straight into IntakeKindPageView, and the
  // empty state opens the create-tracker wizard. So there's no host destination
  // (no redundant kind-switcher list) — management lives in detailPaneContent().
  static func destinationView() -> AnyView? { nil }

  // No log flourish: intake is a high-frequency tracker, so each log confirms
  // with a light tick + announce only (SectionLog.quietLog in IntakeKindPageView
  // and the Next nudge), like Hydration. Fullscreen flourishes are reserved for
  // once-a-day "moment" celebrations. Per-kind stored flourish tokens are dormant.

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    // Only seed-bearing templates are multi-selectable; the blank "Custom"
    // choice (seed == nil) is an action that opens the full wizard, handled
    // by the bespoke row in `extraSections`.
    let templates = IntakeTemplates.all.filter { $0.seed != nil }
    let custom = IntakeTemplates.all.filter { $0.seed == nil }
    return AnyView(SectionOnboarding(
      sectionKey: "intake",
      intro: "Track what you consume — and what you want to cut back on. Each tracker keeps its own methods and doses, and a days-since-last streak for the ones you're reducing. Start with a template or build your own.",
      bullets: [],
      nounPlural: "",
      footer: String(localized: "Start with a template or build your own — edit anytime."),
      groups: [StarterGroup(header: String(localized: "Templates"), items: templates)],
      glyph: { .symbol($0.symbol) },
      primary: { $0.title },
      secondary: { $0.subtitle },
      existsKey: { AnyHashable($0.seed?.id ?? $0.id) },
      loadExistingKeys: {
        await MirrorReader.shared.read { ctx in
          Set(((try? ctx.fetch(FetchDescriptor<IntakeKindEntity>())) ?? [])
            .map { AnyHashable($0.id) })
        }
      },
      add: { items in
        let mutator = SeptenaServices.shared.intakeMutator
        for choice in items { if let seed = choice.seed { mutator.upsertKind(seed: seed) } }
      },
      complete: complete,
      extraSections: {
        Section {
          ForEach(custom) { choice in
            IntakeCustomStarterRow(choice: choice, onCreated: complete)
          }
        }
      }
    ))
  }

  static func detailPaneContent() -> AnyView? { AnyView(IntakeDetailContent()) }

  // MARK: - Import / Export
  //
  // Three tables: the user's trackers (kinds) carry their full config —
  // including the decoded method rows so a round-trip rebuilds the quick-add
  // menus — their variety catalog (items), and the event stream. Archived
  // rows are included (export is a backup, not a view filter).

  static var exportContribution: SectionExportContribution? {
    SectionExportContribution(
      tables: [
        SchemaTable(name: "intakeKind", purpose: "a user-defined consumable tracker", fields: [
          .req("id", "string", "opaque \"ik-<uuid>\", never the name"),
          .req("name", "string"), .req("symbol", "string", "SF Symbol"),
          .opt("color", "string", "hex/hsl token"),
          .opt("sortIndex", "int"),
          .opt("unit", "string", "g | mg | ml"),
          .req("doseStyle", "string", "amount | count | both | none"),
          .opt("countNoun", "string", "hit | cup | puff"),
          .opt("containerNoun", "string", "capsule | pack"),
          .opt("containerCap", "int", "uses per container; omit for no container model"),
          .opt("catalogNoun", "string", "Beans | Strains"),
          .opt("flourish", "string", "motion token"),
          .req("metricMode", "string", "countEvents | sumAmount"),
          .req("objective", "string", "log | limit | reduce | quit"),
          .opt("methods", "array", "method rows: { token, label, emoji?, defaultAmount?, usesContainer }"),
          .opt("templateID", "string"),
          .opt("archivedAt", "timestamp"),
        ]),
        SchemaTable(name: "intakeItem", purpose: "a variety in a tracker's catalog", fields: [
          .req("id", "string"), .req("kindID", "string", "→ intakeKind.id"),
          .req("name", "string"), .opt("emoji", "string", "user glyph"),
          .opt("sortIndex", "int"),
          .opt("archivedAt", "timestamp"),
        ]),
        SchemaTable(name: "intakeEvent", purpose: "a single logged consumption event", fields: [
          .req("id", "string"), .req("kindID", "string", "→ intakeKind.id"),
          .req("date", "date"), .opt("occurredAt", "timestamp"),
          .req("method", "string", "stable token from the kind's method rows"),
          .opt("itemID", "string", "→ intakeItem.id"),
          .opt("amount", "double", "in the kind's unit"),
          .opt("count", "int", "hits/uses; container math reads this"),
          .opt("note", "string"),
        ]),
      ],
      collect: { ctx in
        let kinds  = try ctx.fetch(FetchDescriptor<IntakeKindEntity>())
        let items  = try ctx.fetch(FetchDescriptor<IntakeItemEntity>())
        let events = try ctx.fetch(FetchDescriptor<IntakeEventEntity>())
        return [
          "intakeKind":  kinds.map(intakeKindExportDict),
          "intakeItem":  items.map(intakeItemExportDict),
          "intakeEvent": events.map(intakeEventExportDict),
        ]
      }
    )
  }

  // MARK: - MCP / agent contract
  //
  // Deliberately a META-protocol: this text ships in the binary and the
  // gateway skill.md, so it never names substances — the user's tracker
  // names are user data, resolved live via intake_kinds_list.

  static var mcpSkill: SectionSkill? {
    SectionSkill(
      key: "intake",
      summary: "User-defined consumable trackers (coffee, tea, anything) — log events, manage varieties, and help the user stay under limits or cut back.",
      tools: [
        SectionSkill.Tool("intake_kinds_list", "The user's trackers with FULL config (methods + tokens, units, container state, counts). Call this first",
              inputs: "optional: includeArchived"),
        SectionSkill.Tool("intake_event_log", "Log an event against a tracker",
              inputs: "required: kind (id or name), method (token or label) · optional: date, time, amount, count, item, note"),
        SectionSkill.Tool("intake_events_list", "One tracker's events. Defaults to last 7 days",
              inputs: "required: kind · optional: date, from, to, limit"),
        SectionSkill.Tool("intake_event_delete", "Remove an event (correction)",
              inputs: "required: id"),
        SectionSkill.Tool("intake_kind_create", "Create a tracker — name alone works; every axis editable later",
              inputs: "required: name · optional: symbol, color, unit, doseStyle (none|amount|count|both), countNoun, containerNoun, containerCap, catalogNoun, objective (log|limit|reduce|quit), target, weekly, methods[]"),
        SectionSkill.Tool("intake_kind_update", "Edit config, archive/unarchive, or change the objective goal",
              inputs: "required: kind · optional: any config field, archived, target, weekly"),
        SectionSkill.Tool("intake_items_list", "A tracker's variety catalog", inputs: "required: kind"),
        SectionSkill.Tool("intake_item_create", "Add a variety", inputs: "required: kind, name · optional: emoji"),
        SectionSkill.Tool("intake_item_delete", "Remove a variety", inputs: "required: id"),
      ],
      body: """
      ### Protocol
      Trackers are user-defined — names, methods, and varieties are the user's \
      own vocabulary. Resolve first, then act:
      ```
      intake_kinds_list()                          → find the tracker + its method tokens
      intake_event_log(kind: <name>, method: <token>, count: 2)
      ```
      A failed kind/method/item lookup returns the candidates inline — retry \
      with one of them.

      ### Container trackers
      A kind with `containerCap` models "a container holds N uses" (a capsule, \
      a pack). `lastContainerCountToday` tells you the current use number: log \
      `count: lastContainerCountToday + 1` to continue, `count: 1` for a fresh \
      container.

      ### Objectives
      Each tracker carries an objective — log | limit | reduce | quit — wired \
      to a real goal (`target`, optional `weekly`). For reduce/quit, days-since-\
      last is the streak that matters; prefer encouragement framing when the \
      user is abstaining.
      """
    )
  }

  // MARK: - Aim metrics (per kind, runtime-generated)

  static func aimMetrics(context: ModelContext) -> [GoalMetric] {
    let kinds = (try? context.fetch(FetchDescriptor<IntakeKindEntity>())) ?? []
    return kinds.filter { $0.archivedAt == nil }.flatMap { k -> [GoalMetric] in
      let countUnit = k.countNoun.map { $0.lowercased() + "s" } ?? "entries"
      var metrics: [GoalMetric] = [
        GoalMetric(key: "intake.\(k.id).count",
                   label: "\(k.name) (today)", sectionKey: "intake",
                   window: "today", unitLabel: countUnit),
        GoalMetric(key: "intake.\(k.id).count_week",
                   label: "\(k.name) (this week)", sectionKey: "intake",
                   window: "calendarWeek", unitLabel: countUnit),
        // The reduction/abstinence shape — "days since last" — matters for the
        // half of plausible kinds users track to do *less* of (study §4).
        GoalMetric(key: "intake.\(k.id).days_since_last",
                   label: "\(k.name): days since last", sectionKey: "intake",
                   window: "today", unitLabel: "days"),
      ]
      if k.metricMode == "sumAmount", let unit = k.unit {
        metrics.append(GoalMetric(key: "intake.\(k.id).sum_amount",
                                  label: "\(k.name) total (today)", sectionKey: "intake",
                                  window: "today", unitLabel: unit))
        metrics.append(GoalMetric(key: "intake.\(k.id).sum_amount_week",
                                  label: "\(k.name) total (this week)", sectionKey: "intake",
                                  window: "calendarWeek", unitLabel: unit))
      }
      return metrics
    }
  }

  static func evaluateAim(metric: GoalMetric, context: ModelContext, now: Date) -> Double? {
    // key = "intake.<kindID>.<suffix>"; kind ids are opaque (ik-<uuid>, no dots).
    let parts = metric.key.split(separator: ".")
    guard parts.count >= 3, parts[0] == "intake" else { return nil }
    let kindID = String(parts[1])
    let suffix = parts.dropFirst(2).joined(separator: ".")

    switch suffix {
    case "count", "count_week", "sum_amount", "sum_amount_week":
      guard let (startStr, endStr) = GoalMetricWindow.dateStringRange(for: metric.window, now: now) else { return 0 }
      let rows = (try? context.fetch(FetchDescriptor<IntakeEventEntity>(
        predicate: #Predicate { $0.kindID == kindID && $0.date >= startStr && $0.date <= endStr }
      ))) ?? []
      if suffix.hasPrefix("sum_amount") { return rows.compactMap(\.amount).reduce(0, +) }
      return Double(rows.count)

    case "days_since_last":
      let rows = (try? context.fetch(FetchDescriptor<IntakeEventEntity>(
        predicate: #Predicate { $0.kindID == kindID },
        sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
      ))) ?? []
      guard let last = rows.first else { return nil }  // never logged → no reading
      let cal = Calendar.current
      let days = cal.dateComponents([.day],
                                    from: cal.startOfDay(for: last.occurredAt),
                                    to: cal.startOfDay(for: now)).day ?? 0
      return Double(max(0, days))

    default:
      return nil
    }
  }

  /// Per-kind daily correlation signals — the generic successor to the old
  /// static per-substance features. Every active tracker contributes an
  /// events/day lever; amount-tracking kinds add a dose/day lever. The smart
  /// engine auto-pairs these against outcomes (sleep, readiness, …), so a
  /// user's "matcha" or "nicotine" tracker correlates with no engine edit.
  static func correlationFeatures(context: ModelContext) -> [CorrelationFeature] {
    let kinds = ((try? context.fetch(FetchDescriptor<IntakeKindEntity>())) ?? [])
      .filter { $0.archivedAt == nil }
    guard !kinds.isEmpty else { return [] }
    let events = (try? context.fetch(FetchDescriptor<IntakeEventEntity>())) ?? []
    guard !events.isEmpty else { return [] }
    let byKind = Dictionary(grouping: events, by: \.kindID)

    return kinds.flatMap { k -> [CorrelationFeature] in
      let evs = byKind[k.id] ?? []
      guard !evs.isEmpty else { return [] }

      var countSeries: [String: Double] = [:]
      for e in evs { countSeries[e.date, default: 0] += 1 }
      var out = [CorrelationFeature(
        key: "intake_\(k.id)_count",
        label: "\(k.name) \(k.countNoun.map { $0.lowercased() + "s" } ?? "count")",
        section: "intake",
        unit: "",
        role: .lever,
        distribution: .count,
        series: countSeries)]

      if k.metricMode == "sumAmount", let unit = k.unit {
        var amountSeries: [String: Double] = [:]
        var any = false
        for e in evs { if let a = e.amount { amountSeries[e.date, default: 0] += a; any = true } }
        if any {
          out.append(CorrelationFeature(
            key: "intake_\(k.id)_amount",
            label: "\(k.name) \(unit)",
            section: "intake",
            unit: unit,
            role: .lever,
            distribution: .continuous,
            series: amountSeries))
        }
      }
      return out
    }
  }
}

// MARK: - Entity → export dict mappers
//
// Mirror NutritionPlugin's helpers: top-level, @MainActor, compaction +
// isoDate shared from ImportExportService. Keep in sync with the SchemaTable
// fields above — add a field there, map it here.

@MainActor func intakeKindExportDict(_ k: IntakeKindEntity) -> [String: Any] {
  compact([
    "id": k.id, "name": k.name, "symbol": k.symbol, "color": k.color,
    "sortIndex": k.sortIndex, "unit": k.unit, "doseStyle": k.doseStyle,
    "countNoun": k.countNoun, "containerNoun": k.containerNoun,
    "containerCap": k.containerCap, "catalogNoun": k.catalogNoun,
    "flourish": k.flourish, "metricMode": k.metricMode,
    "objective": k.objective,
    "methods": k.methods.map(intakeMethodExportDict),
    "templateID": k.templateID,
    "archivedAt": k.archivedAt.map(isoDate),
    "updatedAt": isoDate(k.updatedAt),
  ])
}

@MainActor func intakeMethodExportDict(_ m: IntakeMethodRow) -> [String: Any] {
  compact([
    "token": m.token, "label": m.label, "emoji": m.emoji,
    "defaultAmount": m.defaultAmount, "usesContainer": m.usesContainer,
  ])
}

@MainActor func intakeItemExportDict(_ i: IntakeItemEntity) -> [String: Any] {
  compact([
    "id": i.id, "kindID": i.kindID, "name": i.name, "emoji": i.emoji,
    "sortIndex": i.sortIndex,
    "archivedAt": i.archivedAt.map(isoDate),
    "updatedAt": isoDate(i.updatedAt),
  ])
}

@MainActor func intakeEventExportDict(_ e: IntakeEventEntity) -> [String: Any] {
  compact([
    "id": e.id, "kindID": e.kindID, "date": e.date,
    "occurredAt": isoDate(e.occurredAt),
    "method": e.method, "itemID": e.itemID,
    "amount": e.amount, "count": e.count, "note": e.note,
    "updatedAt": isoDate(e.updatedAt),
  ])
}

// The blank "Custom" onboarding choice: not a multi-select template but an
// action that opens the full kind wizard. Lives in its own view so its sheet
// state survives, and the `.sheet` hangs off the concrete Button (a sheet on
// a structural Form element mis-anchors — see commit 736b937).
private struct IntakeCustomStarterRow: View {
  let choice: IntakeTemplates.Choice
  let onCreated: () -> Void
  @Environment(SectionTheme.self) private var theme
  @State private var customizing = false

  private var accent: Color { theme.color(for: "intake") }

  var body: some View {
    Button { customizing = true } label: {
      HStack(spacing: 12) {
        Image(systemName: choice.symbol).frame(width: 26).foregroundStyle(accent)
        VStack(alignment: .leading, spacing: 1) {
          Text(choice.title).foregroundStyle(.primary)
          Text(choice.subtitle).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
      }
    }
    .buttonStyle(.plain)
    .sheet(isPresented: $customizing) {
      // Creating the kind finishes onboarding; cancelling returns to the picker.
      IntakeKindWizard(onCreated: { _ in onCreated() })
    }
  }
}

// MARK: - Settings detail pane (tracker manager)

/// Section-style tracker manager for the Settings detail pane: each kind reads
/// like a section row (its own colored glyph), taps into its identity/Manage
/// sheet, archives via its context menu, and unarchives from the Archived group. Kinds are
/// presented as sections in the UX while staying rows under the host section
/// (Option C — presentation layer). See docs/CONSUMABLES_PLAN.md.
private struct IntakeDetailContent: View {
  @State private var kinds: [IntakeKindDTO] = []
  @State private var managingID: String? = nil
  @State private var creating = false

  private var mutator: IntakeMutator { SeptenaServices.shared.intakeMutator }
  private var active: [IntakeKindDTO] { kinds.filter { !$0.archived } }
  private var archived: [IntakeKindDTO] { kinds.filter { $0.archived } }

  var body: some View {
    Group {
      Section("Trackers") {
        ForEach(active) { kind in
          Button { managingID = kind.id } label: { kindRow(kind) }
            .buttonStyle(.plain)
            .contextMenu {
              Button(role: .destructive) {
                mutator.setKindArchived(id: kind.id, archived: true)
                Task { await reload() }
              } label: { Label("Archive", systemImage: "archivebox") }
            }
        }
        Button { creating = true } label: {
          Label("Add tracker…", systemImage: "plus")
        }
        // Both management sheets hang off this always-present Button leaf, not
        // the enclosing Group/Section. A sheet anchored on a structural Form
        // element mis-anchors and self-presents/dismisses on the appear/layout
        // pass. See the sibling fix in SupplementsPlugin (commit 736b937).
        .sheet(item: managingBinding) { id in IntakeManageSheet(kindID: id.value) }
        .sheet(isPresented: $creating) {
          IntakeKindWizard(onCreated: { _ in Task { await reload() } })
        }
      }
      if !archived.isEmpty {
        Section("Archived") {
          ForEach(archived) { kind in
            HStack {
              kindRow(kind).opacity(0.5)
              Spacer()
              Button("Restore") {
                mutator.setKindArchived(id: kind.id, archived: false)
                Task { await reload() }
              }
              .font(.caption)
            }
          }
        }
      }
    }
    .task { await reload() }
  }

  private func kindRow(_ kind: IntakeKindDTO) -> some View {
    Label {
      HStack {
        Text(kind.name)
        Spacer()
        Text(kind.eventCount == 1 ? "1 entry" : "\(kind.eventCount) entries")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } icon: {
      SectionGlyph(icon: kind.symbol,
                   accent: AdaptiveColor.adaptive(kind.color) ?? .secondary,
                   size: 29, glyphRatio: 0.38)
    }
  }

  // Identifiable wrapper so `.sheet(item:)` drives the Manage sheet off a kind id.
  private struct ManagedKind: Identifiable { let value: String; var id: String { value } }
  private var managingBinding: Binding<ManagedKind?> {
    Binding(get: { managingID.map(ManagedKind.init) },
            set: { managingID = $0?.value })
  }

  private func reload() async {
    kinds = await MirrorReader.shared.read { IntakeReader.loadAllKinds(context: $0) }
  }
}
