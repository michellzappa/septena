import SwiftUI

// Cannabis palette — "Continue capsule" advances `hit = lastHit+1` (resets
// to 1 at the configured cap). Per-strain rows always start a new capsule
// at hit 1 with that strain. Standalone edible row (no strain, no hit).

struct AddCannabisPage: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme
  @Environment(\.dismiss) private var dismiss
  @Bindable var router: AddInfoRouter
  @State private var strains: [CannabisStrain] = []
  @State private var usesPerCapsule: Int = 3
  @State private var lastEntry: CannabisEntry? = nil
  @State private var working = false

  private var trimmed: String {
    router.query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var nextHit: Int {
    guard let last = lastEntry, let h = last.hit, h < usesPerCapsule else { return 1 }
    return h + 1
  }

  var body: some View {
    let tint = AddInfoSection.cannabis.accent(theme: theme)
    let ordered: [CannabisStrain] = {
      guard let lastStrain = lastEntry?.strain else { return strains }
      let pinned = strains.filter { $0.name == lastStrain }
      let rest = strains.filter { $0.name != lastStrain }
      return pinned + rest
    }()
    let filtered = ordered.filter { trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed) }

    List {
      Section {
        Button { continueCapsule() } label: {
          AddInfoRow(
            title: "Continue capsule",
            subtitle: continueSubtitle,
            systemImage: "arrow.clockwise",
            tint: tint
          )
        }
        .buttonStyle(.plain)
        .disabled(working)

        Button { commit(method: "edible", strain: nil, hit: nil) } label: {
          AddInfoRow(
            title: "Edible",
            subtitle: nil,
            systemImage: "circle.fill",
            tint: tint
          )
        }
        .buttonStyle(.plain)
        .disabled(working)
      }
      if !filtered.isEmpty {
        Section("Strains") {
          ForEach(filtered) { strain in
            Button { commit(method: "vape", strain: strain.name, hit: 1) } label: {
              AddInfoRow(
                title: strain.name,
                subtitle: "New capsule · hit 1",
                systemImage: "leaf",
                tint: tint
              )
            }
            .buttonStyle(.plain)
            .disabled(working)
          }
        }
      }
    }
    .task { await load() }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #endif
  }

  private var continueSubtitle: String {
    let strain = lastEntry?.strain ?? "—"
    return "\(strain) · hit \(nextHit)/\(usesPerCapsule)"
  }

  private func continueCapsule() {
    commit(method: lastEntry?.method ?? "vape",
           strain: lastEntry?.strain,
           hit: nextHit)
  }

  private func commit(method: String, strain: String?, hit: Int?) {
    guard !working else { return }
    working = true
    Task {
      defer { working = false }
      do {
        try await client.addCannabisEntry(
          date: SeptenaDate.today,
          time: nowHHMM(),
          method: method,
          strain: strain,
          hit: hit
        )
        Haptics.tick()
        dismiss()
      } catch { Haptics.warning() }
    }
  }

  private func load() async {
    if let cfg = try? await client.cannabisConfig() {
      strains = cfg.strains
      usesPerCapsule = max(1, cfg.usesPerCapsule)
    }
    if let day = try? await client.cannabisDay(date: SeptenaDate.today) {
      lastEntry = day.entries.last
    }
  }
}
