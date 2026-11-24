import AppKit
import CoreGraphics
import Foundation

let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let outDir = "\(scriptDir)/screens"
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func savePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else {
        fatalError("Failed to create PNG destination at \(path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

func makeContext(width: Int, height: Int, flipped: Bool = true, draw: (CGContext) -> Void) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.setShouldSmoothFonts(true)
    if flipped {
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
    }
    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: flipped)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    draw(ctx)
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

func color(_ hex: UInt32, alpha: CGFloat = 1.0) -> NSColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255.0
    let g = CGFloat((hex >> 8) & 0xFF) / 255.0
    let b = CGFloat(hex & 0xFF) / 255.0
    return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
}

func drawRoundedRect(_ rect: CGRect, radius: CGFloat, fill: NSColor? = nil, stroke: NSColor? = nil, lineWidth: CGFloat = 1) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    if let f = fill { f.setFill(); path.fill() }
    if let s = stroke { s.setStroke(); path.lineWidth = lineWidth; path.stroke() }
}

func drawText(_ text: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color
    ]
    NSAttributedString(string: text, attributes: attrs).draw(at: point)
}

func drawTextRight(_ text: String, rightX: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color
    ]
    let str = NSAttributedString(string: text, attributes: attrs)
    let w = str.size().width
    str.draw(at: CGPoint(x: rightX - w, y: y))
}

func drawCheckbox(_ x: CGFloat, _ y: CGFloat, size: CGFloat, stroke: NSColor, radius: CGFloat = 6, lineWidth: CGFloat = 2.5) {
    drawRoundedRect(CGRect(x: x, y: y, width: size, height: size), radius: radius, fill: nil, stroke: stroke, lineWidth: lineWidth)
}

func drawSunIcon(cx: CGFloat, cy: CGFloat, r: CGFloat, color: NSColor) {
    let path = NSBezierPath(ovalIn: CGRect(x: cx - r * 0.45, y: cy - r * 0.45, width: r * 0.9, height: r * 0.9))
    color.setStroke()
    path.lineWidth = r * 0.16
    path.stroke()
    for i in 0..<8 {
        let a = CGFloat(i) * .pi / 4.0
        let ray = NSBezierPath()
        ray.move(to: CGPoint(x: cx + cos(a) * r * 0.72, y: cy + sin(a) * r * 0.72))
        ray.line(to: CGPoint(x: cx + cos(a) * r * 1.0, y: cy + sin(a) * r * 1.0))
        ray.lineWidth = r * 0.15
        ray.lineCapStyle = .round
        ray.stroke()
    }
}

func drawSparkle(cx: CGFloat, cy: CGFloat, r: CGFloat, col: NSColor) {
    let p = NSBezierPath()
    p.move(to: CGPoint(x: cx, y: cy - r))
    p.curve(to: CGPoint(x: cx + r, y: cy), controlPoint1: CGPoint(x: cx + r*0.18, y: cy - r*0.18), controlPoint2: CGPoint(x: cx + r*0.18, y: cy - r*0.18))
    p.curve(to: CGPoint(x: cx, y: cy + r), controlPoint1: CGPoint(x: cx + r*0.18, y: cy + r*0.18), controlPoint2: CGPoint(x: cx + r*0.18, y: cy + r*0.18))
    p.curve(to: CGPoint(x: cx - r, y: cy), controlPoint1: CGPoint(x: cx - r*0.18, y: cy + r*0.18), controlPoint2: CGPoint(x: cx - r*0.18, y: cy + r*0.18))
    p.curve(to: CGPoint(x: cx, y: cy - r), controlPoint1: CGPoint(x: cx - r*0.18, y: cy - r*0.18), controlPoint2: CGPoint(x: cx - r*0.18, y: cy - r*0.18))
    p.close()
    col.setFill()
    p.fill()
}

