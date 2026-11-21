import Foundation
#if os(iOS)
import UIKit
#endif

/// Canonical 31-icon prebaked App Icon system (1 Default + 30 Alternates)
/// for Septena (`Septask/Assets.xcassets/AppIcon*.appiconset`).
///
/// Generated from `tools/logo-builder/dial-svg.mjs` via `scripts/generate-app-icons.mjs`.
/// Every `.appiconset` ships both Light OS and Dark OS (`luminosity: dark`)
/// 1024px artwork, so iOS handles Light/Dark Home Screen switching automatically.

enum AppIconFinish: String, CaseIterable, Sendable, Identifiable {
  /// Black anodized shell, adaptive white/dark dial, accented North & checkmark.
  case obsidian
  /// Porcelain white shell with mild warm-stone moat, adaptive dial, accented North & checkmark.
  case ceramic
  /// Things-style colored fruit shell with dark recessed moat, 90% black (or dark-mode white) checkmark.
  case framed
  /// Always-dark PVD obsidian shell + smoked matte-black dial even in Light OS.
  case stealth

  var id: String { rawValue }

  var title: String {
    switch self {
    case .obsidian: return "Default"
    case .ceramic:  return "Light"
    case .framed:   return "Framed"
    case .stealth:  return "Stealth"
    }
  }

  var assetPrefix: String {
    switch self {
    case .obsidian: return "Obsidian"
    case .ceramic:  return "Ceramic"
    case .framed:   return "Framed"
    case .stealth:  return "Stealth"
    }
  }
}

enum AppIconColor: String, CaseIterable, Sendable, Identifiable {
  case persimmon
  case haskap
  case tamarillo
  case yuzu
  case carambola
  case acai
  case pitaya
  case mono

  var id: String { rawValue }

  var title: String {
    switch self {
    case .persimmon: return "Persimmon"
    case .haskap:    return "Cobalt"
    case .tamarillo: return "Tamarillo"
    case .yuzu:      return "Yuzu"
    case .carambola: return "Carambola"
    case .acai:      return "Açaí"
    case .pitaya:    return "Pitaya"
    case .mono:      return "Mono"
    }
  }

  var assetSuffix: String {
    switch self {
    case .persimmon: return "Persimmon"
    case .haskap:    return "Haskap"
    case .tamarillo: return "Tamarillo"
    case .yuzu:      return "Yuzu"
    case .carambola: return "Carambola"
    case .acai:      return "Acai"
    case .pitaya:    return "Pitaya"
    case .mono:      return "Mono"
    }
  }

  var isMono: Bool { self == .mono }

  /// Canonical palette tokens matching `tools/logo-builder/dial-svg.mjs`.
  var baseHex: String {
    switch self {
    case .persimmon: return "#E05212"
    case .haskap:    return "#1D63DC"
    case .tamarillo: return "#D6333F"
    case .yuzu:      return "#C28500"
    case .carambola: return "#5B8C00"
    case .acai:      return "#6544D6"
    case .pitaya:    return "#D4266C"
    case .mono:      return "#27272E"
    }
  }

  var darkHex: String {
    switch self {
    case .persimmon: return "#FF7738"
    case .haskap:    return "#4E94FF"
    case .tamarillo: return "#FF5C67"
    case .yuzu:      return "#F2BF2C"
    case .carambola: return "#9EE034"
    case .acai:      return "#9B82FF"
    case .pitaya:    return "#FF5C9B"
    case .mono:      return "#C9CDD6"
    }
  }

  var paperHex: String {
    switch self {
    case .persimmon: return "#FFFDF8"
    case .haskap:    return "#FBFDFE"
    case .tamarillo: return "#FFFDF9"
    case .yuzu:      return "#FFFDF6"
    case .carambola: return "#FCFDF8"
    case .acai:      return "#FDFCFF"
    case .pitaya:    return "#FFFBFD"
    case .mono:      return "#FAF9F6"
    }
  }
}

enum AppIconCatalog {
  static let finishStorageKey = "septena.appearance.appIconFinish"
  static let colorStorageKey = "septena.appearance.appIconColor"

  /// Maps the user's Accent + Finish + optional color override to a concrete `AppIconColor`.
  /// In `Colorful` (default blue-leaning accent):
  ///   • `Default`, `Light`, `Stealth` → Persimmon orange north (signature Septena)
  ///   • `Framed` → Haskap cobalt blue (Things-like blue frame)
  static func resolvedColor(
    finish: AppIconFinish,
    colorOverride: AppIconColor?,
    accentColorID: String
  ) -> AppIconColor {
    if let override = colorOverride { return override }
    switch accentColorID {
    case "colorful":
      return finish == .framed ? .haskap : .persimmon
    case "tamarillo":
      return .tamarillo
    case "persimmon":
      return .persimmon
    case "yuzu":
      return .yuzu
    case "carambola":
      return .carambola
    case "acai":
      return .acai
    case "pitaya":
      return .pitaya
    case "jabuticaba":
      return .mono
    default:
      return .persimmon
    }
  }

  /// Effective finish (`Framed` + `Mono` resolves cleanly to `Obsidian` + `Mono`,
  /// avoiding a duplicate asset in the 31-icon bundle).
  static func effectiveFinish(finish: AppIconFinish, color: AppIconColor) -> AppIconFinish {
    (finish == .framed && color == .mono) ? .obsidian : finish
  }

  /// Exact `.appiconset` asset name in `Septask/Assets.xcassets`.
  static func assetName(finish: AppIconFinish, color: AppIconColor) -> String {
    let eff = effectiveFinish(finish: finish, color: color)
    if eff == .obsidian && color == .persimmon {
      return "AppIcon"
    }
    return "AppIcon\(eff.assetPrefix)\(color.assetSuffix)"
  }

  /// Value passed to `UIApplication.shared.setAlternateIconName(_:)`.
  /// `nil` restores the primary `AppIcon`.
  static func alternateIconName(finish: AppIconFinish, color: AppIconColor) -> String? {
    let name = assetName(finish: finish, color: color)
    return name == "AppIcon" ? nil : name
  }

  #if os(iOS)
  @MainActor
  static func applyAlternateIcon(named targetName: String?) {
    guard UIApplication.shared.supportsAlternateIcons else { return }
    guard UIApplication.shared.alternateIconName != targetName else { return }
    UIApplication.shared.setAlternateIconName(targetName) { error in
      if let error {
        print("[AppIcon] Failed to set alternate icon (\(targetName ?? "AppIcon")): \(error.localizedDescription)")
      }
    }
  }
  #endif
}
