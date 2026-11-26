// Generates Google Play Store graphical assets from the canonical Septena app
// icon and store panels. Regenerate, never retouch:
//
//   swift scripts/gen-playstore-assets.swift
//
// Outputs under appstore/playstore/:
//   icon-512.png                  512x512 RGB PNG (no alpha), Play hi-res icon
//   feature-graphic.png           1024x500 RGB PNG (no alpha), Play feature graphic
//   screenshots/phone/01..08.png  1080x2156 RGB PNG (< 2:1 aspect), phone screenshots
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let iconSource = repo.appendingPathComponent("Septask/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
let defaultShots = repo.appendingPathComponent("appstore/screenshots-septask/en-US")
let parentShots = repo.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("appstore/screenshots-septask/en-US")
let shotsSource: URL = {
    if let idx = CommandLine.arguments.firstIndex(of: "--shots"), idx + 1 < CommandLine.arguments.count {
        return URL(fileURLWithPath: CommandLine.arguments[idx + 1])
    }
    if FileManager.default.fileExists(atPath: defaultShots.path) { return defaultShots }
    if FileManager.default.fileExists(atPath: parentShots.path) { return parentShots }
    return defaultShots
}()
let outRoot = repo.appendingPathComponent("appstore/playstore")
let phoneOut = outRoot.appendingPathComponent("screenshots/phone")

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func loadCGImage(_ url: URL) -> CGImage {
    guard let image = NSImage(contentsOf: url),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fatalError("cannot read image: \(url.path)")
    }
    return cg
}

/// Creates an opaque 24-bit RGB bitmap context (noneSkipLast -> Play-compliant no alpha).
func rgbContext(width: Int, height: Int) -> CGContext {
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: srgb,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        fatalError("cannot create RGB context \(width)x\(height)")
    }
    ctx.interpolationQuality = .high
    return ctx
}

func writeOpaquePNG(_ ctx: CGContext, to url: URL) {
    guard let cg = ctx.makeImage() else { fatalError("makeImage failed for \(url.path)") }
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("CGImageDestinationCreateWithURL failed for \(url.path)")
    }
    CGImageDestinationAddImage(dest, cg, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("CGImageDestinationFinalize failed for \(url.path)")
    }
}

// 1. Play Store Hi-Res Icon (512 x 512, opaque RGB PNG)
let appIcon = loadCGImage(iconSource)
do {
    let ctx = rgbContext(width: 512, height: 512)
    ctx.draw(appIcon, in: CGRect(x: 0, y: 0, width: 512, height: 512))
    writeOpaquePNG(ctx, to: outRoot.appendingPathComponent("icon-512.png"))
}

// 2. Play Store Feature Graphic (1024 x 500, opaque RGB PNG)
do {
    let w: CGFloat = 1024
    let h: CGFloat = 500
    let ctx = rgbContext(width: Int(w), height: Int(h))

    // Rich charcoal diagonal gradient derived from the Septena icon palette.
    let bgGrad = CGGradient(
        colorsSpace: srgb,
        colors: [
            CGColor(srgbRed: 0x2a / 255, green: 0x2c / 255, blue: 0x35 / 255, alpha: 1),
            CGColor(srgbRed: 0x14 / 255, green: 0x15 / 255, blue: 0x1c / 255, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])

    // Subtle warm radial accent behind the icon so the silhouette lifts cleanly.
    let glow = CGGradient(
        colorsSpace: srgb,
        colors: [
            CGColor(srgbRed: 0.90, green: 0.36, blue: 0.16, alpha: 0.22),
            CGColor(srgbRed: 0.90, green: 0.36, blue: 0.16, alpha: 0.0),
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: 244, y: 250),
        startRadius: 20,
        endCenter: CGPoint(x: 244, y: 250),
        endRadius: 270,
        options: []
    )

    // Rounded app icon tile on the left with soft drop shadow.
    let iconSize: CGFloat = 236
    let iconRect = CGRect(x: 126, y: (h - iconSize) / 2, width: iconSize, height: iconSize)
    let iconPath = CGPath(roundedRect: iconRect, cornerWidth: 52, cornerHeight: 52, transform: nil)

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -14),
        blur: 36,
        color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55)
    )
    ctx.addPath(iconPath)
    ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(iconPath)
    ctx.clip()
    ctx.draw(appIcon, in: iconRect)
    ctx.restoreGState()

    // Crisp hairline rim around icon tile.
    ctx.saveGState()
    ctx.addPath(iconPath)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14))
    ctx.setLineWidth(1.5)
    ctx.strokePath()
    ctx.restoreGState()

    // Typography via NSGraphicsContext (flipped = false -> origin bottom-left).
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

    let titleFont = NSFont.systemFont(ofSize: 84, weight: .bold)
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: titleFont,
        .foregroundColor: NSColor.white,
        .kern: -2.0,
    ]
    let subFont = NSFont.systemFont(ofSize: 32, weight: .regular)
    let subAttrs: [NSAttributedString.Key: Any] = [
        .font: subFont,
        .foregroundColor: NSColor(srgbRed: 0.80, green: 0.82, blue: 0.86, alpha: 1.0),
        .kern: -0.3,
    ]
    let textX: CGFloat = 418
    NSAttributedString(string: "Septena", attributes: titleAttrs)
        .draw(at: CGPoint(x: textX, y: 244))
    NSAttributedString(string: "Tasks that think with you.", attributes: subAttrs)
        .draw(at: CGPoint(x: textX + 2, y: 186))

    NSGraphicsContext.restoreGraphicsState()

    writeOpaquePNG(ctx, to: outRoot.appendingPathComponent("feature-graphic.png"))
}

