import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// Appearance customization state for Septena (ADR 0019 / docs/CUSTOMIZATION_SPEC.md).
//
// Owns the 8 accents (`colorful` default + 7 global exotic fruits), the 6 locked
// procedural Header Wash textures (+ `none`), intensity, optional 3D `slowDrift`
// motion, Light/Dark/System mode, and opt-in cross-device sync (`syncTheme`).
//
// Seeds are NEVER stored or synced: smart-list textures derive their daily seed
// from `FNV-1a(DayClock.today)` (`YYYY-MM-DD`) so every morning brings a fresh
// terrain that matches identically across all devices; project headers can hash
// `project.id`.

enum AppearanceMode: String, CaseIterable, Sendable, Identifiable {
  case system
  case light
  case dark

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: return "System"
    case .light:  return "Light"
    case .dark:   return "Dark"
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .system: return nil
    case .light:  return .light
    case .dark:   return .dark
    }
  }
}

enum HeaderTextureStyle: String, CaseIterable, Sendable, Identifiable {
  case none
  case topography
  case fieldMatrix
  case stippleDrift
  case causticGlass
  case ridges
  case washiPaper

  var id: String { rawValue }

  var descriptor: RegistryTextureOption {
    RegistryTokens.textures.first { $0.id == rawValue }
      ?? RegistryTextureOption(id: rawValue, name: rawValue, tag: "")
  }
}

enum HeaderTextureMotion: String, CaseIterable, Sendable, Identifiable {
  case still
  case slowDrift

  var id: String { rawValue }
}

extension Notification.Name {
  /// Posted whenever any appearance customization preference changes so AppKit
  /// shells (sidebar, table, header wash) repaint live.
  static let septenaAppearanceChanged = Notification.Name("septena.appearanceChanged")
}

struct RGBTriple: Sendable, Hashable {
  let r: Double
  let g: Double
  let b: Double

  static func fromHex(_ hex: String) -> RGBTriple {
    let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard cleaned.count == 6, let n = UInt32(cleaned, radix: 16) else {
      return RGBTriple(r: 0, g: 0.478, b: 1)
    }
    return RGBTriple(
      r: Double((n >> 16) & 0xFF) / 255.0,
      g: Double((n >> 8) & 0xFF) / 255.0,
      b: Double(n & 0xFF) / 255.0
    )
  }

  var swiftUIColor: Color { Color(red: r, green: g, blue: b) }
}

@MainActor
@Observable
final class AppearancePreferences {
  static let shared = AppearancePreferences()

  var appearanceMode: AppearanceMode {
    didSet {
      guard oldValue != appearanceMode else { return }
      UserDefaults.standard.set(appearanceMode.rawValue, forKey: RegistrySettings.StorageKey.appearanceMode)
      applyPlatformAppearance()
      notifyChanged()
    }
  }

  var syncTheme: Bool {
    didSet {
      guard oldValue != syncTheme else { return }
      UserDefaults.standard.set(syncTheme, forKey: RegistrySettings.StorageKey.syncTheme)
      if syncTheme { pushSyncedIfEnabled() }
      notifyChanged()
    }
  }

  var accentColorID: String {
    didSet {
      guard oldValue != accentColorID else { return }
      UserDefaults.standard.set(accentColorID, forKey: RegistrySettings.StorageKey.accentColor)
      pushSyncedIfEnabled()
      if !isAdoptingSynced {
        applyAppIconIfNeeded()
      }
      notifyChanged()
    }
  }

  var appIconFinish: AppIconFinish {
    didSet {
      guard oldValue != appIconFinish else { return }
      UserDefaults.standard.set(appIconFinish.rawValue, forKey: AppIconCatalog.finishStorageKey)
      applyAppIconIfNeeded()
      notifyChanged()
    }
  }

  var canvasTexture: HeaderTextureStyle {
    didSet {
      guard oldValue != canvasTexture else { return }
      UserDefaults.standard.set(canvasTexture.rawValue, forKey: RegistrySettings.StorageKey.canvasTexture)
      pushSyncedIfEnabled()
      notifyChanged()
    }
  }

