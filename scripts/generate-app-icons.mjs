#!/usr/bin/env node
// Generates all 31 prebaked Septena Upright Compass iOS App Icon asset sets
// (1 Default `AppIcon` + 30 Alternates) inside `Septask/Assets.xcassets/`.
//
// Source of truth: `tools/logo-builder/dial-svg.mjs`.
// Each `.appiconset` ships explicit 1024x1024 opaque RGB PNGs for both Light OS
// and Dark OS (`luminosity: dark`), so iOS handles Light/Dark Home Screen icons
// natively without auto-darkening Stealth icons.
//
// Usage: node scripts/generate-app-icons.mjs

import fs from 'fs';
import os from 'os';
import path from 'path';
import { execFileSync } from 'child_process';
import { fileURLToPath } from 'url';
import { FRUIT_PALETTES, renderDialSVG } from '../tools/logo-builder/dial-svg.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '..');
const assetsDir = path.join(repoRoot, 'Septask', 'Assets.xcassets');

const COLOR_SPECS = [
  { id: 'persimmon', suffix: 'Persimmon', paletteId: 'persimmon', mono: false },
  { id: 'haskap',    suffix: 'Haskap',    paletteId: 'haskap',    mono: false },
  { id: 'tamarillo', suffix: 'Tamarillo', paletteId: 'tamarillo', mono: false },
  { id: 'yuzu',      suffix: 'Yuzu',      paletteId: 'yuzu',      mono: false },
  { id: 'carambola', suffix: 'Carambola', paletteId: 'carambola', mono: false },
  { id: 'acai',      suffix: 'Acai',      paletteId: 'acai',      mono: false },
  { id: 'pitaya',    suffix: 'Pitaya',    paletteId: 'pitaya',    mono: false },
  { id: 'mono',      suffix: 'Mono',      paletteId: 'jabuticaba', mono: true },
];

const FINISH_SPECS = [
  { id: 'obsidian', prefix: 'Obsidian', shellMode: 'black' },
  { id: 'ceramic',  prefix: 'Ceramic',  shellMode: 'white' },
  { id: 'framed',   prefix: 'Framed',   shellMode: 'color' },
  { id: 'stealth',  prefix: 'Stealth',  shellMode: 'stealth' },
];

const paletteById = Object.fromEntries(FRUIT_PALETTES.map(p => [p.id, p]));

// Build the exact 31-asset list (4 finishes x 8 colors, minus duplicate Framed+Mono)
const iconSets = [];
for (const fin of FINISH_SPECS) {
  for (const col of COLOR_SPECS) {
    if (fin.id === 'framed' && col.mono) continue;
    const isDefault = fin.id === 'obsidian' && col.id === 'persimmon';
    const setName = isDefault ? 'AppIcon' : `AppIcon${fin.prefix}${col.suffix}`;
    iconSets.push({
      setName,
      finish: fin,
      color: col,
      palette: paletteById[col.paletteId],
    });
  }
}

console.log(`Generating ${iconSets.length} AppIcon asset sets in ${path.relative(repoRoot, assetsDir)}…`);

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'septena-icons-'));
try {
  // 1. Write all unique SVG inputs (31 light + 23 dark = 54 SVGs; Stealth reuses its dark render for both slots)
  const svgFiles = [];
  const renderJobs = [];

  for (const item of iconSets) {
    const lightBase = `${item.setName}-1024`;
    const lightSvgPath = path.join(tmpDir, `${lightBase}.svg`);
    const lightSvg = renderDialSVG('septena-compass', item.palette, {
      shellMode: item.finish.shellMode,
      faceMode: item.finish.id === 'stealth' ? 'black' : 'white',
      mono: item.color.mono,
      fullBleed: true,
      size: 1024,
      uid: `l_${item.setName}`,
    });
    fs.writeFileSync(lightSvgPath, lightSvg, 'utf8');
    svgFiles.push(lightSvgPath);

    let darkSvgPath = lightSvgPath;
    let darkBase = lightBase;
    if (item.finish.id !== 'stealth') {
      darkBase = `${item.setName}-1024-dark`;
      darkSvgPath = path.join(tmpDir, `${darkBase}.svg`);
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
    }

    renderJobs.push({ item, lightBase, darkBase });
  }

  // 2. Batch rasterize all SVGs to 1024x1024 PNGs in one qlmanage call
  execFileSync('qlmanage', ['-t', '-s', '1024', '-o', tmpDir, ...svgFiles], { stdio: 'ignore' });

  // 3. Flatten every PNG to an exact 1024x1024 opaque RGB PNG (no alpha channel for App Store Connect).
  //    Primary `AppIcon` stays full 8-bit pristine quality; the 30 alternates
  //    use exact 5-bit/channel (32-level, 0...255) noise-free quantization so
  //    Xcode's LZFSE Asset Catalog shrinks ~5x (~10 MB thinned on iPhone instead
  //    of ~46 MB) with zero visible loss at Home Screen size.
  const flattenSwift = `
import Foundation
import AppKit
import CoreGraphics

let args = Array(CommandLine.arguments.dropFirst())
let size = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
let quantLevels = 31

@inline(__always)
func quant5(_ v: UInt8) -> UInt8 {
  let idx = (Int(v) * quantLevels + 127) / 255
  return UInt8((idx * 255 + quantLevels / 2) / quantLevels)
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
    for i in stride(from: 0, to: buf.count, by: 4) {
      buf[i]   = quant5(buf[i])
      buf[i+1] = quant5(buf[i+1])
      buf[i+2] = quant5(buf[i+2])
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
