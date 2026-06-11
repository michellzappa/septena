import SwiftUI
import SwiftData

// One intake kind's page — the per-substance feel under the single host
// section (Option C). Stat strip + day list + container-aware quick-add,
// parameterized entirely by the kind's config. The container math is shared
// with the watch via ConsumableContainer; the accent is the kind's own color
// (not SectionTheme — one section = one SectionEntity). See docs/CONSUMABLES_PLAN.md.

struct IntakeKindPageView: View {
  let kindID: String

  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?
  @Environment(DayClock.self) private var clock

  @State private var kind: IntakeKindDTO? = nil
  @State private var entries: [IntakeEntryDTO] = []
  @State private var itemNames: [String: String] = [:]
  @State private var lastContainerCount: Int? = nil
  @State private var lastEventAt: Date? = nil
  /// Trailing-7-day event instants for the rhythm wheel (see `rhythmSection`).
  @State private var weekPoints: [IntakeReader.IntakeInstant] = []
  @State private var loading = true
  @State private var viewingDate: String = SeptenaDate.today
  @State private var editing: IntakeEntryDTO? = nil
  @State private var creatingMethod: PresetMethod? = nil
  @State private var managing = false

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
                  onLog: handleLogAction,
                  leadingLogActions: quickAddActions,
                  currentDate: $viewingDate,
                  showsSettingsLink: false) {
      if let kind {
        DrawerSection(padding: .standard) {
          StatStrip(stats: statTiles(kind))
        }
      }
      rhythmSection
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
    }
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
  }

  // MARK: Quick-add

  /// Container-aware choices for the "+" menu, built from the kind's methods
  /// exactly as the watch will from the wire. Plus a Manage row.
  private var quickAddActions: [LogAction] {
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
      // Commit flourish — the tracker's OWN motion (bloom / ripple / …), the
      // "motion matches the logged data" delight the old caffeine/cannabis
      // drawers had. Routes through SectionLog so haptic + flourish fire once.
      SectionLog.newLog(section: "intake", accent: accent,
                        motion: Self.motion(for: kind.flourish),
                        announce: "Logged \(kind.name).", logCommit: logCommit) {
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

  /// The kind's stored `flourish` token → commit motion. Same vocabulary the
  /// plugins declare (caffeine bloom, cannabis ripple).
  static func motion(for flourish: String) -> CommitMotion {
    switch flourish {
    case "ripple": return .ripple
    case "burst":  return .burst
    case "snap":   return .snap
    case "sink":   return .sink
    case "arc":    return .arc
    case "fill":   return .fill
    default:       return .bloom
    }
  }

  private var nowInstant: Date {
    SeptenaDate.parse(viewingDate).map { _ in Date() } ?? Date()
  }

  // MARK: Rows

  private func statTiles(_ kind: IntakeKindDTO) -> [Stat] {
    var tiles: [Stat] = [
      Stat(value: "\(entries.count)",
           label: (kind.countNoun.map { $0.lowercased() + "s" }) ?? "today",
           tint: accent)
    ]
    if kind.showsAmount {
      let total = entries.compactMap(\.amount).reduce(0, +)
      if total > 0 {
        tiles.append(Stat(value: total.decimalString(1), label: "total",
                          tint: accent, unit: kind.unit))
      }
    }
    // Reduction signal: a days-since-last streak, only for reduce/quit kinds
    // (the objective decides). "clean" for quit, "since last" for reduce. Hidden
    // at 0 (today's count already says you had some).
    if IntakeObjective.emphasizesStreak(kind.objective), let days = daysSinceLast, days >= 1 {
      tiles.append(Stat(value: "\(days)d",
                        label: IntakeObjective.streakLabel(kind.objective),
                        tint: accent))
    }
    return tiles
  }

  private var daysSinceLast: Int? {
    guard let last = lastEventAt else { return nil }
    let cal = Calendar.current
    return cal.dateComponents([.day],
                              from: cal.startOfDay(for: last),
                              to: cal.startOfDay(for: Date())).day
  }

  // MARK: Rhythm wheel
  //
  // A 24-hour dial of *when* this tracker lands over the trailing 7 days, faded
  // by recency (shared `TimeOfDayWheel`, same as the old caffeine/cannabis
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
    if isViewingToday, events.count >= 3, let kind {
      DrawerSection("When you reach for \(kind.name)", padding: .tight) {
        TimeOfDayWheel(events: events, accent: accent, windowDays: 7, nowFraction: nowFraction)
          .frame(maxWidth: .infinity)
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
  /// `count / cap` plus an "N/cap" caption — the modern take on cannabis's old
  /// `●●○` hit dots, for any container tracker.
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
      return PageBundle(kind: kind, entries: entries, items: items,
                        lastContainerCount: last, lastEventAt: lastAt, weekPoints: week)
    }
    kind = bundle.kind
    entries = bundle.entries
    itemNames = Dictionary(uniqueKeysWithValues: bundle.items.map { ($0.id, $0.name) })
    lastContainerCount = bundle.lastContainerCount
    lastEventAt = bundle.lastEventAt
    weekPoints = bundle.weekPoints
    loading = false
  }

  private struct PageBundle: Sendable {
    let kind: IntakeKindDTO?
    let entries: [IntakeEntryDTO]
    let items: [IntakeItemDTO]
    let lastContainerCount: Int?
    let lastEventAt: Date?
    let weekPoints: [IntakeReader.IntakeInstant]
  }
}
