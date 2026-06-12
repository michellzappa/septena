import SwiftUI

// Meal capture — dedup recent 30-day entries by foods[0], sort by frequency
// (recency tiebreak), cap at 30. Tap duplicates the entry at the current
// time. Macros come along for the ride.

private struct MealCandidate: Identifiable {
  let id: String
  let representative: NutritionEntry
  let count: Int
}

struct AddNutritionPage: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?
  @Bindable var router: AddInfoRouter
  @State private var recent: [NutritionEntry] = []
  @State private var working = false

  private var trimmed: String {
    router.query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    let tint = AddInfoSection.nutrition.accent(theme: theme)
    let candidates = dedup(recent)
      .filter { trimmed.isEmpty || $0.representative.foods.contains(where: { $0.localizedCaseInsensitiveContains(trimmed) }) }

    List {
      if candidates.isEmpty {
        Section { Text("No recent meals").foregroundStyle(.secondary) }
      } else {
        Section("Recent") {
          ForEach(candidates) { meal in
            Button { duplicate(meal.representative) } label: {
              AddInfoRow(
                title: title(for: meal.representative),
                subtitle: macros(for: meal),
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

  private func title(for entry: NutritionEntry) -> String {
    let head = entry.foods.first ?? "Meal"
    if let emoji = entry.emoji, !emoji.isEmpty { return "\(emoji) \(head)" }
    return head
  }

  private func macros(for meal: MealCandidate) -> String {
    let e = meal.representative
    let parts = [
      meal.count > 1 ? "\(meal.count)×" : nil,
      "\(Int(e.proteinG))P",
      "\(Int(e.fatG))F",
      "\(Int(e.carbsG))C",
      "\(Int(e.kcal))kcal",
    ].compactMap { $0 }
    return parts.joined(separator: " · ")
  }

  private func dedup(_ entries: [NutritionEntry]) -> [MealCandidate] {
    // Pick the most-recent representative per dedup key so the row's
    // macros reflect the latest version of that meal (the user may have
    // re-logged it with updated grams).
    var bucketed: [String: (NutritionEntry, Int)] = [:]
    for e in entries {
      guard let first = e.foods.first?.lowercased() else { continue }
      if let existing = bucketed[first] {
        let prevKey = existing.0.date + existing.0.time
        let curKey  = e.date + e.time
        let rep = curKey > prevKey ? e : existing.0
        bucketed[first] = (rep, existing.1 + 1)
      } else {
        bucketed[first] = (e, 1)
      }
    }
    return bucketed.map { (key, value) in
      MealCandidate(id: key, representative: value.0, count: value.1)
    }
    // Sort by recency of last occurrence; frequency only as tiebreaker.
    // Matches the user's expectation that the freshest meal is on top.
    .sorted { lhs, rhs in
      let l = lhs.representative.date + lhs.representative.time
      let r = rhs.representative.date + rhs.representative.time
      if l != r { return l > r }
      return lhs.count > rhs.count
    }
    .prefix(30)
    .map { $0 }
  }

  private func duplicate(_ entry: NutritionEntry) {
    NutritionPlugin.commitMeal(
      loggedAt: .now,
      accent: AddInfoSection.nutrition.accent(theme: theme),
      announce: "Logged \(entry.foods.first ?? "meal").",
      logCommit: logCommit
    ) {
      SeptenaServices.shared.nutritionMutator.addEntry(
        loggedAt: Date.now,
        emoji: entry.emoji,
        foods: entry.foods,
        proteinG: entry.proteinG,
        fatG: entry.fatG,
        carbsG: entry.carbsG,
        fiberG: entry.fiberG,
        kcal: entry.kcal
      )
      AddInfoSection.nutrition.notifyTilesChanged()
    }
    dismiss()
  }

  private func load() async {
    let since = ymd(daysAgo: 30)
    recent = ChecklistMirror.loadNutritionEntries(context: modelContext, since: since)
  }
}

private func ymd(daysAgo: Int) -> String {
  let d = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
  return SeptenaDate.format(d) ?? SeptenaDate.today
}
