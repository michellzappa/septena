#!/usr/bin/env node
// Generates all 23 prebaked Septena Upright Compass iOS App Icon asset sets
// (1 Default `AppIcon` + 22 Alternates) inside `Septask/Assets.xcassets/`.
//
// Source of truth: `scripts/dial-svg.mjs`.
// Each `.appiconset` ships explicit 1024x1024 opaque RGB PNGs for both Light OS
// and Dark OS (`luminosity: dark`), so iOS handles Light/Dark Home Screen icons
// natively.
//
// Usage: node scripts/generate-app-icons.mjs

import fs from 'fs';
import os from 'os';
import path from 'path';
import { execFileSync } from 'child_process';
import { fileURLToPath } from 'url';
import { FRUIT_PALETTES, appIconSets, renderDialSVG } from './dial-svg.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '..');
const assetsDir = path.join(repoRoot, 'Septask', 'Assets.xcassets');

// The finish x colour matrix is shared with the website's brand page
// (septena-site scripts/sync-brand.mjs), so it lives in dial-svg.mjs.
const iconSets = appIconSets();
const paletteById = Object.fromEntries(FRUIT_PALETTES.map(p => [p.id, p]));

console.log(`Generating ${iconSets.length} AppIcon asset sets in ${path.relative(repoRoot, assetsDir)}…`);

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'septena-icons-'));
try {
  // 1. Write all SVG inputs (23 light + 23 dark = 46 SVGs)
  const svgFiles = [];
  const renderJobs = [];

  for (const item of iconSets) {
    const lightBase = `${item.setName}-1024`;
    const lightSvgPath = path.join(tmpDir, `${lightBase}.svg`);
    const lightSvg = renderDialSVG('septena-compass', item.palette, {
      shellMode: item.finish.shellMode,
      faceMode: 'white',
      mono: item.color.mono,
      fullBleed: true,
      size: 1024,
      uid: `l_${item.setName}`,
    });
    fs.writeFileSync(lightSvgPath, lightSvg, 'utf8');
    svgFiles.push(lightSvgPath);

    const darkBase = `${item.setName}-1024-dark`;
    const darkSvgPath = path.join(tmpDir, `${darkBase}.svg`);
    const darkSvg = renderDialSVG('septena-compass', item.palette, {
      shellMode: item.finish.shellMode,
      faceMode: 'black',
      mono: item.color.mono,
      fullBleed: true,
      size: 1024,
      uid: `d_${item.setName}`,
    });
    fs.writeFileSync(darkSvgPath, darkSvg, 'utf8');
    svgFiles.push(darkSvgPath);

    renderJobs.push({ item, lightBase, darkBase });
  }

  // 2. Batch rasterize all SVGs to 1024x1024 PNGs in one qlmanage call
  execFileSync('qlmanage', ['-t', '-s', '1024', '-o', tmpDir, ...svgFiles], { stdio: 'ignore' });

  // 3. Flatten every PNG to an exact 1024x1024 opaque RGB PNG (no alpha channel for App Store Connect).
  //    Primary `AppIcon` stays full 8-bit pristine quality. The 22 alternates
  //    are quantized to fewer levels per channel so Xcode's LZFSE asset
  //    catalog compresses them much better. A plain cut to few levels bands
  //    the dial's gradients, so the cut uses an 8x8 ordered (Bayer) dither:
  //    a repeating pattern still compresses well (random noise or error
  //    diffusion does not), and actool's downscale to Home Screen sizes
  //    averages the pattern back into a smooth gradient.
  //    ICON_QUANT_LEVELS (levels per channel) and ICON_DITHER=0 override the
  //    defaults for size experiments.
  const quantLevels = Number(process.env.ICON_QUANT_LEVELS ?? 32);
  const dither = process.env.ICON_DITHER !== '0';
  const flattenSwift = `
import Foundation
import AppKit
import CoreGraphics

let args = Array(CommandLine.arguments.dropFirst())
let size = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
let quantSteps = ${quantLevels - 1}
let dither = ${dither}
let bayer8: [Int] = [
   0, 32,  8, 40,  2, 34, 10, 42,
  48, 16, 56, 24, 50, 18, 58, 26,
  12, 44,  4, 36, 14, 46,  6, 38,
  60, 28, 52, 20, 62, 30, 54, 22,
   3, 35, 11, 43,  1, 33,  9, 41,
  51, 19, 59, 27, 49, 17, 57, 25,
  15, 47,  7, 39, 13, 45,  5, 37,
  63, 31, 55, 23, 61, 29, 53, 21,
]

@inline(__always)
func quant(_ v: UInt8, _ threshold: Int) -> UInt8 {
  // threshold is 0...63; plain rounding uses the midpoint 32.
  let idx = min(quantSteps, (Int(v) * quantSteps * 64 + threshold * 255) / (255 * 64))
  return UInt8((idx * 255 + quantSteps / 2) / quantSteps)
}

for path in args {
  let url = URL(fileURLWithPath: path)
  let name = url.lastPathComponent
  let isPrimary = name.hasPrefix("AppIcon-1024")
  var buf = [UInt8](repeating: 0, count: size * size * 4)
  guard let img = NSImage(contentsOf: url),
        let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
        let ctx = CGContext(
          data: &buf,
          width: size,
          height: size,
          bitsPerComponent: 8,
          bytesPerRow: size * 4,
          space: colorSpace,
          bitmapInfo: bitmapInfo
        ) else {
    fputs("Failed to load: \\(path)\\n", stderr)
    exit(1)
  }
  ctx.interpolationQuality = .high
  ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
  ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
  if !isPrimary {
    for y in 0..<size {
      for x in 0..<size {
        let t = dither ? bayer8[(y & 7) * 8 + (x & 7)] : 32
        let i = (y * size + x) * 4
        buf[i]   = quant(buf[i], t)
        buf[i+1] = quant(buf[i+1], t)
        buf[i+2] = quant(buf[i+2], t)
      }
    }
  }
  guard let outCG = ctx.makeImage() else { exit(1) }
  let rep = NSBitmapImageRep(cgImage: outCG)
  guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
  try data.write(to: url)
}
`;
  const swiftScript = path.join(tmpDir, 'flatten.swift');
  fs.writeFileSync(swiftScript, flattenSwift, 'utf8');
  const rawPngs = svgFiles.map(f => `${f}.png`);
  execFileSync('swift', [swiftScript, ...rawPngs], { stdio: 'inherit' });

  // 4. Write each .appiconset directory + Contents.json
  for (const job of renderJobs) {
    const { item, lightBase, darkBase } = job;
    const setDir = path.join(assetsDir, `${item.setName}.appiconset`);
    fs.mkdirSync(setDir, { recursive: true });

    const lightFilename = `${item.setName}-1024.png`;
    const darkFilename = `${item.setName}-1024-dark.png`;

    fs.copyFileSync(path.join(tmpDir, `${lightBase}.svg.png`), path.join(setDir, lightFilename));
    fs.copyFileSync(path.join(tmpDir, `${darkBase}.svg.png`), path.join(setDir, darkFilename));

    const contents = {
      images: [
        {
          filename: lightFilename,
          idiom: 'universal',
          platform: 'ios',
          size: '1024x1024',
        },
        {
          appearances: [
            {
              appearance: 'luminosity',
              value: 'dark',
            },
          ],
          filename: darkFilename,
          idiom: 'universal',
          platform: 'ios',
          size: '1024x1024',
        },
      ],
      info: {
        author: 'xcode',
        version: 1,
      },
    };
    fs.writeFileSync(path.join(setDir, 'Contents.json'), JSON.stringify(contents, null, 2) + '\n', 'utf8');
  }

  // 5. Also update watchOS AppIcon (1024px opaque full-bleed Default Compass)
  const watchIconPath = path.join(repoRoot, 'SeptaskWatch', 'Assets.xcassets', 'AppIcon.appiconset', 'AppIcon-1024.png');
  if (fs.existsSync(path.dirname(watchIconPath))) {
    fs.copyFileSync(path.join(assetsDir, 'AppIcon.appiconset', 'AppIcon-1024.png'), watchIconPath);
    console.log(`Updated watchOS icon -> ${path.relative(repoRoot, watchIconPath)}`);
  }

  // 6. Also generate macOS `Septask/AppIcon.icns` (squircle-clipped Default Compass)
  const macSvgPath = path.join(tmpDir, 'MacAppIcon.svg');
  const macSvg = renderDialSVG('septena-compass', paletteById.persimmon, {
    shellMode: 'black',
    faceMode: 'white',
    mono: false,
    fullBleed: false,
    size: 1024,
    uid: 'mac_appicon',
  });
  fs.writeFileSync(macSvgPath, macSvg, 'utf8');
  execFileSync('qlmanage', ['-t', '-s', '1024', '-o', tmpDir, macSvgPath], { stdio: 'ignore' });
  const mac1024Png = `${macSvgPath}.png`;
  const iconsetDir = path.join(tmpDir, 'AppIcon.iconset');
  fs.mkdirSync(iconsetDir, { recursive: true });
  const macSizes = [
    ['icon_16x16.png', 16],
    ['icon_16x16@2x.png', 32],
    ['icon_32x32.png', 32],
    ['icon_32x32@2x.png', 64],
    ['icon_128x128.png', 128],
    ['icon_128x128@2x.png', 256],
    ['icon_256x256.png', 256],
    ['icon_256x256@2x.png', 512],
    ['icon_512x512.png', 512],
    ['icon_512x512@2x.png', 1024],
  ];
  for (const [fname, px] of macSizes) {
    execFileSync('sips', ['-z', String(px), String(px), mac1024Png, '--out', path.join(iconsetDir, fname)], { stdio: 'ignore' });
  }
  const macIcnsPath = path.join(repoRoot, 'Septask', 'AppIcon.icns');
  execFileSync('iconutil', ['-c', 'icns', iconsetDir, '-o', macIcnsPath], { stdio: 'inherit' });
  console.log(`Updated macOS icon -> ${path.relative(repoRoot, macIcnsPath)}`);

  console.log(`Done! Generated ${iconSets.length} iOS .appiconset bundles (${iconSets.length * 2} opaque 1024px PNGs), watchOS icon, and macOS AppIcon.icns.`);
} finally {
  fs.rmSync(tmpDir, { recursive: true, force: true });
}
