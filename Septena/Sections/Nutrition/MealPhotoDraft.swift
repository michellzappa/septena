import Foundation

// What analyzing a meal photo produced — a *draft* the user confirms in the
// edit form, never a logged truth. Every field is optional: the analyzer fills
// what it can find and leaves the rest for the human. Two rungs feed this:
//
//   • `.model`  — on-device multimodal Foundation Models (iOS 27+, behind a
//                 capability gate). Reasons over a freeform plate photo.
//   • `.label`  — Vision OCR + barcode (any iOS 26+ device, no Apple
//                 Intelligence required). Reads a printed nutrition label.
//
// The two are merged (`merging`), model-first with the label filling gaps, so a
// device without the iOS-27 model still gets deterministic nutrition-label OCR.

struct MealPhotoDraft: Equatable {
  enum Source: Equatable { case model, label, mixed }

  var foods: [String] = []
  var ingredients: [String] = []

  var proteinG: Double?
  var fatG: Double?
  var saturatedFatG: Double?
  var carbsG: Double?
  var sugarG: Double?
  var fiberG: Double?
  var kcal: Double?
  var sodiumMg: Double?
  var cholesterolMg: Double?
  var potassiumMg: Double?

  /// A detected barcode payload, if any. Surfaced for a future packaged-food
  /// lookup (see `MealPhotoAnalyzer`); not resolved to nutrients yet.
  var barcode: String?

  var source: Source = .label

  /// True when nothing usable was extracted — the UI shows no "filled" note.
  var isEmpty: Bool {
    foods.isEmpty && ingredients.isEmpty && barcode == nil &&
      [proteinG, fatG, saturatedFatG, carbsG, sugarG, fiberG, kcal,
       sodiumMg, cholesterolMg, potassiumMg].allSatisfy { $0 == nil }
  }

  /// Short, human note for the form ("Filled from label", etc.). nil when empty.
  var note: String? {
    if isEmpty { return nil }
    switch source {
    case .model: return "Estimated from photo — check the numbers"
    case .label: return barcode != nil && macroCount == 0
      ? "Found a barcode — add details below"
      : "Filled from the label — check the numbers"
    case .mixed: return "Filled from photo and label — check the numbers"
    }
  }

  private var macroCount: Int {
    [proteinG, fatG, carbsG, kcal].compactMap { $0 }.count
  }

  /// Which on-device model produced this draft — for the "which model" caption.
  /// `.model` is the on-device multimodal Foundation Model; `.label` is
  /// deterministic Vision OCR/barcode; `.mixed` is both, led by the model.
  /// Never PCC: meal photos are analyzed on-device only.
  var modelTag: AIModelTag {
    switch source {
    case .model, .mixed: return .onDevice
    case .label:         return .onDeviceVision
    }
  }

  /// Combine two drafts, preferring `self`'s values and taking `other`'s only
  /// where `self` is missing. Used to layer the label rung under the model rung.
  func merging(_ other: MealPhotoDraft) -> MealPhotoDraft {
    var out = self
    if out.foods.isEmpty { out.foods = other.foods }
    if out.ingredients.isEmpty { out.ingredients = other.ingredients }
    out.proteinG = out.proteinG ?? other.proteinG
    out.fatG = out.fatG ?? other.fatG
    out.saturatedFatG = out.saturatedFatG ?? other.saturatedFatG
    out.carbsG = out.carbsG ?? other.carbsG
    out.sugarG = out.sugarG ?? other.sugarG
    out.fiberG = out.fiberG ?? other.fiberG
    out.kcal = out.kcal ?? other.kcal
    out.sodiumMg = out.sodiumMg ?? other.sodiumMg
    out.cholesterolMg = out.cholesterolMg ?? other.cholesterolMg
    out.potassiumMg = out.potassiumMg ?? other.potassiumMg
    out.barcode = out.barcode ?? other.barcode
    if isEmpty {
      out.source = other.source
    } else if other.isEmpty {
      out.source = source
    } else {
      out.source = .mixed
    }
    return out
  }
}
