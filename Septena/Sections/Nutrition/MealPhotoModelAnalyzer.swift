import Foundation
#if compiler(>=6.4)
import FoundationModels
import ImageIO
#endif

// iOS-27 multimodal seam — the ONE place that will pass an image to the
// on-device Foundation Model. Image input is an iOS-27 symbol family
// (`Attachment`, `ImageAttachmentContent`, `ImageReference`) that does NOT
// exist in the iOS-26 SDK. It compiles on 26 because the implementation is
// guarded by `#if compiler(>=6.4)`, the first Swift compiler bundled with the
// iOS-27/Xcode-27 SDK.
//
// Current Apple docs checked 2026-07-09:
//   • `Attachment(CGImage, orientation:)` is iOS 27 beta, and `.label(_:)`
//     gives the model turn a stable image identifier.
//   • `respond(generating:includeSchemaInPrompt:options:prompt:)` returns a
//     typed `LanguageModelSession.Response<Content>` where `Content: Generable`.
// Vision OCR/barcode runs as a separate deterministic rung in `MealPhotoAnalyzer`;
// the model turn stays image-only so beta tool calls cannot hold the form open.
// Until Xcode 27 is selected, the implementation below is skipped by
// `#if compiler(>=6.4)` so this repo still builds with the local 26 SDK.

enum MealPhotoModelAnalyzer {
  /// Analyze a meal photo with the on-device multimodal model. Returns nil when
  /// the platform/model can't do it — the caller falls back to the label rung.
  static func analyze(imageData: Data) async -> MealPhotoDraft? {
    guard await OnDeviceAI.supportsImageInput else { return nil }
    #if compiler(>=6.4)
    if #available(iOS 27, macOS 27, *) {
      return await analyzeWithFoundationModels(imageData: imageData)
    }
    #endif
    return nil
  }
}

#if compiler(>=6.4)
@available(iOS 27, macOS 27, *)
private extension MealPhotoModelAnalyzer {
  static func analyzeWithFoundationModels(imageData: Data) async -> MealPhotoDraft? {
    guard let image = cgImage(from: imageData) else { return nil }

    do {
      let session = LanguageModelSession()
      let response = try await session.respond(
        generating: MealPhotoEstimate.self,
        options: GenerationOptions(samplingMode: .greedy)
      ) {
        """
        Analyze this meal photo and return an editable nutrition draft.

        Requirements:
        - Identify the visible foods and ingredients.
        - Estimate the visible portion as one logged meal.
        - Estimate protein, fat, carbs, fiber, kcal, sugar, saturated fat,
          sodium, cholesterol, and potassium.
        - If a nutrition label is visible, read it visually and prefer label
          evidence over freeform visual estimation.
        - Use 0 only when a value cannot be reasonably estimated.
        - Keep names short enough to fit a meal log form.
        """

        Attachment(image).label("meal-photo")
      }

      return response.content.draft
    } catch {
      return nil
    }
  }

  static func cgImage(from data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      return nil
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 1280
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }
}

@available(iOS 27, macOS 27, *)
@Generable(description: "Editable nutrition estimate from a meal photo")
private struct MealPhotoEstimate {
  @Guide(description: "Short meal name")
  var mealName: String

  @Guide(description: "Comma-separated visible foods")
  var foods: String

  @Guide(description: "Comma-separated visible ingredients")
  var ingredients: String

  @Guide(description: "Visible portion summary")
  var portion: String

  @Guide(description: "Confidence from 0 to 1", .range(0...1))
  var confidence: Double

  @Guide(description: "Protein grams")
  var proteinG: Double

  @Guide(description: "Fat grams")
  var fatG: Double

  @Guide(description: "Saturated fat grams")
  var saturatedFatG: Double

  @Guide(description: "Carbohydrate grams")
  var carbsG: Double

  @Guide(description: "Sugar grams")
  var sugarG: Double

  @Guide(description: "Fiber grams")
  var fiberG: Double

  @Guide(description: "Calories in kcal")
  var kcal: Double

  @Guide(description: "Sodium milligrams")
  var sodiumMg: Double

  @Guide(description: "Cholesterol milligrams")
  var cholesterolMg: Double

  @Guide(description: "Potassium milligrams")
  var potassiumMg: Double

  var draft: MealPhotoDraft {
    var draft = MealPhotoDraft(source: .model)
    let parsedFoods = Self.list(from: foods)
    draft.foods = parsedFoods.isEmpty ? [mealName].filter { !$0.isEmpty } : parsedFoods
    draft.ingredients = Self.list(from: ingredients)
    draft.proteinG = Self.positive(proteinG)
    draft.fatG = Self.positive(fatG)
    draft.saturatedFatG = Self.positive(saturatedFatG)
    draft.carbsG = Self.positive(carbsG)
    draft.sugarG = Self.positive(sugarG)
    draft.fiberG = Self.positive(fiberG)
    draft.kcal = Self.positive(kcal)
    draft.sodiumMg = Self.positive(sodiumMg)
    draft.cholesterolMg = Self.positive(cholesterolMg)
    draft.potassiumMg = Self.positive(potassiumMg)
    return draft
  }

  private static func positive(_ value: Double) -> Double? {
    value > 0 ? value : nil
  }

  private static func list(from value: String) -> [String] {
    value
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}
#endif
