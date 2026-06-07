import SwiftUI
import SwiftData

// MoodDestinationView — the section's main pane.
//
// Three bands:
// 1. Three slot cards (morning / afternoon / evening). Each shows the
//    most-recent log for that bucket, or an empty "Log <bucket>" button.
//    Slots are soft — logging more than once in a bucket is allowed; the
//    card shows the latest, and the day list below carries the full set.
// 2. Today's full timeline of logs.
// 3. 30-day heatmap — three rows (one per bucket) × 30 columns, colored
//    by quadrant, opacity by log density.

struct MoodDestinationView: View {
  @Environment(\.modelContext) private var modelContext

  @State private var today: MoodDayResponse? = nil
  @State private var monthEntries: [MoodEntry] = []
  @State private var addingNew = false
  @State private var editing: MoodEntry? = nil
  @State private var loading = true
  /// Day the drawer's date strip is pointing at. Slot cards and the
  /// quadrant breakdown are "today" affordances and hide when browsing
  /// the past — past view is just the day's check-in list.
  @State private var viewingDate: String = SeptenaDate.today

  private var isViewingToday: Bool { viewingDate == SeptenaDate.today }

  var body: some View {
    SectionDrawer(sectionKey: "mood",
                  onLog: { _ in addingNew = true },
                  currentDate: $viewingDate) {
      todaySection
      if isViewingToday {
        breakdownSection
      }
    }
    .sectionReload(on: viewingDate, onDataChange: true) { await reload() }
    .adaptiveDetail(isPresented: $addingNew) {
      AddMoodPage(onLogged: { Task { await reload() } })
    }
    .adaptiveDetail(item: $editing) { entry in
      EditMoodEntrySheet(date: viewingDate,
                         original: entry,
                         onSave: { Task { await reload() } })
    }
  }

  // MARK: - Today list

  @ViewBuilder
  private var todaySection: some View {
    if let today, today.entries.count > 0 {
      DrawerSection(isViewingToday ? "All logs today" : "Logs") {
        ForEach(today.entries.reversed()) { entry in
          Button { editing = entry } label: { EntryRow(entry: entry) }
            .buttonStyle(.plain)
            .contextMenu {
              Button { editing = entry } label: {
                Label("Edit", systemImage: "pencil")
              }
              Button(role: .destructive) {
                SeptenaServices.shared.moodMutator.deleteEntry(id: entry.id)
                Haptics.warning()
                Task { await reload() }
              } label: {
                Label("Delete", systemImage: "trash")
              }
            }
        }
      }
    } else if !loading {
      DrawerSection {
        Text(isViewingToday ? "No check-ins yet today." : "No check-ins on this day.")
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Quadrant breakdown (30d)

  @ViewBuilder
  private var breakdownSection: some View {
    if !monthEntries.isEmpty {
      DrawerSection("Where you spent your time") {
        QuadrantBreakdownView(entries: monthEntries)
      }
    }
  }

  private func reload() async {
    let date = viewingDate
    // The monthly breakdown renders only when viewing today, so only
    // refresh it in that mode — saves a fetch when time-travelling.
    let wantsMonth = isViewingToday
    let result = await MirrorReader.shared.read { ctx in
      (day: ChecklistMirror.loadMoodDay(context: ctx, date: date),
       month: wantsMonth ? Self.loadMonthEntries(context: ctx) : nil)
    }
    today = result.day
    if let month = result.month {
      monthEntries = month
    }
    loading = false
  }

  private static func loadMonthEntries(context: ModelContext) -> [MoodEntry] {
    let today = SeptenaDate.today
    guard let todayDate = SeptenaDate.parse(today) else { return [] }
    let start = Calendar.current.date(byAdding: .day, value: -29, to: todayDate) ?? todayDate
    let startStr = SeptenaDate.format(start) ?? today
    let entities = (try? context.fetch(FetchDescriptor<MoodEventEntity>(
      predicate: #Predicate { $0.date >= startStr && $0.date <= today }
    ))) ?? []
    return entities.map {
      MoodEntry(id: $0.id, time: EventTimestamp.hhmm(from: $0.occurredAt), bucket: $0.bucket,
                quadrant: $0.quadrant, arousal: $0.arousal, valence: $0.valence,
                emotion: $0.emotion, note: $0.note)
    }
  }
}

// MARK: - Single entry row

private struct EntryRow: View {
  let entry: MoodEntry
  var body: some View {
    HStack(spacing: 12) {
      Circle()
        .fill((MoodQuadrant(rawValue: entry.quadrant)?.color ?? .gray).opacity(0.85))
        .frame(width: 12, height: 12)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.emotion).font(.subheadline.weight(.medium))
        if let n = entry.note, !n.isEmpty {
          Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
      }
      Spacer()
      Text(String(entry.time.prefix(5)))
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
  }
}

// MARK: - Quadrant breakdown (% of last 30d in each quadrant)

private struct QuadrantBreakdownView: View {
  let entries: [MoodEntry]

  private var counts: [(MoodQuadrant, Int)] {
    MoodQuadrant.allCases.map { q in
      (q, entries.filter { $0.quadrant == q.rawValue }.count)
    }
  }
  private var total: Int { entries.count }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Stacked bar
      GeometryReader { geo in
        HStack(spacing: 2) {
          ForEach(counts, id: \.0) { q, n in
            if n > 0 {
              q.color.opacity(0.85)
                .frame(width: geo.size.width * CGFloat(n) / CGFloat(max(total, 1)))
            }
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
      }
      .frame(height: 14)
      // Legend rows
      ForEach(counts, id: \.0) { q, n in
        HStack(spacing: 8) {
          Circle().fill(q.color).frame(width: 10, height: 10)
          Text(q.title).font(.caption)
          Spacer()
          Text(total == 0 ? "0%" : "\(Int(round(Double(n) / Double(total) * 100)))%")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}
