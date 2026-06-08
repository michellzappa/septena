import SwiftUI
import SwiftData

// Read-only "infobox" for a single chore — reached by tapping a chore row
// (the checkbox still completes; the row body opens this). Surfaces the
// completion history and the *learned* cadence derived from it: how often
// the chore is actually done versus the cadence the user configured, and
// when it's next due. Nothing here is stored — every figure is computed at
// read time from the chore's `complete` events (the same raw material
// `ChecklistMirror.choreItem` walks), via `ChecklistMirror.choreCompletionDates`
// and the shared `Cadence` learner.
//
// Presented through `.adaptiveDetail` (sheet on iPhone, docked inspector on
// iPad/macOS), so it carries its own minimal chrome: Close · title · Edit.
// "Edit" hands back to the parent through `onEdit`, which swaps this detail
// for the existing `EditChoreSheet`.

struct ChoreDetailView: View {
  let chore: ChoreItem
  /// Routes the toolbar "Edit" affordance back to the parent so it can open
  /// `EditChoreSheet` for the same chore.
  let onEdit: () -> Void

  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme
  @Environment(\.dismiss) private var dismiss
  @Environment(\.adaptiveDetailClose) private var adaptiveClose

  /// Completion dates (YYYY-MM-DD, unique, ascending) loaded once on appear.
  @State private var completionDates: [String] = []

  private var accent: Color { theme.color(for: "chores") }
  private var stats: ChoreStats { ChoreStats.make(item: chore, completionDates: completionDates) }

  private var isInspector: Bool { adaptiveClose != nil }
  private func close() { (adaptiveClose ?? { dismiss() })() }

