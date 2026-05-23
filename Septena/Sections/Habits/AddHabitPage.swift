import SwiftUI

// Habits palette — undone-only + time-of-day bucket filter. Tap toggles
// done. Type a new name to create in the current bucket (morning before
// 12, afternoon 12–17, evening after 17).

private enum DayBucket: String, CaseIterable {
  case morning, afternoon, evening
  static var current: DayBucket {
    let h = Calendar.current.component(.hour, from: .now)
    if h < 12 { return .morning }
    if h < 17 { return .afternoon }
    return .evening
  }
}

private func visibleBuckets(_ all: [String]) -> [String] {
  // Index into a canonical [morning, afternoon, evening] order so that an
  // unknown bucket name is treated as "always visible" (defensive against
  // server-side renames).
  let canonical: [String] = DayBucket.allCases.map { $0.rawValue }
  let cutoffIndex = canonical.firstIndex(of: DayBucket.current.rawValue) ?? canonical.count - 1
  return all.filter { name in
    if let idx = canonical.firstIndex(of: name.lowercased()) {
      return idx <= cutoffIndex
    }
    return true
  }
}

struct AddHabitPage: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(ChecklistMutator.self) private var checklistMutator
  @Environment(SectionTheme.self) private var theme
  @Environment(\.dismiss) private var dismiss
  @Bindable var router: AddInfoRouter
  @State private var day: HabitsDayResponse? = nil
  @State private var working = false

  private var trimmed: String {
    router.query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    let tint = AddInfoSection.habits.accent(theme: theme)
    List {
      if !trimmed.isEmpty, !hasExactMatch {
        Section {
          Button { create(name: trimmed) } label: {
            AddInfoRow(
              title: "Add: “\(trimmed)”",
              subtitle: createBucket.capitalized,
              systemImage: "plus.circle.fill",
              tint: tint
            )
          }
          .buttonStyle(.plain)
          .disabled(working)
        }
      }
      if let day {
        ForEach(visibleBuckets(day.buckets), id: \.self) { bucket in
          let items = (day.grouped[bucket] ?? [])
            .filter { !$0.done && !$0.skipped }
            .filter { trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed) }
          if !items.isEmpty {
            Section(bucket.capitalized) {
              ForEach(items) { item in
                Button { toggle(item) } label: {
                  AddInfoRow(
                    title: item.name,
                    subtitle: nil,
                    tint: tint,
                    accessory: .check(false)
                  )
                }
                .buttonStyle(.plain)
              }
            }
          }
        }
      }
    }
    .task { await load() }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #endif
  }

  private var hasExactMatch: Bool {
    guard let day else { return false }
    return day.grouped.values.contains { items in
      items.contains { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
    }
  }

  /// Bucket for type-to-create: first visible bucket today, fallback morning.
  private var createBucket: String {
    if let day, let first = visibleBuckets(day.buckets).first { return first }
    return DayBucket.current.rawValue
  }

  private func toggle(_ item: HabitDayItem) {
    checklistMutator.toggleHabit(id: item.id, date: SeptenaDate.today, done: true)
    AddInfoSection.habits.notifyTilesChanged()
    Haptics.tick()
    dismiss()
  }

  private func create(name: String) {
    guard !working else { return }
    working = true
    _ = checklistMutator.createHabit(name: name, bucket: createBucket)
    working = false
    AddInfoSection.habits.notifyTilesChanged()
    Haptics.tick()
    dismiss()
  }

  private func load() async {
    let context = LocalStore.shared.container.mainContext
    // Habits are CloudKit-authoritative — read directly from the local mirror.
    day = ChecklistMirror.loadHabitsDay(context: context, date: SeptenaDate.today)
  }
}
