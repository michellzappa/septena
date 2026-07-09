import FoundationModels

@MainActor
enum OnDeviceAI {
  /// Typed availability for surfaces that treat the unavailable states
  /// differently (Settings status row, placeholders). The three reasons differ
  /// in what the user can do: enable it, wait, or nothing.
  enum Status {
    case available
    case notEnabled        // actionable — Apple Intelligence is off in Settings
    case modelNotReady     // temporary — model still downloading
    case deviceNotEligible // permanent — hardware can't run it
    case unknown
  }

  static var status: Status {
    switch availability {
    case .available: return .available
    case .unavailable(.deviceNotEligible): return .deviceNotEligible
    case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
    case .unavailable(.modelNotReady): return .modelNotReady
    @unknown default: return .unknown
    }
  }

  static var availability: SystemLanguageModel.Availability {
    SystemLanguageModel.default.availability
  }

  static var isAvailable: Bool {
    SystemLanguageModel.default.isAvailable
  }

  /// True only where the on-device model can accept image input — iOS 27+ with
  /// Apple Intelligence enabled on an eligible device. Multimodal attachments
  /// are iOS-27 symbols, so the actual call lives behind `#available` in
  /// `MealPhotoModelAnalyzer`; this flag is the capability gate the meal-photo
  /// ladder checks before trying that rung. False on the 26 SDK / older devices,
  /// where the analyzer falls back to Vision OCR (no Apple Intelligence needed).
  static var supportsImageInput: Bool {
    if #available(iOS 27, macOS 27, *) {
      return status == .available
    }
    return false
  }

  static var unavailableReason: String? {
    switch availability {
    case .available:
      return nil
    case .unavailable(.deviceNotEligible):
      return "Self-discovery needs Apple Intelligence, which is not supported on this device."
    case .unavailable(.appleIntelligenceNotEnabled):
      return "Turn on Apple Intelligence in Settings to use self-discovery."
    case .unavailable(.modelNotReady):
      return "The on-device model is still downloading. Try again shortly."
    @unknown default:
      return "On-device intelligence is unavailable right now."
    }
  }
}
