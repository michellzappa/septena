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

  static var logFlourish: LogFlourish? { LogFlourish(motion: .bloom) }

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(IntakeOnboardingView(complete: complete))
  }

  static func detailPaneContent() -> AnyView? { AnyView(IntakeDetailContent()) }

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
