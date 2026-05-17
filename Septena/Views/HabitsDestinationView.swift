import SwiftUI

// Habits mini-app — full-day list grouped by time-of-day bucket. Reached
// by tapping the Habits tile on the Week dashboard. Reuses NextItemsModel
// for loading + optimistic mutations and HabitRow for the row UI, so the
// behavior is identical to the Next tab's current-bucket strip — just
// showing every bucket rather than only "now".

struct HabitsDestinationView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme

  @State private var model = NextItemsModel()

  /// Server section key; accent comes from the user's Septena config so the
  /// hue matches the webapp / sidebar / Next tab without hard-coding.
  private var accent: Color { theme.color(for: "habits") }

  var body: some View {
    List {
      summary
      ForEach(model.habitBuckets, id: \.self) { bucket in
        bucketSection(bucket)
      }
    }
    #if os(macOS)
    .listStyle(.inset)
    #else
    .listStyle(.insetGrouped)
    #endif
    .background(Theme.groupedBackground)
    .navigationTitle("Habits")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .tint(accent)
    .task { await model.load(client: client) }
    .refreshable { await model.load(client: client) }
  }

  // MARK: - Sections

  private var summary: some View {
    let total = model.habits.count
    let done = model.habits.filter { $0.done }.count
    let skipped = model.habits.filter { $0.skipped }.count
    return Section {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("\(done)/\(total)")
            .font(.system(.title2, design: .rounded).weight(.semibold))
            .foregroundStyle(accent)
          Text("done today")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if skipped > 0 {
          VStack(alignment: .trailing, spacing: 2) {
            Text("\(skipped)")
              .font(.system(.title3, design: .rounded).weight(.semibold))
              .foregroundStyle(.secondary)
            Text("skipped")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func bucketSection(_ bucket: String) -> some View {
    let items = model.habits.filter { $0.bucket == bucket }
    let doneCount = items.filter { $0.done }.count
    if !items.isEmpty {
      Section {
        ForEach(items) { habit in
          HabitRow(habit: habit, model: model, client: client, tint: accent)
            .listRowInsets(EdgeInsets())
        }
      } header: {
        HStack {
          Text(bucket.capitalized)
          Spacer()
          Text("\(doneCount)/\(items.count)")
            .monospacedDigit()
        }
      }
    }
  }
}
