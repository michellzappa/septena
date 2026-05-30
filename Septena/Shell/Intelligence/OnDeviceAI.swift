import FoundationModels

@MainActor
enum OnDeviceAI {
  static var availability: SystemLanguageModel.Availability {
    SystemLanguageModel.default.availability
  }

  static var isAvailable: Bool {
    SystemLanguageModel.default.isAvailable
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
