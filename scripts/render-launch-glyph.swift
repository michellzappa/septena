#!/usr/bin/env swift
// Renders the iOS launch-screen glyph for the task app (Septask target) from
// the canonical Septena Upright Compass geometry (`tools/logo-builder/dial-svg.mjs`),
// so the boot screen wears a quiet monochrome vector version of the app icon.
//
//   swift scripts/render-launch-glyph.swift
//
// Output: Septask/Assets.xcassets/LaunchGlyph.imageset, two vector PDFs
// (light and dark appearance). Fitted into a 60 pt square with subtle
// systemGray2 tint (light #AEAEB2, dark #636366) on the system background.

import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
  ? CommandLine.arguments[1]
  : FileManager.default.currentDirectoryPath)
let outDir = root.appendingPathComponent("Septask/Assets.xcassets/LaunchGlyph.imageset")

let side: CGFloat = 60
// Canonical 1024-canvas dial geometry (matches tools/logo-builder/dial-svg.mjs)
let outerRingRadius: CGFloat = 376
let outerRingStroke: CGFloat = 34
let maxExtent = outerRingRadius + outerRingStroke / 2
let scale = (side * 0.5) / maxExtent
let mid = side * 0.5

@inline(__always)
func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
  // SVG y grows down from 512; PDF y grows up from mid.
  CGPoint(x: mid + (x - 512) * scale, y: mid - (y - 512) * scale)
}

func render(_ name: String, rgb: (CGFloat, CGFloat, CGFloat)) throws {
  let url = outDir.appendingPathComponent(name)
  var box = CGRect(x: 0, y: 0, width: side, height: side)
  guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
    fatalError("could not open \(url.path)")
  }
  ctx.beginPDFPage(nil)

  func color(alpha: CGFloat) -> CGColor {
    CGColor(srgbRed: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255, alpha: alpha)
  }

  // 1. Subtle compass bezel ring
  ctx.saveGState()
  ctx.setStrokeColor(color(alpha: 0.52))
  ctx.setLineWidth(outerRingStroke * scale)
  let rPx = outerRingRadius * scale
  ctx.strokeEllipse(in: CGRect(x: mid - rPx, y: mid - rPx, width: rPx * 2, height: rPx * 2))
  ctx.restoreGState()

  // 2. Six machined rounded dial ticks at k = 1...6 (7-way bearings)
  ctx.saveGState()
  ctx.setStrokeColor(color(alpha: 0.50))
  ctx.setLineWidth(26 * scale)
  ctx.setLineCap(.round)
  let step = 360.0 / 7.0
  for i in 1..<7 {
    let rad = (-90.0 + Double(i) * step) * .pi / 180.0
    let p0 = pt(512 + CGFloat(cos(rad)) * 258, 512 + CGFloat(sin(rad)) * 258)
    let p1 = pt(512 + CGFloat(cos(rad)) * 310, 512 + CGFloat(sin(rad)) * 310)
    ctx.move(to: p0)
    ctx.addLine(to: p1)
    ctx.strokePath()
  }
  ctx.restoreGState()

  // 3. Upright North compass pointer (-90°)
  ctx.saveGState()
  ctx.setFillColor(color(alpha: 1.0))
  let a0 = -90.0 * .pi / 180.0
  let aL = (-90.0 - 11.2) * .pi / 180.0
  let aR = (-90.0 + 11.2) * .pi / 180.0
  let tip   = pt(512 + CGFloat(cos(a0)) * 336, 512 + CGFloat(sin(a0)) * 336)
  let right = pt(512 + CGFloat(cos(aR)) * 238, 512 + CGFloat(sin(aR)) * 238)
  let notch = pt(512 + CGFloat(cos(a0)) * 260, 512 + CGFloat(sin(a0)) * 260)
  let left  = pt(512 + CGFloat(cos(aL)) * 238, 512 + CGFloat(sin(aL)) * 238)
  ctx.beginPath()
  ctx.move(to: tip)
  ctx.addLine(to: right)
  ctx.addLine(to: notch)
  ctx.addLine(to: left)
  ctx.closePath()
  ctx.fillPath()
  ctx.restoreGState()

  // 4. Sculpted checkmark collinear to the 2nd tick (-38.57°): M 377 511 L 460 598 L 639 426
  ctx.saveGState()
  ctx.setStrokeColor(color(alpha: 1.0))
  ctx.setLineWidth(68 * scale)
  ctx.setLineCap(.round)
  ctx.setLineJoin(.round)
  ctx.beginPath()
  ctx.move(to: pt(377, 511))
  ctx.addLine(to: pt(460, 598))
  ctx.addLine(to: pt(639, 426))
  ctx.strokePath()
  ctx.restoreGState()

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