// ---------------------------------------------------------------------------
// 1. MACBOOK PRO 14" SCREEN (3024 x 1964) — Warm orange macOS wave + Septena
// ---------------------------------------------------------------------------
let macW = 3024, macH = 1964
let macImg = makeContext(width: macW, height: macH) { ctx in
    let W = CGFloat(macW), H = CGFloat(macH)
    let cs = CGColorSpaceCreateDeviceRGB()

    // Base rich orange-vermilion gradient
    let bgGrad = CGGradient(
        colorsSpace: cs,
        colors: [color(0xC93404).cgColor, color(0xEB5A08).cgColor, color(0xFF8C14).cgColor, color(0xB82902).cgColor] as CFArray,
        locations: [0.0, 0.35, 0.72, 1.0]
    )!
    ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: W, y: H), options: [])

    // Layered abstract macOS-style sweeping waves
    func drawWave(points: [(CGFloat, CGFloat)], c1: UInt32, c2: UInt32, alpha: CGFloat) {
        ctx.saveGState()
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -50, y: H + 50))
        path.addLine(to: CGPoint(x: -50, y: points[0].1 * H))
        for i in 0..<(points.count - 1) {
            let p0 = CGPoint(x: points[i].0 * W, y: points[i].1 * H)
            let p1 = CGPoint(x: points[i+1].0 * W, y: points[i+1].1 * H)
            let mid = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
            path.addQuadCurve(to: mid, control: p0)
        }
        let last = points.last!
        path.addLine(to: CGPoint(x: last.0 * W + 50, y: last.1 * H))
        path.addLine(to: CGPoint(x: W + 50, y: H + 50))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.clip()
        let g = CGGradient(colorsSpace: cs, colors: [color(c1, alpha: alpha).cgColor, color(c2, alpha: alpha).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: W, y: H), options: [])
        ctx.restoreGState()
    }

    drawWave(points: [(0, 0.25), (0.28, 0.08), (0.55, 0.34), (0.82, 0.14), (1.05, 0.32)], c1: 0xFF9F1C, c2: 0xD93805, alpha: 0.85)
    drawWave(points: [(0, 0.56), (0.22, 0.36), (0.48, 0.62), (0.76, 0.38), (1.05, 0.52)], c1: 0xFF7B00, c2: 0xA82002, alpha: 0.90)
    drawWave(points: [(0, 0.78), (0.30, 0.62), (0.62, 0.85), (0.88, 0.66), (1.05, 0.74)], c1: 0xFFB02E, c2: 0xCC3300, alpha: 0.92)
    drawWave(points: [(0, 0.92), (0.25, 0.80), (0.58, 0.95), (0.85, 0.82), (1.05, 0.90)], c1: 0xE64B00, c2: 0x7A1200, alpha: 0.95)

    // Floating Septena macOS window with soft drop shadow
    let winRect = CGRect(x: 290, y: 215, width: W - 580, height: H - 430)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 28), blur: 70, color: NSColor(white: 0, alpha: 0.38).cgColor)
    drawRoundedRect(winRect, radius: 34, fill: color(0xFAFAFA))
    ctx.restoreGState()

    // Clip to window
    ctx.saveGState()
    let winPath = NSBezierPath(roundedRect: winRect, xRadius: 34, yRadius: 34)
    winPath.addClip()

    let sidebarW: CGFloat = 530
    let detailW: CGFloat = 760
    let centerX = winRect.minX + sidebarW
    let detailX = winRect.maxX - detailW

    // Sidebar background
    color(0xF3F2F0).setFill()
    NSRect(x: winRect.minX, y: winRect.minY, width: sidebarW, height: winRect.height).fill()
    // Detail background
    color(0xF8F7F5).setFill()
    NSRect(x: detailX, y: winRect.minY, width: detailW, height: winRect.height).fill()
    // Vertical dividers
    color(0xE6E4E1).setFill()
    NSRect(x: centerX, y: winRect.minY, width: 2, height: winRect.height).fill()
    NSRect(x: detailX, y: winRect.minY, width: 2, height: winRect.height).fill()

    // Traffic lights
    let tlY = winRect.minY + 42
    for (idx, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
        color(hex).setFill()
        NSBezierPath(ovalIn: CGRect(x: winRect.minX + 44 + CGFloat(idx) * 44, y: tlY, width: 24, height: 24)).fill()
    }

    // Sidebar items
    let sbX = winRect.minX + 36
    let accent = color(0xE05212)
    let softOrange = color(0xFCD6BF)
    let ink = color(0x111113)
    let muted = color(0x52525B)

    drawRoundedRect(CGRect(x: sbX - 8, y: winRect.minY + 124, width: sidebarW - 56, height: 74), radius: 18, fill: softOrange)
    drawSunIcon(cx: sbX + 26, cy: winRect.minY + 161, r: 16, color: accent)
    drawText("Today", at: CGPoint(x: sbX + 58, y: winRect.minY + 141), size: 32, weight: .semibold, color: accent)
    drawRoundedRect(CGRect(x: winRect.minX + sidebarW - 88, y: winRect.minY + 143, width: 42, height: 36), radius: 18, fill: color(0xF6B38E))
    drawText("6", at: CGPoint(x: winRect.minX + sidebarW - 75, y: winRect.minY + 145), size: 25, weight: .semibold, color: color(0x7C2D12))

    drawText("Inbox", at: CGPoint(x: sbX + 58, y: winRect.minY + 230), size: 31, weight: .medium, color: ink)
    drawTextRight("2", rightX: winRect.minX + sidebarW - 56, y: winRect.minY + 232, size: 28, weight: .regular, color: muted)

    drawText("Upcoming", at: CGPoint(x: sbX + 58, y: winRect.minY + 305), size: 31, weight: .medium, color: ink)

    drawText("Lists", at: CGPoint(x: sbX + 12, y: winRect.minY + 412), size: 26, weight: .semibold, color: muted)
    drawText("Admin", at: CGPoint(x: sbX + 58, y: winRect.minY + 474), size: 31, weight: .medium, color: ink)
    drawText("Website", at: CGPoint(x: sbX + 58, y: winRect.minY + 548), size: 31, weight: .medium, color: ink)
    drawText("+  New List", at: CGPoint(x: sbX + 18, y: winRect.minY + 626), size: 29, weight: .medium, color: muted)

    // Center pane: Today
    let cx = centerX + 76
    let cw = detailX - centerX - 152
    drawSunIcon(cx: cx + 22, cy: winRect.minY + 150, r: 22, color: accent)
    drawText("Today", at: CGPoint(x: cx + 62, y: winRect.minY + 114), size: 58, weight: .bold, color: ink)

    // Inbox section
    drawText("Inbox", at: CGPoint(x: cx + 42, y: winRect.minY + 230), size: 31, weight: .semibold, color: ink)
    drawText("2", at: CGPoint(x: cx + 140, y: winRect.minY + 232), size: 29, weight: .regular, color: muted)
    color(0xECEAE6).setFill()
    NSRect(x: cx, y: winRect.minY + 280, width: cw, height: 2).fill()

    drawCheckbox(cx + 4, winRect.minY + 306, size: 34, stroke: color(0x71717A), radius: 8, lineWidth: 3.5)
    drawText("Check the download links", at: CGPoint(x: cx + 58, y: winRect.minY + 304), size: 31, weight: .medium, color: ink)
    drawCheckbox(cx + 4, winRect.minY + 378, size: 34, stroke: color(0x71717A), radius: 8, lineWidth: 3.5)
    drawText("Review the product outline", at: CGPoint(x: cx + 58, y: winRect.minY + 376), size: 31, weight: .medium, color: ink)

    // Discuss highlighted card
    let cardY = winRect.minY + 468
    let cardH: CGFloat = 382
    drawRoundedRect(CGRect(x: cx - 22, y: cardY, width: cw + 44, height: cardH), radius: 26, fill: color(0xFDE5D7), stroke: color(0xF0B28C), lineWidth: 2.5)
    drawSparkle(cx: cx + 20, cy: cardY + 48, r: 16, col: accent)
    drawText("Discuss", at: CGPoint(x: cx + 52, y: cardY + 28), size: 32, weight: .bold, color: accent)
    drawCheckbox(cx + 4, cardY + 98, size: 34, stroke: color(0x27272A), radius: 8, lineWidth: 3.5)
    drawText("Send the launch update", at: CGPoint(x: cx + 58, y: cardY + 95), size: 34, weight: .bold, color: ink)

    drawRoundedRect(CGRect(x: cx + 2, y: cardY + 162, width: cw - 4, height: 186), radius: 20, fill: color(0xF9D2BA))
    drawText("What should the update focus on?", at: CGPoint(x: cx + 28, y: cardY + 190), size: 30, weight: .semibold, color: ink)

    let pills = ["What's new", "Launch timing", "Next steps"]
    var px = cx + 28
    for p in pills {
        let pw = CGFloat(p.count) * 16 + 54
        drawRoundedRect(CGRect(x: px, y: cardY + 264, width: pw, height: 56), radius: 28, fill: color(0xFFFFFF))
        drawText(p, at: CGPoint(x: px + 26, y: cardY + 276), size: 25, weight: .medium, color: ink)
        px += pw + 18
    }

    // Agent row
    let agY = cardY + cardH + 46
    drawSparkle(cx: cx + 20, cy: agY + 20, r: 16, col: accent)
    drawText("Draft the launch brief", at: CGPoint(x: cx + 56, y: agY), size: 32, weight: .medium, color: ink)
    drawRoundedRect(CGRect(x: cx + cw - 156, y: agY - 4, width: 156, height: 48), radius: 24, fill: softOrange)
    drawText("Your turn", at: CGPoint(x: cx + cw - 134, y: agY + 5), size: 24, weight: .semibold, color: accent)

    // Admin section
    let adY = agY + 92
    drawText("Admin", at: CGPoint(x: cx + 44, y: adY), size: 33, weight: .bold, color: ink)
    let adminTasks = ["Review the project outline", "Confirm the launch checklist", "Share the final draft"]
    for (i, t) in adminTasks.enumerated() {
        let ry = adY + 68 + CGFloat(i) * 72
        drawCheckbox(cx + 4, ry, size: 34, stroke: color(0x71717A), radius: 8, lineWidth: 3.5)
        drawText(t, at: CGPoint(x: cx + 58, y: ry - 2), size: 31, weight: .medium, color: ink)
    }

    // Right inspector pane
    let dx = detailX + 56
    let dw = detailW - 112
    drawSparkle(cx: dx + 16, cy: winRect.minY + 132, r: 15, col: accent)
    drawText("Discuss", at: CGPoint(x: dx + 44, y: winRect.minY + 114), size: 30, weight: .semibold, color: accent)
    drawText("Send the launch update", at: CGPoint(x: dx, y: winRect.minY + 190), size: 42, weight: .bold, color: ink)
    drawText("What should the update focus on?", at: CGPoint(x: dx, y: winRect.minY + 266), size: 29, weight: .regular, color: color(0x3F3F46))

    var dpx = dx
    for p in pills {
        let pw = CGFloat(p.count) * 14 + 44
        drawRoundedRect(CGRect(x: dpx, y: winRect.minY + 340, width: pw, height: 52), radius: 26, fill: color(0xEFECE8))
        drawText(p, at: CGPoint(x: dpx + 20, y: winRect.minY + 352), size: 23, weight: .medium, color: ink)
        dpx += pw + 14
    }

    drawText("Notes", at: CGPoint(x: dx, y: winRect.minY + 462), size: 28, weight: .semibold, color: muted)
    drawRoundedRect(CGRect(x: dx, y: winRect.minY + 514, width: dw, height: 112), radius: 18, fill: color(0xF1EFEC))
    drawText("Add a note...", at: CGPoint(x: dx + 26, y: winRect.minY + 548), size: 28, weight: .regular, color: color(0xA1A1AA))

    ctx.restoreGState()
}
savePNG(macImg, to: "\(outDir)/demo_mac.png")