  var textureIntensity: Int {
    didSet {
      let clamped = max(15, min(100, textureIntensity))
      if textureIntensity != clamped { textureIntensity = clamped; return }
      guard oldValue != clamped else { return }
      UserDefaults.standard.set(clamped, forKey: RegistrySettings.StorageKey.textureIntensity)
      pushSyncedIfEnabled()
      notifyChanged()
    }
  }

  var textureMotion: HeaderTextureMotion {
    didSet {
      guard oldValue != textureMotion else { return }
      UserDefaults.standard.set(textureMotion.rawValue, forKey: RegistrySettings.StorageKey.textureMotion)
      pushSyncedIfEnabled()
      notifyChanged()
    }
  }

  /// Monotonic bump incremented on every appearance write so SwiftUI views
  /// reading `Theme.*` computed colors can observe changes cleanly.
  private(set) var revision: Int = 0

  @ObservationIgnored private var isAdoptingSynced = false
  @ObservationIgnored private var syncObserver: NSObjectProtocol?
  #if os(macOS)
  @ObservationIgnored private var macThemeObserver: NSObjectProtocol?
  #endif

  private init() {
    let ud = UserDefaults.standard
    let modeRaw = ud.string(forKey: RegistrySettings.StorageKey.appearanceMode)
      ?? RegistrySettings.Defaults.appearanceMode
    self.appearanceMode = AppearanceMode(rawValue: modeRaw) ?? .system

    if ud.object(forKey: RegistrySettings.StorageKey.syncTheme) != nil {
      self.syncTheme = ud.bool(forKey: RegistrySettings.StorageKey.syncTheme)
    } else {
      self.syncTheme = RegistrySettings.Defaults.syncTheme
    }

    let accentRaw = ud.string(forKey: RegistrySettings.StorageKey.accentColor)
      ?? RegistrySettings.Defaults.accentColor
    self.accentColorID = RegistryTokens.fruitAccents.contains(where: { $0.id == accentRaw })
      ? accentRaw
      : RegistrySettings.Defaults.accentColor

    let iconFinishRaw = ud.string(forKey: AppIconCatalog.finishStorageKey)
      ?? RegistrySettings.Defaults.appIconFinish
    self.appIconFinish = AppIconFinish(rawValue: iconFinishRaw) ?? .obsidian

    let texRaw = ud.string(forKey: RegistrySettings.StorageKey.canvasTexture)
      ?? RegistrySettings.Defaults.canvasTexture
    self.canvasTexture = HeaderTextureStyle(rawValue: texRaw) ?? .none

    if ud.object(forKey: RegistrySettings.StorageKey.textureIntensity) != nil {
      self.textureIntensity = max(15, min(100, ud.integer(forKey: RegistrySettings.StorageKey.textureIntensity)))
    } else {
      self.textureIntensity = RegistrySettings.Defaults.textureIntensity
    }

    let motionRaw = ud.string(forKey: RegistrySettings.StorageKey.textureMotion)
      ?? RegistrySettings.Defaults.textureMotion
    self.textureMotion = HeaderTextureMotion(rawValue: motionRaw) ?? .still

    #if SEPTASK
    syncObserver = NotificationCenter.default.addObserver(
      forName: .septaskSettingsPulled, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.adoptSynced(SeptaskSyncedSettings.current())
      }
    }
    #endif

