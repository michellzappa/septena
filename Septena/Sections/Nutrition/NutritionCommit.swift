import SwiftUI
import SwiftData

// The one new-meal commit path — extracted from NutritionPlugin so the meal
// sheets (New / Edit) compile into Septask, which embeds them behind the Next
// fold's fast-break suggestion and Done Today editor but does not compile the
// section plugins. Policy unchanged: only the day's FIRST real meal — the one
// that breaks the overnight fast — earns a flourish (the calm `.bloom`); every
// later meal commits quietly (tick + announce, no canvas).
enum NutritionCommit {
  /// Hydration's water-only sentinel foods list. Defined here (nutrition owns
  /// the entry shape); `HydrationPlugin.waterFoodsMarker` forwards to it.
  static let waterFoodsMarker: [String] = ["Water"]

  /// Decides fast-breaking `.bloom` vs quiet tick from the local mirror at
  /// commit time (never display state), then routes through `SectionLog`.
  /// Water-only rows (hydration's sentinel) don't break a fast, and only
  /// *today's* first meal celebrates — a past-day backfill is a correction,
  /// not a moment.
  @MainActor
  static func commitMeal(loggedAt: Date,
                         today: String,
                         accent: Color,
                         announce: String? = nil,
                         logCommit: LogCommitCenter?,
                         write: () -> Void) {
    if breaksFast(at: loggedAt, today: today) {
      SectionLog.newLog(section: "nutrition", accent: accent,
                        announce: announce, canvas: true,
                        canvasCaption: String(localized: "Broke fast",
                                              comment: "First meal canvas caption"),
                        canvasVoteEyebrow: false,
                        logCommit: logCommit, write: write)
    } else {
      SectionLog.quietLog(announce: announce, write: write)
    }
  }

  /// True when `loggedAt` is today and no real meal (non-water entry)
  /// exists earlier that day in the local mirror.
  @MainActor
  private static func breaksFast(at loggedAt: Date, today: String) -> Bool {
    let cal = Calendar.current
    guard let todayDate = SeptenaDate.parse(today),
          cal.isDate(loggedAt, inSameDayAs: todayDate) else { return false }
    let dayStart = cal.startOfDay(for: loggedAt)
    guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return false }
    let descriptor = FetchDescriptor<NutritionEntryEntity>(
      predicate: #Predicate { $0.loggedAt >= dayStart && $0.loggedAt < dayEnd }
    )
    let rows = (try? LocalStore.shared.container.mainContext.fetch(descriptor)) ?? []
    return !rows.contains { !isWaterOnly($0) }
  }

  /// Hydration's water-only sentinel, on the entity (mirrors
  /// `HydrationPlugin.isHydrationOnly` for the DTO).
  private static func isWaterOnly(_ e: NutritionEntryEntity) -> Bool {
    e.foods.split(separator: "\n").map(String.init) == waterFoodsMarker
      && (e.waterMl ?? 0) > 0
      && e.proteinG == 0 && e.fatG == 0 && e.carbsG == 0
  }
}
