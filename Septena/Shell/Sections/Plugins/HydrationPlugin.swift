import SwiftUI
import SwiftData

// Hydration is a UX layer over the existing Nutrition data — every
// hydration log is a NutritionEntryEntity with `foods: ["Water"]`,
// `waterMl > 0`, and all macros at 0. No new entity, no new CloudKit
// record type, no schema migration.
//
// Why: the Nutrition section already tracks per-meal `waterMl`. A
// dedicated hydration UX adds value (quick-add buttons, progress vs
// target, isolated log) without fragmenting the data.
//
// A real meal that records `waterMl` still counts toward the daily
// total; it just doesn't render as a separate hydration row (the
// Nutrition log already shows that meal). Hydration-specific rows
// are identified by the `foods == ["Water"]` sentinel.

@MainActor
enum HydrationPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["hydration"]!
  }

  /// Marker that distinguishes a water-only log from a meal entry that
  /// happens to record `waterMl`. Both contribute to the daily total;
  /// only the marker produces a Today event under "hydration" (the
  /// meal contributes under "nutrition" instead).
  static let waterFoodsMarker: [String] = ["Water"]

  static func isHydrationOnly(_ entry: NutritionEntry) -> Bool {
    entry.foods == waterFoodsMarker
      && (entry.waterMl ?? 0) > 0
      && entry.proteinG == 0
      && entry.fatG == 0
      && entry.carbsG == 0
  }

  // MARK: - Today timeline

  static func todayEvents(date: String, ctx: TodayContext) -> [TodayEvent] {
    let accent = ctx.theme.color(for: "hydration")
    return ctx.nutrition
      .filter { $0.date == date && isHydrationOnly($0) }
      .map { entry in
        let ml = Int(entry.waterMl ?? 0)
        return TodayEvent(
          id: "hyd-\(entry.id)",
          time: entry.time,
          section: "hydration",
          color: accent,
          title: "💧 \(ml) ml",
          detail: nil,
          kind: .nutrition(entry)
        )
      }
  }

  static func destinationView() -> AnyView? { AnyView(HydrationDestinationView()) }

  // MARK: - First-enable onboarding

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SectionExplainerView(
      sectionKey: "hydration",
      title: "Hydration",
      intro: "Tracks water intake against a daily target (default 2,000 ml). Each glass becomes a water-tagged nutrition entry, so meal logs count too.",
      bullets: [
        .init("One-tap presets", "250 / 330 / 500 ml, or enter a custom amount.", icon: "drop.fill"),
        .init("No double-counting", "Water you logged on a meal entry rolls into today's total automatically.", icon: "checkmark.seal"),
        .init("Lives on top of Nutrition", "No separate data store. Disabling Hydration leaves every glass intact in Nutrition.", icon: "square.stack.3d.up"),
      ],
      primaryActionLabel: "Start logging",
      complete: complete
    ))
  }

  // MARK: - MCP / agent contract

  static var mcpSkill: SectionSkill? {
    SectionSkill(
      key: "hydration",
      summary: "Log water intake. Backed by Nutrition (water-only entries).",
      tools: [
        SectionSkill.Tool("hydration_log", "Log a water intake in ml",
              inputs: "required: ml (int) · optional: loggedAt (ISO8601, defaults to now), note"),
        SectionSkill.Tool("hydration_today", "Today's total ml + entries (includes water recorded on meals)"),
        SectionSkill.Tool("hydration_history", "Daily totals over a range",
              inputs: "optional: from (date), to (date), days (int, default 7)"),
      ],
      body: """
      Hydration writes through Nutrition. Each `hydration_log` creates a \
      `nutrition_entry_log` with `foods: ["Water"]`, `waterMl: <ml>`, and \
      all macros set to 0. The daily summary tool already sums waterMl \
      across all nutrition entries — including water logged on real \
      meals — so `hydration_today` is effectively a view over \
      `nutrition_day_summary.waterMl`.

      Don't write hydration entries directly via `nutrition_entry_log` \
      unless you want them counted as meals; use `hydration_log` for \
      the water-only path.
      """
    )
  }
}

// MARK: - Destination view

