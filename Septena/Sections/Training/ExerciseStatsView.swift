import SwiftUI
import SwiftData

// Per-exercise detail/stats — the training counterpart to the habit/
// supplement/chore detail views, on the same shared `LogDetailBody` surface.
// Reached by tapping an exercise in the catalog. Shows last performed, training
// frequency (learned cadence), personal records, a consistency heatmap, and the
// recent sets — all derived from `ExerciseEntryEntity` history + the existing
// `TrainingPRCalculator`. "Edit" pushes the catalog's `ExerciseDetailView`
// editor for the same exercise.

struct ExerciseStatsView: View {
  let entity: ExerciseDefinitionEntity

  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme
  @State private var detail = LogDetail()
  @State private var showEdit = false

  private var accent: Color { theme.color(for: "training") }

  var body: some View {
    LogDetailBody(detail: detail, accent: accent)
      .navigationTitle(entity.name)
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .tint(accent)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button("Edit") { showEdit = true }
        }
      }
      .navigationDestination(isPresented: $showEdit) {
        ExerciseDetailView(entity: entity)
      }
      .task { reload() }
      .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in reload() }
  }

  private func reload() {
    detail = Self.build(entity: entity, context: modelContext)
  }

  // MARK: - Build

  static func build(entity: ExerciseDefinitionEntity, context: ModelContext) -> LogDetail {
    let key = exerciseKey(entity.name)
    let all = (try? context.fetch(FetchDescriptor<ExerciseEntryEntity>(
      sortBy: [SortDescriptor(\.date, order: .reverse),
               SortDescriptor(\.loggedAt, order: .reverse)]
    ))) ?? []
    let rows = all.filter { exerciseKey($0.exercise) == key }
    let dates = Array(Set(rows.map(\.date))).sorted()
    let baseline = TrainingPRCalculator.baselines(for: [entity.name], in: context)[key] ?? .empty

    var d = LogDetail()
    d.subtitle = rows.isEmpty
      ? "No sessions yet"
      : "Performed \(dates.count) \(dates.count == 1 ? "day" : "days")"

    // Tiles: last performed · sessions in 30d · headline PR.
    let last = dates.last
    let last30 = sessionsInLast30(dates)
    d.tiles = [
      LogStat(value: last.map(LogDetailFormat.relativeDay) ?? "—", caption: "Last done"),
      LogStat(value: "\(last30)", caption: "last 30 days",
              tone: last30 > 0 ? .accent : .normal),
      LogStat(value: headlinePR(baseline), caption: prCaption(baseline)),
    ]

    // PR card — only the records that exist for this exercise's modality.
    var pr = LogCard(title: "Records")
    if let e = baseline.e1RM {
      var v = "\(Int(e.rounded())) kg"
      if let w = baseline.bestWeight, let r = baseline.bestReps {
        v += "  ·  \(trimKg(w)) × \(r)"
      }
      pr.rows.append(LogKeyValue(label: "Est. 1RM", value: v))
    } else if let w = baseline.bestWeight {
      let r = baseline.bestReps.map { " × \($0)" } ?? ""
      pr.rows.append(LogKeyValue(label: "Best set", value: "\(trimKg(w))\(r)"))
    }
    if let dist = baseline.bestDistanceM {
      pr.rows.append(LogKeyValue(label: "Best distance", value: formatDistance(dist)))
    }
    if let dur = baseline.bestDurationMin {
      pr.rows.append(LogKeyValue(label: "Longest", value: "\(Int(dur.rounded())) min"))
    }
    if !pr.rows.isEmpty { d.cards.append(pr) }

    // Learned training frequency (reuses the chore cadence learner).
    if let cad = Cadence.acrossDays(dates: dates) {
      var card = LogCard(title: "Frequency")
      card.rows.append(LogKeyValue(label: "Trained about every",
                                   value: "\(cad.medianGap) \(cad.medianGap == 1 ? "day" : "days")",
                                   muted: !cad.isConfident))
      if !cad.isConfident {
        card.note = "Learning your rhythm — a few more sessions sharpens this."
      }
      d.cards.append(card)
    }

    if !dates.isEmpty {
      let perDay = Dictionary(grouping: rows, by: \.date).mapValues(\.count)
      d.heatmap = LogHeatmap(firstDate: LogDetailFormat.firstDate(dates),
                             level: { iso in heatLevel(perDay[iso] ?? 0) })
    }

    d.recentTitle = "Recent sets"
    d.recent = rows.prefix(12).map { row in
      LogRecent(title: LogDetailFormat.longDay(row.date),
                detail: detailLine(row),
                trailing: LogDetailFormat.relativeDay(row.date))
    }
    return d
  }

  // MARK: - Helpers

  private static func sessionsInLast30(_ dates: [String]) -> Int {
    guard let today = SeptenaDate.parse(SeptenaDate.today) else { return 0 }
    let cutoff = Calendar.current.date(byAdding: .day, value: -29, to: today)
      .flatMap(SeptenaDate.format) ?? SeptenaDate.today
    return dates.filter { $0 >= cutoff }.count
  }

  private static func heatLevel(_ count: Int) -> Int {
    switch count {
    case 0: return 0
    case 1: return 2
    case 2: return 3
    default: return 4
    }
  }

  private static func headlinePR(_ b: PRBaseline) -> String {
    if let e = b.e1RM { return "\(Int(e.rounded()))kg" }
    if let w = b.bestWeight { return "\(trimKg(w))kg" }
    if let dist = b.bestDistanceM { return formatDistance(dist) }
    if let dur = b.bestDurationMin { return "\(Int(dur.rounded()))m" }
    return "—"
  }

  private static func prCaption(_ b: PRBaseline) -> String {
    if b.e1RM != nil { return "est. 1RM" }
    if b.bestWeight != nil { return "best set" }
    if b.bestDistanceM != nil { return "best distance" }
    if b.bestDurationMin != nil { return "longest" }
    return "record"
  }

  private static func trimKg(_ w: Double) -> String {
    w.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(w))kg" : "\(w.decimalString(1))kg"
  }

  private static func formatDistance(_ m: Double) -> String {
    m >= 1000 ? "\((m / 1000).decimalString(1)) km" : "\(Int(m)) m"
  }

  private static func detailLine(_ e: ExerciseEntryEntity) -> String? {
    var parts: [String] = []
    if let w = e.weight, w > 0 { parts.append(trimKg(w)) }
    if let s = e.sets, let r = e.reps { parts.append("\(s)×\(r)") }
    else if let r = e.reps { parts.append(r) }
    if let d = e.durationMin, d > 0 { parts.append("\(Int(d)) min") }
    if let m = e.distanceM, m > 0 { parts.append(formatDistance(m)) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}
