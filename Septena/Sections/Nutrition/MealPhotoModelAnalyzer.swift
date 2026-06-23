import Foundation

// iOS-27 multimodal seam — the ONE place that will pass an image to the
// on-device Foundation Model. Image input is an iOS-27 symbol that does NOT
// exist in the iOS-26 SDK, so this file references no such symbol yet and
// returns nil today. It compiles on the 26 SDK exactly like the Private Cloud
// Compute seam in `SeptenaCore/ReasoningProvider.swift` (`ProviderAvailability`).
//
// When Xcode 27 lands, fill in the `#available(iOS 27, *)` branch:
//   1. Build a `LanguageModelSession` and a `@Generable` macro struct mirroring
//      `MealPhotoDraft`'s fields (`@Guide` each macro: "grams, nil if unknown").
//   2. Attach the image to the prompt (the new multimodal `Prompt`/segment API)
//      and offer the Vision OCR + barcode tools so the model can read a label
//      or scan a code itself.
//   3. Map the generated struct into `MealPhotoDraft(source: .model)`.
// Until then `MealPhotoAnalyzer` falls through to the label rung, so devices
// without the iOS-27 model still get a real result.

enum MealPhotoModelAnalyzer {
  /// Analyze a meal photo with the on-device multimodal model. Returns nil when
  /// the platform/model can't do it — the caller falls back to the label rung.
  static func analyze(imageData: Data) async -> MealPhotoDraft? {
    guard await OnDeviceAI.supportsImageInput else { return nil }
    if #available(iOS 27, macOS 27, *) {
      // TODO(Xcode 27): real multimodal call — see the file header. Returning
      // nil keeps the build green on the 26 SDK and degrades to the label rung.
      return nil
    }
    return nil
  }
}
