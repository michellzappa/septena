import Foundation

// Which model produced a given AI output. Surfaced as small secondary text next
// to each AI spot so on-device vs Private Cloud Compute vs the user's Claude is
// visible at a glance — added during the iOS-27 beta bring-up so we can SEE
// where a reply came from (e.g. whether the Coach is actually on PCC now that
// the device reports it available). A temporary diagnostic gated by
// `AIModelTag.isVisible`, not permanent chrome.
//
// Not a replacement for `AIProviderKind` (the router's admissibility currency):
// this adds the two *non-provider* on-device sources the UI also needs to name
// — deterministic Vision, and "no model ran" — and carries display strings.

enum AIModelTag: String, Sendable, Equatable {
  case onDevice            // Apple Foundation Models, on-device (SystemLanguageModel)
  case privateCloudCompute // Apple Private Cloud Compute (iOS 27+)
  case claude              // the user's own Claude, via MCP
  case onDeviceVision      // deterministic Vision (OCR / barcode) — no LLM
  case none                // nothing ran / echo fallback

  var label: String {
    switch self {
    case .onDevice:            return "On-device"
    case .privateCloudCompute: return "Private Cloud Compute"
    case .claude:              return "My Claude"
    case .onDeviceVision:      return "On-device Vision"
    case .none:                return "No model"
    }
  }

  /// SF Symbol paired with the label in the badge.
  var systemImage: String {
    switch self {
    case .onDevice:            return "cpu"
    case .privateCloudCompute: return "cloud"
    case .claude:              return "person.crop.circle"
    case .onDeviceVision:      return "text.viewfinder"
    case .none:                return "circle.slash"
    }
  }

  /// Map a persisted conversation provider to a display tag. `.unknown`
  /// (forward-compat decode) and a missing provider read as "no model".
  init(_ provider: ConvoTurn.Provider?) {
    switch provider {
    case .onDevice: self = .onDevice
    case .applePCC: self = .privateCloudCompute
    case .claude:   self = .claude
    case .unknown, .none: self = .none
    }
  }

  // MARK: Beta visibility toggle

  /// User default key for the "show model labels" beta toggle.
  static let visibilityKey = "septena.ai.showModelTags"

  /// Whether model tags are shown anywhere in the UI. Defaults ON during the
  /// iOS-27 beta ("always indicate, for now"); the toggle lives in Settings ▸
  /// Claude & AI so it can be turned off without a build.
  static var isVisible: Bool {
    UserDefaults.standard.object(forKey: visibilityKey) as? Bool ?? true
  }
}
