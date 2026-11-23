import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
import CoreGraphics
#endif

/// Canonical 23-icon prebaked App Icon system (1 Default + 22 Alternates)
/// for Septena (`Septask/Assets.xcassets/AppIcon*.appiconset` on iOS, live
/// CoreGraphics Dock + bundle icon on macOS).
///
/// Generated from `tools/logo-builder/dial-svg.mjs` via `scripts/generate-app-icons.mjs`.
/// Every `.appiconset` ships both Light OS and Dark OS (`luminosity: dark`)
/// 1024px artwork, so iOS handles Light/Dark Home Screen switching automatically;
/// macOS renders the identical geometry live into `NSApp.applicationIconImage`.

enum AppIconFinish: String, CaseIterable, Sendable, Identifiable {
  /// Black anodized shell, adaptive white/dark dial, accented North & checkmark.
  case obsidian
  /// Porcelain white shell with mild warm-stone moat, adaptive dial, accented North & checkmark.
  case ceramic
  /// Things-style colored fruit shell with dark recessed moat, 90% black (or dark-mode white) checkmark.
  case framed

  var id: String { rawValue }

  var title: String {
    switch self {
    case .obsidian: return "Default"
    case .ceramic:  return "Light"
    case .framed:   return "Framed"
    }
  }

  var assetPrefix: String {
    switch self {
    case .obsidian: return "Obsidian"
    case .ceramic:  return "Ceramic"
    case .framed:   return "Framed"
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
    case .haskap:    return "Haskap"
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
  static let finishStorageKey = RegistrySettings.StorageKey.appIconFinish
  /// Theme = icon: the icon color follows the app accent one to one.
  /// `Persimmon` is the default accent and the primary icon, so a fresh
  /// install never switches icons. `Colorful` (system blue) also keeps it. `Jabuticaba` maps to `Mono`.
  static func resolvedColor(accentColorID: String) -> AppIconColor {
    switch accentColorID {
    case "jabuticaba": return .mono
    default: return AppIconColor(rawValue: accentColorID) ?? .persimmon
    }
  }

  /// Effective finish (`Framed` + `Mono` resolves cleanly to `Obsidian` + `Mono`,
  /// avoiding a duplicate asset in the 23-icon bundle).
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
  #elseif os(macOS)
  /// Applies the selected Septena Upright Compass icon to the running macOS
  /// app (`NSApp.applicationIconImage` + Dock tile) and, when installed under
  /// `/Applications` or `~/Applications`, persists it on the bundle via
  /// `NSWorkspace.setIcon(_:forFile:)` so Finder & pinned Dock tiles keep it
  /// after quit.
  @MainActor
  static func applyMacIcon(finish: AppIconFinish, color: AppIconColor, isDarkOS: Bool) {
    guard let app = NSApp else { return }
    let eff = effectiveFinish(finish: finish, color: color)
    let isDefaultLight = (eff == .obsidian && color == .persimmon && !isDarkOS)
    let image = renderMacAppIcon(finish: eff, color: color, isDarkOS: isDarkOS)
    app.applicationIconImage = image
    app.dockTile.display()

    let bundlePath = Bundle.main.bundlePath
    let homeApps = (NSHomeDirectory() as NSString).appendingPathComponent("Applications/")
    if bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(homeApps) {
      NSWorkspace.shared.setIcon(isDefaultLight ? nil : image, forFile: bundlePath, options: [])
    }
  }

  /// Renders the canonical Septena Upright Compass icon into a 1024×1024
  /// Retina `NSImage` with macOS HIG Dock padding (~828px squircle centered
  /// inside 1024px canvas + soft downward drop shadow).
  @MainActor
  static func renderMacAppIcon(
    finish: AppIconFinish,
    color: AppIconColor,
    isDarkOS: Bool
  ) -> NSImage {
    let canvas: CGFloat = 1024
    let pad: CGFloat = 98 // ~9.6% HIG Dock margin -> 828px icon body
    let body = canvas - pad * 2
    let sc = body / 1024.0
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!

    let isWhiteShell = finish == .ceramic
    let isBlackShell = finish == .obsidian
    let isColoredShell = finish == .framed
    let isDarkFace = isDarkOS
    let isMono = color.isMono
    let accentCheck = !isColoredShell

    func cg(_ hex: String, alpha: CGFloat = 1.0) -> CGColor {
      let c = RGBTriple.fromHex(hex)
      return CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: alpha)
    }

    func adjustL(_ hex: String, delta: Double, minL: Double = 0.06, maxL: Double = 0.85) -> CGColor {
      let rgb = RGBTriple.fromHex(hex)
      let maxC = max(rgb.r, max(rgb.g, rgb.b))
      let minC = min(rgb.r, min(rgb.g, rgb.b))
      var h = 0.0
      var s = 0.0
      let l = (maxC + minC) / 2.0
      if maxC != minC {
        let d = maxC - minC
        s = l > 0.5 ? d / (2.0 - maxC - minC) : d / (maxC + minC)
        if maxC == rgb.r { h = ((rgb.g - rgb.b) / d + (rgb.g < rgb.b ? 6.0 : 0.0)) / 6.0 }
        else if maxC == rgb.g { h = ((rgb.b - rgb.r) / d + 2.0) / 6.0 }
        else { h = ((rgb.r - rgb.g) / d + 4.0) / 6.0 }
      }
      let nl = max(minL, min(maxL, l + delta))
      let c = (1.0 - abs(2.0 * nl - 1.0)) * s
      let hh = h * 6.0
      let x = c * (1.0 - abs(hh.truncatingRemainder(dividingBy: 2.0) - 1.0))
      let m = nl - c / 2.0
      let (r1, g1, b1): (Double, Double, Double) = switch Int(hh) % 6 {
      case 0: (c, x, 0)
      case 1: (x, c, 0)
      case 2: (0, c, x)
      case 3: (0, x, c)
      case 4: (x, 0, c)
      default: (c, 0, x)
      }
      return CGColor(
        srgbRed: max(0, min(1, r1 + m)),
        green: max(0, min(1, g1 + m)),
        blue: max(0, min(1, b1 + m)),
        alpha: 1
      )
    }

    let shellTop, shellMid, shellBot, shellRim, wellTop, wellMid, wellBot, shadowCol: CGColor
    if isWhiteShell {
      shellTop = cg("#FFFFFF"); shellMid = cg("#F4F2ED"); shellBot = cg("#E4E1D9"); shellRim = cg("#FFFFFF")
      wellTop = cg(isDarkFace ? "#AEABA2" : "#B9B5AC")
      wellMid = cg(isDarkFace ? "#C2BFB7" : "#CBC7BE")
      wellBot = cg(isDarkFace ? "#D4D1C9" : "#DBD8D0")
      shadowCol = cg("#6E6A61")
    } else if isBlackShell {
      shellTop = cg("#3B3C46"); shellMid = cg("#27272E"); shellBot = cg("#15151A"); shellRim = cg("#686A78")
      wellTop = cg("#07070A"); wellMid = cg("#0F1015"); wellBot = cg("#181920")
      shadowCol = cg("#040407")
    } else {
      shellTop = adjustL(color.baseHex, delta: 0.11)
      shellMid = cg(color.baseHex)
      shellBot = adjustL(color.baseHex, delta: -0.13)
      shellRim = cg(color.darkHex)
      wellTop = adjustL(color.baseHex, delta: -0.28, minL: 0.11, maxL: 0.20)
      wellMid = adjustL(color.baseHex, delta: -0.23, minL: 0.15, maxL: 0.25)
      wellBot = adjustL(color.baseHex, delta: -0.17, minL: 0.20, maxL: 0.31)
      shadowCol = adjustL(color.baseHex, delta: -0.36, minL: 0.03, maxL: 0.14)
    }

    let faceTop = isDarkFace ? cg("#2E2F38") : cg("#FFFFFF")
    let faceMid = isDarkFace ? cg("#22232B") : cg(color.paperHex)
    let faceBot = isDarkFace ? cg("#17181E") : adjustL(color.paperHex, delta: -0.05, minL: 0.86, maxL: 0.96)

    let accLight, accMid, accDeep: CGColor
    if isMono {
      accLight = cg(isDarkFace ? "#EFEFF4" : "#525660")
      accMid   = cg(isDarkFace ? "#D5D7E0" : "#434750")
      accDeep  = cg(isDarkFace ? "#B4B7C2" : "#32353C")
    } else {
      accLight = cg(color.darkHex)
      accMid   = cg(color.baseHex)
      accDeep  = adjustL(color.baseHex, delta: -0.15, minL: 0.12, maxL: 0.72)
    }

    let checkInkTop = cg(isDarkFace ? "#F6F6F8" : "#4C5058")
    let checkInkBot = cg(isDarkFace ? "#DFDFE5" : "#363940")
    let mutedGlyph = cg(
      isDarkFace ? "#C7C9D4" : "#6A6770",
      alpha: isDarkFace ? 0.34 : 0.28
    )

    guard let ctx = CGContext(
      data: nil,
      width: Int(canvas),
      height: Int(canvas),
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: cs,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      return NSImage(size: NSSize(width: 512, height: 512))
    }

    // Flip to SVG/top-left coordinates inside the padded icon body
    func squircle(in rect: CGRect, radiusRatio: CGFloat = 0.285) -> CGPath {
      let x0 = rect.minX, y0 = rect.minY, x1 = rect.maxX, y1 = rect.maxY
      let ext = rect.width * radiusRatio
      let k = ext * 0.36
      let p = CGMutablePath()
      p.move(to: CGPoint(x: x0 + ext, y: y0))
      p.addLine(to: CGPoint(x: x1 - ext, y: y0))
      p.addCurve(to: CGPoint(x: x1, y: y0 + ext), control1: CGPoint(x: x1 - k, y: y0), control2: CGPoint(x: x1, y: y0 + k))
      p.addLine(to: CGPoint(x: x1, y: y1 - ext))
      p.addCurve(to: CGPoint(x: x1 - ext, y: y1), control1: CGPoint(x: x1, y: y1 - k), control2: CGPoint(x: x1 - k, y: y1))
      p.addLine(to: CGPoint(x: x0 + ext, y: y1))
      p.addCurve(to: CGPoint(x: x0, y: y1 - ext), control1: CGPoint(x: x0 + k, y: y1), control2: CGPoint(x: x0, y: y1 - k))
      p.addLine(to: CGPoint(x: x0, y: y0 + ext))
      p.addCurve(to: CGPoint(x: x0 + ext, y: y0), control1: CGPoint(x: x0, y: y0 + k), control2: CGPoint(x: x0 + k, y: y0))
      p.closeSubpath()
      return p
    }

    ctx.translateBy(x: 0, y: canvas)
    ctx.scaleBy(x: 1, y: -1)

    let bodyRect = CGRect(x: pad, y: pad, width: body, height: body)
    let outerPath = squircle(in: bodyRect)

    // Soft macOS Dock elevation shadow behind squircle
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 28, color: cg("#000000", alpha: 0.34))
    ctx.addPath(outerPath)
    ctx.setFillColor(shellMid)
    ctx.fillPath()
    ctx.restoreGState()

    // Clip all icon layers to squircle
    ctx.saveGState()
    ctx.addPath(outerPath)
    ctx.clip()

    // Map 0...1024 icon space into bodyRect
    ctx.translateBy(x: pad, y: pad)
    ctx.scaleBy(x: sc, y: sc)

    // 1. Shell linear gradient + top-left sheen
    if let g = CGGradient(colorsSpace: cs, colors: [shellTop, shellMid, shellBot] as CFArray, locations: [0, 0.48, 1]) {
      ctx.drawLinearGradient(g, start: CGPoint(x: 164, y: 20), end: CGPoint(x: 860, y: 1024), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    let sheenAlpha: CGFloat = isWhiteShell ? 0.45 : (isBlackShell ? 0.16 : 0.24)
    if let sg = CGGradient(colorsSpace: cs, colors: [cg("#FFFFFF", alpha: sheenAlpha), cg("#FFFFFF", alpha: 0.02), cg("#000000", alpha: isWhiteShell ? 0.06 : 0.14)] as CFArray, locations: [0, 0.55, 1]) {
      ctx.drawRadialGradient(sg, startCenter: CGPoint(x: 286, y: 123), startRadius: 0, endCenter: CGPoint(x: 286, y: 123), endRadius: 737, options: [.drawsAfterEndLocation])
    }

    // Outer specular rim
    ctx.addPath(squircle(in: CGRect(x: 8, y: 8, width: 1008, height: 1008), radiusRatio: 0.282))
    ctx.setStrokeColor(isWhiteShell ? cg("#000000", alpha: 0.08) : shellRim.copy(alpha: 0.32) ?? shellRim)
    ctx.setLineWidth(6)
    ctx.strokePath()

    // 2. Bold recessed ring / moat (r = 416)
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: 512 - 416, y: 512 - 416, width: 832, height: 832))
    ctx.clip()
    if let wg = CGGradient(colorsSpace: cs, colors: [wellTop, wellMid, wellBot] as CFArray, locations: [0, 0.55, 1]) {
      ctx.drawLinearGradient(wg, start: CGPoint(x: 205, y: 96), end: CGPoint(x: 819, y: 928), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    ctx.restoreGState()

    ctx.setStrokeColor(shadowCol.copy(alpha: isWhiteShell ? 0.28 : 0.55) ?? shadowCol)
    ctx.setLineWidth(8)
    ctx.strokeEllipse(in: CGRect(x: 512 - 412, y: 512 - 412, width: 824, height: 824))

    ctx.setStrokeColor(cg("#FFFFFF", alpha: isWhiteShell ? 0.85 : 0.20))
    ctx.setLineWidth(4)
    ctx.strokeEllipse(in: CGRect(x: 512 - 415, y: 515 - 415, width: 830, height: 830))

    // 3. Elevated inner dial plate (r = 354)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * sc), blur: 16 * sc, color: shadowCol.copy(alpha: isWhiteShell ? 0.30 : 0.44) ?? shadowCol)
    ctx.setFillColor(faceMid)
    ctx.fillEllipse(in: CGRect(x: 512 - 354, y: 512 - 354, width: 708, height: 708))
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: 512 - 354, y: 512 - 354, width: 708, height: 708))
    ctx.clip()
    if let fg = CGGradient(colorsSpace: cs, colors: [faceTop, faceMid, faceBot] as CFArray, locations: [0, 0.62, 1]) {
      ctx.drawRadialGradient(fg, startCenter: CGPoint(x: 430, y: 307), startRadius: 0, endCenter: CGPoint(x: 430, y: 307), endRadius: 510, options: [.drawsAfterEndLocation])
    }
    ctx.restoreGState()

    ctx.setStrokeColor(cg("#FFFFFF", alpha: isDarkFace ? 0.18 : 0.94))
    ctx.setLineWidth(5)
    ctx.strokeEllipse(in: CGRect(x: 512 - 351, y: 512 - 351, width: 702, height: 702))

    // 4. Six machined rounded dial ticks (k = 1...6)
    ctx.saveGState()
    ctx.setStrokeColor(mutedGlyph)
    ctx.setLineWidth(24)
    ctx.setLineCap(.round)
    let step = 360.0 / 7.0
    for i in 1..<7 {
      let rad = (-90.0 + Double(i) * step) * .pi / 180.0
      ctx.move(to: CGPoint(x: 512 + cos(rad) * 260, y: 512 + sin(rad) * 260))
      ctx.addLine(to: CGPoint(x: 512 + cos(rad) * 310, y: 512 + sin(rad) * 310))
      ctx.strokePath()
    }
    ctx.restoreGState()

    // 5. Upright North compass pointer (-90°)
    let a0 = -90.0 * .pi / 180.0
    let aL = (-90.0 - 11.2) * .pi / 180.0
    let aR = (-90.0 + 11.2) * .pi / 180.0
    let north = CGMutablePath()
    north.move(to: CGPoint(x: 512 + cos(a0) * 336, y: 512 + sin(a0) * 336))
    north.addLine(to: CGPoint(x: 512 + cos(aR) * 238, y: 512 + sin(aR) * 238))
    north.addLine(to: CGPoint(x: 512 + cos(a0) * 260, y: 512 + sin(a0) * 260))
    north.addLine(to: CGPoint(x: 512 + cos(aL) * 238, y: 512 + sin(aL) * 238))
    north.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * sc), blur: 6 * sc, color: shadowCol.copy(alpha: 0.30) ?? shadowCol)
    ctx.addPath(north)
    ctx.setFillColor(accMid)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(north)
    ctx.clip()
    if let ag = CGGradient(colorsSpace: cs, colors: [accLight, accMid, accDeep] as CFArray, locations: [0, isDarkFace ? 0.68 : 0.52, 1]) {
      ctx.drawLinearGradient(ag, start: CGPoint(x: 472, y: 176), end: CGPoint(x: 552, y: 274), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    ctx.restoreGState()

    // 6. Sculpted checkmark aligned to 2nd tick (-38.57°): M 377 511 L 460 598 L 639 426
    let checkPath = CGMutablePath()
    checkPath.move(to: CGPoint(x: 377, y: 511))
    checkPath.addLine(to: CGPoint(x: 460, y: 598))
    checkPath.addLine(to: CGPoint(x: 639, y: 426))

    let strokedCheck = checkPath.copy(strokingWithWidth: 64, lineCap: .round, lineJoin: .round, miterLimit: 10)
    if accentCheck {
      ctx.saveGState()
      ctx.setShadow(offset: CGSize(width: 0, height: -6 * sc), blur: 6 * sc, color: shadowCol.copy(alpha: 0.30) ?? shadowCol)
      ctx.addPath(strokedCheck)
      ctx.setFillColor(accMid)
      ctx.fillPath()
      ctx.restoreGState()

      ctx.saveGState()
      ctx.addPath(strokedCheck)
      ctx.clip()
      if let ag = CGGradient(colorsSpace: cs, colors: [accLight, accMid, accDeep] as CFArray, locations: [0, isDarkFace ? 0.68 : 0.52, 1]) {
        ctx.drawLinearGradient(ag, start: CGPoint(x: 377, y: 426), end: CGPoint(x: 639, y: 598), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
      }
      ctx.restoreGState()
    } else {
      if !isDarkFace {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: 5)
        ctx.addPath(checkPath)
        ctx.setStrokeColor(cg("#FFFFFF", alpha: 0.65))
        ctx.setLineWidth(66)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
      }
      ctx.saveGState()
      ctx.addPath(strokedCheck)
      ctx.clip()
      if let ig = CGGradient(colorsSpace: cs, colors: [checkInkTop, checkInkBot] as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(ig, start: CGPoint(x: 420, y: 426), end: CGPoint(x: 590, y: 598), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
      }
      ctx.restoreGState()
    }

    ctx.restoreGState() // unclip squircle

    guard let outCG = ctx.makeImage() else {
      return NSImage(size: NSSize(width: 512, height: 512))
    }
    let img = NSImage(size: NSSize(width: 512, height: 512))
    img.addRepresentation(NSBitmapImageRep(cgImage: outCG))
    return img
  }
  #endif
}
