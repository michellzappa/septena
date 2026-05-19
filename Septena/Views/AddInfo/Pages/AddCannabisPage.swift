import SwiftUI

// Cannabis palette — mirrors the webapp command palette (components/
// command-palette.tsx :: page === "cannabis"). Rows, in order:
//
//   1. Start new capsule  → vape, no strain, hit 1
//   2. Continue · {strain} (or "Continue · Hit N") → vape, last strain,
//      next hit. "Continue" advances hit = lastHit+1 against the last
//      *vape* entry; wraps to 1 at the configured cap.
//   3. Start over · {strain} (one per configured strain, last-used first)
//      → vape, that strain, hit 1
//   4. Edible → edible, no strain, no hit
//
// The search query filters the per-strain rows only; the fixed rows
// (start/continue/edible) always show.

struct AddCannabisPage: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(HTTPOutbox.self) private var outbox
  @Environment(SectionTheme.self) private var theme
  @Environment(\.dismiss) private var dismiss
  @Bindable var router: AddInfoRouter
  @State private var strains: [CannabisStrain] = []
  @State private var usesPerCapsule: Int = 3
  @State private var entries: [CannabisEntry] = []
  @State private var working = false

  private var trimmed: String {
    router.query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // Last *vape* entry — edibles don't carry a hit and shouldn't influence
  // the suggested next hit or the pinned strain order.
  private var lastVape: CannabisEntry? {
    entries.reversed().first { $0.method == "vape" }
  }

  private var lastStrain: String? {
    entries.reversed().first { $0.method == "vape" && ($0.strain?.isEmpty == false) }?.strain
  }

  private var suggestedHit: Int {
    guard let h = lastVape?.hit else { return 1 }
    return (h >= 1 && h < usesPerCapsule) ? h + 1 : 1
  }

  // Strain list, with the last-used strain pinned to the top. If the last
  // strain isn't present in the configured strain list (e.g. user-typed in
  // an old entry), synthesize a row for it — same shim the webapp uses.
  private var orderedStrains: [CannabisStrain] {
    guard let last = lastStrain else { return strains }
    if let match = strains.first(where: { $0.name == last }) {
      return [match] + strains.filter { $0.name != last }
    }
    return [CannabisStrain(id: "last-strain", name: last)] + strains
  }

  private var filteredStrains: [CannabisStrain] {
    orderedStrains.filter { trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed) }
  }

  var body: some View {
    let tint = AddInfoSection.cannabis.accent(theme: theme)

    List {
      Section {
        Button { commit(method: "vape", strain: nil, hit: 1) } label: {
          AddInfoRow(
            title: "Start new capsule",
            subtitle: "No strain · hit 1",
            systemImage: "plus.circle",
            tint: tint
          )
        }
        .buttonStyle(.plain)
        .disabled(working)

        Button { continueCapsule() } label: {
          AddInfoRow(
            title: continueLabel,
            subtitle: "Keep current capsule · log hit \(suggestedHit)",
            systemImage: "arrow.clockwise",
            tint: tint
          )
        }
        .buttonStyle(.plain)
        .disabled(working)
      }

      if !filteredStrains.isEmpty {
        Section("Strains") {
          ForEach(filteredStrains) { strain in
            Button { commit(method: "vape", strain: strain.name, hit: 1) } label: {
              AddInfoRow(
                title: "Start over · \(strain.name)",
                subtitle: strain.name == lastStrain
                  ? "New capsule · reset to hit 1"
                  : "New capsule · hit 1",
                tint: tint
              )
            }
            .buttonStyle(.plain)
            .disabled(working)
          }
        }
      }

      Section {
        Button { commit(method: "edible", strain: nil, hit: nil) } label: {
          AddInfoRow(
            title: "Edible",
            subtitle: "Standalone",
            systemImage: "circle.fill",
            tint: tint
          )
        }
        .buttonStyle(.plain)
        .disabled(working)
      }
    }
    .task { await load() }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #endif
  }

  private var continueLabel: String {
    if let s = lastStrain { return "Continue · \(s)" }
    return "Continue · Hit \(suggestedHit)"
  }

  private func continueCapsule() {
    commit(method: "vape", strain: lastStrain, hit: suggestedHit)
  }

  private func commit(method: String, strain: String?, hit: Int?) {
    let time = nowHHMM()
    var body: [String: Any] = [
      "date": SeptenaDate.today,
      "time": time,
      "method": method,
    ]
    if let strain { body["strain"] = strain }
    if let hit { body["hit"] = hit }
    outbox.enqueue(method: "POST", path: "/api/cannabis/entry",
                   body: body, kind: "cannabis.add")
    // Optimistically advance the cached day so a quick re-open of the FAB
    // progresses from this hit rather than the stale server state, which
    // hasn't been written yet by the outbox.
    appendToCache(method: method, strain: strain, hit: hit, time: time)
    AddInfoSection.cannabis.notifyTilesChanged()
    Haptics.tick()
    dismiss()
  }

  private func appendToCache(method: String, strain: String?, hit: Int?, time: String) {
    let newEntry = CannabisEntry(
      id: "pending-\(UUID().uuidString)",
      time: time,
      method: method,
      strain: strain,
      hit: hit,
      grams: nil,
      note: nil,
      effect: nil
    )
    let prior = ResponseCache.load(CannabisDayResponse.self, forKey: "cannabis.today")
    let next = (prior?.entries ?? []) + [newEntry]
    let updated = CannabisDayResponse(
      date: prior?.date ?? SeptenaDate.today,
      entries: next,
      sessionCount: (prior?.sessionCount ?? 0) + 1,
      totalG: prior?.totalG
    )
    ResponseCache.save(updated, forKey: "cannabis.today")
    entries = next
  }

  private func load() async {
    // Paint last-known state from cache first so we don't regress to an older
    // server snapshot while an enqueued add is still draining.
    if let cached = ResponseCache.load(CannabisDayResponse.self, forKey: "cannabis.today") {
      entries = cached.entries
    }
    if let cfg = try? await client.cannabisConfig() {
      strains = cfg.strains
      usesPerCapsule = max(1, cfg.usesPerCapsule)
    }
    if let day = try? await client.cannabisDay(date: SeptenaDate.today) {
      let cached = ResponseCache.load(CannabisDayResponse.self, forKey: "cannabis.today")
      if (cached?.entries.count ?? 0) <= day.entries.count {
        entries = day.entries
        ResponseCache.save(day, forKey: "cannabis.today")
      } else {
        entries = cached?.entries ?? day.entries
      }
    }
  }
}
