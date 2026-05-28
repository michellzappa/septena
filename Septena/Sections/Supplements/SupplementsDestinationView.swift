import SwiftUI

// Supplements mini-app — single flat list of today's stack. Simpler than
// Habits (no time-of-day bucketing) and Chores (no defer / overdue);
// supplements are taken or not, that's it. Reuses NextItemsModel and the
// promoted SupplementRow.

struct SupplementsDestinationView: View {
  @Environment(ChecklistMutator.self) private var checklistMutator
  @Environment(SectionTheme.self) private var theme

  @State private var model = NextItemsModel()
  @State private var editing: SupplementDayItem? = nil
  @State private var creating = false
  @State private var history: [SupplementHistoryPoint] = []
  /// `.sheet(item:)` needs Identifiable; String isn't, so wrap.
  private struct BackfillDate: Identifiable { let id: String }
  @State private var backfillDate: BackfillDate? = nil

  private var accent: Color { theme.color(for: "supplements") }

  var body: some View {
    SectionDrawer(sectionKey: "supplements",
                  title: "Supplements",
                  onLog: { _ in creating = true }) {
      summary
      DrawerSection("Today", padding: .none) {
        ForEach(model.supplements) { supp in
          Button { editing = supp } label: {
            SupplementRow(supplement: supp, model: model, checklistMutator: checklistMutator, tint: accent,
                          onDelete: { delete(supp) })
          }
          .buttonStyle(.plain)
        }
      }
      if model.hasLoaded && model.supplements.isEmpty {
        ContentUnavailableView("No supplements configured",
                               systemImage: theme.icon(for: "supplements"),
                               description: Text("Add some in the webapp's Supplements settings."))
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
          onTapDay: { iso in backfillDate = BackfillDate(id: iso) }
        )
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
    .sheet(item: $editing) { supp in
      EditSupplementSheet(
        original: supp,
        onDone: { updated in
          if let updated, let idx = model.supplements.firstIndex(where: { $0.id == updated.id }) {
            model.supplements[idx] = updated
          }
        }
      )
    }
    .sheet(isPresented: $creating) {
      EditSupplementSheet(
        original: nil,
        onDone: { _ in Task { await model.load() } }
      )
      #if os(iOS)
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
      #endif
    }
    .sheet(item: $backfillDate) { wrap in
      BackfillSupplementsSheet(date: wrap.id)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }
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
