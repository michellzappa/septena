import SwiftUI
import SwiftData

// Shared per-item detail surface for every loggable/aggregate section —
// habits, supplements, chores, training exercises (and any future log that
// has a named recurring item with a dated history). One data-driven layout so
// the surface reads identically everywhere; sections only compute a `LogDetail`
// value describing what to show.
//
// Two layers:
//   • `LogDetailBody` — the pure scrolling content (masthead, stat tiles,
//     consistency heatmap, key/value cards, recent list). No chrome, no I/O.
//     Reuses the app's real components: `ConsistencyHeatmap`, `ChartCard`,
//     `StatGrid`/`StatTile`, `DrawerSection`, `LogRow`.
//   • `LogDetailScaffold` — wraps the body with the adaptive Close · title ·
//     Edit chrome (sheet on iPhone, docked inspector on iPad/macOS) and the
//     load-on-appear / reload-on-data-change lifecycle. Push-navigation hosts
//     (training catalog) use `LogDetailBody` directly instead.

// MARK: - Data model

/// A single stat tile (value + caption). `tone` colors the value.
struct LogStat: Identifiable {
  enum Tone { case normal, accent, warn }
  let id = UUID()
  let value: String
  let caption: String
  var tone: Tone = .normal
}

/// A labeled row inside a key/value card (cadence, PRs, …).
struct LogKeyValue: Identifiable {
  let id = UUID()
  let label: String
  let value: String
  var muted: Bool = false
}

/// A titled card of key/value rows with an optional explanatory note —
/// used for the chore cadence card and the training PR card.
struct LogCard: Identifiable {
  let id = UUID()
  let title: String
  var rows: [LogKeyValue] = []
  var note: String? = nil
}

/// One row in the "Recent" history list (rendered with `LogRow`). `status`
/// drives an optional leading dot for daily-item timelines (done/skipped/
/// missed); `.none` leaves the row glyph-free (event-log lists).
struct LogRecent: Identifiable {
  enum Status { case none, done, skipped, missed }
  let id = UUID()
  let title: String
  var detail: String? = nil
  var trailing: String? = nil
  var status: Status = .none
}

/// Drives the consistency heatmap. `level` maps an ISO date → 0…4 intensity.
struct LogHeatmap {
  let firstDate: Date?
  let level: (String) -> Int
  var detail: String? = "last weeks"
}

/// Everything `LogDetailBody` needs to render. Sections build one of these.
struct LogDetail {
  var emoji: String? = nil
  var subtitle: String = ""
  var tiles: [LogStat] = []
  var heatmap: LogHeatmap? = nil
  /// Title for the heatmap card. "Consistency" reads right for done/skipped
  /// logs (habits, supplements); graded logs (symptoms) override it.
  var heatmapTitle: String = "Consistency"
  var cards: [LogCard] = []
  var recent: [LogRecent] = []
  var recentTitle: String = "Recent"
}

// MARK: - Pure content body

struct LogDetailBody: View {
  let detail: LogDetail
  let accent: Color

