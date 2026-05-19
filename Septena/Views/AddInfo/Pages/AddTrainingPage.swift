import SwiftUI

// Training page — suggested session pinned at top, then static fallback
// types. v1 dismisses and lets the user complete the session in whatever
// training UI exists; no draft state is persisted from here. Mirrors the
// webapp's flow up to the point where IndexedDB draft logic kicks in.

private let staticSessionTypes: [String] = [
  "Upper", "Lower", "Push", "Pull", "Conditioning", "Cardio",
]

struct AddTrainingPage: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme
  @Environment(\.dismiss) private var dismiss
  @Bindable var router: AddInfoRouter
  @State private var suggested: SuggestedWorkout? = nil
  @State private var daysAgo: [String: Int] = [:]

  private var trimmed: String {
    router.query.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let types = staticSessionTypes
          .filter { trimmed.isEmpty || $0.localizedCaseInsensitiveContains(trimmed) }
        ForEach(types, id: \.self) { type in
          Button { start(type) } label: {
            AddInfoRow(
              title: type,
              subtitle: subtitle(for: type),
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

  private func subtitle(for type: String) -> String? {
    guard let n = daysAgo[type.lowercased()] else { return nil }
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
    if let resp = try? await client.suggestedWorkout() {
      suggested = resp.suggested
      daysAgo = resp.daysAgo
    }
  }
}
