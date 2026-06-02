import SwiftUI

// Supplements mini-app — single flat list of today's stack. Simpler than
// Habits (no time-of-day bucketing) and Chores (no defer / overdue);
// supplements are taken or not, that's it. Reuses NextItemsModel and the
// promoted SupplementRow.

struct SupplementsDestinationView: View {
  @Environment(ChecklistMutator.self) private var checklistMutator
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme

  @State private var model = NextItemsModel()
  @State private var editing: SupplementDayItem? = nil
  @State private var creating = false
  @State private var history: [SupplementHistoryPoint] = []
  /// Day the drawer's date strip is pointing at. Heatmap tap updates
  /// this rather than opening a modal backfill sheet.
  @State private var viewingDate: String = SeptenaDate.today
  /// Past-day state for `viewingDate`. Loaded when not viewing today.
  @State private var pastDay: SupplementsDayResponse? = nil

  private var isViewingToday: Bool { viewingDate == SeptenaDate.today }

  private var accent: Color { theme.color(for: "supplements") }

  var body: some View {
    SectionDrawer(sectionKey: "supplements",
                  title: "Supplements",
                  onLog: { _ in creating = true },
                  currentDate: $viewingDate) {
      if isViewingToday {
        summary
        // Open list — a just-taken supplement lingers here (struck through)
        // for the settle beat, then fades down into "Done".
        if !model.openSupplements.isEmpty {
          DrawerSection("Today", padding: .none) {
            ForEach(model.openSupplements) { supp in
              Button { editing = supp } label: {
                SupplementRow(supplement: supp, model: model, checklistMutator: checklistMutator, tint: accent,
                              onDelete: { delete(supp) })
              }
              .buttonStyle(.plain)
              .transition(.opacity)
            }
          }
        }
        if !model.doneSupplements.isEmpty {
          DrawerSection("Done", padding: .none) {
            ForEach(model.doneSupplements) { supp in
              Button { editing = supp } label: {
                SupplementRow(supplement: supp, model: model, checklistMutator: checklistMutator, tint: accent,
                              onDelete: { delete(supp) })
              }
              .buttonStyle(.plain)
            }
          }
        }
        if model.hasLoaded && model.supplements.isEmpty {
          ContentUnavailableView("No supplements configured",
                                 systemImage: theme.icon(for: "supplements"),
                                 description: Text("Tap + to add a supplement."))
        }
        if !history.isEmpty {
          ChecklistHeatmapSection(
            title: "Supplement consistency",
            noun: "supplement",
            accent: accent,
            daily: history,
            date: { $0.date },
            done: { $0.done },
            total: { $0.total },
            // Heatmap tap → date strip jump. Same pattern as Habits.
            onTapDay: { iso in viewingDate = iso }
          )
        }
      } else {
        pastDaySection
      }
    }
    .trackScreen("supplements")
    .tint(accent)
    .task {
      model.paintFromCache()
      await model.load()
      // History is computed locally from the CloudKit-backed mirror.
      let resp = ChecklistMirror.loadSupplementsHistory(
        context: LocalStore.shared.container.mainContext, days: 365)
      history = resp.daily
    }
    .onChange(of: viewingDate) { _, _ in reloadPastDay() }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in
      reloadPastDay()
    }
    .adaptiveDetail(item: $editing) { supp in
      EditSupplementSheet(
        original: supp,
        onDone: { updated in
          if let updated, let idx = model.supplements.firstIndex(where: { $0.id == updated.id }) {
            model.supplements[idx] = updated
          }
        }
      )
    }
    .adaptiveDetail(isPresented: $creating) {
      EditSupplementSheet(
        original: nil,
        onDone: { _ in Task { await model.load() } }
      )
    }
  }

  // MARK: - Past-day section

  @ViewBuilder
  private var pastDaySection: some View {
    if let resp = pastDay {
      if resp.items.isEmpty {
        DrawerSection {
          Text("No supplements configured.")
            .foregroundStyle(.secondary)
        }
      } else {
        DrawerSection(padding: .none) {
          ForEach(resp.items) { item in
            pastDayRow(item)
          }
        }
      }
    } else {
      DrawerSection { ProgressView() }
    }
  }

  // Mirrors `SupplementRow` (today) exactly: shared `TaskCheckbox` glyph, same
  // fonts/padding/strikethrough treatment, checkbox-only tap target. Only the
  // write target differs — it commits to `viewingDate`, not today.
  private func pastDayRow(_ item: SupplementDayItem) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.iconTextGap) {
      TaskCheckbox(tint: accent, isDone: item.done) {
        let next = !item.done
        checklistMutator.toggleSupplement(id: item.id, date: viewingDate, done: next)
        if next { Haptics.success() } else { Haptics.tap() }
      }
      .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }
      Text(item.emoji ?? "•").font(.body)
      Text(item.name)
        .font(.septenaTaskTitle)
        .foregroundStyle(item.done ? Theme.inkSecondary : Theme.inkPrimary)
        .strikethrough(item.done)
        .opacity(item.done ? 0.5 : 1)
      Spacer()
    }
    .padding(.horizontal, Theme.hPadding)
    .padding(.vertical, Theme.rowVPadding)
  }

  private func reloadPastDay() {
    guard !isViewingToday else { pastDay = nil; return }
    pastDay = ChecklistMirror.loadSupplementsDay(context: modelContext, date: viewingDate)
  }

  private func delete(_ supp: SupplementDayItem) {
    checklistMutator.deleteSupplement(id: supp.id)
    model.supplements.removeAll { $0.id == supp.id }
    Haptics.warning()
  }

  private var summary: some View {
    let total = model.supplements.count
    let done = model.supplements.filter { $0.done }.count
    return DrawerSection {
      StatStrip(stats: [
        Stat(value: "\(done)/\(total)", label: "taken today", tint: accent),
      ])
    }
  }
}