// ---------------------------------------------------------------------------
// 2. IPHONE SCREEN (1290 x 2796) — Light-mode Septena Today + Orange accent
// ---------------------------------------------------------------------------
let iosW = 1290, iosH = 2796
let iosImg = makeContext(width: iosW, height: iosH) { ctx in
    let W = CGFloat(iosW), H = CGFloat(iosH)
    let ink = color(0x111113)
    let muted = color(0x52525B)
    let accent = color(0xE05212)
    let softOrange = color(0xFCD6BF)

    color(0xF5F4F1).setFill()
    NSRect(x: 0, y: 0, width: W, height: H).fill()

    // Status bar (clean uninterrupted top edge — no Dynamic Island / notch)
    drawText("9:41", at: CGPoint(x: 108, y: 66), size: 46, weight: .semibold, color: ink)
    // Signal / battery minimalist marks
    for i in 0..<4 {
        let bh = CGFloat(14 + i * 7)
        drawRoundedRect(CGRect(x: W - 265 + CGFloat(i)*14, y: 104 - bh, width: 9, height: bh), radius: 3, fill: ink)
    }
    drawRoundedRect(CGRect(x: W - 180, y: 74, width: 68, height: 32), radius: 8, fill: nil, stroke: ink, lineWidth: 4)
    drawRoundedRect(CGRect(x: W - 174, y: 80, width: 52, height: 20), radius: 4, fill: ink)

    // Top bar pills
    drawRoundedRect(CGRect(x: 64, y: 210, width: 104, height: 104), radius: 52, fill: color(0xFFFFFF))
    drawSunIcon(cx: 116, cy: 262, r: 22, color: ink)
    drawRoundedRect(CGRect(x: W - 270, y: 210, width: 206, height: 104), radius: 52, fill: color(0xFFFFFF))
    drawText("•••", at: CGPoint(x: W - 234, y: 238), size: 36, weight: .bold, color: ink)
    // Search circle
    let sc = NSBezierPath(ovalIn: CGRect(x: W - 144, y: 242, width: 34, height: 34))
    ink.setStroke(); sc.lineWidth = 5; sc.stroke()

    // Today Title
    drawSunIcon(cx: 106, cy: 432, r: 34, color: accent)
    drawText("Today", at: CGPoint(x: 162, y: 378), size: 96, weight: .bold, color: ink)

    // Inbox section
    let pad: CGFloat = 76
    drawText("Inbox", at: CGPoint(x: pad + 56, y: 572), size: 46, weight: .semibold, color: ink)
    drawText("2", at: CGPoint(x: pad + 196, y: 574), size: 44, weight: .regular, color: muted)

    drawRoundedRect(CGRect(x: pad, y: 654, width: W - pad*2, height: 240), radius: 36, fill: color(0xFFFFFF), stroke: color(0xE4E2DD), lineWidth: 2)
    drawCheckbox(pad + 36, 696, size: 48, stroke: color(0x71717A), radius: 12, lineWidth: 4.5)
    drawText("Check the download links", at: CGPoint(x: pad + 114, y: 694), size: 44, weight: .medium, color: ink)
    color(0xE8E5DF).setFill()
    NSRect(x: pad + 36, y: 774, width: W - pad*2 - 72, height: 2).fill()
    drawCheckbox(pad + 36, 812, size: 48, stroke: color(0x71717A), radius: 12, lineWidth: 4.5)
    drawText("Review the product outline", at: CGPoint(x: pad + 114, y: 810), size: 44, weight: .medium, color: ink)

    // Discuss highlighted card
    let cy: CGFloat = 956
    let ch: CGFloat = 650
    drawRoundedRect(CGRect(x: pad - 10, y: cy, width: W - pad*2 + 20, height: ch), radius: 44, fill: color(0xFDE5D7), stroke: color(0xEDA880), lineWidth: 3.5)
    drawSparkle(cx: pad + 52, cy: cy + 78, r: 24, col: accent)
    drawText("Discuss", at: CGPoint(x: pad + 98, y: cy + 48), size: 48, weight: .bold, color: accent)

    drawCheckbox(pad + 32, cy + 158, size: 50, stroke: color(0x18181B), radius: 12, lineWidth: 5)
    drawText("Send the launch update", at: CGPoint(x: pad + 112, y: cy + 152), size: 52, weight: .bold, color: ink)

    drawRoundedRect(CGRect(x: pad + 26, y: cy + 258, width: W - pad*2 - 52, height: 344), radius: 32, fill: color(0xF9D2BA))
    drawText("What should the update focus on?", at: CGPoint(x: pad + 62, y: cy + 306), size: 46, weight: .semibold, color: ink)

    let pills = ["What's new", "Launch timing", "Next steps"]
    var px = pad + 54
    for p in pills {
        let pw = CGFloat(p.count) * 23 + 74
        drawRoundedRect(CGRect(x: px, y: cy + 444, width: pw, height: 96), radius: 48, fill: color(0xFFFFFF))
        drawText(p, at: CGPoint(x: px + 34, y: cy + 468), size: 37, weight: .medium, color: ink)
        px += pw + 22
    }

    // Draft brief agent row
    let ay: CGFloat = cy + ch + 78
    drawSparkle(cx: pad + 44, cy: ay + 30, r: 24, col: accent)
    drawText("Draft the launch brief", at: CGPoint(x: pad + 98, y: ay), size: 46, weight: .medium, color: ink)
    drawRoundedRect(CGRect(x: W - pad - 246, y: ay - 10, width: 246, height: 76), radius: 38, fill: softOrange)
    drawText("Your turn", at: CGPoint(x: W - pad - 210, y: ay + 6), size: 36, weight: .semibold, color: accent)

    // Admin section
    let ady: CGFloat = ay + 152
    drawText("Admin", at: CGPoint(x: pad + 56, y: ady), size: 50, weight: .bold, color: ink)
    let adminTasks = ["Review the project outline", "Confirm the launch checklist", "Share the final draft"]
    drawRoundedRect(CGRect(x: pad, y: ady + 84, width: W - pad*2, height: 360), radius: 36, fill: color(0xFFFFFF), stroke: color(0xE4E2DD), lineWidth: 2)
    for (i, t) in adminTasks.enumerated() {
        let ry = ady + 126 + CGFloat(i) * 114
        if i > 0 {
            color(0xE8E5DF).setFill()
            NSRect(x: pad + 36, y: ry - 26, width: W - pad*2 - 72, height: 2).fill()
        }
        drawCheckbox(pad + 36, ry, size: 48, stroke: color(0x71717A), radius: 12, lineWidth: 4.5)
        drawText(t, at: CGPoint(x: pad + 114, y: ry - 2), size: 44, weight: .medium, color: ink)
    }

    // Floating Orange + Button
    let fabSize: CGFloat = 196
    let fabRect = CGRect(x: W - pad - fabSize, y: H - 290, width: fabSize, height: fabSize)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 36, color: color(0xEA580C, alpha: 0.45).cgColor)
    drawRoundedRect(fabRect, radius: fabSize / 2, fill: color(0xF95B12))
    ctx.restoreGState()
    // Plus sign inside FAB
    color(0xFFFFFF).setFill()
    NSRect(x: fabRect.midX - 42, y: fabRect.midY - 6, width: 84, height: 12).fill()
    NSRect(x: fabRect.midX - 6, y: fabRect.midY - 42, width: 12, height: 84).fill()

    // Home indicator
    drawRoundedRect(CGRect(x: W/2 - 220, y: H - 56, width: 440, height: 16), radius: 8, fill: color(0x18181B, alpha: 0.85))
}
savePNG(iosImg, to: "\(outDir)/demo_ios.png")