  var body: some View {
    ScrollView {
      VStack(spacing: Theme.Spacing.xxl) {
        masthead
        if !detail.tiles.isEmpty { tiles }
        if let hm = detail.heatmap { heatmap(hm, title: detail.heatmapTitle) }
        ForEach(detail.cards) { card in cardView(card) }
        if !detail.recent.isEmpty { recent }
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
      if let emoji = detail.emoji {
        Text(emoji).font(.system(size: 48))
      }
      Text(detail.subtitle)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
  }

  private var tiles: some View {
    // 3 tiles → 3 columns; 1–2 → match count; 4+ → wrap at 3.
    let cols = detail.tiles.count >= 3 ? 3 : detail.tiles.count
    return StatGrid(columns: max(1, cols)) {
      ForEach(detail.tiles) { stat in
        StatTile {
          VStack(spacing: 4) {
            Text(stat.value)
              .font(.system(.title3, design: .rounded).weight(.semibold))
              .foregroundStyle(color(for: stat.tone))
              .multilineTextAlignment(.center)
              .lineLimit(1)
              .minimumScaleFactor(0.7)
            Text(stat.caption)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
          }
          .padding(.horizontal, 4)
        }
      }
    }
  }

  private func color(for tone: LogStat.Tone) -> Color {
    switch tone {
    case .normal: return Theme.inkPrimary
    case .accent: return accent
    case .warn: return Theme.overdueRed
    }
  }

  private func heatmap(_ hm: LogHeatmap, title: String) -> some View {
    ChartCard(title: title, detail: hm.detail) {
      ConsistencyHeatmap(
        endDate: Date(),
        firstDataDate: hm.firstDate,
        accent: accent,
        getDay: { iso in HeatmapDay(level: hm.level(iso), label: iso) }
      )
      .padding(.vertical, 2)
    }
  }

  private func cardView(_ card: LogCard) -> some View {
    DrawerSection(card.title) {
      VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
        ForEach(card.rows) { row in
          HStack {
            Text(row.label).foregroundStyle(.secondary)
            Spacer()
            Text(row.value)
              .foregroundStyle(row.muted ? Color.secondary : Theme.inkPrimary)
              .multilineTextAlignment(.trailing)
          }
          .font(.subheadline)
        }
        if let note = card.note {
          if !card.rows.isEmpty { Divider() }
          Text(note).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  private var recent: some View {
    DrawerSection(detail.recentTitle, padding: .none) {
      VStack(spacing: 0) {
        ForEach(Array(detail.recent.enumerated()), id: \.element.id) { idx, row in
          if idx > 0 { Divider() }
          LogRow(title: row.title, detail: row.detail, trailing: row.trailing,
                 leading: statusGlyph(row.status))
        }
      }
    }
  }

  /// Leading status dot for a daily-timeline row. `nil` for `.none` so
  /// event-log lists render without a glyph column.
  private func statusGlyph(_ status: LogRecent.Status) -> AnyView? {
    switch status {
    case .none: return nil
    case .done:
      return AnyView(Image(systemName: "checkmark.circle.fill")
        .font(.footnote).foregroundStyle(accent))
    case .skipped:
      return AnyView(Image(systemName: "minus.circle.fill")
        .font(.footnote).foregroundStyle(.tertiary))
    case .missed:
      return AnyView(Image(systemName: "circle")
        .font(.footnote).foregroundStyle(Color.secondary.opacity(0.35)))
    }
  }
}

// MARK: - Adaptive-detail chrome (sheet / inspector hosts)

struct LogDetailScaffold: View {
  let title: String
  let accent: Color
  /// Builds the detail from a context — re-run on appear and after writes.
  let load: (ModelContext) -> LogDetail
  /// Routes the toolbar "Edit" back to the parent (swaps to the edit sheet).
  /// Omit for surfaces with no editor.
  var onEdit: (() -> Void)? = nil

  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @Environment(\.adaptiveDetailClose) private var adaptiveClose

  @State private var detail = LogDetail()

  private var isInspector: Bool { adaptiveClose != nil }
  private func close() { (adaptiveClose ?? { dismiss() })() }

  var body: some View {
    Group {
      if isInspector {
        LogDetailBody(detail: detail, accent: accent)
          .safeAreaInset(edge: .top, spacing: 0) { inspectorHeader }
      } else {
        NavigationStack {
          LogDetailBody(detail: detail, accent: accent)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
              ToolbarItem(placement: .cancellationAction) {
                Button("Close", action: close).keyboardShortcut(.cancelAction)
              }
              if let onEdit {
                ToolbarItem(placement: .primaryAction) { Button("Edit", action: onEdit) }
              }
            }
        }
      }
    }
    .tint(accent)
    .task { reload() }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in reload() }
  }

  private func reload() { detail = load(modelContext) }

  private var inspectorHeader: some View {
    HStack {
      Button("Close", action: close).keyboardShortcut(.cancelAction)
      Spacer()
      Text(title).font(.headline).lineLimit(1)
      Spacer()
      if let onEdit {
        Button("Edit", action: onEdit).fontWeight(.semibold)
      } else {
        // Keep the title centered when there's no Edit affordance.
        Button("Edit", action: {}).fontWeight(.semibold).hidden()
      }
    }
    .tint(accent)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.bar)
  }
}

// MARK: - Shared formatting helpers

enum LogDetailFormat {
  /// "Today" / "Yesterday" / "Tomorrow" / "3 days ago" / "in 2 days" / "Jun 3",
  /// computed against `SeptenaDate.today` so it tracks time travel.
  static func relativeDay(_ iso: String) -> String {
    guard let date = SeptenaDate.parse(iso),
          let today = SeptenaDate.parse(SeptenaDate.today) else { return iso }
    let days = Calendar.current.dateComponents([.day], from: today, to: date).day ?? 0
    switch days {
    case 0: return "Today"
    case 1: return "Tomorrow"
    case -1: return "Yesterday"
    case let d where d < -1 && d > -7: return "\(-d) days ago"
    case let d where d > 1 && d < 7: return "in \(d) days"
    default:
      let f = DateFormatter(); f.dateFormat = "MMM d"
      return f.string(from: date)
    }
  }

  /// "Tue, Jun 3" — the title used in the Recent list.
  static func longDay(_ iso: String) -> String {
    guard let date = SeptenaDate.parse(iso) else { return iso }
    let f = DateFormatter(); f.dateFormat = "EEE, MMM d"
    return f.string(from: date)
  }

  /// Earliest ISO date in a list, as a `Date` for the heatmap's left edge.
  static func firstDate(_ isoDates: [String]) -> Date? {
    isoDates.min().flatMap(SeptenaDate.parse)
  }
}
