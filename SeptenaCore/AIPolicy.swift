import Foundation

// The user-facing AI policy — ONE global dial (not a per-function model matrix).
// It sets how far a reasoning request may reach; the router still picks the
// specific provider per step by capability. Engine-independent: the in-app
// orchestrator (and iOS 27's PCC provider) read `admissibleProviders` once built.
// User explainer: docs/AI_TASKS_EXPLAINER.md.

/// How much AI may use / how far a request may leave the device.
enum AIMode: String, CaseIterable, Codable, Sendable {
  case onDeviceOnly   // privacy floor — never escalate off-device
  case auto           // recommended — on-device first, escalate only when a step needs more
  case useMyClaude    // prefer the user's connected Claude for the thinking

  var title: String {
    switch self {
    case .onDeviceOnly: return "On-device only"
    case .auto:         return "Automatic"
    case .useMyClaude:  return "Use my Claude"
    }
  }

  var blurb: String {
    switch self {
    case .onDeviceOnly:
      return "Everything stays on this device. Nothing leaves; a step that needs more pauses until you decide."
    case .auto:
      return "On-device first, escalating to Apple’s Private Cloud Compute or your own Claude only when a step needs more. Recommended."
    case .useMyClaude:
      return "Prefer your connected Claude for the thinking — your account, your data. Septena still never runs AI on your tasks."
    }
  }
}

/// The reasoning backends that can exist. The router chooses among the
/// ADMISSIBLE set for the current mode. There is deliberately no
/// "hosted-by-Septena" option — the admissibility rule is *zero inference cost
/// to Septena* (Apple on-device, Apple PCC, or the user's own Claude).
enum AIProviderKind: String, CaseIterable, Codable, Sendable {
  case onDevice    // Apple Foundation Models (26.0+) — free, private, offline
  case applePCC    // Apple Private Cloud Compute (iOS 27) — stronger, still private
  case claude      // the user's own Claude, via MCP — off-device, user pays

  var label: String {
    switch self {
    case .onDevice: return "On-device (Apple)"
    case .applePCC: return "Private Cloud Compute"
    case .claude:   return "My Claude"
    }
  }
}

enum AIPolicy {
  static let modeKey = "septena.ai.mode"
  /// Developer-only (macOS debug): pin every reasoning step to one provider for
  /// testing. Empty string = off. Never surfaced in the consumer UI.
  static let devForceProviderKey = "septena.ai.devForceProvider"

  static var mode: AIMode {
    AIMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .auto
  }

  static var devForcedProvider: AIProviderKind? {
    let raw = UserDefaults.standard.string(forKey: devForceProviderKey) ?? ""
    return raw.isEmpty ? nil : AIProviderKind(rawValue: raw)
  }

  /// Providers the router may use, most-private-first, given the current mode,
  /// whether the user has connected their Claude, and whether PCC is available.
  /// The router still gates each by per-step capability + confidence. A dev
  /// override (if set) wins outright — testing only.
  static func admissibleProviders(claudeConnected: Bool, pccAvailable: Bool) -> [AIProviderKind] {
    if let forced = devForcedProvider { return [forced] }
    switch mode {
    case .onDeviceOnly:
      return [.onDevice]
    case .auto:
      var p: [AIProviderKind] = [.onDevice]
      if pccAvailable { p.append(.applePCC) }
      if claudeConnected { p.append(.claude) }
      return p
    case .useMyClaude:
      return claudeConnected ? [.claude, .onDevice] : [.onDevice]
    }
  }
}