// ---------------------------------------------------------------------------
// 3. APPLE WATCH SCREEN (410 x 502) — Pure OLED Dark Septena Today
// ---------------------------------------------------------------------------
let wW = 410, wH = 502
let watchImg = makeContext(width: wW, height: wH) { ctx in
    let W = CGFloat(wW), H = CGFloat(wH)
    color(0x030304).setFill()
    NSRect(x: 0, y: 0, width: W, height: H).fill()

    let accent = color(0xFF6B1A)
    drawText("Today", at: CGPoint(x: 34, y: 36), size: 44, weight: .bold, color: accent)
    drawTextRight("9:41", rightX: W - 34, y: 40, size: 38, weight: .semibold, color: color(0xF4F4F5))

    let rows = ["Check the down...", "Review the prod...", "Send the launch..."]
    for (i, r) in rows.enumerated() {
        let ry = CGFloat(130 + i * 110)
        drawRoundedRect(CGRect(x: 22, y: ry, width: W - 44, height: 92), radius: 24, fill: color(0x161618))
        let circle = NSBezierPath(ovalIn: CGRect(x: 42, y: ry + 26, width: 38, height: 38))
        color(0x71717A).setStroke(); circle.lineWidth = 3.5; circle.stroke()
        drawText(r, at: CGPoint(x: 96, y: ry + 26), size: 32, weight: .medium, color: color(0xFAFAFA))
    }
}
savePNG(watchImg, to: "\(outDir)/demo_watch.png")

