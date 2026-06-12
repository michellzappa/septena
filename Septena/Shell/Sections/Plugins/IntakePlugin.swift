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

  static func destinationView() -> AnyView? { AnyView(IntakeDestinationView()) }

  // The host has no quick-log of its own — quick-add is per kind (each kind page
  // builds its own container-aware menu). Keeping this empty avoids duplicating
  // those actions on every kind page (SectionDrawer appends plugin.logActions).
  static var logActions: [LogAction] { [] }

  // Crisp snap for every tracker log (see IntakeKindPageView.motion(for:),
  // which renders it in-page — on iPhone the kind page is a sheet, above
  // the root overlay). Per-kind stored flourish tokens are dormant.
  static var logFlourish: LogFlourish? { LogFlourish(motion: .snap) }

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(IntakeOnboardingView(complete: complete))
  }

  static func detailPaneContent() -> AnyView? { AnyView(IntakeDetailContent()) }

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
        SectionSkill.Tool("intake_item_create", "Add a variety", inputs: "required: kind, name"),
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

  static func evaluateAim(metric: GoalMetric, context: ModelContext) -> Double? {
    // key = "intake.<kindID>.<suffix>"; kind ids are opaque (ik-<uuid>, no dots).
    let parts = metric.key.split(separator: ".")
    guard parts.count >= 3, parts[0] == "intake" else { return nil }
    let kindID = String(parts[1])
    let suffix = parts.dropFirst(2).joined(separator: ".")

    switch suffix {
    case "count", "count_week", "sum_amount", "sum_amount_week":
      guard let (startStr, endStr) = GoalMetricWindow.dateStringRange(for: metric.window) else { return 0 }
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
                                    to: cal.startOfDay(for: Date())).day ?? 0
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

// MARK: - First-enable onboarding (template picker)

private struct IntakeOnboardingView: View {
  let complete: () -> Void
  @Environment(SectionTheme.self) private var theme
  @State private var selected: Set<String> = []
  @State private var existingIDs: Set<String> = []
  @State private var customizing = false

  private var accent: Color { theme.color(for: "intake") }
  private var mutator: IntakeMutator { SeptenaServices.shared.intakeMutator }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          SectionOnboardingHero(
            sectionKey: "intake",
            title: "Intake",
            intro: "Track what you consume — and what you want to cut back on. Each tracker keeps its own methods and doses, and a days-since-last streak for the ones you're reducing. Start with a template or build your own."
          )
          .onboardingHeroSection()
        }
        Section("Templates") {
          ForEach(IntakeTemplates.all) { templateRow($0) }
        }
      }
      .formStyle(.grouped)
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .safeAreaInset(edge: .bottom) { bottomBar }
      .task { await loadExisting() }
      .sheet(isPresented: $customizing) {
        // A blank kind from the full wizard. Creating it finishes onboarding;
        // cancelling returns to the template picker.
        IntakeKindWizard(onCreated: { _ in complete() })
      }
    }
  }

  @ViewBuilder
  private func templateRow(_ choice: IntakeTemplates.Choice) -> some View {
    // Custom has no seed — it's an action that opens the full wizard, not a
    // multi-select template. (Selecting it in a checklist did nothing — the bug.)
    if choice.seed == nil {
      customRow(choice)
    } else {
      selectableRow(choice)
    }
  }

  private func customRow(_ choice: IntakeTemplates.Choice) -> some View {
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
  }

  @ViewBuilder
  private func selectableRow(_ choice: IntakeTemplates.Choice) -> some View {
    let exists = choice.seed.map { existingIDs.contains($0.id) } ?? false
    let isSelected = selected.contains(choice.id)
    Button {
      guard !exists else { return }
      if isSelected { selected.remove(choice.id) } else { selected.insert(choice.id) }
    } label: {
      HStack(spacing: 12) {
        Image(systemName: choice.symbol)
          .frame(width: 26)
          .foregroundStyle(exists ? .secondary : accent)
        VStack(alignment: .leading, spacing: 1) {
          Text(choice.title).foregroundStyle(exists ? .secondary : .primary)
          Text(choice.subtitle).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if exists {
          Text("Already added").font(.caption).foregroundStyle(.secondary)
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
    let seedCount = selected.filter { id in
      IntakeTemplates.all.first { $0.id == id }?.seed != nil
    }.count
    return seedCount == 0 ? String(localized: "Done") : String(localized: "Add \(seedCount)")
  }

  private func addAndFinish() {
    for choice in IntakeTemplates.all where selected.contains(choice.id) {
      if let seed = choice.seed, !existingIDs.contains(seed.id) {
        mutator.upsertKind(seed: seed)
      }
    }
    complete()
  }

  private func loadExisting() async {
    existingIDs = await MirrorReader.shared.read { ctx in
      Set(((try? ctx.fetch(FetchDescriptor<IntakeKindEntity>())) ?? []).map(\.id))
    }
  }
}

// MARK: - Settings detail pane (tracker manager)

/// Section-style tracker manager for the Settings detail pane: each kind reads
/// like a section row (its own colored glyph), taps into its identity/Manage
/// sheet, archives by swipe, and unarchives from the Archived group. Kinds are
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
            .swipeActions {
              Button(role: .destructive) {
                mutator.setKindArchived(id: kind.id, archived: true)
                Task { await reload() }
              } label: { Label("Archive", systemImage: "archivebox") }
            }
        }
        Button { creating = true } label: {
          Label("Add tracker…", systemImage: "plus")
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
    .sheet(item: managingBinding) { id in IntakeManageSheet(kindID: id.value) }
    .sheet(isPresented: $creating) {
      IntakeKindWizard(onCreated: { _ in Task { await reload() } })
    }
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
