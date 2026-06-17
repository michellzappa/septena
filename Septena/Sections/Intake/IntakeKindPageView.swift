import SwiftUI
import SwiftData

// One intake kind's page — the per-substance feel under the single host
// section (Option C). Stat strip + day list + container-aware quick-add,
// parameterized entirely by the kind's config. The container math is shared
// with the watch via ConsumableContainer; the accent is the kind's own color
// (not SectionTheme — one section = one SectionEntity). See docs/CONSUMABLES_PLAN.md.

struct IntakeKindPageView: View {
  let kindID: String

  @Environment(DayClock.self) private var clock

  @State private var kind: IntakeKindDTO? = nil
  @State private var entries: [IntakeEntryDTO] = []
  @State private var itemNames: [String: String] = [:]
  @State private var lastContainerCount: Int? = nil
  @State private var lastEventAt: Date? = nil
  /// Trailing-7-day event instants for the rhythm wheel (see `rhythmSection`).
  @State private var weekPoints: [IntakeReader.IntakeInstant] = []
  /// Event dates over the trailing ~17 weeks for the frequency heatmap.
  @State private var freqDates: [String] = []
  @State private var loading = true
  @State private var viewingDate: String = SeptenaDate.today
  @State private var editing: IntakeEntryDTO? = nil
  @State private var creatingMethod: PresetMethod? = nil
  @State private var managing = false
  /// The quick-log chooser sheet (nutrition pattern): the drawer's single big
  /// "+" opens it; the container-aware choices live inside, so the toolbar
  /// control stays the prominent accent circle instead of a multi-action Menu.
  @State private var quickLogging = false
  /// The choice picked in the quick-log sheet, dispatched in its `onDismiss` so
  /// any follow-on sheet (method detail / Manage) presents cleanly after the
  /// chooser has dismissed rather than racing it.
  @State private var pendingChoice: String? = nil
  // Intake is an editable dual section: Log = stat strip + the day's entries
  // (time-travelable); Patterns = the rhythm wheel. Remembered PER KIND — every
  // tracker page shares sectionKey "intake" but keeps its own mode. Default Log.
  @State private var mode: DrawerMode
  /// Whether the one-shot empty-state nudge has run for this appearance.
  @State private var didNudge = false

  init(kindID: String) {
    self.kindID = kindID
    _mode = State(initialValue: .remembered(for: "intake.\(kindID)", default: .log))
  }

  private struct PresetMethod: Identifiable, Hashable {
    let method: String
    var id: String { method }
  }

  private var mutator: IntakeMutator { SeptenaServices.shared.intakeMutator }
  private var accent: Color { kind.flatMap { AdaptiveColor.adaptive($0.color) } ?? Color.accentColor }