    #if os(macOS)
    macThemeObserver = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.appearanceMode == .system else { return }
        self.applyAppIconIfNeeded()
      }
    }
    #endif
  }

  // MARK: - Resolved Tokens

  var currentFruit: RegistryFruitAccent {
    RegistryTokens.fruitAccents.first { $0.id == accentColorID }
      ?? RegistryTokens.fruitAccents.first
      ?? RegistryFruitAccent(
        id: "colorful", name: "Colorful", origin: "Default · Blue + semantic",
        lightHex: "#007AFF", darkHex: "#0A84FF",
        checkLightHex: "#FFFFFF", checkDarkHex: "#FFFFFF", multicolor: true
      )
  }

  var isColorful: Bool { currentFruit.multicolor }
  var hasActiveTexture: Bool { canvasTexture != .none }
  var isSlowDrift: Bool { hasActiveTexture && textureMotion == .slowDrift }
  var preferredColorScheme: ColorScheme? { appearanceMode.colorScheme }

  // MARK: - Resolved App Icon

  var resolvedAppIconColor: AppIconColor {
    AppIconCatalog.resolvedColor(accentColorID: accentColorID)
  }

  var resolvedAppIconFinish: AppIconFinish {
    AppIconCatalog.effectiveFinish(finish: appIconFinish, color: resolvedAppIconColor)
  }

  var resolvedAppIconAssetName: String {
    AppIconCatalog.assetName(finish: appIconFinish, color: resolvedAppIconColor)
  }

  var resolvedAlternateIconName: String? {
    AppIconCatalog.alternateIconName(finish: appIconFinish, color: resolvedAppIconColor)
  }

  func applyAppIconIfNeeded() {
    #if os(iOS)
    AppIconCatalog.applyAlternateIcon(named: resolvedAlternateIconName)
    #elseif os(macOS)
    let isDarkOS: Bool
    switch appearanceMode {
    case .light:
      isDarkOS = false
    case .dark:
      isDarkOS = true
    case .system:
      isDarkOS = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }
    AppIconCatalog.applyMacIcon(
      finish: resolvedAppIconFinish,
      color: resolvedAppIconColor,
      isDarkOS: isDarkOS
    )
    #endif
  }

  /// Today icon color in the sidebar: gold in Colorful mode (matching the
  /// macOS Multicolor idiom), and active accent or gold per locked spec.
  /// Spec: Today icon is gold (#F5C721) in sidebar, quiet gray in list heading.
  var isMonochromeAccent: Bool { accentColorID == "jabuticaba" }

  func accentRGB(isDark: Bool) -> RGBTriple {
    let f = currentFruit
    return RGBTriple.fromHex(isDark ? f.darkHex : f.lightHex)
  }

  func checkInkRGB(isDark: Bool) -> RGBTriple {
    let f = currentFruit
    return RGBTriple.fromHex(isDark ? f.checkDarkHex : f.checkLightHex)
  }

  var accentSwiftUIColor: Color {
    let f = currentFruit
    let light = RGBTriple.fromHex(f.lightHex)
    let dark = RGBTriple.fromHex(f.darkHex)
    return Self.dynamicColor(light: light, dark: dark)
  }

  var checkInkSwiftUIColor: Color {
    let f = currentFruit
    let light = RGBTriple.fromHex(f.checkLightHex)
    let dark = RGBTriple.fromHex(f.checkDarkHex)
    return Self.dynamicColor(light: light, dark: dark)
  }

  var selectionFillSwiftUIColor: Color {
    let f = currentFruit
    let light = RGBTriple.fromHex(f.lightHex)
    let dark = RGBTriple.fromHex(f.darkHex)
    return Self.dynamicColor(
      light: light, lightAlpha: RegistryTokens.Selection.emphasizedAlphaLight,
      dark: dark, darkAlpha: RegistryTokens.Selection.emphasizedAlphaDark
    )
  }

  #if os(macOS)
  var accentNSColor: NSColor {
    let f = currentFruit
    let light = RGBTriple.fromHex(f.lightHex)
    let dark = RGBTriple.fromHex(f.darkHex)
    return NSColor(name: nil) { appearance in
      let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
      let c = isDark ? dark : light
      return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }
  }

  var checkInkNSColor: NSColor {
    let f = currentFruit
    let light = RGBTriple.fromHex(f.checkLightHex)
    let dark = RGBTriple.fromHex(f.checkDarkHex)
    return NSColor(name: nil) { appearance in
      let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
      let c = isDark ? dark : light
      return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }
  }

  func selectionFillNSColor(emphasized: Bool) -> NSColor {
    let f = currentFruit
    let light = RGBTriple.fromHex(f.lightHex)
    let dark = RGBTriple.fromHex(f.darkHex)
    return NSColor(name: nil) { appearance in
      let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
      if emphasized {
        let c = isDark ? dark : light
        let alpha = isDark
          ? CGFloat(RegistryTokens.Selection.emphasizedAlphaDark)
          : CGFloat(RegistryTokens.Selection.emphasizedAlphaLight)
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: alpha)
      }
      return isDark
        ? NSColor(white: 1, alpha: CGFloat(RegistryTokens.Selection.unemphasizedAlphaDark))
        : NSColor(white: 0, alpha: CGFloat(RegistryTokens.Selection.unemphasizedAlphaLight))
    }
  }

  func applyPlatformAppearance() {
    switch appearanceMode {
    case .system: NSApp?.appearance = nil
    case .light:  NSApp?.appearance = NSAppearance(named: .aqua)
    case .dark:   NSApp?.appearance = NSAppearance(named: .darkAqua)
    }
    applyAppIconIfNeeded()
  }
  #else
  func applyPlatformAppearance() {}
  #endif

  // MARK: - Daily & Project Deterministic Seeds (FNV-1a)

  /// Deterministic FNV-1a 32-bit hash matching the cross-platform rule.
  nonisolated static func fnv1a(_ input: String) -> UInt32 {
    var hash: UInt32 = 2166136261
    for byte in input.utf8 {
      hash ^= UInt32(byte)
      hash = hash &* 16777619
    }
    return hash
  }

  /// Daily terrain seed derived from `DayClock.today` (`YYYY-MM-DD`).
  /// Matches identically across all devices on the same day with zero sync.
  nonisolated static func dailySeed(for dayISO: String) -> UInt32 {
    max(1, fnv1a("septena.wash:\(dayISO)") % 9999)
  }

  /// Project-specific seed (or daily seed when no project ID is given).
  nonisolated static func resolvedSeed(dayISO: String, projectID: String? = nil) -> UInt32 {
    if let pid = projectID, !pid.isEmpty {
      return max(1, fnv1a("septena.wash.project:\(pid)") % 9999)
    }
    return dailySeed(for: dayISO)
  }

  // MARK: - Sync Bridge

  func adoptSynced(_ settings: AppSettings) {
    guard syncTheme else { return }
    isAdoptingSynced = true
    defer { isAdoptingSynced = false }

    var changed = false
    if let a = settings.accentColor,
       RegistryTokens.fruitAccents.contains(where: { $0.id == a }),
       a != accentColorID {
      accentColorID = a
      changed = true
    }
    if let t = settings.canvasTexture,
       let style = HeaderTextureStyle(rawValue: t),
       style != canvasTexture {
      canvasTexture = style
      changed = true
    }
    if let i = settings.textureIntensity {
      let clamped = max(15, min(100, i))
      if clamped != textureIntensity {
        textureIntensity = clamped
        changed = true
      }
    }
    if let m = settings.textureMotion,
       let motion = HeaderTextureMotion(rawValue: m),
       motion != textureMotion {
      textureMotion = motion
      changed = true
    }
    if changed { notifyChanged() }
  }

  private func pushSyncedIfEnabled() {
    guard !isAdoptingSynced, syncTheme else { return }
    #if SEPTASK
    let context = LocalStore.shared.container.mainContext
    var s = SettingsMirror.loadSettings(context: context) ?? SeptaskSyncedSettings.empty
    s.accentColor = accentColorID
    s.canvasTexture = canvasTexture.rawValue
    s.textureIntensity = textureIntensity
    s.textureMotion = textureMotion.rawValue
    SettingsMirror.upsert(settings: s, context: context, engine: nil)
    #endif
  }

  private func notifyChanged() {
    revision &+= 1
    NotificationCenter.default.post(name: .septenaAppearanceChanged, object: nil)
  }

  // MARK: - Dynamic Color Builder

  private static func dynamicColor(
    light: RGBTriple, lightAlpha: Double = 1.0,
    dark: RGBTriple, darkAlpha: Double = 1.0
  ) -> Color {
    #if os(macOS)
    return Color(nsColor: NSColor(name: nil) { appearance in
      let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
      let c = isDark ? dark : light
      let a = isDark ? darkAlpha : lightAlpha
      return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: a)
    })
    #elseif canImport(UIKit)
    return Color(uiColor: UIColor { traits in
      let isDark = traits.userInterfaceStyle == .dark
      let c = isDark ? dark : light
      let a = isDark ? darkAlpha : lightAlpha
      return UIColor(red: c.r, green: c.g, blue: c.b, alpha: a)
    })
    #else
    return Color(red: dark.r, green: dark.g, blue: dark.b, opacity: darkAlpha)
    #endif
  }
}