// ---------------------------------------------------------------------------
// 4. IPAD MINI SCREEN (2266 x 1488 Landscape) — Crisp 2-pane Septena iPadOS
// ---------------------------------------------------------------------------
let ipW = 2266, ipH = 1488
let ipadImg = makeContext(width: ipW, height: ipH) { ctx in
    let W = CGFloat(ipW), H = CGFloat(ipH)
    let ink = color(0x111113)
    let muted = color(0x52525B)
    let accent = color(0xE05212)
    let softOrange = color(0xFCD6BF)

    color(0xF6F5F2).setFill()
    NSRect(x: 0, y: 0, width: W, height: H).fill()

    let sbW: CGFloat = 540
    color(0xEEEDE9).setFill()
    NSRect(x: 0, y: 0, width: sbW, height: H).fill()
    color(0xDDDAD4).setFill()
    NSRect(x: sbW, y: 0, width: 2, height: H).fill()

    // Status bar (inset neatly inside concentric rounded corners)
    drawText("9:41  Tue Nov 24", at: CGPoint(x: 92, y: 36), size: 30, weight: .semibold, color: ink)
    drawTextRight("100%", rightX: W - 155, y: 36, size: 30, weight: .semibold, color: ink)
    drawRoundedRect(CGRect(x: W - 140, y: 42, width: 54, height: 26), radius: 6, fill: nil, stroke: ink, lineWidth: 3)
    drawRoundedRect(CGRect(x: W - 135, y: 47, width: 42, height: 16), radius: 3, fill: ink)

    // Sidebar
    let sx: CGFloat = 46
    drawRoundedRect(CGRect(x: sx - 12, y: 150, width: sbW - 68, height: 86), radius: 22, fill: softOrange)
    drawSunIcon(cx: sx + 26, cy: 193, r: 19, color: accent)
    drawText("Today", at: CGPoint(x: sx + 64, y: 170), size: 38, weight: .bold, color: accent)
    drawRoundedRect(CGRect(x: sbW - 104, y: 171, width: 48, height: 42), radius: 21, fill: color(0xF5AE85))
    drawText("6", at: CGPoint(x: sbW - 89, y: 174), size: 28, weight: .bold, color: color(0x7C2D12))

    drawText("Inbox", at: CGPoint(x: sx + 64, y: 274), size: 36, weight: .medium, color: ink)
    drawTextRight("2", rightX: sbW - 62, y: 276, size: 34, weight: .medium, color: muted)
    drawText("Upcoming", at: CGPoint(x: sx + 64, y: 362), size: 36, weight: .medium, color: ink)
    drawText("Lists", at: CGPoint(x: sx + 12, y: 486), size: 30, weight: .semibold, color: muted)
    drawText("Admin", at: CGPoint(x: sx + 64, y: 558), size: 36, weight: .medium, color: ink)
    drawText("Website", at: CGPoint(x: sx + 64, y: 644), size: 36, weight: .medium, color: ink)
    drawText("Launch", at: CGPoint(x: sx + 64, y: 730), size: 36, weight: .medium, color: ink)

    // Main pane
    let mx = sbW + 92
    let mw = W - mx - 92
    drawSunIcon(cx: mx + 30, cy: 192, r: 28, color: accent)
    drawText("Today", at: CGPoint(x: mx + 80, y: 148), size: 74, weight: .bold, color: ink)

    // Inbox card
    drawText("Inbox  2", at: CGPoint(x: mx + 12, y: 276), size: 36, weight: .semibold, color: ink)
    drawRoundedRect(CGRect(x: mx, y: 336, width: mw, height: 196), radius: 28, fill: color(0xFFFFFF), stroke: color(0xE4E2DD), lineWidth: 2)
    drawCheckbox(mx + 34, 368, size: 40, stroke: color(0x71717A), radius: 10, lineWidth: 4)
    drawText("Check the download links", at: CGPoint(x: mx + 98, y: 366), size: 38, weight: .medium, color: ink)
    color(0xE8E5DF).setFill()
    NSRect(x: mx + 34, y: 434, width: mw - 68, height: 2).fill()
    drawCheckbox(mx + 34, 464, size: 40, stroke: color(0x71717A), radius: 10, lineWidth: 4)
    drawText("Review the product outline", at: CGPoint(x: mx + 98, y: 462), size: 38, weight: .medium, color: ink)

    // Discuss highlighted card
    let cy: CGFloat = 582
    drawRoundedRect(CGRect(x: mx - 8, y: cy, width: mw + 16, height: 428), radius: 34, fill: color(0xFDE5D7), stroke: color(0xEDA880), lineWidth: 3)
    drawSparkle(cx: mx + 44, cy: cy + 56, r: 20, col: accent)
    drawText("Discuss", at: CGPoint(x: mx + 82, y: cy + 32), size: 40, weight: .bold, color: accent)
    drawCheckbox(mx + 32, cy + 114, size: 42, stroke: color(0x18181B), radius: 10, lineWidth: 4.5)
    drawText("Send the launch update", at: CGPoint(x: mx + 96, y: cy + 110), size: 44, weight: .bold, color: ink)

    drawRoundedRect(CGRect(x: mx + 26, y: cy + 190, width: mw - 52, height: 204), radius: 24, fill: color(0xF9D2BA))
    drawText("What should the update focus on?", at: CGPoint(x: mx + 56, y: cy + 220), size: 38, weight: .semibold, color: ink)
    var px = mx + 54
    for p in ["What's new", "Launch timing", "Next steps"] {
        let pw = CGFloat(p.count) * 20 + 68
        drawRoundedRect(CGRect(x: px, y: cy + 298, width: pw, height: 68), radius: 34, fill: color(0xFFFFFF))
        drawText(p, at: CGPoint(x: px + 32, y: cy + 314), size: 31, weight: .semibold, color: ink)
        px += pw + 22
    }

    // Agent row + Admin
    let ay = cy + 476
    drawSparkle(cx: mx + 36, cy: ay + 24, r: 20, col: accent)
    drawText("Draft the launch brief", at: CGPoint(x: mx + 82, y: ay), size: 40, weight: .semibold, color: ink)
    drawRoundedRect(CGRect(x: mx + mw - 210, y: ay - 6, width: 210, height: 62), radius: 31, fill: softOrange)
    drawText("Your turn", at: CGPoint(x: mx + mw - 180, y: ay + 7), size: 31, weight: .bold, color: accent)

    let ady = ay + 112
    drawText("Admin", at: CGPoint(x: mx + 12, y: ady), size: 40, weight: .bold, color: ink)
    drawRoundedRect(CGRect(x: mx, y: ady + 62, width: mw, height: 196), radius: 28, fill: color(0xFFFFFF), stroke: color(0xE4E2DD), lineWidth: 2)
    drawCheckbox(mx + 34, ady + 94, size: 40, stroke: color(0x71717A), radius: 10, lineWidth: 4)
    drawText("Review the project outline", at: CGPoint(x: mx + 98, y: ady + 92), size: 38, weight: .medium, color: ink)
    color(0xE8E5DF).setFill()
    NSRect(x: mx + 34, y: ady + 160, width: mw - 68, height: 2).fill()
    drawCheckbox(mx + 34, ady + 188, size: 40, stroke: color(0x71717A), radius: 10, lineWidth: 4)
    drawText("Confirm the launch checklist", at: CGPoint(x: mx + 98, y: ady + 186), size: 38, weight: .medium, color: ink)

    // Floating + button
    let fabSize: CGFloat = 132
    let fabRect = CGRect(x: W - 92 - fabSize, y: H - 186, width: fabSize, height: fabSize)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 26, color: color(0xE05212, alpha: 0.45).cgColor)
    drawRoundedRect(fabRect, radius: fabSize / 2, fill: color(0xE05212))
    ctx.restoreGState()
    color(0xFFFFFF).setFill()
    NSRect(x: fabRect.midX - 28, y: fabRect.midY - 5, width: 56, height: 10).fill()
    NSRect(x: fabRect.midX - 5, y: fabRect.midY - 28, width: 10, height: 56).fill()
}
savePNG(ipadImg, to: "\(outDir)/demo_ipad.png")

print("Generated demo screens in \(outDir)")