  var body: some View {
    SectionDrawer(sectionKey: "intake",
                  title: kind?.name ?? "Tracker",
                  accent: accent,
                  quickAdd: DrawerQuickAdd("Log \(kind?.name ?? "")") { quickLogging = true },
                  currentDate: $viewingDate,
                  mode: $mode,
                  modeStorageKey: "intake.\(kindID)",
                  showsSettingsLink: false,
                  log: {
      DrawerSection("Log", padding: .none) {
        if !entries.isEmpty {
          ForEach(entries.reversed()) { entry in
            LogEntryRow(
              title: methodLabel(entry.method),
              detail: detailLine(entry),
              trailing: entry.time,
              accessory: capsuleAccessory(entry),
              tint: accent,
              isSelected: editing?.id == entry.id,
              onEdit: { editing = entry },
              onDelete: { delete(entry) }
            )
          }
        } else if !loading {
          Text("Nothing logged yet.")
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
      }
    }, patterns: {
      EventFrequencySection(
        title: "How often", accent: accent, dates: freqDates,
        emptyText: loading ? nil : "Log a few and a daily-frequency heatmap appears here.")
      rhythmSection
    })
    .tint(accent)
    .sectionReload(on: viewingDate, onDataChange: true,
                   forSections: ["intake"]) { await reload() }
    .sheet(isPresented: $managing) {
      IntakeManageSheet(kindID: kindID)
    }
    .adaptiveDetail(item: $editing) { entry in
      EditIntakeEntrySheet(kindID: kindID, date: viewingDate, original: entry,
                           onSave: { Task { await reload() } })
    }
    .sheet(item: $creatingMethod) { preset in
      EditIntakeEntrySheet(kindID: kindID, date: viewingDate, original: nil,
                           presetMethod: preset.method,
                           onSave: { Task { await reload() } })
    }
    // The quick-log chooser. A pick is recorded and the sheet dismissed; the
    // actual log / Manage runs in onDismiss so any follow-on sheet presents
    // after this one is gone (no sheet-over-sheet race on iPhone).
    .sheet(isPresented: $quickLogging, onDismiss: {
      if let id = pendingChoice { pendingChoice = nil; handleLogAction(id) }
    }) {
      IntakeQuickLogSheet(kindName: kind?.name ?? "Tracker",
                          accent: accent,
                          choices: quickChoices,
                          onPick: { id in pendingChoice = id; quickLogging = false })
    }
  }

  // MARK: Quick-add

  /// Container-aware choices shown inside the quick-log sheet, built from the
  /// kind's methods exactly as the watch will from the wire. Plus a Manage row.
  private var quickChoices: [LogAction] {
    guard let kind else { return [] }
    let methods = kind.methods.map {
      ConsumableContainer.Method(token: $0.token, label: $0.label,
                                 symbol: $0.symbol, usesContainer: $0.usesContainer)
    }
    let choices = ConsumableContainer.choices(
      lastCount: lastContainerCount,
      containerCap: kind.containerCap,
      containerNoun: kind.containerNoun ?? "container",
      countNoun: kind.countNoun ?? "use",
      methods: methods)
    var actions = choices.map {
      LogAction(id: "log:\($0.value)", title: $0.label, systemImage: $0.symbol ?? "plus")
    }
    actions.append(LogAction(id: "manage", title: "Manage \(kind.name)",
                             systemImage: "slider.horizontal.3"))
    return actions
  }

  private func handleLogAction(_ id: String) {
    if id == "manage" { managing = true; return }
    guard let kind, id.hasPrefix("log:") else { return }
    let value = String(id.dropFirst("log:".count))
    let (token, count) = ConsumableContainer.parse(value: value)
    let method = kind.methods.first { $0.token == token }

    // A container choice carries an explicit count → log it directly (the fast
    // path). A plain method tap opens the sheet when the kind needs more input
    // (amount / count / a catalog item); a bare "just log it" kind logs directly.
    let needsInput = kind.showsAmount || kind.showsCount || kind.hasCatalog
    if count != nil || !needsInput {
      let amount = kind.showsAmount ? method?.defaultAmount : nil
      // Intake is a quiet, high-frequency log: it confirms with a light tick +
      // VoiceOver only, no fullscreen flourish (those are reserved for
      // once-a-day "moment" celebrations).
      SectionLog.quietLog(announce: "Logged \(kind.name).") {
        mutator.addEntry(kindID: kindID,
                         date: viewingDate,
                         time: EventTimestamp.hhmm(from: nowInstant),
                         method: token, amount: amount, count: count)
      }
      Task { await reload() }
    } else {
      creatingMethod = .init(method: token)
    }
  }

  private var nowInstant: Date {
    SeptenaDate.parse(viewingDate).map { _ in Date() } ?? Date()
  }

  // MARK: Rows

  // MARK: Rhythm wheel
  //
  // A 24-hour dial of *when* this tracker lands over the trailing 7 days, faded
  // by recency (shared `TimeOfDayWheel`, same as the old consumable
  // drawers). Only on today and only with enough events to read a pattern.

  private var isViewingToday: Bool { viewingDate == SeptenaDate.today }

  private var todayStart: Date {
    SeptenaDate.parse(clock.today).map { Calendar.current.startOfDay(for: $0) }
      ?? Calendar.current.startOfDay(for: clock.now)
  }

  private var nowFraction: Double {
    let c = Calendar.current.dateComponents([.hour, .minute], from: clock.now)
    return (Double(c.hour ?? 0) * 60 + Double(c.minute ?? 0)) / 1440
  }

  private var wheelEvents: [TimeOfDayWheel.Event] {
    let start = todayStart
    return weekPoints.compactMap {
      TimeOfDayWheel.Event(id: $0.id, occurredAt: $0.at, todayStart: start, windowDays: 7)
    }
  }

  @ViewBuilder
  private var rhythmSection: some View {
    let events = wheelEvents
    if events.count >= 3, let kind {
      DrawerSection("When you reach for \(kind.name)", padding: .tight) {
        TimeOfDayWheel(events: events, accent: accent, windowDays: 7, nowFraction: nowFraction)
          .frame(maxWidth: .infinity)
      }
    } else if !loading {
      DrawerSection("Rhythm") {
        Text("Not enough logged yet to read a rhythm — keep at it and a 7-day pattern shows here.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func methodLabel(_ token: String) -> String {
    kind?.methods.first { $0.token == token }?.label ?? token.capitalized
  }

  /// True when this entry's method consumes the container (so its count is a
  /// capsule slot number rather than a free count).
  private func isContainerEntry(_ e: IntakeEntryDTO) -> Bool {
    kind?.containerCap != nil
      && kind?.methods.first(where: { $0.token == e.method })?.usesContainer == true
      && e.count != nil
  }

  private func detailLine(_ e: IntakeEntryDTO) -> String? {
    var parts: [String] = []
    if let itemID = e.itemID, let name = itemNames[itemID], !name.isEmpty { parts.append(name) }
    // Container entries show their count as capsule slots (the accessory); only
    // non-container counts read as text here.
    if let n = e.count, !isContainerEntry(e) { parts.append("\(kind?.countNoun ?? "use") \(n)") }
    if let a = e.amount { parts.append("\(a.decimalString(1))\(kind?.unit ?? "")") }
    if let note = e.note, !note.isEmpty { parts.append(note) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// Capsule-slots accessory: the shared `ProjectProgressIcon` ring filled to
  /// `count / cap` plus an "N/cap" caption — the modern take on the container
  /// accessory's old `●●○` hit dots, for any container tracker.
  private func capsuleAccessory(_ e: IntakeEntryDTO) -> AnyView? {
    guard isContainerEntry(e), let cap = kind?.containerCap, let count = e.count else { return nil }
    return AnyView(
      HStack(spacing: 5) {
        ProjectProgressIcon(progress: Double(count) / Double(max(cap, 1)), tint: accent)
        Text("\(count)/\(cap)")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    )
  }

  private func delete(_ entry: IntakeEntryDTO) {
    mutator.deleteEntry(id: entry.id)
    Task { await reload() }
    Haptics.warning()
  }

  // MARK: Load

  private func reload() async {
    let id = kindID
    let date = viewingDate
    // The wheel's window is the trailing 7 days from *today* (not the viewing
    // date), so compute it on the main actor from the day clock before the read.
    let weekStart = Calendar.current.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
    // Frequency heatmap window — trailing ~17 weeks. `weekInstants` just filters
    // by `since`, so a 119-day floor reuses it for the full history pull.
    let histStart = Calendar.current.date(byAdding: .day, value: -118, to: todayStart) ?? todayStart
    let bundle = await MirrorReader.shared.read { ctx -> PageBundle in
      let kind = IntakeReader.loadKind(context: ctx, id: id)
      let entries = IntakeReader.loadDay(context: ctx, kindID: id, date: date)
      let items = IntakeReader.loadItems(context: ctx, kindID: id)
      var last: Int? = nil
      if let token = kind?.methods.first(where: { $0.usesContainer })?.token {
        last = IntakeReader.lastContainerCount(context: ctx, kindID: id,
                                               containerToken: token, date: date)
      }
      let lastAt = IntakeReader.lastEventInstant(context: ctx, kindID: id)
      let week = IntakeReader.weekInstants(context: ctx, kindID: id, since: weekStart)
      let hist = IntakeReader.weekInstants(context: ctx, kindID: id, since: histStart)
        .compactMap { SeptenaDate.format($0.at) }
      return PageBundle(kind: kind, entries: entries, items: items,
                        lastContainerCount: last, lastEventAt: lastAt,
                        weekPoints: week, freqDates: hist)
    }
    kind = bundle.kind
    entries = bundle.entries
    itemNames = Dictionary(uniqueKeysWithValues: bundle.items.map { ($0.id, $0.name) })
    lastContainerCount = bundle.lastContainerCount
    lastEventAt = bundle.lastEventAt
    weekPoints = bundle.weekPoints
    freqDates = bundle.freqDates
    loading = false
    applyEmptyStateNudgeIfNeeded()
  }

  private func applyEmptyStateNudgeIfNeeded() {
    DrawerMode.nudgeEmptyDayToPatterns(mode: $mode, didNudge: $didNudge,
                                       isViewingToday: isViewingToday,
                                       isEmpty: entries.isEmpty)
  }

  private struct PageBundle: Sendable {
    let kind: IntakeKindDTO?
    let entries: [IntakeEntryDTO]
    let items: [IntakeItemDTO]
    let lastContainerCount: Int?
    let lastEventAt: Date?
    let weekPoints: [IntakeReader.IntakeInstant]
    let freqDates: [String]
  }
}

/// The intake quick-log chooser — the sheet the per-kind drawer's single "+"
/// circle opens (the Nutrition pattern). Lists the container-aware log choices,
/// with the Manage row split into its own footer section. Picking a row hands
/// its id back to the page, which logs it (or opens the method-detail sheet).
private struct IntakeQuickLogSheet: View {
  let kindName: String
  let accent: Color
  let choices: [LogAction]
  let onPick: (String) -> Void
  @Environment(\.dismiss) private var dismiss

  private var logChoices: [LogAction] { choices.filter { $0.id != "manage" } }
  private var manage: LogAction? { choices.first { $0.id == "manage" } }

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(logChoices) { choice in
            Button { onPick(choice.id) } label: {
              Label(choice.title, systemImage: choice.systemImage ?? "plus")
            }
          }
        }
        if let manage {
          Section {
            Button { onPick(manage.id) } label: {
              Label(manage.title, systemImage: manage.systemImage ?? "slider.horizontal.3")
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      .tint(accent)
      .navigationTitle("Log \(kindName)")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      }
    }
    .presentationDetents([.medium, .large])
  }
}
