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
        Button { creating = true } label: { Image(systemName: "plus") }
      }
    }
    .sheet(isPresented: $creating) {
      IntakeKindWizard(onCreated: { _ in Task { await reload() } })
    }
    .sectionReload(onDataChange: true) { await reload() }
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
      Text("Track anything you consume — each tracker gets its own methods, doses, and history.")
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
