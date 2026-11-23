// Generates the Android adaptive launcher icon from the Septask default app
// icon (#282). Regenerate, never retouch:
//
//   swift scripts/gen-android-icon.swift
//
// Source: Septask/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png.
// Foreground: the dial, cut out of the source with a circle mask, sized so
// it fills the launcher mask as it fills the iOS squircle (the 72dp visible
// area of the 108dp layer maps to the full 1024 source).
// Background: the source's dark diagonal gradient, sampled at its corners.
// Output: android/app/src/main/res/mipmap-*/ic_launcher_{foreground,background}.png
import AppKit

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = repo.appendingPathComponent("Septask/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
let res = repo.appendingPathComponent("android/app/src/main/res")

guard let image = NSImage(contentsOf: source),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
  fatalError("cannot read \(source.path)")
}

// Dial geometry in source pixels: the outer edge of the dark ring sits at
// x = 97 on the center row, so the radius is 415; 3px more keeps its rim.
let dialRadius: CGFloat = 418
let sourceSize: CGFloat = 1024
// Corner samples of the source background (top-left light, bottom-right dark).
let gradientStart = CGColor(srgbRed: 0x59 / 255, green: 0x5a / 255, blue: 0x64 / 255, alpha: 1)
let gradientEnd = CGColor(srgbRed: 0x16 / 255, green: 0x17 / 255, blue: 0x1e / 255, alpha: 1)

let densities: [(String, Int)] = [("mdpi", 108), ("hdpi", 162), ("xhdpi", 216), ("xxhdpi", 324), ("xxxhdpi", 432)]

func context(_ side: Int) -> CGContext {
  CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func write(_ ctx: CGContext, _ url: URL) {
  let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
  try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

for (name, side) in densities {
  let s = CGFloat(side)
  let dir = res.appendingPathComponent("mipmap-\(name)")

  // Foreground: source drawn at 72/108 of the layer, centered, clipped to the dial.
  let fg = context(side)
  let drawn = s * 72 / 108
  let origin = (s - drawn) / 2
  let scale = drawn / sourceSize
  let r = dialRadius * scale
  fg.addEllipse(in: CGRect(x: s / 2 - r, y: s / 2 - r, width: 2 * r, height: 2 * r))
  fg.clip()
  fg.interpolationQuality = .high
  fg.draw(cg, in: CGRect(x: origin, y: origin, width: drawn, height: drawn))
  write(fg, dir.appendingPathComponent("ic_launcher_foreground.png"))

  // Background: diagonal gradient, top-left to bottom-right (CG's origin is bottom-left).
  let bg = context(side)
  let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                            colors: [gradientStart, gradientEnd] as CFArray, locations: [0, 1])!
  bg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
  write(bg, dir.appendingPathComponent("ic_launcher_background.png"))
}
print("wrote \(densities.count) densities to \(res.path)")
