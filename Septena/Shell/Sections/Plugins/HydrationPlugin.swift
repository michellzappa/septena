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

  /// The day's total water (water-only logs + meal-attached water) straight
  /// from the local mirror — the same sum the destination view shows.
  ///
  /// This is the commit-time truth for the goal-crossing check. Display
  /// state must never gate it: the dashboard's `hydrationToday` is seeded
  /// from a cache whose "today" may be yesterday (launch after rollover) and
  /// can lag drawer logs — a stale base there mis-fires the once-a-day
  /// `.fill` flood on an ordinary glass.
  @MainActor
  static func waterMl(onDayStarting dayStart: Date,
                      in context: ModelContext) -> Int {
    guard let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
    else { return 0 }
    let descriptor = FetchDescriptor<NutritionEntryEntity>(
      predicate: #Predicate { $0.loggedAt >= dayStart && $0.loggedAt < dayEnd }
    )
    let rows = (try? context.fetch(descriptor)) ?? []
    return rows.reduce(0) { $0 + Int($1.waterMl ?? 0) }
  }

  static func destinationView() -> AnyView? { AnyView(HydrationDestinationView()) }

  // Every glass gets the calm `.bloom`, not the full-page `.fill` flood —
  // you log water many times a day, and by the "celebration budget" rule
  // (TaskComponents) a high-frequency moment never earns the canvas. The
  // `.fill` flood is *reserved* for the one glass that crosses the daily
  // target (see HydrationDestinationView.commit) — a once-a-day payoff that
  // actually means "you hit your goal," the hydration sibling of the tasks
  // `.arc` rule. Everyday glasses bloom; the goal glass floods.
  static var logFlourish: LogFlourish? { LogFlourish(motion: .bloom) }

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

  // MARK: - Notifications

  static var notificationDescriptors: [NotificationDescriptor] {
    [NotificationDescriptor(
      id: "hydration.behind", sectionKey: "hydration", title: String(localized: "Behind-on-water nudge", comment: "Scheduled notification name"),
      actions: [
        NotificationAction(id: NotificationActionID.hydrationAdd250, title: "💧 +250 ml"),
        NotificationAction(id: NotificationActionID.hydrationAdd500, title: "+500 ml"),
      ],
      priority: 5)]
  }

  static func evaluateNotification(_ descriptorID: String,
                                   context: ModelContext,
                                   now: Date) -> NotificationPlan? {
    guard descriptorID == "hydration.behind" else { return nil }
    // Same target the destination view's stepper writes (@AppStorage).
    let target = UserDefaults.standard.object(forKey: "hydration.dailyTargetMl") as? Int ?? 2000
    guard target > 0 else { return nil }

    let today = SeptenaDate.today
    let entries = (try? context.fetch(FetchDescriptor<NutritionEntryEntity>())) ?? []
    let dayMl = entries
      .filter { SeptenaDate.format($0.loggedAt) == today }
      .reduce(0) { $0 + Int($1.waterMl ?? 0) }
    guard dayMl < target else { return nil }   // hit the target → suppress

    // A late-afternoon check-in: enough of the day left to act on it.
    return NotificationPlan(descriptorID: descriptorID, title: String(localized: "Hydration"),
                            body: String(localized: "You’re at \(dayMl) of \(target) ml — log a glass?"),
                            threadID: "hydration", hour: 17, minute: 0)
  }
}

// MARK: - Destination view