// 3. Play Store Phone Screenshots (1080 x 2116, aspect 1.959:1 < Google Play's 2:1 max)
// Uses the 8 platform-neutral panels (0..7); skips 8_iphone69_devices.png which names Apple devices.
let panels: [(src: String, dst: String, cropPhoto: Bool)] = [
    ("0_iphone69_photo.png",        "01-hero.png",         true),
    ("1_iphone69_from-agent.png",   "02-from-agent.png",   false),
    ("2_iphone69_asks.png",         "03-asks.png",         false),
    ("3_iphone69_agent-result.png", "04-agent-result.png", false),
    ("4_iphone69_lets-go.png",      "05-lets-go.png",      false),
    ("5_iphone69_move-in.png",      "06-move-in.png",      false),
    ("6_iphone69_open.png",         "07-open.png",         false),
    ("7_iphone69_looks.png",        "08-looks.png",        false),
]

let outW = 1080
let outH = 2156 // 2156 / 1080 = 1.996 (< 2.0 max required by Google Play)

for panel in panels {
    let srcURL = shotsSource.appendingPathComponent(panel.src)
    guard FileManager.default.fileExists(atPath: srcURL.path) else {
        print("skip missing panel: \(panel.src)")
        continue
    }
    let cg = loadCGImage(srcURL)
    let ctx = rgbContext(width: outW, height: outH)

    if panel.cropPhoto {
        // Photo panel: trim slightly less from the top than the bottom so both
        // the headline and footer keep generous breathing room, with no edge mirror.
        let targetAspect = CGFloat(outW) / CGFloat(outH)
        let cropH = min(cg.height, Int((CGFloat(cg.width) / targetAspect).rounded()))
        let totalTrim = cg.height - cropH
        let topTrim = Int((CGFloat(totalTrim) * 0.42).rounded())
        let cropped = cg.cropping(to: CGRect(x: 0, y: topTrim, width: cg.width, height: cropH))!
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))
    } else {
        // Graphic panels: preserve full vertical composition and extend left/right edges seamlessly
        // by horizontally mirroring the outermost 72px strip (~5% per side) into 1464x2868.
        let scale = CGFloat(outH) / CGFloat(cg.height)
        let drawnW = (CGFloat(cg.width) * scale).rounded()
        let pad = ((CGFloat(outW) - drawnW) / 2).rounded()

        // Left mirrored strip
        let stripSrcW = max(1, Int((pad / scale).rounded(.up)))
        if let leftStrip = cg.cropping(to: CGRect(x: 0, y: 0, width: stripSrcW, height: cg.height)) {
            ctx.saveGState()
            ctx.translateBy(x: pad, y: 0)
            ctx.scaleBy(x: -1, y: 1)
            ctx.draw(leftStrip, in: CGRect(x: 0, y: 0, width: pad, height: CGFloat(outH)))
            ctx.restoreGState()
        }
        // Right mirrored strip
        if let rightStrip = cg.cropping(to: CGRect(x: cg.width - stripSrcW, y: 0, width: stripSrcW, height: cg.height)) {
            let rightX = pad + drawnW
            let rightW = CGFloat(outW) - rightX
            ctx.saveGState()
            ctx.translateBy(x: rightX + rightW, y: 0)
            ctx.scaleBy(x: -1, y: 1)
            ctx.draw(rightStrip, in: CGRect(x: 0, y: 0, width: rightW, height: CGFloat(outH)))
            ctx.restoreGState()
        }
        // Center full panel
        ctx.draw(cg, in: CGRect(x: pad, y: 0, width: drawnW, height: CGFloat(outH)))
    }

    writeOpaquePNG(ctx, to: phoneOut.appendingPathComponent(panel.dst))
}

print("wrote Play Store assets to \(outRoot.path)")
