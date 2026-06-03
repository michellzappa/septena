import SwiftUI
import SwiftData

// Caffeine mini-app — today's sessions log, reads from SwiftData and
// writes through CaffeineMutator.

struct CaffeineDestinationView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?

  @State private var today: CaffeineDayResponse? = nil
  @State private var loading = true
  @State private var editing: CaffeineEntry? = nil
  @State private var managingTypes = false
  /// Driven by `CaffeinePlugin.logActions`: tapping "Log V60" / "Log
  /// Matcha" / "Log other" sets this to the method id; the sheet opens
  /// in create mode with `presetMethod` seeded.
  @State private var loggingMethod: LoggingMethod? = nil
  private struct LoggingMethod: Identifiable, Hashable {
    let method: String
    var id: String { method }
  }
  @State private var history: [CaffeineHistoryPoint] = []
  /// Day the drawer is currently viewing — driven by the drawer's
  /// `currentDate` date strip. Defaults to today; heatmap taps jump it
  /// to the picked day.
  @State private var viewingDate: String = SeptenaDate.today

  private var caffeine: CaffeineMutator { SeptenaServices.shared.caffeineMutator }

  private var accent: Color { theme.color(for: "caffeine") }

  /// When the date strip is on a past day we want a read-only log
  /// review — the heatmap is a "today" affordance and becomes noise
  /// when reviewing yesterday's caffeine.
  private var isViewingToday: Bool { viewingDate == SeptenaDate.today }

  var body: some View {
    SectionDrawer(sectionKey: "caffeine",
                  title: "Caffeine",
                  onLog: handleLogAction,
                  leadingLogActions: leadingLogActions,
                  currentDate: $viewingDate) {
      DrawerSection("Today", padding: .none) {
        if let today, !today.entries.isEmpty {
          ForEach(Array(today.entries.reversed())) { entry in
            LogEntryRow(
              title: methodLabel(entry.method),
              detail: detailLine(entry),
              trailing: entry.time,
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
      if isViewingToday && !history.isEmpty {
        ActivityHeatmapSection(
          title: "Caffeine days",
          accent: accent,
          daily: history,
          date: { $0.date },
          value: { Double($0.sessions) },
          levelFor: { v in
            let n = Int(v)
            if n <= 0 { return 0 }
            if n == 1 { return 1 }
            if n == 2 { return 2 }
            if n == 3 { return 3 }
            return 4
          },
          labelFor: { v in
            let n = Int(v)
            return "\(n) \(n == 1 ? "session" : "sessions")"
          },
          subtitleFor: { active, total, sum in
            "\(active) of \(total) days · \(Int(sum)) sessions"
          },
          onTapDay: { iso in viewingDate = iso }
        )
      }
    }
    .trackScreen("caffeine")
    .tint(accent)
    .task { reload() }
    .onChange(of: viewingDate) { _, _ in reload() }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in
      reload()
    }
    .sheet(isPresented: $managingTypes) {
      CaffeineTypeSheet()
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }
    .adaptiveDetail(item: $editing) { entry in
      EditCaffeineEntrySheet(
        date: viewingDate,
        original: entry,
        onSave: { _ in reload() }
      )
    }
    .sheet(item: $loggingMethod) { wrap in
      EditCaffeineEntrySheet(
        date: viewingDate,
        original: nil,
        presetMethod: wrap.method,
        onSave: { _ in reload() }
      )
    }
  }

  private func delete(_ entry: CaffeineEntry) {
    caffeine.deleteEntry(id: entry.id)
    reload()
    Haptics.warning()
  }

  /// Smart "Repeat" row injected above the plugin's log actions in the "+"
  /// menu — mirrors the dashboard tile's quick-add so both surfaces show the
  /// same options. Only on today (a past-day repeat is odd) and only when
  /// there's an entry to repeat. Logs directly (the fast path); the static
  /// "Log V60/Matcha/other" items below it open the create sheet for detail.
  private var leadingLogActions: [LogAction] {
    guard isViewingToday, let last = today?.entries.last else { return [] }
    return [LogAction(id: "repeat",
                      title: "Repeat: \(last.beans ?? methodLabel(last.method))",
                      systemImage: "arrow.clockwise")]
  }

  /// Dispatch table for `CaffeinePlugin.logActions` ids (plus the dynamic
  /// "repeat" leading action). Keeping this close to the destination so
  /// adding a new menu item is a two-touch change.
  private func handleLogAction(_ id: String) {
    switch id {
    case "repeat":
      if let last = today?.entries.last {
        CaffeineCommit.logNew(method: last.method, beans: last.beans,
                              grams: last.grams, accent: accent, logCommit: logCommit)
      }
    case "log-v60":    loggingMethod = .init(method: "v60")
    case "log-matcha": loggingMethod = .init(method: "matcha")
    case "log-other":  loggingMethod = .init(method: "other")
    case "manage":     managingTypes = true
    default:           loggingMethod = .init(method: "v60")
    }
  }

  private func methodLabel(_ m: String) -> String {
    switch m {
    case "v60":    return "V60"
    case "matcha": return "Matcha"
    default:       return m.capitalized
    }
  }

  private func detailLine(_ e: CaffeineEntry) -> String? {
    var parts: [String] = []
    if let beans = e.beans, !beans.isEmpty { parts.append(beans) }
    if let g = e.grams { parts.append(String(format: "%.1fg", g)) }
    if let n = e.note, !n.isEmpty { parts.append(n) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func reload() {
    today = ChecklistMirror.loadCaffeineDay(context: modelContext, date: viewingDate)
    history = ChecklistMirror.loadCaffeineHistory(context: modelContext, days: 365).daily
    loading = false
  }
}
