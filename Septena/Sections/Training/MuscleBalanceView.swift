import SwiftUI
import SwiftData

/// Tier-2 per-muscle progress screen: all 16 groups with a growth-zone bar,
/// a Last-7-days / Trend toggle, and Push/Pull/Legs/Core filtering. Data-only
/// (no anatomy art) — every number derives from logged `ExerciseEntryEntity`
/// rows resolved to each exercise's `primaryMuscle`. Reached from the Training
/// drawer's muscle-load card. See docs/MUSCLE_TAXONOMY_16.md.
struct MuscleBalanceView: View {
  @Environment(\.modelContext) private var context
  @Environment(SectionTheme.self) private var theme

  enum Window: String, CaseIterable, Identifiable {
    case last7 = "Last 7 days"
    case trend = "Trend"
    var id: String { rawValue }
    /// Aggregation window in days; trend averages four trailing weeks.
    var days: Int { self == .trend ? 28 : 7 }
    var weeks: Int { self == .trend ? 4 : 1 }
  }

  enum Group: String, CaseIterable, Identifiable {
    case all = "All", push = "Push", pull = "Pull", legs = "Legs", core = "Core"
    var id: String { rawValue }
    var muscles: [Muscle] {
      switch self {
      case .all:  return Muscle.allCases
      case .push: return [.chest, .frontDelts, .sideDelts, .triceps]
      case .pull: return [.lats, .upperBack, .rearDelts, .biceps, .forearms]
      case .legs: return [.quads, .hamstrings, .glutes, .calves, .adductors]
      case .core: return [.abs, .lowerBack]
      }
    }
  }

  // Weekly volume landmarks (sets per muscle): below `zoneFloor` is
  // under-stimulus; zoneFloor…target is the productive "growth zone".
  static let zoneFloor = 8
  static let target = 12

  @State private var window: Window = .last7
  @State private var group: Group = .all

  private var accent: Color { theme.color(for: "training") }

  private var setsByMuscle: [Muscle: Int] {
    MuscleVolume.setsPerMuscle(daysBack: window.days - 1, context: context)
  }

  var body: some View {
    let totals = setsByMuscle
    List {
      Section {
        Picker("Window", selection: $window) {
          ForEach(Window.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .listRowSeparator(.hidden)
        groupStrip
          .listRowSeparator(.hidden)
          .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 6, trailing: 16))
      }
      Section {
        ForEach(group.muscles) { muscle in
          MuscleBalanceRow(muscle: muscle,
                           totalSets: totals[muscle] ?? 0,
                           weeks: window.weeks,
                           floor: Self.zoneFloor,
                           target: Self.target)
        }
      } header: {
        Text(window == .trend
             ? "Weekly average per muscle · last 4 weeks"
             : "Sets per muscle · last 7 days")
      } footer: {
        Text("Counts hard sets (within ~1 rep of failure) toward the exercise's primary muscle; lighter sets count partially, easy or unrated sets not at all. Growth zone: \(Self.zoneFloor)–\(Self.target) sets/week.")
      }
    }
    .navigationTitle("Muscle Balance")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
  }

  private var groupStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(Group.allCases) { g in
          let selected = group == g
          Button { group = g } label: {
            Text(g.rawValue)
              .font(.subheadline)
              .padding(.horizontal, 12).padding(.vertical, 6)
              .background(selected ? accent : Color.secondary.opacity(0.15), in: Capsule())
              .foregroundStyle(selected ? Color.white : Color.primary)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.vertical, 2)
    }
    .listRowBackground(Color.clear)
  }
}

/// One muscle's row: label + status + a segmented growth-zone bar. The bar
/// has `target` cells; cells below `floor` read "building" (blue), the
/// zone cells read "in zone" (green). Filled cells = sets logged.
private struct MuscleBalanceRow: View {
  let muscle: Muscle
  let totalSets: Int
  let weeks: Int
  let floor: Int
  let target: Int

  /// Per-week figure (trend mode averages the window).
  private var perWeek: Int {
    weeks <= 1 ? totalSets : Int((Double(totalSets) / Double(weeks)).rounded())
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(muscle.label).font(.subheadline.weight(.medium))
        Spacer()
        Text(statusText)
          .font(.caption.weight(.medium))
          .foregroundStyle(statusColor)
      }
      HStack(spacing: 8) {
        zoneBar
        Text("\(perWeek)/\(target)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(width: 40, alignment: .trailing)
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(muscle.label): \(perWeek) of \(target) weekly sets, \(statusText)")
  }

  private var zoneBar: some View {
    HStack(spacing: 3) {
      ForEach(1...target, id: \.self) { i in
        let inZoneCell = i >= floor
        let base: Color = inZoneCell ? .green : .blue
        let filled = i <= perWeek
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .fill(base.opacity(filled ? 0.9 : 0.14))
          .frame(maxWidth: .infinity)
          .frame(height: 10)
      }
    }
  }

  private var statusText: String {
    if perWeek == 0 { return "untrained" }
    if perWeek < floor { return "\(floor - perWeek) to zone" }
    if perWeek > target { return "+\(perWeek - target) over" }
    return "in zone"
  }

  private var statusColor: Color {
    if perWeek == 0 { return .secondary }
    if perWeek < floor { return .blue }
    if perWeek > target { return .orange }
    return .green
  }
}

/// Shared sets-per-muscle aggregation. Resolves each logged entry's exercise
/// to its definition's `primaryMuscle` (cardio/mobility have none, so they
/// drop out → implicitly strength + core) and sums *effective hard sets* per
/// muscle over a trailing day window. Each set is weighted by logged effort
/// (`TrainingMetrics.difficultyWeight`: hard/max = 1.0, moderate = 0.5,
/// easy/unrated = 0) so this matches the headline hard-sets number and the
/// goal ring instead of counting every raw set — including warm-ups and easy
/// sets — as a full hard set. Per-muscle effective totals are rounded for the
/// integer growth-zone UI.
@MainActor
enum MuscleVolume {
  private static let ymd: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; return f
  }()

  static func setsPerMuscle(daysBack: Int, context: ModelContext) -> [Muscle: Int] {
    let defs = (try? context.fetch(FetchDescriptor<ExerciseDefinitionEntity>())) ?? []
    var muscleByKey: [String: Muscle] = [:]
    for def in defs {
      guard let m = Muscle.resolve(def.primaryMuscle) else { continue }
      let idKey = exerciseKey(def.id), nameKey = exerciseKey(def.name)
      if muscleByKey[idKey] == nil { muscleByKey[idKey] = m }
      if muscleByKey[nameKey] == nil { muscleByKey[nameKey] = m }
    }
    let cutoffDate = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
    let cutoff = ymd.string(from: cutoffDate)
    let entries = (try? context.fetch(FetchDescriptor<ExerciseEntryEntity>())) ?? []
    var effective: [Muscle: Double] = [:]
    for e in entries where e.date >= cutoff {
      guard let muscle = muscleByKey[exerciseKey(e.exercise)],
            let s = e.sets.flatMap(Int.init), s > 0 else { continue }
      effective[muscle, default: 0] += Double(s) * TrainingMetrics.difficultyWeight(e.difficulty)
    }
    return effective.mapValues { Int($0.rounded()) }.filter { $0.value > 0 }
  }
}
