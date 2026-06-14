import SwiftUI
import SwiftData

// Intake host destination — the kind switcher. Lists the user's trackers
// (caffeine, tea, …) and routes into a per-kind page. Option C: one host
// section, kinds are rows (not sections). Entry points to create a kind:
// the empty state and the "+" toolbar (and, later, the MCP tool). No manifest
// row yet — reached from the debug Settings entry. See docs/CONSUMABLES_PLAN.md.

struct IntakeDestinationView: View {
  @State private var kinds: [IntakeKindDTO] = []
  @State private var loading = true
  @State private var creating = false

  var body: some View {
    List {
      if kinds.isEmpty, !loading {
        emptyState
      } else {
        Section {
          ForEach(kinds) { kind in
            NavigationLink {
              IntakeKindPageView(kindID: kind.id)
            } label: {
              kindRow(kind)
            }
          }
        }
      }
    }
    .navigationTitle("Intake")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        // Route through the shared drawer control so the host "+" reads as the
        // same prominent accent-glass circle every section drawer renders —
        // not a bespoke flat toolbar glyph. (Per-kind pages use the same
        // component via SectionDrawer's `leadingLogActions`.)
        DrawerActionButton(
          actions: [LogAction(id: "new", title: "Add tracker", systemImage: "plus")],
          accent: .accentColor,
          onLog: { _ in creating = true })
      }
    }
    .sheet(isPresented: $creating) {
      IntakeKindWizard(onCreated: { _ in Task { await reload() } })
    }
    .sectionReload(onDataChange: true, forSections: ["intake"]) { await reload() }
  }

  private func kindRow(_ kind: IntakeKindDTO) -> some View {
    HStack(spacing: 12) {
      Image(systemName: kind.symbol)
        .font(.title3)
        .foregroundStyle(AdaptiveColor.adaptive(kind.color) ?? Color.secondary)
        .frame(width: 30)
      VStack(alignment: .leading, spacing: 1) {
        Text(kind.name)
        Text(kind.eventCount == 1 ? "1 entry" : "\(kind.eventCount) entries")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label("No trackers yet", systemImage: "cup.and.saucer")
    } description: {
      Text("Add a tracker for anything you consume — each keeps its own doses and a streak counting the days since you last logged.")
    } actions: {
      Button("Create a tracker") { creating = true }
        .buttonStyle(.borderedProminent)
    }
  }

  private func reload() async {
    kinds = await MirrorReader.shared.read { IntakeReader.loadKinds(context: $0) }
    loading = false
  }
}
