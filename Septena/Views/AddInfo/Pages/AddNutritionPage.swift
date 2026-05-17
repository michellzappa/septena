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
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme
  @Environment(\.dismiss) private var dismiss
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
                systemImage: "fork.knife",
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
    var bucketed: [String: (NutritionEntry, Int)] = [:]
    for e in entries {
      guard let first = e.foods.first?.lowercased() else { continue }
      if let existing = bucketed[first] {
        bucketed[first] = (existing.0, existing.1 + 1)
      } else {
        bucketed[first] = (e, 1)
      }
    }
    return bucketed.map { (key, value) in
      MealCandidate(id: key, representative: value.0, count: value.1)
    }
    .sorted { lhs, rhs in
      if lhs.count != rhs.count { return lhs.count > rhs.count }
      let l = lhs.representative.date + lhs.representative.time
      let r = rhs.representative.date + rhs.representative.time
      return l > r
    }
    .prefix(30)
    .map { $0 }
  }

  private func duplicate(_ entry: NutritionEntry) {
    guard !working else { return }
    working = true
    Task {
      defer { working = false }
      do {
        let now = nowHHMM()
        try await client.addNutritionEntry(
          date: SeptenaDate.today,
          time: now,
          foods: entry.foods,
          proteinG: entry.proteinG,
          fatG: entry.fatG,
          carbsG: entry.carbsG,
          fiberG: entry.fiberG,
          kcal: entry.kcal,
          emoji: entry.emoji
        )
        Haptics.tick()
        dismiss()
      } catch { Haptics.warning() }
    }
  }

  private func load() async {
    let since = ymd(daysAgo: 30)
    recent = (try? await client.nutritionEntries(since: since)) ?? []
  }
}

private func ymd(daysAgo: Int) -> String {
  let d = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
  return SeptenaDate.format(d) ?? SeptenaDate.today
}

func nowHHMM() -> String {
  let f = DateFormatter()
  f.dateFormat = "HH:mm"
  f.locale = Locale(identifier: "en_US_POSIX")
  return f.string(from: .now)
}