private struct HydrationDestinationView: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(\.modelContext) private var modelContext
  @AppStorage("hydration.dailyTargetMl") private var targetMl: Int = 2000
  @State private var todayMl: Int = 0
  @State private var entries: [NutritionEntryEntity] = []
  @State private var showCustom = false

  private var accent: Color { theme.color(for: "hydration") }
  private var mutator: NutritionMutator { SeptenaServices.shared.nutritionMutator }

  private var progressFraction: Double {
    guard targetMl > 0 else { return 0 }
    return min(1, Double(todayMl) / Double(targetMl))
  }

  var body: some View {
    List {
      summary
      quickAdd
      log
      preferences
    }
    .navigationTitle("Hydration")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .task { reload() }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in reload() }
    .sheet(isPresented: $showCustom) {
      CustomAmountSheet(accent: accent) { ml in
        commit(ml: ml)
      }
    }
  }

  // MARK: Summary

  @ViewBuilder
  private var summary: some View {
    Section {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text("\(todayMl)").font(.system(.largeTitle, design: .rounded).weight(.semibold))
          Text("ml").font(.body).foregroundStyle(.secondary)
          Spacer()
          Text("of \(targetMl)")
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        ProgressView(value: progressFraction)
          .tint(accent)
      }
      .padding(.vertical, 4)
    } header: {
      Text("Today")
    }
  }

  // MARK: Quick-add

  private let presets: [Int] = [250, 330, 500]

  @ViewBuilder
  private var quickAdd: some View {
    Section("Quick add") {
      HStack(spacing: 10) {
        ForEach(presets, id: \.self) { ml in
          Button { commit(ml: ml) } label: {
            VStack(spacing: 2) {
              Text("\(ml)").font(.body.weight(.semibold)).monospacedDigit()
              Text("ml").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
          }
          .buttonStyle(.bordered)
          .tint(accent)
        }
        Button { showCustom = true } label: {
          VStack(spacing: 2) {
            Image(systemName: "plus")
            Text("Custom").font(.caption2)
          }
          .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(accent)
      }
    }
  }

  // MARK: Log

  @ViewBuilder
  private var log: some View {
    Section("Log") {
      if entries.isEmpty {
        Text("No water logged yet today.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(entries) { e in
          HStack {
            Text("💧 \(Int(e.waterMl ?? 0)) ml")
              .monospacedDigit()
            Spacer()
            Text(timeString(e.loggedAt))
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
              delete(e)
            } label: {
              Label("Delete", systemImage: "trash")
            }
          }
        }
      }
    }
  }

  // MARK: Preferences

  @ViewBuilder
  private var preferences: some View {
    Section("Daily target") {
      Stepper(value: $targetMl, in: 500...5000, step: 250) {
        HStack {
          Text("Target")
          Spacer()
          Text("\(targetMl) ml")
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
      }
    }
  }

  // MARK: Logic

  private func commit(ml: Int) {
    _ = mutator.addEntry(
      loggedAt: .now,
      emoji: "💧",
      foods: HydrationPlugin.waterFoodsMarker,
      mealType: nil,
      source: "manual",
      waterMl: Double(ml)
    )
    Haptics.tick()
    reload()
  }

  private func delete(_ e: NutritionEntryEntity) {
    mutator.deleteEntry(id: e.id)
    Haptics.tick()
    reload()
  }

  private func reload() {
    let today = SeptenaDate.today
    let descriptor = FetchDescriptor<NutritionEntryEntity>(
      sortBy: [SortDescriptor(\.loggedAt, order: .reverse)]
    )
    let all = (try? modelContext.fetch(descriptor)) ?? []
    let dayEntries = all.filter { dayString($0.loggedAt) == today }
    // Today's total includes ALL water (water-only logs + meal-attached water)
    todayMl = dayEntries.reduce(0) { $0 + Int($1.waterMl ?? 0) }
    // Log shows only water-only entries — the meals already appear in Nutrition
    entries = dayEntries.filter { isHydrationOnly($0) }
  }

  private func isHydrationOnly(_ e: NutritionEntryEntity) -> Bool {
    let foods = e.foods.split(separator: "\n").map(String.init)
    return foods == HydrationPlugin.waterFoodsMarker
      && (e.waterMl ?? 0) > 0
      && e.proteinG == 0 && e.fatG == 0 && e.carbsG == 0
  }

  private func dayString(_ d: Date) -> String {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: d)
  }

  private func timeString(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm"
    return f.string(from: d)
  }
}

// MARK: - Custom amount sheet

private struct CustomAmountSheet: View {
  let accent: Color
  let onCommit: (Int) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var ml: Int = 400

  var body: some View {
    NavigationStack {
      Form {
        Stepper(value: $ml, in: 50...2000, step: 50) {
          HStack {
            Text("Amount")
            Spacer()
            Text("\(ml) ml")
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Custom amount")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Log") {
            onCommit(ml)
            dismiss()
          }
          .tint(accent)
        }
      }
    }
    #if os(iOS)
    .presentationDetents([.medium])
    #endif
  }
}
