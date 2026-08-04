import SwiftUI

enum NutritionRelogging {
  static let defaultPercent = 100
  static let range = 10...300
  static let step = 10

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
                           percent: Int = defaultPercent,
                           loggedAt: Date = .now) -> NutritionEntryEntity {
    let factor = factor(for: percent)
    return SeptenaServices.shared.nutritionMutator.addEntry(
      loggedAt: loggedAt,
      emoji: entry.emoji,
      foods: entry.foods,
      ingredients: entry.ingredients,
      proteinG: scaled(entry.proteinG, by: factor),
      fatG: scaled(entry.fatG, by: factor),
      carbsG: scaled(entry.carbsG, by: factor),
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

struct NutritionMultiplierControl: View {
  @Binding var percent: Int

  var body: some View {
    Stepper(value: $percent,
            in: NutritionRelogging.range,
            step: NutritionRelogging.step) {
      LabeledContent("Amount") {
        Text("\(percent)%")
          .font(.septenaMetric)
      }
    }
    .accessibilityLabel("Meal amount")
    .accessibilityValue("\(percent) percent")
  }
}
