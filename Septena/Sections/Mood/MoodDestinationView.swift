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
  @State private var history: [MoodHistoryPoint] = []
  @State private var monthEntries: [MoodEntry] = []
  @State private var addingNew = false
  @State private var editing: MoodEntry? = nil
  @State private var loading = true
  /// Day the drawer's date strip is pointing at. Slot cards, heatmap,
  /// and quadrant breakdown are "today" affordances and hide when
  /// browsing the past — past view is just the day's check-in list.
  @State private var viewingDate: String = SeptenaDate.today

  private var isViewingToday: Bool { viewingDate == SeptenaDate.today }

  var body: some View {
    SectionDrawer(sectionKey: "mood",
                  title: "Mood",
                  onLog: { _ in addingNew = true },
                  currentDate: $viewingDate) {
      if isViewingToday {
        slotSection
      }
      todaySection
      if isViewingToday {
        heatmapSection
        breakdownSection
      }
    }
    .trackScreen("mood")
    .task { reload() }
    .onChange(of: viewingDate) { _, _ in reload() }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in
      reload()
    }
    .sheet(isPresented: $addingNew) {
      AddMoodPage(onLogged: { reload() })
    }
    .sheet(item: $editing) { entry in
      EditMoodEntrySheet(date: viewingDate,
                         original: entry,
                         onSave: { reload() })
    }
  }

  // MARK: - Slot cards (morning / afternoon / evening)

  private var slotSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      DayBucketHeader(bucket: DayBucket.current.rawValue,
                      trailing: "\(today?.logCount ?? 0)/3")
        .padding(.horizontal, 16)
      DrawerSection(spacing: 0, padding: .none) {
        ForEach(DayBucket.allCases) { bucket in
          SlotCard(bucket: bucket,
                   latest: today?.byBucket[bucket.rawValue],
                   onTap: {
                     if let entry = today?.byBucket[bucket.rawValue] {
                       editing = entry
                     } else {
                       addingNew = true
                     }
                   })
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
      }
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
                reload()
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

  // MARK: - 30-day heatmap

  @ViewBuilder
  private var heatmapSection: some View {
    if !history.isEmpty {
      DrawerSection("Past 30 days", padding: .tight) {
        MoodHeatmapView(history: Array(history.suffix(30)))
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

  private func reload() {
    today = ChecklistMirror.loadMoodDay(context: modelContext, date: viewingDate)
    // Heatmap + monthly breakdown render only when viewing today, so
    // only refresh them in that mode — saves a fetch when time-travelling.
    if isViewingToday {
      history = ChecklistMirror.loadMoodHistory(context: modelContext, days: 30).daily
      monthEntries = loadMonthEntries()
    }
    loading = false
  }

  private func loadMonthEntries() -> [MoodEntry] {
    let today = SeptenaDate.today
    guard let todayDate = SeptenaDate.parse(today) else { return [] }
    let start = Calendar.current.date(byAdding: .day, value: -29, to: todayDate) ?? todayDate
    let startStr = SeptenaDate.format(start) ?? today
    let entities = (try? modelContext.fetch(FetchDescriptor<MoodEventEntity>(
      predicate: #Predicate { $0.date >= startStr && $0.date <= today }
    ))) ?? []
    return entities.map {
      MoodEntry(id: $0.id, time: $0.time, bucket: $0.bucket,
                quadrant: $0.quadrant, arousal: $0.arousal, valence: $0.valence,
                emotion: $0.emotion, note: $0.note)
    }
  }
}

// MARK: - Slot card

private struct SlotCard: View {
  let bucket: DayBucket
  let latest: MoodEntry?
  let onTap: () -> Void

  private var isCurrent: Bool { bucket == DayBucket.current }

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 12) {
        Circle()
          .fill(quadrantColor.opacity(latest == nil ? 0.18 : 0.85))
          .frame(width: 38, height: 38)
          .overlay(
            Image(systemName: bucket.icon)
              .foregroundStyle(latest == nil ? .secondary : Color.black.opacity(0.8))
          )
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(bucket.title)
              .font(.subheadline.weight(.medium))
            if isCurrent && latest == nil {
              Text("Now")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                .foregroundStyle(Color.accentColor)
            }
          }
          if let e = latest {
            Text("\(e.emotion) · \(String(e.time.prefix(5)))")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            Text(isCurrent ? "Tap to check in" : "Not logged")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        if latest != nil {
          Image(systemName: "checkmark")
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var quadrantColor: Color {
    guard let q = latest.flatMap({ MoodQuadrant(rawValue: $0.quadrant) }) else {
      return .secondary
    }
    return q.color
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

// MARK: - Heatmap (3 rows × 30 days)

private struct MoodHeatmapView: View {
  let history: [MoodHistoryPoint]

  /// `[date: [bucket: quadrant]]`. Empty buckets are simply absent from
  /// the inner map so the heatmap renders them as empty cells rather
  /// than inferring a color.
  private var index: [String: [String: String]] {
    Dictionary(uniqueKeysWithValues: history.map { ($0.date, $0.bucketQuadrants) })
  }

  var body: some View {
    let dates = history.map(\.date)
    VStack(alignment: .leading, spacing: 6) {
      ForEach(DayBucket.allCases) { bucket in
        HStack(spacing: 3) {
          Image(systemName: bucket.icon)
            .scaledFont(size: 10)
            .foregroundStyle(.secondary)
            .frame(width: 36, alignment: .leading)
          ForEach(Array(dates.enumerated()), id: \.offset) { _, date in
            cellView(date: date, bucket: bucket.rawValue)
          }
        }
      }
      HStack(spacing: 3) {
        Color.clear.frame(width: 36, height: 8)
        ForEach(Array(dates.enumerated()), id: \.offset) { idx, date in
          if idx % 5 == 0 {
            Text(String(date.suffix(2)))
              .scaledFont(size: 8)
              .foregroundStyle(.secondary)
              .frame(minWidth: 8)
          } else {
            Color.clear.frame(width: 1)
          }
        }
      }
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private func cellView(date: String, bucket: String) -> some View {
    let quadrant = index[date]?[bucket]
    let color = quadrant.flatMap { MoodQuadrant(rawValue: $0)?.color }
    RoundedRectangle(cornerRadius: 2)
      .fill(color ?? Color.secondary.opacity(0.12))
      .frame(height: 18)
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
