import SwiftUI

// Training page — suggested session pinned at top, then the user's
// real (non-archived) SessionTypeConfig list pulled from SwiftData.
// No more hardcoded fallback: every routine the user has authored
// (including Yoga, Conditioning, custom splits, etc.) shows up here.

struct AddTrainingPage: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(DayClock.self) private var clock
  @Environment(SectionTheme.self) private var theme
  @Environment(\.dismiss) private var dismiss
  @Bindable var router: AddInfoRouter
  @State private var suggested: SuggestedWorkout? = nil
  @State private var daysAgo: [String: Int] = [:]
  @State private var sessionTypes: [SessionTypeConfig] = []

  private var trimmed: String {
    router.query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var filteredTypes: [SessionTypeConfig] {
    let active = sessionTypes.filter { !$0.archived }
    guard !trimmed.isEmpty else { return active }
    return active.filter {
      $0.label.localizedCaseInsensitiveContains(trimmed) ||
      $0.id.localizedCaseInsensitiveContains(trimmed)
    }
  }

  var body: some View {
    let tint = AddInfoSection.training.accent(theme: theme)
    List {
      if let suggested {
        Section("Suggested") {
          Button { start(suggested.type) } label: {
            AddInfoRow(
              title: suggested.type,
              subtitle: suggested.reason,
              systemImage: "sparkles",
              tint: tint
            )
          }
          .buttonStyle(.plain)
        }
      }
      Section("Session type") {
        ForEach(filteredTypes) { type in
          Button { start(type.label) } label: {
            AddInfoRow(
              title: type.label,
              subtitle: subtitle(for: type.id),
              systemImage: type.kind.icon,
              tint: tint
            )
          }
          .buttonStyle(.plain)
        }
      }
    }
    .task { await load() }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #endif
  }

  private func subtitle(for typeID: String) -> String? {
    guard let n = daysAgo[typeID.lowercased()] else { return nil }
    if n == 0 { return "Today" }
    if n == 1 { return "1 day ago" }
    return "\(n) days ago"
  }

  private func start(_ type: String) {
    // v1: no draft persistence — just dismiss. The user finishes the
    // session in the dedicated training UI (or web). Haptic confirms the
    // intent. Future work: hook a local draft store here.
    Haptics.tick()
    _ = type
    dismiss()
  }

  private func load() async {
    let resp = ChecklistMirror.loadSuggestedWorkout(context: modelContext, today: clock.today, now: clock.now)
    suggested = resp.suggested
    daysAgo = resp.daysAgo
    sessionTypes = ChecklistMirror.loadSessionTypes(context: modelContext) ?? []
  }
}
