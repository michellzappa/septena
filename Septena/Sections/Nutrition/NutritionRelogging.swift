import SwiftUI

enum NutritionRelogging {
  /// Duplicating a meal is always a 1:1 copy. To eat more or less of it,
  /// log it, then scale the logged entry (see `scale(_:percent:)`).
  /// The rungs offered in the scale menu, 50%–200%. 100% is omitted —
  /// it's a no-op.
  static let scaleOptions = [50, 75, 125, 150, 200]

  static func factor(for percent: Int) -> Double {
    Double(percent) / 100.0
  }

  static func scaled(_ value: Double, by factor: Double) -> Double {
    value * factor
  }

  static func scaled(_ value: Double?, by factor: Double) -> Double? {
    guard let value else { return nil }
    let scaled = value * factor
    return scaled == 0 ? nil : scaled
  }

  @discardableResult
  @MainActor
  static func addDuplicate(_ entry: NutritionEntry,
                           loggedAt: Date = .now) -> NutritionEntryEntity {
    SeptenaServices.shared.nutritionMutator.addEntry(
      loggedAt: loggedAt,
      emoji: entry.emoji,
      foods: entry.foods,
      ingredients: entry.ingredients,
      proteinG: entry.proteinG,
      fatG: entry.fatG,
      carbsG: entry.carbsG,
      fiberG: entry.fiberG,
      sugarG: entry.sugarG,
      saturatedFatG: entry.saturatedFatG,
      alcoholG: entry.alcoholG,
      kcal: entry.kcal == 0 ? nil : entry.kcal,
      sodiumMg: entry.sodiumMg,
      cholesterolMg: entry.cholesterolMg,
      potassiumMg: entry.potassiumMg,
      waterMl: entry.waterMl
    )
  }

  /// Scale a meal that is already logged — multiply every macro in place.
  /// `percent` is relative to the entry's current values, so 150% on a
  /// 150%-scaled entry gives 225%. Fields that are nil stay nil.
  @MainActor
  static func scale(_ entry: NutritionEntry, percent: Int) {
    let factor = factor(for: percent)
    SeptenaServices.shared.nutritionMutator.updateEntry(
      id: entry.file,
      // Explicit multiply on the non-optional macros — passing them to
      // `scaled` is ambiguous between the Double and Double? overloads.
      proteinG: entry.proteinG * factor,
      fatG: entry.fatG * factor,
      carbsG: entry.carbsG * factor,
      fiberG: scaled(entry.fiberG, by: factor),
      sugarG: scaled(entry.sugarG, by: factor),
      saturatedFatG: scaled(entry.saturatedFatG, by: factor),
      alcoholG: scaled(entry.alcoholG, by: factor),
      kcal: entry.kcal == 0 ? nil : entry.kcal * factor,
      sodiumMg: scaled(entry.sodiumMg, by: factor),
      cholesterolMg: scaled(entry.cholesterolMg, by: factor),
      potassiumMg: scaled(entry.potassiumMg, by: factor),
      waterMl: scaled(entry.waterMl, by: factor)
    )
  }
}

/// Scale-an-existing-meal menu. Lives in the logged entry's context menu —
/// duplicating is always 100%, scaling changes what is already on the day.
struct NutritionScaleMenu: View {
  let onScale: (Int) -> Void

  var body: some View {
    Menu {
      ForEach(NutritionRelogging.scaleOptions, id: \.self) { percent in
        Button("\(percent)%") { onScale(percent) }
      }
    } label: {
      Label("Scale portion", systemImage: "arrow.up.left.and.arrow.down.right")
    }
  }
}