  var body: some View {
    Group {
      if isInspector {
        scroll
          .safeAreaInset(edge: .top, spacing: 0) { inspectorHeader }
      } else {
        NavigationStack {
          scroll
            .navigationTitle(chore.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
              ToolbarItem(placement: .cancellationAction) {
                Button("Close", action: close).keyboardShortcut(.cancelAction)
              }
              ToolbarItem(placement: .primaryAction) {
                Button("Edit", action: onEdit)
              }
            }
        }
      }
    }
    .tint(accent)
    .task { reload() }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in reload() }
  }

  private func reload() {
    completionDates = ChecklistMirror.choreCompletionDates(context: modelContext, choreID: chore.id)
  }

  // MARK: Chrome

  private var inspectorHeader: some View {
    HStack {
      Button("Close", action: close).keyboardShortcut(.cancelAction)
      Spacer()
      Text(chore.name).font(.headline).lineLimit(1)
      Spacer()
      Button("Edit", action: onEdit).fontWeight(.semibold)
    }
    .tint(accent)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.bar)
  }

  private var scroll: some View {
    ScrollView {
      VStack(spacing: Theme.Spacing.xxl) {
        masthead
        tiles
        cadenceCard
        if !stats.recentDates.isEmpty { recentCard }
      }
      .padding(.horizontal, Theme.pageGutter)
      .padding(.top, Theme.Spacing.lg)
      .padding(.bottom, 24)
    }
    .background(Theme.groupedBackground)
  }

  // MARK: Sections

  private var masthead: some View {
    VStack(spacing: Theme.Spacing.sm) {
      Text(chore.emoji ?? "•")
        .font(.system(size: 48))
      Text(stats.completionCount == 0
           ? "Not done yet"
           : "Done \(stats.completionCount) \(stats.completionCount == 1 ? "time" : "times")")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
  }

  private var tiles: some View {
    StatGrid(columns: 2) {
      StatTile {
        tileBody(value: stats.lastCompleted.map { relativeDay($0) } ?? "—",
                 caption: "Last done",
                 detail: stats.lastCompletedTime)
      }
      StatTile {
        tileBody(value: stats.nextDue.map { relativeDay($0) } ?? "—",
                 caption: "Next due",
                 detail: nil,
                 valueColor: stats.daysOverdue > 0 ? Theme.overdueRed : nil)
      }
    }
  }

  @ViewBuilder
  private func tileBody(value: String, caption: String, detail: String?,
                        valueColor: Color? = nil) -> some View {
    VStack(spacing: 4) {
      Text(value)
        .font(.system(.title3, design: .rounded).weight(.semibold))
        .foregroundStyle(valueColor ?? Theme.inkPrimary)
        .multilineTextAlignment(.center)
      Text(caption).font(.caption).foregroundStyle(.secondary)
      if let detail, !detail.isEmpty {
        Text(detail).font(.caption2).foregroundStyle(.secondary.opacity(0.7))
      }
    }
    .padding(.horizontal, Theme.Spacing.sm)
  }

  private var cadenceCard: some View {
    DrawerSection("Cadence") {
      VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
        if let configured = stats.configuredCadenceDays {
          labeledRow("Scheduled", value: "every \(cadenceLabel(configured))")
        }
        if let learned = stats.learnedCadenceDays {
          labeledRow("Actual rhythm",
                     value: "about every \(cadenceLabel(learned))",
                     muted: !stats.learnedConfident)
          if stats.learnedConfident, let predicted = stats.learnedNextDue {
            Divider()
            Text("At your real pace, expect this again **\(relativeDay(predicted))**.")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else if !stats.learnedConfident {
            Divider()
            Text("Learning your rhythm — a couple more completions and Septena will predict the next one.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } else {
          Text("No rhythm yet — the schedule above drives the next-due date until there's a pattern to learn from.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var recentCard: some View {
    DrawerSection("Recent") {
      VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
        ForEach(stats.recentDates, id: \.self) { date in
          HStack {
            Text(relativeDay(date))
            Spacer()
            Text(weekday(date)).foregroundStyle(.secondary)
          }
          .font(.subheadline)
        }
      }
    }
  }

  @ViewBuilder
  private func labeledRow(_ label: String, value: String, muted: Bool = false) -> some View {
    HStack {
      Text(label).foregroundStyle(.secondary)
      Spacer()
      Text(value).foregroundStyle(muted ? Color.secondary : Theme.inkPrimary)
    }
    .font(.subheadline)
  }

  // MARK: Formatting

  private func cadenceLabel(_ days: Int) -> String {
    switch days {
    case 1: return "day"
    case 7: return "week"
    case 14: return "2 weeks"
    case 30, 31: return "month"
    default: return "\(days) days"
    }
  }

  /// "Today" / "Yesterday" / "3 days ago" / "in 2 days" / a date for anything
  /// further out, computed against `DayClock.today` so it tracks time travel.
  private func relativeDay(_ iso: String) -> String {
    guard let date = SeptenaDate.parse(iso),
          let today = SeptenaDate.parse(SeptenaDate.today) else { return iso }
    let days = Calendar.current.dateComponents([.day], from: today, to: date).day ?? 0
    switch days {
    case 0: return "Today"
    case 1: return "Tomorrow"
    case -1: return "Yesterday"
    case let d where d < -1: return "\(-d) days ago"
    case let d where d > 1 && d < 7: return "in \(d) days"
    default:
      let f = DateFormatter()
      f.dateFormat = "MMM d"
      return f.string(from: date)
    }
  }

  private func weekday(_ iso: String) -> String {
    guard let date = SeptenaDate.parse(iso) else { return "" }
    let f = DateFormatter()
    f.dateFormat = "EEE"
    return f.string(from: date)
  }
}

// MARK: - Derived stats

/// Everything the detail view shows about a chore, derived at read time from
/// its completion dates plus the already-projected `ChoreItem` fields. The
/// *learned* cadence comes from the shared `Cadence` learner fed days-between
/// completions; the configured cadence and the scheduled next-due come from
/// the chore definition (via `ChoreItem`). Pure value type — no I/O.
struct ChoreStats {
  let completionCount: Int
  let lastCompleted: String?
  let lastCompletedTime: String?
  /// Scheduled next-due — configured-cadence projection (or a defer), as
  /// already computed by `ChecklistMirror.choreItem`.
  let nextDue: String?
  let daysOverdue: Int
  let configuredCadenceDays: Int?
  /// Median gap in days between actual completions; nil with fewer than two.
  let learnedCadenceDays: Int?
  /// True once enough gaps are observed to trust the learned rhythm.
  let learnedConfident: Bool
  /// Most-recent completion dates, newest first (capped for display).
  let recentDates: [String]

  /// Next-due predicted from the *learned* rhythm rather than the configured
  /// cadence — only when the rhythm is trustworthy.
  var learnedNextDue: String? {
    guard learnedConfident, let last = lastCompleted, let gap = learnedCadenceDays,
          let base = SeptenaDate.parse(last),
          let next = Calendar.current.date(byAdding: .day, value: gap, to: base) else { return nil }
    return SeptenaDate.format(next)
  }

  static func make(item: ChoreItem, completionDates dates: [String]) -> ChoreStats {
    let cadence = Cadence.acrossDays(dates: dates)
    return ChoreStats(
      completionCount: dates.count,
      lastCompleted: item.lastCompleted ?? dates.last,
      lastCompletedTime: item.lastCompletedTime,
      nextDue: item.dueDate,
      daysOverdue: item.daysOverdue,
      configuredCadenceDays: item.cadenceDays,
      learnedCadenceDays: cadence?.medianGap,
      learnedConfident: cadence?.isConfident ?? false,
      recentDates: Array(dates.reversed().prefix(12))
    )
  }
}
