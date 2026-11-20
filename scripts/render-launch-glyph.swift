#!/usr/bin/env swift
// Renders the iOS launch-screen glyph for the task app (Septask target) from
// the app icon's own disc geometry, so the mark is never redrawn by hand.
//
//   swift scripts/render-launch-glyph.swift
//
// Source: Septask/AppIcon.icon/Assets/discs.svg. Like every shipped icon asset
// (docs/SEPTASK.md, "Icon Notes"), it reads the raw cx/cy/r as 1024-canvas
// pixels and ignores the viewBox transform.
//
// Output: Septask/Assets.xcassets/LaunchGlyph.imageset, two vector PDFs
// (light and dark appearance). The discs are fitted into a 60 pt square,
// centered on the disc cluster. The tint is subtle on purpose: systemGray2
// (light #AEAEB2, dark #636366) on the system background.

import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
  ? CommandLine.arguments[1]
  : FileManager.default.currentDirectoryPath)
let svgURL = root.appendingPathComponent("Septask/AppIcon.icon/Assets/discs.svg")
let outDir = root.appendingPathComponent("Septask/Assets.xcassets/LaunchGlyph.imageset")

let svg = try String(contentsOf: svgURL, encoding: .utf8)
let pattern = try NSRegularExpression(
  pattern: #"<circle\s+cx="([\d.]+)"\s+cy="([\d.]+)"\s+r="([\d.]+)""#)
let discs: [(x: Double, y: Double, r: Double)] = pattern
  .matches(in: svg, range: NSRange(svg.startIndex..., in: svg))
  .map { m in
    func num(_ i: Int) -> Double { Double(svg[Range(m.range(at: i), in: svg)!])! }
    return (num(1), num(2), num(3))
  }
guard discs.count == 7 else {
  fatalError("expected 7 discs in \(svgURL.path), found \(discs.count)")
}

let minX = discs.map { $0.x - $0.r }.min()!
let maxX = discs.map { $0.x + $0.r }.max()!
let minY = discs.map { $0.y - $0.r }.min()!
let maxY = discs.map { $0.y + $0.r }.max()!

let side: CGFloat = 60
let scale = side / CGFloat(max(maxX - minX, maxY - minY))
let centerX = (minX + maxX) / 2
let centerY = (minY + maxY) / 2

func render(_ name: String, rgb: (CGFloat, CGFloat, CGFloat)) throws {
  let url = outDir.appendingPathComponent(name)
  var box = CGRect(x: 0, y: 0, width: side, height: side)
  guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
    fatalError("could not open \(url.path)")
  }
  ctx.beginPDFPage(nil)
  ctx.setFillColor(CGColor(srgbRed: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255, alpha: 1))
  for d in discs {
    // SVG y grows down, PDF y grows up.
    let x = side / 2 + CGFloat(d.x - centerX) * scale
    let y = side / 2 - CGFloat(d.y - centerY) * scale
    let r = CGFloat(d.r) * scale
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
  }
  ctx.endPDFPage()
  ctx.closePDF()
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
try render("LaunchGlyph.pdf", rgb: (174, 174, 178))       // systemGray2, light
try render("LaunchGlyph-dark.pdf", rgb: (99, 99, 102))    // systemGray2, dark

let contents = """
{
  "images" : [
    {
      "filename" : "LaunchGlyph.pdf",
      "idiom" : "universal"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "filename" : "LaunchGlyph-dark.pdf",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "preserves-vector-representation" : true
  }
}

"""
try contents.write(to: outDir.appendingPathComponent("Contents.json"),
                   atomically: true, encoding: .utf8)
print("wrote \(outDir.path)")