private struct HydrationDestinationView: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(\.modelContext) private var modelContext
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?
  @Environment(DayClock.self) private var clock
  @AppStorage("hydration.dailyTargetMl") private var targetMl: Int = 2000
  /// Total ml on the currently-viewed day (today, or a past day reached
  /// via the drawer's time-travel strip). Includes water recorded on
  /// meals, matching the daily-total convention.
  @State private var dayMl: Int = 0
  @State private var entries: [NutritionEntryEntity] = []
  @State private var showCustom = false
  /// The day the drawer is viewing. Bound to `SectionDrawer.currentDate`
  /// so the user can step prev/next through past days; `reload()`
  /// re-fetches for the selected day. Defaults to today.
  @State private var viewingDate: String = SeptenaDate.today

  private var accent: Color { theme.color(for: "hydration") }
  private var mutator: NutritionMutator { SeptenaServices.shared.nutritionMutator }

  /// On a past day the quick-add presets, the live progress summary, and
  /// the target stepper are suppressed — those are "today" affordances.
  /// A past day is a read-only review of that day's logged glasses.
  private var isViewingToday: Bool { viewingDate == SeptenaDate.today }

  private var progressFraction: Double {
    guard targetMl > 0 else { return 0 }
    return min(1, Double(dayMl) / Double(targetMl))
  }

  var body: some View {
    SectionDrawer(sectionKey: "hydration",
                  currentDate: $viewingDate) {
      if isViewingToday {
        summaryCard
        quickAddCard
      } else {
        pastDayHeader
      }
      logCard
      if isViewingToday {
        preferencesCard
      }
    }
    .tint(accent)
    .task { reload() }
    .onChange(of: viewingDate) { _, _ in reload() }
    // Roll the viewing pointer forward at midnight only if the user was
    // already on "today"; otherwise leave their selection put.
    .onChange(of: clock.today) { _, newToday in
      if isViewingToday { viewingDate = newToday }
      reload()
    }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { note in
      if note.affectsSection("hydration") { reload() }
    }
    .sheet(isPresented: $showCustom) {
      CustomAmountSheet(accent: accent) { ml in
        commit(ml: ml)
      }
    }
  }

  // MARK: Summary

  @ViewBuilder
  private var summaryCard: some View {
    DrawerSection("Today") {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text("\(dayMl)").font(.system(.largeTitle, design: .rounded).weight(.semibold))
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
    }
  }

  /// Compact total shown at the top of a past day (no progress vs target —
  /// the target is a "today" goal, meaningless retro).
  @ViewBuilder
  private var pastDayHeader: some View {
    DrawerSection {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text("\(dayMl)").font(.system(.title, design: .rounded).weight(.semibold))
        Text("ml").font(.body).foregroundStyle(.secondary)
        Spacer()
        Text(viewingDate)
          .font(.callout)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
    }
  }

  // MARK: Quick-add

  private let presets: [Int] = [250, 330, 500]

  @ViewBuilder
  private var quickAddCard: some View {
    DrawerSection("Quick add") {
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
  private var logCard: some View {
    DrawerSection(isViewingToday ? "Log" : nil, padding: .none) {
      if entries.isEmpty {
        Text(isViewingToday ? "No water logged yet today." : "No water logged on this day.")
          .foregroundStyle(.secondary)
          .padding(.horizontal, 14)
          .padding(.vertical, 12)
      } else {
        ForEach(entries) { e in
          LogEntryRow(
            title: "💧 \(Int(e.waterMl ?? 0)) ml",
            trailing: timeString(e.loggedAt),
            onDelete: { delete(e) }
          )
        }
      }
    }
  }

  // MARK: Preferences

  @ViewBuilder
  private var preferencesCard: some View {
    DrawerSection("Daily target") {
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
    // Does THIS glass take you from under your target to at/over it? That's
    // the earned moment: it plays the full-page `.fill` flood, once. Only on
    // today (the target is a "today" goal) and only on the crossing — the
    // next glass after you've hit the goal blooms like the rest.
    let crossed = isViewingToday
      && targetMl > 0
      && dayMl < targetMl
      && dayMl + ml >= targetMl

    // The crossing floods near-full; an everyday glass blooms, its reach
    // scaling gently with the amount (a 500ml glass is the calibrated 1.0).
    let motion: CommitMotion? = crossed ? .fill : nil   // nil → plugin's `.bloom`
    let intensity = crossed ? 1.4 : min(1.4, max(0.6, Double(ml) / 500))
    let announce = crossed
      ? "Hydration goal reached — \(dayMl + ml) of \(targetMl) ml."
      : "Logged \(ml) ml of water."

    SectionLog.newLog(
      section: "hydration",
      accent: accent,
      motion: motion,
      intensity: intensity,
      announce: announce,
      logCommit: logCommit
    ) {
      _ = mutator.addEntry(
        loggedAt: .now,
        emoji: "💧",
        foods: HydrationPlugin.waterFoodsMarker,
        mealType: nil,
        source: "manual",
        waterMl: Double(ml)
      )
      reload()
    }
  }

  private func delete(_ e: NutritionEntryEntity) {
    mutator.deleteEntry(id: e.id)
    Haptics.tick()
    reload()
  }

  private func reload() {
    let descriptor = FetchDescriptor<NutritionEntryEntity>(
      sortBy: [SortDescriptor(\.loggedAt, order: .reverse)]
    )
    let all = (try? modelContext.fetch(descriptor)) ?? []
    let dayEntries = all.filter { dayString($0.loggedAt) == viewingDate }
    // The day's total includes ALL water (water-only logs + meal-attached water)
    dayMl = dayEntries.reduce(0) { $0 + Int($1.waterMl ?? 0) }
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
