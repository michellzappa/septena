import SwiftUI

// Focused-search modal for re-logging a previously-eaten meal.
//
// Presented from the Nutrition QuickAdd menu's "Search…" item. Shows the
// full 30-day meal history deduped by foods[0], sorted by recency, with
// a `.searchable` text field at the top for filtering. Tap a row → posts
// a fresh nutrition entry at the current time (same payload as
// AddNutritionPage.duplicate()) → dismisses.
//
// Distinct from the AddInfo sheet (which lives behind "Nutrition…") so
// that the search affordance feels like a deliberate "find me a meal"
// modal rather than the broader capture palette.

struct NutritionSearchSheet: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(HTTPOutbox.self) private var outbox
  @Environment(\.dismiss) private var dismiss

  let entries: [NutritionEntry]
  @State private var query: String = ""

  private struct Candidate: Identifiable {
    let id: String
    let representative: NutritionEntry
    let count: Int
  }

  /// Dedup → sort by most-recent → cap at 100 (anything beyond is noise).
  private var candidates: [Candidate] {
    var bucketed: [String: (NutritionEntry, Int)] = [:]
    for e in entries {
      guard let first = e.foods.first?.lowercased() else { continue }
      if let existing = bucketed[first] {
        let prev = existing.0.date + existing.0.time
        let cur  = e.date + e.time
        let rep  = cur > prev ? e : existing.0
        bucketed[first] = (rep, existing.1 + 1)
      } else {
        bucketed[first] = (e, 1)
      }
    }
    return bucketed.map { key, value in
      Candidate(id: key, representative: value.0, count: value.1)
    }
    .sorted { lhs, rhs in
      let l = lhs.representative.date + lhs.representative.time
      let r = rhs.representative.date + rhs.representative.time
      return l > r
    }
    .prefix(100)
    .map { $0 }
  }

  private var filtered: [Candidate] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if q.isEmpty { return candidates }
    return candidates.filter { c in
      c.representative.foods.contains(where: { $0.localizedCaseInsensitiveContains(q) })
    }
  }

  var body: some View {
    NavigationStack {
      List {
        if filtered.isEmpty {
          Section {
            Text(query.isEmpty ? "No recent meals" : "No matches for “\(query)”")
              .foregroundStyle(.secondary)
          }
        } else {
          ForEach(filtered) { c in
            Button { duplicate(c.representative) } label: {
              row(c)
            }
            .buttonStyle(.plain)
          }
        }
      }
#if os(iOS) || os(tvOS)
      .listStyle(.insetGrouped)
#endif
      .navigationTitle("Search meals")
#if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
#endif
#if os(iOS) || os(tvOS)
      .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
#else
      .searchable(text: $query)
#endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
  }

  private func row(_ c: Candidate) -> some View {
    let e = c.representative
    let title: String = {
      let head = e.foods.first ?? "Meal"
      if let emoji = e.emoji, !emoji.isEmpty { return "\(emoji) \(head)" }
      return head
    }()
    let macros = [
      c.count > 1 ? "\(c.count)×" : nil,
      "\(Int(e.proteinG))P",
      "\(Int(e.fatG))F",
      "\(Int(e.carbsG))C",
      "\(Int(e.kcal))kcal",
    ].compactMap { $0 }.joined(separator: " · ")

    return VStack(alignment: .leading, spacing: 2) {
      Text(title)
      Text(macros)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }

  /// Same payload as AddNutritionPage.duplicate — POST a fresh entry at
  /// the current time, reusing the historical meal's macros + emoji.
  private func duplicate(_ entry: NutritionEntry) {
    var body: [String: Any] = [
      "date": SeptenaDate.today,
      "time": nowHHMM(),
      "foods": entry.foods,
      "protein_g": entry.proteinG,
      "fat_g": entry.fatG,
      "carbs_g": entry.carbsG,
      "kcal": entry.kcal,
    ]
    if let fiberG = entry.fiberG { body["fiber_g"] = fiberG }
    if let emoji = entry.emoji { body["emoji"] = emoji }
    outbox.enqueue(method: "POST", path: "/api/nutrition/entries",
                   body: body, kind: "nutrition.add")
    AddInfoSection.nutrition.notifyTilesChanged()
    Haptics.tick()
    dismiss()
  }
}
